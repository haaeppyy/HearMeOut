import AVFoundation
import Foundation

/// Output target for TTS-rendered audio. Implementations must tolerate being
/// driven from a background queue.
///
/// Call ordering is guaranteed: on one serial pipeline, `begin` precedes all
/// `emit`s of an utterance and `end` follows the last one — including across a
/// rapid stop-then-respeak, where the previous `end` is ordered before the new
/// `begin`.
///
/// Adapted from EchoSign's TTSSinks with two additions the original
/// `TypeAndSpeakController` already assumed but the protocol lacked
/// (`onFramesPushed`, `flush`) — the version skew is resolved here rather
/// than in the controller, and `AgoraService` references are repointed at
/// `AgoraCallManager`.
protocol TTSAudioSink: AnyObject {
    /// The format this sink consumes. The service converts all rendered audio
    /// to it before emitting, so each sink controls its own fidelity (e.g. the
    /// test speaker plays full-rate while Agora's custom track needs 16 kHz).
    var preferredFormat: AVAudioFormat { get }

    /// Fires with the count of target-timeline frames actually handed to the
    /// output (scheduled or pushed). `TypeAndSpeakController` drives word
    /// highlighting off this.
    var onFramesPushed: ((AVAudioFrameCount) -> Void)? { get set }

    /// Called once before an utterance's first buffer (e.g. duck the mic).
    func begin()
    /// One converted chunk in `preferredFormat`.
    func emit(_ buffer: AVAudioPCMBuffer)
    /// All buffers delivered (or the utterance was cancelled/stopped).
    func end()
    /// Drop anything generated-but-not-yet-output (stop button semantics).
    /// Must also leave the sink in a state where the next `begin` works.
    func flush()
}

/// Production sink: injects rendered speech into the Agora call's outgoing
/// custom audio track while the microphone is muted.
final class AgoraPushSink: TTSAudioSink {

    private weak var agora: AgoraCallManager?
    var onFramesPushed: ((AVAudioFrameCount) -> Void)?

    /// Agora's custom track and playback-caption pipeline run at 16 kHz mono.
    let preferredFormat = AVAudioFormat(
        standardFormatWithSampleRate: Double(AgoraCallManager.sampleRate),
        channels: 1
    )!

    init(agora: AgoraCallManager) {
        self.agora = agora
    }

    func begin() {
        // Duck the mic capture only — the custom track must stay published.
        agora?.setMicrophoneCaptureMuted(true)
    }

    func emit(_ buffer: AVAudioPCMBuffer) {
        // `AgoraCallManager` re-chunks into 10 ms frames internally.
        let frames = buffer.frameLength
        if agora?.pushExternalAudioFrame(buffer) == true {
            onFramesPushed?(frames)
        }
    }

    func end() {
        agora?.setMicrophoneCaptureMuted(false)
    }

    func flush() {
        // Synchronous push: nothing is ever queued inside this sink, so
        // dropping pending output is a no-op. Mic state is owned by
        // begin()/end(), not flush().
    }
}

/// Test/debug sink: plays rendered speech through the device speaker so the
/// synthesis pipeline can be validated without an active call.
final class SpeakerSink: NSObject, TTSAudioSink {

    var onError: ((String) -> Void)?
    var onFramesPushed: ((AVAudioFrameCount) -> Void)?

    /// Reports cumulative played frames and the current output route
    /// (e.g. "Speaker") so the test UI can show where audio actually went.
    var onStats: ((_ playedFrames: Int, _ routeDescription: String) -> Void)?

    /// Full-bandwidth local playback — the 16 kHz ceiling only exists for the
    /// Agora custom-track path.
    let preferredFormat = AVAudioFormat(
        standardFormatWithSampleRate: 48000,
        channels: 1
    )!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isEngineRunning = false

    /// Tracks scheduled buffers so `end` drains playback instead of cutting it.
    private let drainGroup = DispatchGroup()

    private let statsLock = NSLock()
    private var playedFrameCount = 0

    override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: preferredFormat)
    }

    func begin() {
        statsLock.lock()
        playedFrameCount = 0
        statsLock.unlock()

        if !isEngineRunning {
            do {
                try engine.start()
                isEngineRunning = true
            } catch {
                onError?("Couldn't start local audio playback: \(error.localizedDescription)")
                return
            }
        }
        player.play()
        reportStats()
    }

    func emit(_ buffer: AVAudioPCMBuffer) {
        guard isEngineRunning else { return }
        let frameCount = Int(buffer.frameLength)
        onFramesPushed?(buffer.frameLength)
        drainGroup.enter()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else {
                return
            }
            self.statsLock.lock()
            self.playedFrameCount += frameCount
            self.statsLock.unlock()
            self.reportStats()
            self.drainGroup.leave()
        }
    }

    func end() {
        guard isEngineRunning else { return }
        reportStats()
        drainGroup.notify(queue: .main) { [weak self] in
            guard let self, self.isEngineRunning else { return }
            self.player.stop()
            self.engine.stop()
            self.isEngineRunning = false
        }
    }

    func flush() {
        // AVAudioPlayerNode has no queue-flush: stopping drops scheduled
        // buffers. end() afterwards re-reports and shuts down cleanly.
        guard isEngineRunning else { return }
        player.stop()
    }

    private func reportStats() {
        statsLock.lock()
        let frames = playedFrameCount
        statsLock.unlock()

        let route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "unknown"
        DispatchQueue.main.async { [weak self] in
            self?.onStats?(frames, route)
        }
    }
}
