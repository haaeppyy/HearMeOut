import CallKit
import Foundation
import PushKit

/// Was a fully untouched stub the entire session — never instantiated
/// anywhere in the app, `register()` did nothing, `didReceiveIncomingPushWith`
/// had no body. That meant incoming calls could never work regardless of
/// whether the backend push-sending was real, since nothing on-device was
/// listening. Implemented for real here.
final class PushKitManager: NSObject {

    private struct PendingIncomingCall {
        let callId: String
        let callerId: String
        let callerName: String
    }

    private let registry = PKPushRegistry(queue: .main)
    private let callKit: CallKitManager
    private let signaling: CallSignalingClient

    /// Keyed by the CallKit UUID `reportIncomingCall` was given — lets
    /// `CallKitManager.onAnswerCall` (which only knows the UUID) be
    /// resolved back to the actual `callId` the backend needs.
    private var pendingCalls: [UUID: PendingIncomingCall] = [:]

    /// Fired once the user answers from the CallKit UI, with enough info
    /// for whoever owns call-engine lifecycle (`CallViewModel`) to actually
    /// join the call.
    var onIncomingCallAnswered: ((_ callId: String, _ callerId: String) -> Void)?

    init(callKit: CallKitManager, signaling: CallSignalingClient) {
        self.callKit = callKit
        self.signaling = signaling
        super.init()

        registry.delegate = self
        callKit.onAnswerCall = { [weak self] uuid in
            guard let self, let pending = self.pendingCalls[uuid] else { return }
            self.onIncomingCallAnswered?(pending.callId, pending.callerId)
        }
        // Deliberately NOT wiring callKit.onCallEndedByCallKit here — it's
        // a single closure property, and CallViewModel/AppCallCoordinator
        // also needs to react to the same event (to reset UI state). Two
        // independent assignments to the same property silently clobber
        // each other; AppCallCoordinator owns that wiring and calls
        // `handleCallEnded()` below explicitly instead.
    }

    /// Call from wherever `callKit.onCallEndedByCallKit` is centrally
    /// wired (see `AppCallCoordinator`), for the case CallViewModel alone
    /// can't handle: a call that was never answered (declined or timed
    /// out) has no `CallViewModel`/engine tracking it at all — only this
    /// class's `pendingCalls` knows it exists, so only this class can tell
    /// the backend it ended.
    func handleCallEnded() {
        guard let uuid = callKit.activeCallUUID, let pending = pendingCalls[uuid] else { return }
        Task { try? await signaling.endCall(callId: pending.callId) }
        pendingCalls.removeValue(forKey: uuid)
    }

    /// Call once at app launch (or after sign-in) to start receiving VoIP
    /// pushes.
    func register() {
        registry.desiredPushTypes = [.voIP]
    }
}

extension PushKitManager: PKPushRegistryDelegate {

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task {
            do {
                try await signaling.registerPushToken(token)
            } catch {
                // Retry-worthy but not fatal to app launch — without this,
                // incoming calls silently won't ring on this device until
                // the next successful registration.
                print("[PushKit] Failed to register push token: \(error)")
            }
        }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        print("[PushKit] Push token invalidated — incoming calls won't ring until re-registered")
    }

    /// Apple requires `reportNewIncomingCall` to be called before this
    /// method returns (via the completion handler) — deferring or skipping
    /// it risks the app being terminated for violating PushKit's contract,
    /// so every path here calls `completion()`, including malformed
    /// payloads.
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        guard let callId = payload.dictionaryPayload["callId"] as? String,
              let callerId = payload.dictionaryPayload["callerId"] as? String else {
            print("[PushKit] Malformed incoming push payload — reporting a generic call so the app doesn't get penalized for a silent push")
            let uuid = UUID()
            callKit.reportIncomingCall(uuid: uuid, callerName: "Unknown caller") { _ in
                completion()
            }
            return
        }

        let callerName = payload.dictionaryPayload["callerName"] as? String ?? "EchoSign user"
        let uuid = UUID()
        pendingCalls[uuid] = PendingIncomingCall(callId: callId, callerId: callerId, callerName: callerName)

        callKit.reportIncomingCall(uuid: uuid, callerName: callerName) { [weak self] error in
            if error != nil {
                self?.pendingCalls.removeValue(forKey: uuid)
            }
            completion()
        }
    }
}
