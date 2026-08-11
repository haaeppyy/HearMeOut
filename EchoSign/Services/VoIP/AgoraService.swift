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

    private(set) var eventSubject = PassthroughSubject<AgoraEvent, Never>()

    private let engine: AgoraRtcEngineKit
    private var audioTrackID = -1

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

    // MARK: - Engine one-off setup

    /// Idempotent engine configuration shared between call and TTS paths.
    /// Call once before the first join.
    func prepare() {
        engine.enableAudio()
        // Custom audio track used to inject TTS into the outgoing stream.
        if audioTrackID < 0 {
            audioTrackID = Int(engine.createCustomAudioTrack(.mixable, config: AgoraAudioTrackConfig()))
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