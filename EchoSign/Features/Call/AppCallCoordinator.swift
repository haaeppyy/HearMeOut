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

    private let agora: AgoraService
    private let callKit: CallKitManager
    private let signaling: CallSignalingClient
    private let pushKit: PushKitManager
    private let rtmFactory: () -> AgoraRtmService

    init() {
        let agora = AgoraService(appID: Secrets.agoraAppID)
        let callKit = CallKitManager()
        let signaling = CallSignalingClient(baseURL: Secrets.backendBaseURL) {
            try await Secrets.currentUserAuthToken()
        }
        self.agora = agora
        self.callKit = callKit
        self.signaling = signaling
        self.pushKit = PushKitManager(callKit: callKit, signaling: signaling)
        self.rtmFactory = { AgoraRtmService() }

        pushKit.onIncomingCallAnswered = { [weak self] callId, callerId in
            self?.handleIncomingCallAnswered(callId: callId, callerId: callerId)
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

    func startOutgoingCall(target: CallTarget) -> CallViewModel {
        let viewModel = makeCallViewModel()
        activeCallViewModel = viewModel
        viewModel.startCall(target: target)
        return viewModel
    }

    private func handleIncomingCallAnswered(callId: String, callerId: String) {
        let viewModel = makeCallViewModel()
        activeCallViewModel = viewModel
        viewModel.answerIncomingCall(callId: callId)
    }

    private func makeCallViewModel() -> CallViewModel {
        CallViewModel(
            channelID: "",
            agora: agora,
            callKit: callKit,
            captionService: CaptionService(),
            signaling: signaling,
            rtmFactory: rtmFactory
        )
    }
}
