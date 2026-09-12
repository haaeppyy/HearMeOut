import AVFoundation
import Combine
import Foundation
import os

/// Counters for one utterance's journey through the render pipeline, surfaced
/// via `onStats` so diagnostics can pinpoint exactly where audio dies:
/// `write` callbacks → PCM casts → conversion → sink.
struct TTSStats: Equatable, Sendable {
    /// Invocations of the `write` handler, before any type checks.
    var rawCallbacks = 0
    /// Handlers that delivered an `AVAudioPCMBuffer`.
    var pcmBuffers = 0
    /// Frames received from the synthesizer (pre-conversion).
    var sourceFrames = 0
    /// Frames handed to the sink (post-conversion).
    var emittedFrames = 0
}

/// "Type & Speak" — renders typed text offline via `AVSpeechSynthesizer.write`
/// and streams the converted PCM to a `TTSAudioSink`.
///
/// `write(_:toBufferCallback:)` is asynchronous: buffers arrive on an internal
/// queue while synthesis progresses, and `speechSynthesizer(_:didFinish:)`
/// marks the end. The service therefore:
/// - converts each incoming buffer to 16 kHz mono Float32 as it arrives and
///   accumulates it,
/// - opens the sink and hands over all samples only *after* synthesis settles
///   — a running local audio engine during rendering is a known way to starve
///   `write`'s callback stream,
/// - finalizes from delegate finish/cancel events matched per-utterance, with
///   a timer fallback if the synthesizer never reports,
/// - retries once with the system voice when an attempt renders zero audio
///   (nil-voice `write` is a known instant-finish trap).
///
/// `speakDirectly(_:)` bypasses all of this with plain audible synthesis for
/// speaker/session sanity checks.
final class TTSService: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false
    var onCompletion: (() -> Void)?
    var onError: ((String) -> Void)?

    /// Stats snapshots after each pipeline link (invoked on main).
    var onStats: ((TTSStats) -> Void)?

    private let sink: TTSAudioSink
    private let synthesizer = AVSpeechSynthesizer()

    /// All sink interaction happens here, in FIFO order, so `end` can never
    /// overtake pending `emit`s of the same or a preceding utterance.
    private let renderQueue = DispatchQueue(label: "echo.tts.render", qos: .userInitiated)

    /// The sink's declared format — every emitted buffer converts to this.
    /// Full-rate for the test speaker, 16 kHz for Agora's custom track.
    private let targetFormat: AVAudioFormat

    /// When set (test-screen voice picker), resolves via
    /// `AVSpeechSynthesisVoice(identifier:)`. Nil keeps the en-US default on
    /// attempt 1 and the system default voice on attempt 2.
    var voiceIdentifier: String?

    private struct LockedState: Sendable {
        var generation = 0
        var stats = TTSStats()
    }

    /// Generation + stats are touched from main/render/synth queues; the lock
    /// keeps every transition atomic.
    private let stateLock = OSAllocatedUnfairLock<LockedState>(initialState: LockedState())
    private var generation: Int {
        stateLock.withLock { $0.generation }
    }

    private struct UtteranceInfo {
        let generation: Int
        let isPipeline: Bool
        let attempt: Int
        let text: String
    }

    /// Main-thread-only. Maps live utterances so finish/cancel events settle
    /// *their* utterance's generation instead of racing a newer one (a stale
    /// `didCancel` must never finalize a just-started utterance).
    private var utterances: [ObjectIdentifier: UtteranceInfo] = [:]
    private var activeIsPipeline = false
    private var fallbackTimer: Timer?

    /// Rebuilt when the voice's buffer format changes; reused across buffers of
    /// one utterance so converter state persists. Confined to `renderQueue`.
    private var converter: AVAudioConverter?

    /// Converted 16 kHz mono samples accumulated while `write` renders, then
    /// flushed to the sink in one go at settle time. Confined to `renderQueue`.
    private var pendingSamples: [Float] = []

    init(sink: TTSAudioSink) {
        self.sink = sink
        self.targetFormat = sink.preferredFormat
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Pipeline path: renders offline and streams PCM to the sink (no local
    /// playback). This is what production calls use via `AgoraPushSink`.
    func speak(_ text: String) {
        startPipeline(text: text, attempt: 1)
    }

    /// Diagnostic bypass: plain `synthesizer.speak()` through the device
    /// speaker, independent of the custom render pipeline.
    func speakDirectly(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        teardownActive()

        let currentGeneration = bumpGeneration(resettingStats: true)
        isSpeaking = true
        activeIsPipeline = false

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        register(utterance, generation: currentGeneration, isPipeline: false, attempt: 2, text: trimmed)

        scheduleFallback(timeout: fallbackTimeout(for: trimmed), for: currentGeneration)
        pushStatsSnapshot()
        synthesizer.speak(utterance)
    }

    func stop() {
        teardownActive()
    }

    /// Current cumulative stats (thread-safe snapshot).
    func snapshotStats() -> TTSStats {
        stateLock.withLock { $0.stats }
    }

    // MARK: - Pipeline utterance

    private func startPipeline(text: String, attempt: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        teardownActive()

        let currentGeneration = bumpGeneration(resettingStats: true)
        // NOTE: the sink is deliberately NOT opened here. Starting the local
        // audio engine while `write` renders is a known way to starve its
        // callback stream; the sink opens at settle time instead (see `finish`).

        isSpeaking = true
        activeIsPipeline = true

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let identifier = voiceIdentifier,
           let selected = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = selected
        } else if attempt == 1, let enUSVoice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = enUSVoice
        } // attempt 2 without a picker choice deliberately uses the system default
        register(utterance, generation: currentGeneration, isPipeline: true, attempt: attempt, text: trimmed)

        scheduleFallback(timeout: fallbackTimeout(for: trimmed), for: currentGeneration)

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }
            self.stateLock.withLock { $0.stats.rawCallbacks += 1 }

            guard let pcm = buffer as? AVAudioPCMBuffer else {
                self.pushStatsSnapshot()
                return
            }
            self.stateLock.withLock {
                $0.stats.pcmBuffers += 1
                $0.stats.sourceFrames += Int(pcm.frameLength)
            }
            self.pushStatsSnapshot()

            self.renderQueue.async {
                guard self.generation == currentGeneration else { return }
                self.convertAndEmit(pcm)
            }
        }
        pushStatsSnapshot()
    }

    // MARK: - Utterance lifecycle

    /// Delegate-driven settle. No-ops for unknown/superseded utterances.
    private func settle(utterance: AVSpeechUtterance) {
        let info = utterances.removeValue(forKey: ObjectIdentifier(utterance))
        guard let info, info.generation == generation else { return }
        finish(info: info)
    }

    /// Fallback when the synthesizer never reports; settles whatever the
    /// current generation is.
    private func handleFallbackTimeout() {
        guard isSpeaking else { return }
        let currentGeneration = generation
        print("[TTS] fallback timeout fired (generation \(currentGeneration))")

        if let entry = utterances.first(where: { $0.value.generation == currentGeneration }) {
            utterances.removeValue(forKey: entry.key)
            finish(info: entry.value)
        } else {
            finish(info: UtteranceInfo(
                generation: currentGeneration,
                isPipeline: activeIsPipeline,
                attempt: 2,
                text: ""
            ))
        }
    }

    private func finish(info: UtteranceInfo) {
        cancelFallback()
        isSpeaking = false

        // Synthesis is done — the engine can now safely run. Open the sink,
        // hand over every accumulated sample, then close it, all on the render
        // queue so ordering with any concurrent stop/respeak holds.
        renderQueue.async { [weak self] in
            guard let self else { return }
            guard !self.pendingSamples.isEmpty else {
                self.sink.end()
                return
            }
            self.sink.begin()
            self.flushPendingSamples()
            self.sink.end()
        }
        onCompletion?()

        guard info.isPipeline else { return }
        let stats = snapshotStats()
        if stats.emittedFrames == 0 {
            if info.attempt < 2, !info.text.isEmpty {
                onError?("No audio rendered — retrying with the system default voice…")
                startPipeline(text: info.text, attempt: 2)
            } else {
                onError?("Synthesis produced no audio. Use 'Speaker sanity' to verify plain playback works.")
            }
        }
    }

    /// renderQueue-confined. Drains the converter's held-back tail first, then
    /// hands the whole utterance to the sink as one buffer.
    private func flushPendingSamples() {
        drainConverterTail()

        let sampleCount = pendingSamples.count
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              ) else {
            pendingSamples.removeAll(keepingCapacity: false)
            return
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        pendingSamples.withUnsafeBufferPointer { samples in
            if let dst = buffer.floatChannelData?[0] {
                dst.update(from: samples.baseAddress!, count: sampleCount)
            }
        }
        sink.emit(buffer)
        pendingSamples.removeAll(keepingCapacity: false)
    }

    /// Signals end-of-stream once and pumps until the converter reports it is
    /// done, capturing any samples held back by filter/priming latency. The
    /// converter is recreated per utterance, so ending it here is safe.
    private func drainConverterTail() {
        guard let converter else { return }

        // 100 ms chunks at the target rate.
        let capacity = AVAudioFrameCount(Int(targetFormat.sampleRate) / 10)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var sentEndOfStream = false
        for _ in 0..<8 {
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if sentEndOfStream {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                sentEndOfStream = true
                outStatus.pointee = .endOfStream
                return nil
            }

            if out.frameLength > 0, let channelData = out.floatChannelData?[0] {
                accumulate(out, channelData: channelData)
            }
            if let error {
                print("[TTS] tail-drain conversion error: \(error)")
            }

            if status == .endOfStream || status == .error || out.frameLength == 0 {
                break
            }
        }
    }

    // MARK: - Conversion (renderQueue-confined)

    private func convertAndEmit(_ source: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var handedOff = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if handedOff {
                // More buffers follow this one — `.noDataNow` keeps the
                // converter's internal state alive across calls. Signaling
                // `.endOfStream` here would flush it and permanently stall
                // every subsequent buffer.
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOff = true
            outStatus.pointee = .haveData
            return source
        }

        guard status == .haveData || status == .inputRanDry,
              out.frameLength > 0,
              error == nil,
              let channelData = out.floatChannelData?[0] else {
            if let error {
                print("[TTS] conversion error: \(error)")
            }
            return
        }

        accumulate(out, channelData: channelData)
    }

    private func accumulate(_ buffer: AVAudioPCMBuffer, channelData: UnsafeMutablePointer<Float>) {
        let frameCount = Int(buffer.frameLength)
        stateLock.withLock { $0.stats.emittedFrames += frameCount }
        pushStatsSnapshot()
        pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameCount))
    }

    // MARK: - Shared plumbing

    private func teardownActive() {
        cancelFallback()
        _ = bumpGeneration(resettingStats: false)
        synthesizer.stopSpeaking(at: .immediate)
        utterances.removeAll()
        activeIsPipeline = false

        renderQueue.async {
            self.converter = nil
            self.pendingSamples.removeAll(keepingCapacity: false)
            self.sink.end()
        }
        isSpeaking = false
        pushStatsSnapshot()
    }

    private func bumpGeneration(resettingStats: Bool) -> Int {
        stateLock.withLock { state in
            state.generation += 1
            if resettingStats {
                state.stats = TTSStats()
            }
            return state.generation
        }
    }

    private func register(
        _ utterance: AVSpeechUtterance,
        generation: Int,
        isPipeline: Bool,
        attempt: Int,
        text: String
    ) {
        utterances[ObjectIdentifier(utterance)] = UtteranceInfo(
            generation: generation,
            isPipeline: isPipeline,
            attempt: attempt,
            text: text
        )
    }

    private func pushStatsSnapshot() {
        let snapshot = snapshotStats()
        DispatchQueue.main.async { [weak self] in
            self?.onStats?(snapshot)
        }
    }

    // MARK: - Fallback timer

    /// ~10 chars/sec at the default rate, clamped to sane bounds.
    private func fallbackTimeout(for text: String) -> TimeInterval {
        min(60, max(8, Double(text.count) / 10.0))
    }

    private func scheduleFallback(timeout: TimeInterval, for generationValue: Int) {
        cancelFallback()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            _ = generationValue
            self.handleFallbackTimeout()
        }
    }

    private func cancelFallback() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.settle(utterance: utterance) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.settle(utterance: utterance) }
    }
}
