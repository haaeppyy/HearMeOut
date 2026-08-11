import Foundation
import PushKit

/// Skeleton for inbound-call signaling. This prototype is outgoing-only, so this
/// class never drives a live call — it exists to show where PushKit would plug in.
///
/// To make incoming calls real you need a signaling backend that:
///   1. Learns this device's PushKit token via `pushRegistry(_:didUpdate:for:)`.
///   2. Sends a VoIP push (containing at least a channel ID + caller info) when
///      someone calls this user.
///   3. On push receipt (below), reports a new incoming call to CallKit and joins
///      the channel once the user answers.
final class PushKitManager: NSObject, PKPushRegistryDelegate {

    private var onIncomingCall: ((String) -> Void)?

    override init() {
        super.init()
    }

    /// Registers for VoIP pushes. Call once at app launch.
    func register() -> PKPushRegistry {
        let registry = PKPushRegistry(queue: nil)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        return registry
    }

    // MARK: - PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        // Send `pushCredentials.token` to your signaling backend so it can
        // deliver VoIP pushes to this device. No backend exists in this prototype.
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        // Backend should be told this token is dead. No backend in this prototype.
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // TODO: incoming call
        // ------------------------------------------------------------------
        // This is where an incoming call would be surfaced. With a real
        // signaling backend in place, this handler would:
        //
        //   1. Parse the channel ID (and caller display name) from `payload.dictionaryPayload`.
        //   2. Build a `CXCallUpdate` and call
        //      `callKitManager.provider.reportNewIncomingCall(
        //          with: UUID(), update: update, completion: ...)`
        //      using the shared `CallKitManager`/`CXProvider`.
        //   3. Call `completion()` once CallKit resolves (or immediately).
        //   4. On `CXAnswerCallAction`, join the channel via `AgoraService.joinChannel`.
        //
        // None of that is wired up here — the prototype has no backend to send
        // pushes, so this handler does nothing but acknowledge the push.
        completion()
    }
}