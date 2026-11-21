import SwiftUI

/// What the app is showing right now.
enum RootState: Equatable {
    /// Checking whether there is a stored session.
    case restoringSession
    /// No session — the user has to sign in.
    case signedOut
    /// Signed in, but the account's profile has not come back yet.
    case loadingProfile
    /// Signed in, but the account has not been through onboarding.
    case needsOnboarding
    /// Signed in and set up.
    case main

    /// Works out what to show from the four things that decide it.
    ///
    /// The order matters: a session that is still being restored hides
    /// everything else, and an account whose profile has not arrived yet
    /// cannot be sent to onboarding or to the app, because the answer is not
    /// known.
    static func resolve(
        isRestoringSession: Bool,
        isSignedIn: Bool,
        isProfileLoaded: Bool,
        needsOnboarding: Bool
    ) -> RootState {
        if isRestoringSession { return .restoringSession }
        if !isSignedIn { return .signedOut }
        if !isProfileLoaded { return .loadingProfile }
        if needsOnboarding { return .needsOnboarding }
        return .main
    }
}

/// The root of the app.
///
/// It owns two things: which screen the user is on, and the presentation of
/// active and incoming calls.
///
/// Both calls are rendered as overlays here rather than as covers from
/// deeper in the hierarchy. The Calls tab already presents a full-screen
/// cover for the call detail screen, and a second cover presented from a
/// different level while that one is up fails to appear at all — so an
/// incoming call that arrives while the user is reading a call detail would
/// silently never ring.
struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var stores: AppStores
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var callCoordinator: AppCallCoordinator

    var body: some View {
        ZStack {
            content
                .zIndex(0)

            if let viewModel = callCoordinator.activeCallViewModel {
                ActiveCallContainer(viewModel: viewModel)
                    .zIndex(10)
            }

            if let pending = callCoordinator.pendingIncomingCall {
                IncomingCallOverlay(
                    callerName: pending.callerName,
                    answer: { callCoordinator.answerPendingIncomingCall() },
                    decline: { callCoordinator.declinePendingIncomingCall() }
                )
                .zIndex(20)
            }
        }
        .task(id: auth.userID) {
            guard let userID = auth.userID else { return }
            // Fetching the profile is what decides whether this account
            // still has to go through onboarding.
            await stores.loadProfile(for: userID.uuidString)
            // And the history picks up anything that happened while the app
            // was closed.
            await stores.syncHistory()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .restoringSession:
            ProgressView("Restoring session…")
        case .signedOut:
            AuthView(auth: auth)
        case .loadingProfile:
            ProgressView("Loading your profile…")
        case .needsOnboarding:
            CommunicationOnboarding()
        case .main:
            CallsView(logout: signOut)
        }
    }

    private var state: RootState {
        RootState.resolve(
            isRestoringSession: auth.isRestoringSession,
            isSignedIn: auth.session != nil,
            isProfileLoaded: profileStore.isProfileLoaded,
            needsOnboarding: profileStore.needsOnboarding
        )
    }

    private func signOut() {
        Task {
            try? await auth.signOut()
            callCoordinator.didSignOut()
            stores.resetForSignOut()
        }
    }
}

/// The incoming-call surface, presented as an overlay at the root.
private struct IncomingCallOverlay: View {
    let callerName: String
    let answer: () -> Void
    let decline: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            IncomingCallView(callerName: callerName, answer: answer, decline: decline)
        }
        .transition(.opacity)
    }
}
