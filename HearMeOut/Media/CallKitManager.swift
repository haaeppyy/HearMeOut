import AVFoundation
import CallKit
import Foundation

/// Wraps `CXProvider` + `CXCallController` for the outgoing-call lifecycle.
///
/// Ownership is deliberately simple for this prototype:
/// - `provider(_:perform:)` for a `CXStartCallAction` joins the Agora channel,
///   fulfilling the action and reporting the "connecting" state.
/// - `startCall`/`endCall` are triggered by the view model; the provider delegate
///   does the actual Agora work so CallKit's ordering is respected.
///
/// Incoming-call plumbing is deliberately absent here — see `PushKitManager`.
/// Wraps `CXProvider` + `CXCallController` for the outgoing-call lifecycle.
///
/// Deliberately engine-agnostic now — it used to call `agora?.leaveChannel()`
/// directly from its own CXProviderDelegate callback, which worked only
/// because every call was an Agora call. That breaks once PSTN calls go
/// through Twilio's SDK instead. Media teardown and audio-session
/// activation/deactivation are now closures the active engine sets, not a
/// hardcoded Agora reference — Twilio's own docs are explicit that audio
/// device enable/disable must happen inside `didActivate`/`didDeactivate`,
/// so this needs to be real plumbing, not a no-op comment.
final class CallKitManager: NSObject, CXProviderDelegate {

    private static let appName = "EchoSign"

    private let provider: CXProvider
    private let callController = CXCallController()

    private(set) var activeCallUUID: UUID?

    /// Invoked when CallKit asks us to tear the call down (user ended it from
    /// the CallKit in-call UI, provider reset, etc.) — the active engine sets
    /// this to whatever actually releases its media (Agora's leaveChannel,
    /// Twilio's TVOCall.disconnect, etc.).
    var onTeardownMedia: (() -> Void)?

    /// Fired from `provider(_:didActivate:)` — Twilio's SDK requires enabling
    /// its audio device exactly here, not at connect time, or audio can come
    /// up in the wrong state. Agora's engine currently no-ops this.
    var onAudioSessionActivated: ((AVAudioSession) -> Void)?

    /// Fired from `provider(_:didDeactivate:)` — same requirement in reverse.
    var onAudioSessionDeactivated: ((AVAudioSession) -> Void)?

    /// Invoked when CallKit asks us to tear the call down (user ended it from the
    /// CallKit in-call UI, provider reset, etc.). The view model uses this to sync UI.
    var onCallEndedByCallKit: (() -> Void)?

    /// Surfaced when a CallKit transaction is rejected by the OS (e.g. stale call
    /// state). The view model shows this so failures are visible, not silent.
    var onCallKitError: ((String) -> Void)?

    /// Fired when the user answers an incoming call from the CallKit UI —
    /// the view model uses this to actually join Agora, since CallKit only
    /// knows about the call's existence, not how to join its media.
    var onAnswerCall: ((UUID) -> Void)?

    override init() {
        // Provider name comes from the app (CFBundleDisplayName); localizedName
        // is get-only since iOS 14.
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]

        self.provider = CXProvider(configuration: configuration)
        super.init()

        provider.setDelegate(self, queue: nil)
    }

    // MARK: - Outgoing call control (called by the view model)

    func startCall(displayName: String) {
        guard activeCallUUID == nil else { return }

        endStaleCalls()

        let uuid = UUID()
        activeCallUUID = uuid

        let handle = CXHandle(type: .generic, value: displayName)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = false

        request(CXTransaction(action: startAction))
    }

    /// End any calls CallKit still believes are active (left behind by previous
    /// sessions that force-quit mid-call). With `maximumCallsPerCallGroup = 1`
    /// a stale call otherwise makes every new start transaction fail.
    private func endStaleCalls() {
        for call in callController.callObserver.calls {
            guard call.uuid != activeCallUUID else { continue }
            print("[CallKit] ending stale call \(call.uuid)")
            request(CXTransaction(action: CXEndCallAction(call: call.uuid)))
        }
    }

    func endCall() {
        guard let uuid = activeCallUUID else { return }
        request(CXTransaction(action: CXEndCallAction(call: uuid)))
    }

    /// Report the call as connected once the local user has joined the channel
    /// (fires when `AgoraService` reports `didJoinChannel`).
    func reportConnected() {
        guard let uuid = activeCallUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// Report a failed call (e.g. Agora join / connection error).
    func reportCallFailed() {
        guard let uuid = activeCallUUID else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        activeCallUUID = nil
    }

    // MARK: - Incoming call control (called by PushKitManager)

    /// Reports an incoming call to CallKit, showing the native incoming-call
    /// UI. `completion` fires once CallKit has processed the report — call
    /// PushKit's own completion handler from inside it, per Apple's
    /// requirement that `reportNewIncomingCall` be answered promptly.
    func reportIncomingCall(uuid: UUID, callerName: String, completion: @escaping (Error?) -> Void) {
        endStaleCalls()
        activeCallUUID = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                print("[CallKit] reportNewIncomingCall failed: \(error)")
                self?.activeCallUUID = nil
            }
            completion(error)
        }
    }

    private func request(_ transaction: CXTransaction) {
        callController.request(transaction) { [weak self] error in
            if let error {
                print("[CallKit] transaction error: \(error)")
                self?.onCallKitError?(error.localizedDescription)
            }
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        print("[CallKit] providerDidReset")
        activeCallUUID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // The Agora join is owned by CallViewModel, not CallKit — CallKit's
        // transaction can be rejected or reset independently of the media call.
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onTeardownMedia?()
        action.fulfill()
        activeCallUUID = nil
        onCallEndedByCallKit?()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onAudioSessionActivated?(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        onAudioSessionDeactivated?(audioSession)
        // Baseline reset stays here regardless of which engine was active,
        // so a stale category never leaks into the next call.
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - CXProviderDelegate stubs for interactions we don't support yet

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Fulfilled immediately (standard pattern — audio comes up properly
        // via didActivate regardless of exactly when fulfill() is called);
        // the actual Agora join happens async via onAnswerCall, since
        // CallKit itself has no concept of "join this specific channel."
        onAnswerCall?(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        action.fulfill()
    }
}
