import AgoraRtcKit
import AVFoundation
import Combine
import Foundation

/// Events surfaced by `AgoraService` for the owning view model to observe.
enum AgoraEvent: Equatable {
    case didJoinChannel(channel: String, uid: UInt)
    case remoteUserJoined(uid: UInt)
    case remoteUserOffline(uid: UInt)
    case connectionStateChanged(state: AgoraConnectionState, reason: AgoraConnectionChangedReason)
    case didLeaveChannel
}

/// Thin wrapper around `AgoraRtcEngineKit` for this prototype.
///
/// Responsibilities:
/// - Join / leave an app-to-app channel.
/// - Mute / speaker-phone controls.
/// - Surface engine delegate callbacks through Combine.
/// - Expose a playback audio-frame delegate so remote PCM can be captioned.
/// - Push synthesized TTS audio into the outgoing stream via a custom audio track.
final class AgoraService: NSObject {

    /// Pipe for playback PCM frames (already normalized to 16 kHz / mono Int16).
    /// Invoked on the engine's audio thread — hop to main before touching UI.
    var onPlaybackPCM: ((UnsafeMutablePointer<Int16>, Int, Int) -> Void)?

    /// Called when the other side sends text over the data stream.
    var onDataStreamMessage: ((String) -> Void)?

    private(set) var eventSubject = PassthroughSubject<AgoraEvent, Never>()

    private let engine: AgoraRtcEngineKit
    private(set) var audioTrackID = -1

    /// The id of the data stream used to carry exact text. `-1` means the
    /// stream has not been opened.
    private var dataStreamID = -1

    /// Dev telemetry: remote playback frames delivered by the delegate, and
    /// TTS push attempts/failures. Read by the call screen's footnote.
    private(set) var playbackFrameCount = 0
    private(set) var pushAttempts = 0
    private(set) var pushFailures = 0
    private var lastFrameHeartbeatAt: CFAbsoluteTime = 0

    /// External-audio format. TTS renders at these settings; playback captions are
    /// requested in this same format so one format runs through the whole pipeline.
    static let sampleRate = 16000
    static let channelCount = 1
    static let samplesPer10ms = sampleRate / 100 // 160

    init(appID: String) {
        engine = AgoraRtcEngineKit.sharedEngine(withAppId: appID, delegate: nil)
        super.init()
        engine.delegate = self
    }

    // MARK: - Public control

    /// Join a channel. `uid == 0` lets Agora auto-assign a UID.
    func joinChannel(channelName: String, token: String, uid: UInt) {
        let options = AgoraRtcChannelMediaOptions()
        options.channelProfile = .communication
        options.publishMicrophoneTrack = true
        options.publishCustomAudioTrack = true
        options.publishCustomAudioTrackId = audioTrackID
        options.autoSubscribeAudio = true

        let code = engine.joinChannel(byToken: token, channelId: channelName, uid: uid, mediaOptions: options)
        if code != 0 {
            print("[Agora] joinChannel returned error \(code)")
            eventSubject.send(.connectionStateChanged(state: .failed, reason: .reasonInterrupted))
        }
    }

    func leaveChannel() {
        engine.leaveChannel(nil)
    }

    func muteLocalAudio(_ muted: Bool) {
        engine.muteLocalAudioStream(muted)
    }

    /// Ducks only the microphone capture signal while leaving channel
    /// publication — including the custom TTS track — untouched. Used around
    /// Type & Speak playback; `muteLocalAudioStream` would silence the custom
    /// track too, so it must not be used there.
    func setMicrophoneCaptureMuted(_ muted: Bool) {
        engine.adjustRecordingSignalVolume(muted ? 0 : 100)
    }

    func setSpeakerphone(_ on: Bool) {
        engine.setDefaultAudioRouteToSpeakerphone(on)
    }

    /// Capture-caption path: piped playback frames are forwarded so `CaptionService`
    /// can transcribe the remote party. Expects the engine to be configured for
    /// 16 kHz / mono playback frames.
    func setPlaybackCaptionsEnabled(_ enabled: Bool) {
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
    }

    /// Push one mono, 16 kHz, Float32 `AVAudioPCMBuffer` into the outgoing stream
    /// in Agora's expected 10 ms (160-sample) Int16 chunks.
    /// Returns `false` if the buffer isn't in the required format.
    func pushExternalAudioFrame(_ buffer: AVAudioPCMBuffer) -> Bool {
        pushAttempts += 1
        let success = pushExternalAudioFrameInternal(buffer)
        if !success {
            pushFailures += 1
            print("[Agora] pushExternalAudioFrame failed (\(pushFailures) total)")
        }
        return success
    }

    private func pushExternalAudioFrameInternal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard
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

    private static func int16From(float: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, float))
        return Int16((clamped * 32767.0).rounded())
    }

    // MARK: - Text data stream

    /// Whether the data stream is open and able to carry text.
    var isTextStreamOpen: Bool { dataStreamID >= 0 }

    /// Opens the data stream used to carry exact text to the other side.
    ///
    /// The stream rides the same Agora connection as the audio, so it needs
    /// no extra SDK and no extra server. Messages are not synchronised with
    /// the audio: text should arrive as soon as it is sent, not when the
    /// audio catches up.
    @discardableResult
    func openTextStream() -> Bool {
        guard dataStreamID < 0 else { return true }

        var streamID = 0
        let config = AgoraDataStreamConfig()
        config.ordered = true
        config.syncWithAudio = false
        let code = engine.createDataStream(&streamID, config: config)
        guard code == 0 else {
            print("[Agora] createDataStream failed: \(code)")
            return false
        }
        dataStreamID = streamID
        return true
    }

    /// Sends text to the other side.
    ///
    /// Agora caps a data message at 1 KB and the whole stream at 6 KB/s,
    /// which is far more than a chat message needs.
    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard dataStreamID >= 0 else {
            print("[Agora] sendText failed: the data stream is not open")
            return false
        }
        guard let data = text.data(using: .utf8) else { return false }
        let code = engine.sendStreamMessage(dataStreamID, data: data)
        if code != 0 {
            print("[Agora] sendStreamMessage failed: \(code)")
            return false
        }
        return true
    }

    /// Closes the data stream.
    func closeTextStream() {
        dataStreamID = -1
    }

    // MARK: - Engine one-off setup

    /// Idempotent engine configuration shared between call and TTS paths.
    /// Call once before the first join.
    func prepare() {
        engine.enableAudio()
        // Custom audio track used to inject TTS into the outgoing stream.
        if audioTrackID < 0 {
            let ttsTrackConfig = AgoraAudioTrackConfig()
            // This track is outgoing Type & Speak audio. Agora defaults to
            // playing custom-track audio locally, which would make a sender
            // hear their own typed speech through the device speaker.
            ttsTrackConfig.enableLocalPlayback = false
            audioTrackID = Int(engine.createCustomAudioTrack(.mixable, config: ttsTrackConfig))
            print("[Agora] custom audio track created: id=\(audioTrackID)")
        }
        setPlaybackCaptionsEnabled(false)
    }

    // MARK: - Teardown

    func destroy() {
        engine.setAudioFrameDelegate(nil)
        engine.leaveChannel(nil)
        AgoraRtcEngineKit.destroy()
    }
}

// MARK: - AgoraRtcEngineDelegate

extension AgoraService: AgoraRtcEngineDelegate {

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        print("[Agora] didJoinChannel: channel=\(channel) uid=\(uid)")
        eventSubject.send(.didJoinChannel(channel: channel, uid: uid))
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        print("[Agora] didOccurError: \(errorCode.rawValue)")
        eventSubject.send(.connectionStateChanged(state: .failed, reason: .reasonInterrupted))
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        print("[Agora] remote joined: uid=\(uid)")
        eventSubject.send(.remoteUserJoined(uid: uid))
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        print("[Agora] remote offline: uid=\(uid) reason=\(reason.rawValue)")
        eventSubject.send(.remoteUserOffline(uid: uid))
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didLeaveChannelWith stats: AgoraChannelStats) {
        print("[Agora] didLeaveChannel")
        eventSubject.send(.didLeaveChannel)
    }

    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        receiveStreamMessageFromUid uid: UInt,
        streamId: Int,
        data: Data
    ) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onDataStreamMessage?(text)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        print("[Agora] connectionChangedTo: state=\(state.rawValue) reason=\(reason.rawValue)")
        eventSubject.send(.connectionStateChanged(state: state, reason: reason))
    }
}

// MARK: - AgoraAudioFrameDelegate (remote playback → captions)

extension AgoraService: AgoraAudioFrameDelegate {

    // Only the playback position is observed here; the delivered frame format is
    // set via `setPlaybackAudioFrameParameters` (Method 1), which takes
    // precedence over the params returned by the getters below.
    func getObservedAudioFramePosition() -> AgoraAudioFramePosition {
        .playback
    }

    func getPlaybackAudioParams() -> AgoraAudioParams {
        AgoraAudioParams()
    }

    func getRecordAudioParams() -> AgoraAudioParams {
        AgoraAudioParams()
    }

    func getMixedAudioParams() -> AgoraAudioParams {
        AgoraAudioParams()
    }

    func getEarMonitoringAudioParams() -> AgoraAudioParams {
        AgoraAudioParams()
    }

    func onRecordAudioFrame(_ frame: AgoraAudioFrame, channelId: String) -> Bool {
        true
    }

    func onMixedAudioFrame(_ frame: AgoraAudioFrame, channelId: String) -> Bool {
        true
    }

    func onPlaybackAudioFrame(
        beforeMixing frame: AgoraAudioFrame,
        channelId: String,
        uid: UInt
    ) -> Bool {
        true
    }

    func onEarMonitoringAudioFrame(_ frame: AgoraAudioFrame) -> Bool {
        true
    }

    func onPlaybackAudioFrame(_ frame: AgoraAudioFrame, channelId: String) -> Bool {
        playbackFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFrameHeartbeatAt >= 5 {
            lastFrameHeartbeatAt = now
            print("[Agora] playback frames delivered: \(playbackFrameCount)")
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
