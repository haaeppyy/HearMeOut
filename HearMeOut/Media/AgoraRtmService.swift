import Combine
import Foundation

/// Stub for Agora Real-Time Messaging (RTM) service. Used by VoIPCallEngine
/// as a non-blocking caption-feed side channel — never on the audio or
/// control path.
///
/// RTM carries plain text transcripts so an EchoSign-to-EchoSign receiver
/// can show exact text instead of relying on speech recognition against
/// synthesized audio. A dropped RTM message degrades captions, never the call.
///
/// TODO: Add AgoraRtmKit via SPM when the RTM SDK is integrated. This stub
/// provides the interface so the rest of the codebase compiles; the real
/// implementation will wrap `AgoraRtmKit`'s `AgoraRtmClient`.
final class AgoraRtmService {

    /// Whether the RTM client is currently logged in and joined to a channel.
    private(set) var isConnected = false

    private var currentUserId: String?
    private var currentChannel: String?

    init() {}

    /// Log in to the RTM service. Must be called before `joinChannel`.
    /// - Parameters:
    ///   - userId: The user's RTM ID (typically the Agora UID as a string).
    ///   - token: The RTM token from the signaling backend.
    func login(userId: String, token: String) async throws {
        // TODO: Implement with AgoraRtmKit
        // agortamClient.login(token, userId: userId)
        self.currentUserId = userId
        self.isConnected = true
        print("[RTM] login: userId=\(userId)")
    }

    /// Join an RTM channel to send/receive messages.
    func joinChannel(_ channel: String) async throws {
        // TODO: Implement with AgoraRtmKit
        // agortamClient.joinChannel(channel)
        self.currentChannel = channel
        print("[RTM] joined channel: \(channel)")
    }

    /// Send a text message on the current channel. Fire-and-forget: failures
    /// are logged but never propagate to the caller.
    func send(_ text: String) {
        guard isConnected, let channel = currentChannel else {
            print("[RTM] send failed: not connected")
            return
        }
        // TODO: Implement with AgoraRtmKit
        // agortamClient.sendMessage(text, channel: channel)
        print("[RTM] sent to \(channel): \(text.prefix(50))...")
    }

    /// Leave the current channel and disconnect.
    func leave() {
        // TODO: Implement with AgoraRtmKit
        // agortamClient.leaveChannel(channel)
        // agortamClient.logout()
        isConnected = false
        currentChannel = nil
        currentUserId = nil
        print("[RTM] disconnected")
    }
}
