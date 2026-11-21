import AVFoundation
import SwiftUI

@main
struct HearMeOutApp: App {

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var callCoordinator: AppCallCoordinator
    @StateObject private var auth = AuthService.shared
    @StateObject private var stores: AppStores
    @StateObject private var router: CallRouter

    init() {
        Self.configureAudioSession()
        // One signaling client for the whole app: the call path and the
        // profile path talk to the same backend.
        let signaling = CallSignalingClient(baseURL: Secrets.backendBaseURL) {
            try await Secrets.currentUserAuthToken()
        }
        let stores = AppStores.make(signaling: signaling)
        let coordinator = AppCallCoordinator(
            signaling: signaling,
            callHistory: stores.callHistory
        )
        _stores = StateObject(wrappedValue: stores)
        _callCoordinator = StateObject(wrappedValue: coordinator)
        _router = StateObject(wrappedValue: CallRouter(
            signaling: signaling,
            contactsStore: stores.contacts,
            coordinator: coordinator
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(callCoordinator)
                .environmentObject(stores)
                .environmentObject(router)
                .environmentObject(stores.profile)
                .environmentObject(stores.contacts)
                .environmentObject(stores.callHistory)
                .onAppear {
                    stores.loadAll()
                    // Registers for VoIP pushes once, at app launch — not tied
                    // to whether any particular call screen is on screen. This
                    // has to happen here, not inside CallViewModel, or an
                    // incoming call while the user is anywhere else in the app
                    // would never be caught at all.
                    callCoordinator.start()
                    if auth.userID != nil {
                        callCoordinator.didAuthenticate()
                    }
                }
                .onChange(of: auth.userID) { _, userID in
                    if userID != nil {
                        callCoordinator.didAuthenticate()
                    } else {
                        callCoordinator.didSignOut()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        callCoordinator.didReturnToForeground()
                        // The app may have missed calls while it was in the
                        // background.
                        Task { await stores.syncHistory() }
                    }
                }
        }
    }

    /// Configure the audio session before any call starts so Agora and the
    /// speech services inherit the voice-call route. Agora may re-apply its
    /// own session settings on join; this guarantees a sensible baseline.
    private static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        } catch {
            assertionFailure("Failed to configure the audio session: \(error)")
        }
    }
}
