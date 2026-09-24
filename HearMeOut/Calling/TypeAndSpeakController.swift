import AVFoundation
import Combine

/// In-call "Type & Speak": sender-side synthesis with word-level highlighting
/// and an authoritative stop button.
///
/// Buffers are converted to `sink.preferredFormat` before ever reaching
/// `emit` — the Agora custom track silently rejects anything that isn't
/// already 16 kHz mono, and `AVSpeechSynthesizer.write` does not render at
/// that rate natively.
///
/// Unlike `TTSService`'s "accumulate everything, flush once at the end"
/// strategy (which exists to avoid starving `write()`'s callback stream by
/// starting a *local AVAudioEngine* mid-render), this emits incrementally in
/// real time: `AgoraPushSink` doesn't start an engine, it forwards
/// already-converted bytes into Agora's own running engine — and incremental
/// emission is required for word highlighting to track actual playback.
///
/// Ported from EchoSign's TypeAndSpeakController (no logic changes).
final class TypeAndSpeakController: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false
    @Published private(set) var highlightedRange: NSRange?
    @Published private(set) var currentText = ""

    /// Fires per word, once that word has actually been sent to the sink —
    /// same timing as `highlightedRange`. Callers may ship the text over RTM
    /// for receiver-side captions alongside the audio.
    var onWordBoundary: ((NSRange, String) -> Void)?

    var voiceIdentifier: String?

    private let synthesizer = AVSpeechSynthesizer()
    private let sink: TTSAudioSink
    private let targetFormat: AVAudioFormat
    private let renderQueue = DispatchQueue(label: "hearmeout.typeandspeak.render", qos: .userInitiated)

    // Reused across buffers of one utterance so converter state persists;
    // confined to renderQueue, same discipline as TTSService.
    private var converter: AVAudioConverter?

    // Word-boundary events are recorded against *source* (pre-conversion)
    // frame offsets, since that's the synthesizer's own timeline. They're
    // compared against pushed frames in the *target* timeline by scaling
    // with the sample-rate ratio. This is an approximation — good enough
    // for word-level granularity.
    private var pendingWordEvents: [(sourceFrameOffset: AVAudioFrameCount, range: NSRange)] = []
    private var sourceFramesGeneratedSoFar: AVAudioFrameCount = 0
    private var targetFramesPushedSoFar: AVAudioFrameCount = 0
    private var conversionRatio: Double = 1.0
    private var stopped = false
    private var sinkOpened = false

    init(sink: TTSAudioSink) {
        self.sink = sink
        self.targetFormat = sink.preferredFormat
        super.init()
        synthesizer.delegate = self
        var mutableSink = sink
        mutableSink.onFramesPushed = { [weak self] frames in
            self?.advanceHighlight(by: frames)
        }
    }

    /// Sending a new message while one is still in flight replaces it rather
    /// than queueing — if the sender retyped or corrected something, the old
    /// version should never still reach the other party just because it was
    /// "next in line."
    func speak(_ text: String) {
        stop()
        stopped = false
        currentText = text
        isSpeaking = true
        pendingWordEvents.removeAll()
        sourceFramesGeneratedSoFar = 0
        targetFramesPushedSoFar = 0
        sinkOpened = false

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let identifier = voiceIdentifier,
           let selected = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = selected
        } else if let enUSVoice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = enUSVoice
        }

        synthesizer.write(utterance) { [weak self] avBuffer in
            guard let self, !self.stopped,
                  let pcm = avBuffer as? AVAudioPCMBuffer,
                  pcm.frameLength > 0 else { return }

            self.renderQueue.async {
                guard !self.stopped else { return }
                self.sourceFramesGeneratedSoFar += pcm.frameLength
                self.conversionRatio = self.targetFormat.sampleRate / pcm.format.sampleRate
                self.convertAndEmit(pcm)
            }
        }
    }

    /// The pause/stop button. Three things have to happen together:
    /// silence the synthesizer so no more buffers get generated, flush the
    /// sink's queue so anything already generated-but-not-yet-sent doesn't
    /// still play, and close the sink (unducking the mic) so a stopped
    /// message doesn't leave capture muted.
    func stop() {
        guard isSpeaking else { return }
        stopped = true
        synthesizer.stopSpeaking(at: .immediate)
        sink.flush()
        if sinkOpened {
            sink.end()
            sinkOpened = false
        }
        converter = nil
        isSpeaking = false
        highlightedRange = nil
        pendingWordEvents.removeAll()
    }

    // MARK: - renderQueue-confined

    private func convertAndEmit(_ source: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: targetFormat)
        }
        guard let converter else { return }

        let capacity = AVAudioFrameCount(Double(source.frameLength) * conversionRatio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var handedOff = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if handedOff {
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOff = true
            outStatus.pointee = .haveData
            return source
        }

        guard status == .haveData || status == .inputRanDry,
              out.frameLength > 0,
              error == nil else {
            if let error {
                print("[TypeAndSpeak] conversion error: \(error)")
            }
            return
        }

        if !sinkOpened {
            sink.begin()
            sinkOpened = true
        }
        sink.emit(out)
    }

    private func advanceHighlight(by pushedTargetFrames: AVAudioFrameCount) {
        targetFramesPushedSoFar += pushedTargetFrames
        while let next = pendingWordEvents.first {
            let scaledOffset = AVAudioFrameCount(Double(next.sourceFrameOffset) * conversionRatio)
            guard scaledOffset <= targetFramesPushedSoFar else { break }
            highlightedRange = next.range
            onWordBoundary?(next.range, currentText)
            pendingWordEvents.removeFirst()
        }
    }

    // MARK: - Settle

    private func settle() {
        guard !stopped, isSpeaking else { return }
        renderQueue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.sinkOpened {
                    self.sink.end()
                    self.sinkOpened = false
                }
                self.isSpeaking = false
                self.highlightedRange = nil
            }
        }
    }
}

extension TypeAndSpeakController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard !stopped else { return }
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.pendingWordEvents.append((sourceFrameOffset: self.sourceFramesGeneratedSoFar, range: characterRange))
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.settle() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.settle() }
    }
}
