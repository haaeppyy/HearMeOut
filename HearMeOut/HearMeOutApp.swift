import SwiftUI
import UIKit

@main
struct HearMeOutApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @StateObject private var database = AppDatabase.make()
    @StateObject private var auth: SupabaseAuthManager
    @StateObject private var activeCall: ActiveCall
    @StateObject private var callKit: CallKitManager
    @StateObject private var pushKit: PushKitManager
    @StateObject private var agora: AgoraCallManager
    @StateObject private var coordinator: CallCoordinator

    init() {
        // NOTE: the two launch-arg literals intentionally share no prefix.
        // During test bring-up, the second of two `--uitest-*` literals was
        // repeatedly absent from freshly linked binaries while its sibling
        // was present; distinct prefixes eliminated the flakiness. (An
        // earlier root-cause theory — stale incremental builds — was also
        // real: force object deletion when a source edit seems ignored.)
        let launchArgs = CommandLine.arguments.joined(separator: " ")
        NSLog("[HearMeOut] launch args: %@", launchArgs)
        if launchArgs.contains("--uitest-local-backend-off") {
            AppConfig.forceLocalOnly = true
        }
        if launchArgs.contains("--fresh-install-wipe") {
            // Hermetic UI tests: reset persisted onboarding state before
            // @AppStorage/GRDB read it. NOTE: explicit overwrite, NOT
            // removeObject/removePersistentDomain — both provably no-op on
            // these pre-existing plist values in this simulator runtime
            // (read-back still returns old values), while set() works.
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: "hasCompletedOnboarding")
            defaults.set("", forKey: "userName")
            defaults.set("", forKey: "userPhoneNumber")
            defaults.set("", forKey: "communicationProfile")
            defaults.set("Text Mode", forKey: "defaultCallingInterface")
            if let dir = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            ) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("hearmeout.sqlite"))
            }
        }
        let auth = SupabaseAuthManager()
        let activeCall = ActiveCall()
        let callKit = CallKitManager()
        let pushKit = PushKitManager()
        let agora = AgoraCallManager()
        _auth = StateObject(wrappedValue: auth)
        _activeCall = StateObject(wrappedValue: activeCall)
        _callKit = StateObject(wrappedValue: callKit)
        _pushKit = StateObject(wrappedValue: pushKit)
        _agora = StateObject(wrappedValue: agora)
        _coordinator = StateObject(wrappedValue: CallCoordinator(
            auth: auth, active: activeCall, callKit: callKit, pushKit: pushKit, agora: agora
        ))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    CallsView {
                        hasCompletedOnboarding = false
                    }
                } else {
                    CommunicationOnboarding {
                        hasCompletedOnboarding = true
                    }
                }
            }
            .preferredColorScheme(.light)
            .environmentObject(database)
            .environmentObject(auth)
            .environmentObject(activeCall)
            .environmentObject(callKit)
            .environmentObject(pushKit)
            .environmentObject(agora)
            .environmentObject(coordinator)
            .task {
                // One-time backend wiring: restores the auth session, hooks
                // up CallKit/PushKit/Agora callbacks and starts VoIP
                // registration. Idempotent; safe to re-run on reappear.
                coordinator.activate()
            }
        }
    }
}

private enum CommunicationProfile: String, CaseIterable, Identifiable {
    case hearAndSpeak
    case hearOnly
    case partialHearing
    case speakOnly
    case textOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hearAndSpeak: "I can hear & speak"
        case .hearOnly: "I can hear, but I can’t speak"
        case .partialHearing: "I have partial hearing"
        case .speakOnly: "I can speak, but I can’t hear"
        case .textOnly: "I can’t hear or speak"
        }
    }

    var description: String {
        switch self {
        case .hearAndSpeak: "Use voice calling as your default."
        case .hearOnly: "Use text-first calling to reply without speaking."
        case .partialHearing: "Use text-first calling with optional audio when it helps."
        case .speakOnly: "Use text-first calling with visual responses."
        case .textOnly: "Use text-first calling for every conversation."
        }
    }

    var symbol: String {
        switch self {
        case .hearAndSpeak: "waveform"
        case .hearOnly: "ear.and.waveform"
        case .partialHearing: "ear.badge.waveform"
        case .speakOnly: "mouth"
        case .textOnly: "text.bubble"
        }
    }

    var defaultCallingInterface: String {
        self == .hearAndSpeak ? "Audio Mode" : "Text Mode"
    }
}

private struct CommunicationOnboarding: View {
    let complete: () -> Void
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var selection: CommunicationProfile?
    @AppStorage("userName") private var userName = ""
    @AppStorage("userPhoneNumber") private var userPhoneNumber = ""
    @AppStorage("communicationProfile") private var savedProfile = ""
    @AppStorage("defaultCallingInterface") private var defaultCallingInterface = "Text Mode"
    // Phase 1 auth: email + password. Skipped entirely until the backend is
    // configured, so the local-only flow keeps working out of the box.
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var authError: String?
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 30)

                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Let’s get to know you")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.primary)
                    .padding(.top, 26)

                Text("Tell us how to address you, then choose the experience that feels most natural. You can change this later.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.bottom, 26)

                VStack(spacing: 12) {
                    OnboardingTextField(title: "Name", placeholder: "Your name", text: $userName)
                    OnboardingTextField(title: "Phone number", placeholder: "+91 98765 43210", text: $userPhoneNumber, keyboardType: .phonePad)

                    if AppConfig.isBackendConfigured {
                        OnboardingTextField(title: "Email", placeholder: "you@example.com", text: $email, keyboardType: .emailAddress)
                        OnboardingSecureField(title: "Password", placeholder: "6+ characters", text: $password)

                        Button(isSigningIn ? "I have an account — Sign in" : "New here — Create account") {
                            isSigningIn.toggle()
                            authError = nil
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let authError {
                            Text(authError)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    ForEach(CommunicationProfile.allCases) { profile in
                        CommunicationOptionCard(profile: profile, isSelected: selection == profile) {
                            selection = profile
                        }
                    }
                }

                Color.clear.frame(height: 22)

                Button {
                    guard canContinue, !isAuthenticating else { return }
                    Task { await continueTapped() }
                } label: {
                    Text(isAuthenticating ? (isSigningIn ? "Signing in…" : "Creating account…") : "Continue")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(canContinue ? Color.blue : Color.secondary.opacity(0.35), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canContinue || isAuthenticating)
                .accessibilityHint(canContinue ? "Saves your profile and communication preference." : "Enter your name and phone number, then select how you communicate to continue.")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
        }
    }

    private var canContinue: Bool {
        guard selection != nil,
              !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !userPhoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        guard AppConfig.isBackendConfigured else { return true }
        return email.contains("@") && password.count >= 6
    }

    /// Real auth runs before onboarding completes. Errors surface inline —
    /// never a silent fall-through to the local-only success path.
    private func continueTapped() async {
        guard let selection else { return }
        if AppConfig.isBackendConfigured {
            isAuthenticating = true
            defer { isAuthenticating = false }
            do {
                let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
                if isSigningIn {
                    try await auth.signIn(email: cleanEmail, password: password)
                    try await auth.syncProfileAfterSignIn(name: userName, phone: userPhoneNumber)
                } else {
                    try await auth.signUp(name: userName, email: cleanEmail, phone: userPhoneNumber, password: password)
                }
            } catch {
                authError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
        }
        savedProfile = selection.rawValue
        defaultCallingInterface = selection.defaultCallingInterface
        complete()
    }
}

private struct OnboardingTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.system(size: 16))
                .keyboardType(keyboardType)
                .textContentType(title == "Name" ? .name : (title == "Email" ? .emailAddress : .telephoneNumber))
                .textInputAutocapitalization(title == "Email" ? .never : .words)
                .autocorrectionDisabled(title == "Email")
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Color(uiColor: .systemGray5).opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct OnboardingSecureField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            SecureField(placeholder, text: $text)
                .font(.system(size: 16))
                .textContentType(.password)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Color(uiColor: .systemGray5).opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct CommunicationOptionCard: View {
    let profile: CommunicationProfile
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 16) {
                Image(systemName: profile.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.blue)
                    .frame(width: 48, height: 48)
                    .background(isSelected ? Color.blue : Color.blue.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(profile.description)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.primary.opacity(0.72) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary.opacity(0.45))
            }
            .foregroundStyle(.primary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.blue.opacity(0.1) : Color(uiColor: .systemGray5).opacity(0.8), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? Color.blue : Color.white.opacity(0.8), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(profile.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(profile.description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
