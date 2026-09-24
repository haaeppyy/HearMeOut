import Combine
import Foundation
import Testing

@testable import HearMeOut

/// Scriptable PushKitDriving test double: no PKPushRegistry, no entitlements.
/// Tests synthesize incoming pushes (the OS path) and observe the completion
/// chaining the coordinator owes the system.
final class FakePushKitManager: PushKitDriving {
    var voipToken: String?
    private let tokenSubject = CurrentValueSubject<String?, Never>(nil)
    var voipTokenPublisher: AnyPublisher<String?, Never> {
        tokenSubject.eraseToAnyPublisher()
    }

    var onIncomingPush: ((PushKitManager.IncomingPush, @escaping () -> Void) -> Void)?

    private(set) var startCount = 0

    func start() {
        startCount += 1
    }

    /// Publish a token change like PKPushRegistry would.
    func emitToken(_ token: String?) {
        voipToken = token
        tokenSubject.send(token)
    }

    /// Deliver a synthesized push through the coordinator-wired handler.
    func simulateIncomingPush(
        _ push: PushKitManager.IncomingPush,
        completion: @escaping () -> Void
    ) {
        onIncomingPush?(push, completion)
    }

    static func push(
        callId: String = "call-1",
        channel: String = "ch-1",
        callerId: String = "user-9",
        callerName: String = "Amar"
    ) -> PushKitManager.IncomingPush {
        PushKitManager.IncomingPush(
            callId: callId, channelName: channel,
            callerId: callerId, callerName: callerName
        )
    }
}
