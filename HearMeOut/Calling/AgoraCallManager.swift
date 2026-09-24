import AVFoundation
import Combine
import Foundation

#if canImport(AgoraRtcKit)
import AgoraRtcKit
#endif
#if canImport(AgoraRtmKit)
import AgoraRtmKit
#endif

enum CallEngineError: LocalizedError {
    case sdkMissing(String)
    case joinFailed(String)
    case messagingFailed(String)

    var errorDescription: String? {
        switch self {
        case .sdkMissing(let what): return "\(what) SDK isn't linked. Re-add the package in Xcode."
        case .joinFailed(let m): return m
        case .messagingFailed(let m): return m
        }
    }
}

/// Wraps Agora RTC (audio) + RTM/Signaling (text) behind one interface.
///
/// SDK-absent degradation: every method throws CallEngineError.sdkMissing
/// when its package isn't linked, so the app still builds and runs its
/// local-only flow (and the known RTC 4.5+/Signaling 2.2+ `aosl` duplicate
/// conflict can be worked around by dropping one package without breaking
/// compilation — see the Phase 5 notes).
///
/// Threading: Agora delegate callbacks arrive off-main. The class is
/// @MainActor; delegate methods are nonisolated and hop back explicitly.
@MainActor
final class AgoraCallManager: NSObject, ObservableObject {
    @Published private(set) var audioJoined = false
    @Published private(set) var remoteUserJoined = false
    @Published private(set) var isMuted = false
    @Published private(set) var speakerEnabled = false
    @Published private(set) var messagingReady = false

    /// (channel, text, publisherId)
    var onMessageReceived: ((String, String, String) -> Void)?

    /// Pipe for remote playback PCM frames (16 kHz / mono Int16), consumed by
    /// `CaptionService.appendRemotePCM`. Written from the main actor
    /// (coordinator wiring), invoked on the engine's audio thread — hence
    /// opted out of isolation; the value is a plain closure set once per call.
    nonisolated(unsafe) var onPlaybackPCM: ((UnsafeMutablePointer<Int16>, Int, Int) -> Void)?

    /// External-audio format. TTS renders at these settings; playback captions
    /// are requested in this same format so one format runs through the whole
    /// speech pipeline.
    static let sampleRate = 16000
    static let channelCount = 1
    static let samplesPer10ms = sampleRate / 100 // 160

    /// Dev telemetry, audio-thread safe. Snapshot via the `telemetry()`
    /// method for UI; never touch @Published state from the audio thread.
    private let telemetryBox = TelemetryBox()

    func telemetry() -> (playbackFrames: Int, pushAttempts: Int, pushFailures: Int) {
        telemetryBox.snapshot()
    }

    /// Nonisolated so the app graph can be built in HearMeOutApp.init.
    nonisolated override init() {
        super.init()
    }

    #if canImport(AgoraRtcKit)
    private var rtcEngine: AgoraRtcEngineKit?
    /// Main-actor view of the engine. `engineRef` mirrors it for the
    /// audio-thread push/duck path (set once per join, before any audio
    /// flows — the only cross-thread handoff).
    private nonisolated(unsafe) var engineRef: AgoraRtcEngineKit?
    /// Custom audio track for TTS injection; -1 until prepare() creates it.
    /// Set once on the main actor before any audio flows.
    private nonisolated(unsafe) var audioTrackID = -1
    #endif
    #if canImport(AgoraRtmKit)
    private var rtmKit: AgoraRtmClientKit?
    private var rtmChannel: String?
    #endif

    static var isRTCAvailable: Bool {
        #if canImport(AgoraRtcKit)
        return true
        #else
        return false
        #endif
    }

    static var isRTMAvailable: Bool {
        #if canImport(AgoraRtmKit)
        return true
        #else
        return false
        #endif
    }

    // MARK: - audio (RTC)

    /// Join the voice channel with the token minted by startCall/call-join.
    /// `uid` is the numeric id the server bound into that token.
    func joinAudio(channel: String, token: String, uid: UInt) async throws {
        #if canImport(AgoraRtcKit)
        guard let appID = AppConfig.agoraAppID else { throw CallEngineError.joinFailed("Agora App ID isn't configured.") }
        let engine: AgoraRtcEngineKit
        if let existing = rtcEngine {
            engine = existing
        } else {
            engine = AgoraRtcEngineKit.sharedEngine(withAppId: appID, delegate: self)
            engine.setChannelProfile(.communication)
            engine.enableAudio()
            engine.setDefaultAudioRouteToSpeakerphone(false)
            rtcEngine = engine
            engineRef = engine
        }
        prepareAudioPipeline()
        remoteUserJoined = false
        var options = AgoraRtcChannelMediaOptions()
        options.channelProfile = .communication
        options.clientRoleType = .broadcaster
        options.publishMicrophoneTrack = true
        options.publishCameraTrack = false
        // Custom TTS track: synthesized speech is injected here while the mic
        // is ducked (see setMicrophoneCaptureMuted). Must stay published.
        options.publishCustomAudioTrack = true
        options.autoSubscribeAudio = true
        options.autoSubscribeVideo = false
        if audioTrackID >= 0 {
            options.publishCustomAudioTrackId = audioTrackID
        }
        let code = engine.joinChannel(byToken: token, channelId: channel, uid: uid, mediaOptions: options)
        guard code == 0 else { throw CallEngineError.joinFailed("Couldn't join the voice channel (code \(code)).") }
        #else
        throw CallEngineError.sdkMissing("Agora RTC")
        #endif
    }

    /// Idempotent engine configuration shared between call and TTS paths.
    /// Call once before the first join (joinAudio calls it automatically).
    func prepareAudioPipeline() {
        #if canImport(AgoraRtcKit)
        guard let engine = rtcEngine, audioTrackID < 0 else { return }
        audioTrackID = Int(engine.createCustomAudioTrack(.mixable, config: AgoraAudioTrackConfig()))
        print("[Agora] custom audio track created: id=\(audioTrackID)")
        #endif
    }

    /// Capture-caption path: piped playback frames are forwarded so
    /// `CaptionService` can transcribe the remote party. Expects 16 kHz /
    /// mono playback frames.
    func setPlaybackCaptionsEnabled(_ enabled: Bool) {
        #if canImport(AgoraRtcKit)
        guard let engine = rtcEngine else { return }
        if enabled {
            engine.setPlaybackAudioFrameParametersWithSampleRate(
                Self.sampleRate,
                channel: Self.channelCount,
                mode: .readOnly,
                samplesPerCall: Self.samplesPer10ms
            )
            engine.setAudioFrameDelegate(self)
        } else {
            engine.setAudioFrameDelegate(nil)
        }
        #endif
    }

    /// Ducks only the microphone capture signal while leaving channel
    /// publication — including the custom TTS track — untouched. Used around
    /// Type & Speak playback; `muteLocalAudioStream` would silence the custom
    /// track too, so it must not be used there.
    ///
    /// Nonisolated: called from TTS render queues as well as the main actor.
    nonisolated func setMicrophoneCaptureMuted(_ muted: Bool) {
        #if canImport(AgoraRtcKit)
        engineRef?.adjustRecordingSignalVolume(muted ? 0 : 100)
        #endif
    }

    /// Push one mono, 16 kHz, Float32 `AVAudioPCMBuffer` into the outgoing
    /// stream in Agora's expected 10 ms (160-sample) Int16 chunks.
    /// Returns `false` if the buffer isn't in the required format.
    ///
    /// Nonisolated: called from TTS render queues. Never touches @Published
    /// state — telemetry goes through the lock-protected box.
    nonisolated func pushExternalAudioFrame(_ buffer: AVAudioPCMBuffer) -> Bool {
        #if canImport(AgoraRtcKit)
        telemetryBox.noteAttempt()
        let success = pushExternalAudioFrameInternal(buffer)
        if !success {
            telemetryBox.noteFailure()
            print("[Agora] pushExternalAudioFrame failed (\(telemetryBox.snapshot().pushFailures) total)")
        }
        return success
        #else
        return false
        #endif
    }

    #if canImport(AgoraRtcKit)
    private nonisolated func pushExternalAudioFrameInternal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard
            let engine = engineRef,
            audioTrackID >= 0,
            let channelData = buffer.floatChannelData,
            buffer.format.sampleRate == Double(Self.sampleRate),
            buffer.format.channelCount == 1
        else {
            return false
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return true }

        var int16 = [Int16](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            int16[i] = Self.int16From(float: channelData[0][i])
        }

        var offset = 0
        int16.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < frameLength {
                let count = min(Self.samplesPer10ms, frameLength - offset)
                engine.pushExternalAudioFrameRawData(
                    UnsafeMutableRawPointer(base.advanced(by: offset)),
                    samples: count,
                    sampleRate: Self.sampleRate,
                    channels: Self.channelCount,
                    trackId: audioTrackID,
                    timestamp: 0
                )
                offset += count
            }
        }
        return true
    }

    private nonisolated static func int16From(float: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, float))
        return Int16((clamped * 32767.0).rounded())
    }
    #endif

    func leaveAudio() {
        #if canImport(AgoraRtcKit)
        setPlaybackCaptionsEnabled(false)
        rtcEngine?.leaveChannel()
        #endif
        audioJoined = false
        remoteUserJoined = false
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        #if canImport(AgoraRtcKit)
        rtcEngine?.muteLocalAudioStream(muted)
        #endif
    }

    func setSpeakerphone(_ enabled: Bool) {
        speakerEnabled = enabled
        #if canImport(AgoraRtcKit)
        // Default-route (Echo's choice) survives route changes better than
        // the in-call-only setEnableSpeakerphone.
        rtcEngine?.setDefaultAudioRouteToSpeakerphone(enabled)
        #endif
    }

    // MARK: - text (RTM / Signaling 2.x)

    /// Log in to Signaling and subscribe to the call's message channel.
    /// The server mints the RTM token for user id String(rtcuUid), so the
    /// same string must be used here or login is rejected.
    func joinMessaging(channel: String, token: String, rtcUid: Int) async throws {
        #if canImport(AgoraRtmKit)
        guard let appID = AppConfig.agoraAppID else { throw CallEngineError.messagingFailed("Agora App ID isn't configured.") }
        let userId = String(rtcUid)
        leaveMessaging()
        let kit: AgoraRtmClientKit
        do {
            kit = try AgoraRtmClientKit(AgoraRtmClientConfig(appId: appID, userId: userId), delegate: self)
        } catch {
            throw CallEngineError.messagingFailed("Couldn't start messaging: \(error.localizedDescription)")
        }
        rtmKit = kit
        rtmChannel = channel
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // 2.x: userId is bound at config time (init), login takes the token only.
            kit.login(token) { _, error in
                if let error {
                    continuation.resume(throwing: CallEngineError.messagingFailed("Messaging login failed: \(error.reason) (\(error.errorCode.rawValue))."))
                } else {
                    continuation.resume()
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            kit.subscribe(channelName: channel, option: nil) { _, error in
                if let error {
                    continuation.resume(throwing: CallEngineError.messagingFailed("Couldn't subscribe to messages: \(error.reason) (\(error.errorCode.rawValue))."))
                } else {
                    continuation.resume()
                }
            }
        }
        messagingReady = true
        #else
        throw CallEngineError.sdkMissing("Agora RTM")
        #endif
    }

    /// Publish a text reply. Resolves only on server ack — callers append to
    /// sent history on success, never before.
    func sendMessage(_ text: String, channel: String) async throws {
        #if canImport(AgoraRtmKit)
        guard let kit = rtmKit else { throw CallEngineError.messagingFailed("Messaging isn't connected.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            kit.publish(channelName: channel, message: text, option: nil) { _, error in
                if let error {
                    continuation.resume(throwing: CallEngineError.messagingFailed("Message not delivered: \(error.reason) (\(error.errorCode.rawValue))."))
                } else {
                    continuation.resume()
                }
            }
        }
        #else
        throw CallEngineError.sdkMissing("Agora RTM")
        #endif
    }

    func leaveMessaging() {
        #if canImport(AgoraRtmKit)
        if let kit = rtmKit {
            if let channel = rtmChannel { kit.unsubscribe(channel, completion: nil) }
            kit.logout(nil)
            kit.destroy()
        }
        rtmKit = nil
        rtmChannel = nil
        #endif
        messagingReady = false
    }

    func leaveAll() {
        leaveAudio()
        leaveMessaging()
    }
}

// MARK: - RTC delegate (off-main -> hop to @MainActor)

#if canImport(AgoraRtcKit)
extension AgoraCallManager: AgoraRtcEngineDelegate {
    nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        Task { @MainActor [weak self] in self?.audioJoined = true }
    }

    nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didLeaveChannelWith stats: AgoraChannelStats) {
        Task { @MainActor [weak self] in
            self?.audioJoined = false
            self?.remoteUserJoined = false
        }
    }

    nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        Task { @MainActor [weak self] in self?.remoteUserJoined = true }
    }

    nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        Task { @MainActor [weak self] in self?.remoteUserJoined = false }
    }

    nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        // Transport-level errors surface here; call state stays owned by
        // ActiveCall/CallKit, so log only.
        print("Agora RTC error: \(errorCode.rawValue)")
    }
}
#endif

// MARK: - RTM delegate (off-main -> hop to @MainActor)

#if canImport(AgoraRtmKit)
extension AgoraCallManager: AgoraRtmClientDelegate {
    nonisolated func rtmKit(_ rtmKit: AgoraRtmClientKit, didReceiveMessageEvent event: AgoraRtmMessageEvent) {
        guard let text = event.message.stringData else { return }
        Task { @MainActor [weak self] in
            self?.onMessageReceived?(event.channelName, text, event.publisher)
        }
    }

    nonisolated func rtmKit(_ rtmKit: AgoraRtmClientKit, didReceiveLinkStateEvent event: AgoraRtmLinkStateEvent) {
        print("RTM link state: \(event.currentState.rawValue)")
    }
}
#endif

// MARK: - Audio frame delegate: remote playback PCM -> CaptionService
// Ported from EchoSign's AgoraService audio-caption pipe. Only the playback
// position is observed; the delivered frame format comes from
// setPlaybackAudioFrameParameters (Method 1), which takes precedence over
// the params returned by the getters below.

#if canImport(AgoraRtcKit)
extension AgoraCallManager: AgoraAudioFrameDelegate {
    nonisolated func getObservedAudioFramePosition() -> AgoraAudioFramePosition {
        .playback
    }

    nonisolated func getPlaybackAudioParams() -> AgoraAudioParams {
        AgoraAudioParams()
    }

    nonisolated func getRecordAudioParams() -> AgoraAudioParams {
        AgoraAudioParams()
    }

    nonisolated func getMixedAudioParams() -> AgoraAudioParams {
        AgoraAudioParams()
    }

    nonisolated func getEarMonitoringAudioParams() -> AgoraAudioParams {
        AgoraAudioParams()
    }

    nonisolated func onRecordAudioFrame(_ frame: AgoraAudioFrame, channelId: String) -> Bool {
        true
    }

    nonisolated func onMixedAudioFrame(_ frame: AgoraAudioFrame, channelId: String) -> Bool {
        true
    }

    nonisolated func onPlaybackAudioFrame(
        beforeMixing frame: AgoraAudioFrame,
        channelId: String,
        uid: UInt
    ) -> Bool {
        true
    }

    nonisolated func onEarMonitoringAudioFrame(_ frame: AgoraAudioFrame) -> Bool {
        true
    }

    nonisolated func onPlaybackAudioFrame(_ frame: AgoraAudioFrame, channelId: String) -> Bool {
        let count = telemetryBox.noteFrame()
        if count % 500 == 1 {
            print("[Agora] playback frames delivered: \(count)")
        }

        guard
            let buffer = frame.buffer,
            frame.samplesPerChannel > 0,
            frame.channels > 0
        else {
            return true
        }
        let int16Pointer = buffer.assumingMemoryBound(to: Int16.self)
        onPlaybackPCM?(int16Pointer, Int(frame.samplesPerChannel), Int(frame.channels))
        return true
    }
}

/// Lock-free telemetry safe to touch from the audio thread.
private final class TelemetryBox: Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var attempts = 0
    private var failures = 0

    func noteFrame() -> Int {
        lock.lock()
        defer { lock.unlock() }
        frames += 1
        return frames
    }

    func noteAttempt() {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
    }

    func noteFailure() {
        lock.lock()
        defer { lock.unlock() }
        failures += 1
    }

    func snapshot() -> (playbackFrames: Int, pushAttempts: Int, pushFailures: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, attempts, failures)
    }
}
#endif
