import Combine
import Foundation

/// Owns everything that has to exist for the app's *entire* lifetime, not
/// just while a call screen happens to be on screen: `CallKitManager`,
/// `PushKitManager`, and the shared `AgoraService`/`CallSignalingClient`.
///
/// This matters specifically because `PushKitManager` has to be
/// registered once at app launch to receive incoming-call pushes — if it
/// were owned by a per-screen `CallViewModel` instead (as it would be
/// using only that class's convenience initializer), an incoming call
/// while the dialer screen isn't on screen would never be caught at all.
///
/// The UI layer (wherever that ends up living) observes
/// `pendingIncomingCall` to show an answer/decline surface, and calls
/// `answerIncoming()`/`declineIncoming()`. `activeCallViewModel` is the
/// `CallViewModel` for whichever call — outgoing or answered-incoming —
/// is currently live; the UI binds to it once it exists.
@MainActor
final class AppCallCoordinator: ObservableObject {

    @Published private(set) var activeCallViewModel: CallViewModel?
    @Published private(set) var pendingIncomingCall: PendingIncomingCall?

    struct PendingIncomingCall: Identifiable {
        let id: String
        let callerID: String
        let callerName: String
        /// The caller's phone number, when the server knew it.
        let callerPhone: String?
    }

    private let agora: AgoraService
    private let callKit: CallKitManager
    /// The signaling client. It is internal rather than private so the rest
    /// of the app can reach the backend for things that are not calls —
    /// restoring the user's profile, for example.
    let signaling: CallSignalingClient
    private let pushKit: PushKitManager
    private let incomingCallListener: IncomingCallListener
    private let rtmFactory: () -> AgoraRtmService
    private let callHistoryStore: CallHistoryStore?
    private var seenIncomingCallIDs = Set<String>()

    init(signaling: CallSignalingClient? = nil, callHistory: CallHistoryStore? = nil) {
        let agora = AgoraService(appID: Secrets.agoraAppID)
        let callKit = CallKitManager()
        let signaling = signaling ?? CallSignalingClient(baseURL: Secrets.backendBaseURL) {
            try await Secrets.currentUserAuthToken()
        }
        self.agora = agora
        self.callKit = callKit
        self.signaling = signaling
        self.pushKit = PushKitManager(callKit: callKit, signaling: signaling)
        self.incomingCallListener = IncomingCallListener(client: AuthService.shared.client)
        self.rtmFactory = { AgoraRtmService() }
        self.callHistoryStore = callHistory

        incomingCallListener.onIncomingCall = { [weak self] call in
            self?.handleRealtimeIncomingCall(call)
        }

        incomingCallListener.onCallStoppedRinging = { [weak self] callId in
            self?.handleCallStoppedRinging(callId: callId.uuidString)
        }

        pushKit.onIncomingCallReceived = { [weak self] callId in
            self?.registerIncomingCall(callId) ?? false
        }

        pushKit.onIncomingCallAnswered = { [weak self] callId, callerId, callerName, callerPhone in
            self?.handleIncomingCallAnswered(
                callId: callId,
                callerId: callerId,
                callerName: callerName,
                callerPhone: callerPhone
            )
        }

        // Single owner of this closure — see PushKitManager's own note on
        // why it doesn't set this itself. Both reactions need to happen:
        // reset whichever CallViewModel is active (if any — an answered
        // call has one, a declined-before-answering call doesn't), and
        // tell the backend the call ended if it was never answered.
        callKit.onCallEndedByCallKit = { [weak self] in
            self?.activeCallViewModel?.endCall()
            self?.pushKit.handleCallEnded()
        }
    }

    /// Call once at app launch (see `EchoSignApp`).
    func start() {
        pushKit.register()
    }

    /// Called whenever an authenticated session becomes available. This
    /// retries a token delivered by PushKit before the user signed in.
    func didAuthenticate() {
        pushKit.register()
        pushKit.registerCurrentToken()
        if let userID = AuthService.shared.userID {
            incomingCallListener.start(for: userID)
        }
    }

    func didReturnToForeground() {
        incomingCallListener.catchUp()
    }

    func didSignOut() {
        incomingCallListener.stop()
        pendingIncomingCall = nil
    }

    /// Starts an outgoing call and returns the view model that drives it.
    @discardableResult
    func startOutgoingCall(
        target: CallTarget,
        phone: String? = nil,
        remoteUserID: String? = nil
    ) -> CallViewModel {
        let viewModel = makeCallViewModel(
            otherPartyDisplayName: target.displayName,
            phone: phone,
            remoteUserID: remoteUserID
        )
        activeCallViewModel = viewModel
        viewModel.startCall(target: target)
        return viewModel
    }

    func savePhoneNumber(_ phone: String) async throws -> String {
        try await signaling.savePhoneNumber(phone)
    }

    func startOutgoingCall(phone: String) async throws {
        let callee = try await signaling.lookupUser(phone: phone)
        _ = startOutgoingCall(target: .contact(id: callee.id, displayName: callee.displayName ?? phone))
    }

    private func handleIncomingCallAnswered(
        callId: String,
        callerId: String,
        callerName: String,
        callerPhone: String?
    ) {
        let viewModel = makeCallViewModel(
            otherPartyDisplayName: callerName,
            phone: callerPhone,
            remoteUserID: callerId
        )
        viewModel.direction = .incoming
        activeCallViewModel = viewModel
        viewModel.answerIncomingCall(callId: callId)
    }

    func clearActiveCall() {
        activeCallViewModel = nil
    }

    func answerPendingIncomingCall() {
        guard let pending = pendingIncomingCall else { return }
        pendingIncomingCall = nil
        let viewModel = makeCallViewModel(
            otherPartyDisplayName: pending.callerName,
            phone: pending.callerPhone,
            remoteUserID: pending.callerID
        )
        viewModel.direction = .incoming
        activeCallViewModel = viewModel
        viewModel.answerIncomingCall(callId: pending.id)
    }

    func declinePendingIncomingCall() {
        guard let pending = pendingIncomingCall else { return }
        pendingIncomingCall = nil
        // A call that was turned away is a decline, which the caller sees
        // as such rather than as a call that was never picked up.
        Task { try? await signaling.endCall(callId: pending.id, outcome: .declined) }
    }

    /// A call that was ringing is no longer ringing — the caller hung up,
    /// or it was answered somewhere else. Take the ringing UI down instead
    /// of leaving it up for a call that is already over.
    private func handleCallStoppedRinging(callId: String) {
        guard pendingIncomingCall?.id == callId else { return }
        pendingIncomingCall = nil
    }

    private func registerIncomingCall(_ callId: String) -> Bool {
        seenIncomingCallIDs.insert(callId).inserted
    }

    private func handleRealtimeIncomingCall(_ call: IncomingCallListener.IncomingCall) {
        let callId = call.id.uuidString
        guard registerIncomingCall(callId) else { return }
        // The server snapshots the caller's name and number onto the call
        // when it is created, so the phone can show who is calling without
        // being able to read anyone else's profile.
        let callerName = call.callerDisplayName ?? "HearMeOut user"

        #if targetEnvironment(simulator)
        pendingIncomingCall = PendingIncomingCall(
            id: callId,
            callerID: call.callerID.uuidString,
            callerName: callerName,
            callerPhone: call.callerPhone
        )
        #else
        pushKit.receiveIncomingCall(
            callId: callId,
            callerId: call.callerID.uuidString,
            callerName: callerName,
            callerPhone: call.callerPhone
        )
        #endif
    }

    private func makeCallViewModel(
        otherPartyDisplayName: String,
        phone: String? = nil,
        remoteUserID: String? = nil
    ) -> CallViewModel {
        let viewModel = CallViewModel(
            otherPartyDisplayName: otherPartyDisplayName,
            agora: agora,
            callKit: callKit,
            captionService: CaptionService(),
            signaling: signaling,
            rtmFactory: rtmFactory
        )
        viewModel.otherPartyPhone = phone
        viewModel.otherPartyRemoteUserID = remoteUserID
        viewModel.onCallEnded = { [weak self, weak viewModel] summary in
            // The transcript is only here if the user said they wanted to
            // keep it.
            let transcript = viewModel?.transcriptProvider?() ?? []
            self?.callHistoryStore?.record(summary: summary, transcript: transcript)
            self?.clearActiveCall()
        }
        return viewModel
    }
}
