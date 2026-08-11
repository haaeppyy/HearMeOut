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
final class CallKitManager: NSObject, CXProviderDelegate {

    private static let appName = "EchoSign"

    private let provider: CXProvider
    private let callController = CXCallController()
    private weak var agora: AgoraService?

    private(set) var activeCallUUID: UUID?

    /// Invoked when CallKit asks us to tear the call down (user ended it from the
    /// CallKit in-call UI, provider reset, etc.). The view model uses this to sync UI.
    var onCallEndedByCallKit: (() -> Void)?

    /// Surfaced when a CallKit transaction is rejected by the OS (e.g. stale call
    /// state). The view model shows this so failures are visible, not silent.
    var onCallKitError: ((String) -> Void)?

    init(agora: AgoraService) {
        // Provider name comes from the app (CFBundleDisplayName); localizedName
        // is get-only since iOS 14.
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]

        self.provider = CXProvider(configuration: configuration)
        self.agora = agora
        super.init()

        provider.setDelegate(self, queue: nil)
    }

    // MARK: - Outgoing call control (called by the view model)

    func startCall(channelID: String) {
        guard activeCallUUID == nil else { return }

        endStaleCalls()

        let uuid = UUID()
        activeCallUUID = uuid

        let handle = CXHandle(type: .generic, value: channelID)
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
        agora?.leaveChannel()
        action.fulfill()
        activeCallUUID = nil
        onCallEndedByCallKit?()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Prototype: Agora manages its own audio session settings after join.
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Reset to the baseline category configured at launch.
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - CXProviderDelegate stubs for interactions we don't support yet

    // TODO: incoming call — see PushKitManager. When a VoIP push arrives, the
    // backend would call `provider.reportNewIncomingCall(with:update:completion:)`
    // here, which is how CallKit can show the incoming call UI.
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
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