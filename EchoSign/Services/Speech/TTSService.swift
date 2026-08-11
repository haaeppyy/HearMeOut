import AVFoundation
import Combine
import Foundation

/// "Type & Speak" — renders typed text offline via `AVSpeechSynthesizer.write`
/// instead of playing it on the device speaker, then pushes the PCM into the
/// call's outgoing stream through `AgoraService`'s custom audio track.
///
/// While synthesized audio is being pushed, the local microphone is muted so the
/// TTS doesn't overlap/garble with live mic input; it's unmuted when done.
///
/// `write(_:toBufferCallback:)` renders synchronously: `AVAudioBuffer`s are
/// delivered during the call and the call returns when the whole utterance has
/// been produced (there is no nil/"done" sentinel in this SDK). So buffered
/// samples are collected inline, and the push job is enqueued *after* `write`
/// returns to guarantee ordering.
final class TTSService: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false
    var onCompletion: (() -> Void)?
    var onError: ((String) -> Void)?

    private let agora: AgoraService
    private let synthesizer = AVSpeechSynthesizer()

    /// Push work happens here so the calling thread stays responsive.
    private let pushQueue = DispatchQueue(label: "echo.tts.push", qos: .userInitiated)

    /// 16 kHz mono Float32 — the format `AgoraService.pushExternalAudioFrame` expects.
    private let targetFormat = AVAudioFormat(
        standardFormatWithSampleRate: Double(AgoraService.sampleRate),
        channels: 1
    )!

    /// Accumulated, converted samples for the in-flight utterance.
    /// Written on the main thread (inside the synchronous `write` callback),
    /// read on `pushQueue` after `write` returns — ordered by queue enqueue.
    private var master: [Float] = []
    private var converter: AVAudioConverter?

    /// Bumped on every new utterance / stop so stale callbacks are ignored.
    private var activeGeneration = 0

    init(agora: AgoraService) {
        self.agora = agora
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()

        let generation = newGeneration()

        agora.muteLocalAudio(true)
        isSpeaking = true

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self,
                  let pcm = buffer as? AVAudioPCMBuffer,
                  self.activeGeneration == generation else { return }
            self.master.append(contentsOf: self.samples(from: pcm))
        }

        // `write` has returned → every sample for this utterance is buffered.
        // Enqueue the push job now so it runs after all the collections above.
        pushQueue.async { [weak self] in
            guard let self else { return }
            guard generation == self.activeGeneration else { return }
            self.finish(generation: generation)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        activeGeneration += 1
        master.removeAll(keepingCapacity: true)
        converter = nil
        agora.muteLocalAudio(false)
        isSpeaking = false
    }

    // MARK: - Conversion

    private func newGeneration() -> Int {
        activeGeneration += 1
        master.removeAll(keepingCapacity: true)
        converter = nil
        return activeGeneration
    }

    /// Convert one voice buffer (sample rate/format varies per voice and can
    /// change between utterances) to the 16 kHz mono target and return its
    /// samples.
    private func samples(from source: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || converter?.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: targetFormat)
        }
        guard let converter else { return [] }

        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }

        var handedOff = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if handedOff {
                outStatus.pointee = .endOfStream
                return nil
            }
            handedOff = true
            outStatus.pointee = .haveData
            return source
        }

        guard (status == .haveData || status == .inputRanDry),
              out.frameLength > 0,
              let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    // MARK: - Push & teardown

    /// Push the accumulated speech to Agora in 10 ms (160-sample) chunks.
    private func finish(generation: Int) {
        guard generation == activeGeneration else { return }

        let chunk = AgoraService.samplesPer10ms
        var offset = 0
        while offset < master.count {
            let count = min(chunk, master.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(count)
            ) else { break }
            buffer.frameLength = AVAudioFrameCount(count)

            if let dst = buffer.floatChannelData?[0] {
                for i in 0..<count {
                    dst[i] = master[offset + i]
                }
            }
            _ = agora.pushExternalAudioFrame(buffer)
            offset += count
        }

        agora.muteLocalAudio(false)
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.onCompletion?()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    // Safety net: if the synthesizer reports finish/cancel on its own, make sure
    // we don't stay muted or stuck. (The `write` pipeline normally handles this.)
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        handleSynthesizerSettled()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        handleSynthesizerSettled()
    }

    private func handleSynthesizerSettled() {
        DispatchQueue.main.async {
            guard self.isSpeaking else { return }
            self.activeGeneration += 1
            self.master.removeAll(keepingCapacity: true)
            self.converter = nil
            self.agora.muteLocalAudio(false)
            self.isSpeaking = false
        }
    }
}