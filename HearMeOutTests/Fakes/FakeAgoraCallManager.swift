import AVFoundation
import Combine
import Foundation
import Testing

@testable import HearMeOut

/// Scriptable AgoraDriving test double: every join/send succeeds unless its
/// matching error is set, and every call is recorded for assertions.
///
/// The two nonisolated audio-thread members record into a lock-guarded box
/// (Sendable), since a nonisolated witness can't touch @MainActor state.
@MainActor
final class FakeAgoraCallManager: AgoraDriving {
    var isMuted = false
    var onMessageReceived: ((String, String, String) -> Void)?
    var onPlaybackPCM: ((UnsafeMutablePointer<Int16>, Int, Int) -> Void)?

    private let joinSubject = PassthroughSubject<Bool, Never>()
    var remoteUserJoinedPublisher: AnyPublisher<Bool, Never> {
        joinSubject.eraseToAnyPublisher()
    }

    /// Drives the coordinator's remoteUserJoined → startCaptions path.
    /// (Captions stay idle in these tests — the point is the subscription
    /// doesn't crash and doesn't fire without a join.)
    func simulateRemoteJoin() {
        joinSubject.send(true)
    }

    var joinAudioError: (any Error)?
    var joinMessagingError: (any Error)?
    var sendMessageError: (any Error)?

    private(set) var joinedAudio: [(channel: String, token: String, uid: UInt)] = []
    private(set) var joinedMessaging: [(channel: String, token: String, rtcUid: Int)] = []
    private(set) var sentMessages: [(text: String, channel: String)] = []
    private(set) var leaveAllCount = 0
    private(set) var playbackCaptionsValues: [Bool] = []

    func joinAudio(channel: String, token: String, uid: UInt) async throws {
        if let joinAudioError { throw joinAudioError }
        joinedAudio.append((channel, token, uid))
    }

    func joinMessaging(channel: String, token: String, rtcUid: Int) async throws {
        if let joinMessagingError { throw joinMessagingError }
        joinedMessaging.append((channel, token, rtcUid))
    }

    func sendMessage(_ text: String, channel: String) async throws {
        if let sendMessageError { throw sendMessageError }
        sentMessages.append((text, channel))
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    func setPlaybackCaptionsEnabled(_ enabled: Bool) {
        playbackCaptionsValues.append(enabled)
    }

    func leaveAll() {
        leaveAllCount += 1
    }

    // MARK: - audio-thread path (nonisolated, lock-boxed records)

    private let audioBox = AudioBox()

    final class AudioBox: @unchecked Sendable {
        private let lock = NSLock()
        private var mutes: [Bool] = []
        private var pushes: [Int] = []
        func noteMute(_ muted: Bool) {
            lock.lock(); defer { lock.unlock() }
            mutes.append(muted)
        }
        func notePush(frames: Int) {
            lock.lock(); defer { lock.unlock() }
            pushes.append(frames)
        }
        var muteValues: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return mutes
        }
        var pushFrameCounts: [Int] {
            lock.lock(); defer { lock.unlock() }
            return pushes
        }
    }

    nonisolated func setMicrophoneCaptureMuted(_ muted: Bool) {
        audioBox.noteMute(muted)
    }

    nonisolated func pushExternalAudioFrame(_ buffer: AVAudioPCMBuffer) -> Bool {
        audioBox.notePush(frames: Int(buffer.frameLength))
        return true
    }

    var micCaptureMutedValues: [Bool] { audioBox.muteValues }
    var pushedFrameCounts: [Int] { audioBox.pushFrameCounts }
}
