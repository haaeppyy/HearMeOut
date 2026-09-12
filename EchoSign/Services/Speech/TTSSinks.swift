import AVFoundation
import Foundation

/// Output target for TTS-rendered audio. The service hands the sink 16 kHz /
/// mono / Float32 buffers as they stream out of `AVSpeechSynthesizer.write`,
/// so implementations must tolerate being driven from a background queue.
///
/// Call ordering is guaranteed: on one serial pipeline, `begin` precedes all
/// `emit`s of an utterance and `end` follows the last one — including across a
/// rapid stop-then-respeak, where the previous `end` is ordered before the new
/// `begin`.
protocol TTSAudioSink: AnyObject {
    /// The format this sink consumes. The service converts all rendered audio
    /// to it before emitting, so each sink controls its own fidelity (e.g. the
    /// test speaker plays full-rate while Agora's custom track needs 16 kHz).
    var preferredFormat: AVAudioFormat { get }

    /// Called once before an utterance's first buffer (e.g. duck the mic).
    func begin()
    /// One converted chunk in `preferredFormat`.
    func emit(_ buffer: AVAudioPCMBuffer)
    /// All buffers delivered (or the utterance was cancelled/stopped).
    func end()

    /// Discards queued-but-not-yet-sent buffers. Makes stop() authoritative
    /// — without it, buffers already handed to the sink before stop() would
    /// still go out.
    func flush()

    /// Fired once per chunk *actually* pushed to the underlying transport
    /// (Agora's custom track, or the speaker), with the frame count of that
    /// chunk. TypeAndSpeakController uses this for word-highlighting timing,
    /// since synthesis can run ahead of real-time.
    var onFramesPushed: ((AVAudioFrameCount) -> Void)? { get set }
}

/// Production sink: injects rendered speech into the Agora call's outgoing
/// custom audio track while the microphone is muted.
final class AgoraPushSink: TTSAudioSink {

    var onFramesPushed: ((AVAudioFrameCount) -> Void)?

    private weak var agora: AgoraService?
    private let duckCoordinator: MicDuckCoordinator
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private let queue = DispatchQueue(label: "echosign.agorapushsink")

    /// Agora's custom track and playback-caption pipeline run at 16 kHz mono.
    let preferredFormat = AVAudioFormat(
        standardFormatWithSampleRate: Double(AgoraService.sampleRate),
        channels: 1
    )!

    init(agora: AgoraService, duckCoordinator: MicDuckCoordinator) {
        self.agora = agora
        self.duckCoordinator = duckCoordinator
    }

    func begin() {
        // Duck through the coordinator, not directly — so this can never
        // silently override a manual mute the user already has in effect,
        // and end() won't un-mute someone who muted themselves independently.
        duckCoordinator.setTTSDucking(true)
    }

    func emit(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingBuffers.append(buffer)
            self.drain()
        }
    }

    func end() {
        duckCoordinator.setTTSDucking(false)
    }

    /// Paces buffer delivery to Agora. Calls `onFramesPushed` after each
    /// buffer is actually handed to the transport, keeping highlighting
    /// synced to what's audibly going out rather than what's been synthesized.
    private func drain() {
        while !pendingBuffers.isEmpty {
            let buffer = pendingBuffers.removeFirst()
            _ = agora?.pushExternalAudioFrame(buffer)
            let frames = buffer.frameLength
            DispatchQueue.main.async { [weak self] in
                self?.onFramesPushed?(frames)
            }
        }
    }

    /// Drops anything queued but not yet handed to Agora. Anything already
    /// past that point (in Agora's own internal send buffer) is a much
    /// smaller, roughly-fixed latency window you likely can't reach from
    /// here — flushing this queue removes the *controllable* delay.
    func flush() {
        queue.async { [weak self] in
            self?.pendingBuffers.removeAll()
        }
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

    /// Diagnostic sink: stops playback immediately. No queue to drain since
    /// `emit` schedules buffers directly to the player node.
    func flush() {
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
