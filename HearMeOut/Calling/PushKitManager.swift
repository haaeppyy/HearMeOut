import Foundation
import PushKit

/// VoIP push registration + incoming-payload parsing. Token registration
/// targets CallAPIClient.push-token (Phase 3); the incoming path hands the
/// payload to CallKit synchronously — Apple terminates apps that do async
/// work before reportNewIncomingCall, so `onIncomingPush` must return fast
/// and the coordinator must not await anything before calling through.
final class PushKitManager: NSObject, ObservableObject {
    struct IncomingPush {
        let callId: String
        let channelName: String
        let callerId: String
        let callerName: String
    }

    /// Hex-encoded device token, set from didUpdate. The coordinator sends
    /// it to the backend once auth exists (and again on every change).
    @Published private(set) var voipToken: String?

    /// Invoked synchronously on the push callback thread (.main queue).
    /// The completion MUST be called after CallKit has been told about the
    /// call — completing first risks the OS killing the app for an
    /// unreported incoming call. The coordinator chains it behind
    /// reportNewIncomingCall's own completion.
    var onIncomingPush: ((IncomingPush, @escaping () -> Void) -> Void)?

    private var registry: PKPushRegistry?

    /// Nonisolated so the app graph can be built in HearMeOutApp.init.
    /// Call start() later (coordinator.activate does this at launch).
    nonisolated override init() {
        super.init()
    }

    func start() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    /// Pure payload parsing, extracted for PushPayloadParsingTests — no
    /// PKPushPayload needed, tests pass dictionary literals directly.
    /// Exact keys from src/services/push.ts's APNs body (top level,
    /// alongside aps.content-available).
    static func parse(_ d: [AnyHashable: Any]) -> IncomingPush? {
        guard
            let callId = d["callId"] as? String,
            let channelName = d["channelName"] as? String,
            let callerId = d["callerId"] as? String
        else {
            return nil
        }
        let callerName = (d["callerName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return IncomingPush(
            callId: callId,
            channelName: channelName,
            callerId: callerId,
            callerName: callerName?.isEmpty == false ? callerName! : "Unknown caller"
        )
    }
}

extension PushKitManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        voipToken = hex
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        voipToken = nil
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // Exact keys from src/services/push.ts's APNs body (top level,
        // alongside aps.content-available).
        let d = payload.dictionaryPayload
        guard let push = Self.parse(d) else {
            completion()
            return
        }
        guard let handler = onIncomingPush else {
            completion()
            return
        }
        handler(push, completion)
    }
}
