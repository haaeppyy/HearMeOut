import AVFoundation
import Combine
import Foundation

/// Test seam for CallCoordinator: the Agora surface the coordinator drives,
/// without AgoraRtcEngineKit / Signaling underneath.
///
/// AgoraCallManager already satisfies this — the extension below only adds
/// the Combine projection the coordinator subscribes to. Tests inject
/// FakeAgoraCallManager, scriptable to succeed or throw per call.
///
/// @MainActor like the concrete class: every requirement except the two
/// marked nonisolated is main-actor-isolated there, so the protocol matches
/// that isolation and both the class and @MainActor fakes conform
/// naturally. The speech plane (MicDuckCoordinator, AgoraPushSink) runs off
/// the main actor and may only touch the two nonisolated members.
@MainActor
protocol AgoraDriving: AnyObject {
    var isMuted: Bool { get }
    var onMessageReceived: ((String, String, String) -> Void)? { get set }
    var onPlaybackPCM: ((UnsafeMutablePointer<Int16>, Int, Int) -> Void)? { get set }
    /// Publisher form of the @Published remoteUserJoined the coordinator
    /// subscribes to (protocols can't witness a projected value directly).
    var remoteUserJoinedPublisher: AnyPublisher<Bool, Never> { get }

    func joinAudio(channel: String, token: String, uid: UInt) async throws
    func joinMessaging(channel: String, token: String, rtcUid: Int) async throws
    func sendMessage(_ text: String, channel: String) async throws
    func setMuted(_ muted: Bool)
    func setPlaybackCaptionsEnabled(_ enabled: Bool)
    func leaveAll()

    /// Audio-thread path: TTS injection + mic ducking, callable off-main.
    nonisolated func setMicrophoneCaptureMuted(_ muted: Bool)
    nonisolated func pushExternalAudioFrame(_ buffer: AVAudioPCMBuffer) -> Bool
}

extension AgoraCallManager: AgoraDriving {
    var remoteUserJoinedPublisher: AnyPublisher<Bool, Never> {
        $remoteUserJoined.eraseToAnyPublisher()
    }
}
