import SwiftUI

/// The first-run screen: name, phone number, and how the user prefers to
/// communicate.
///
/// The answers are written to the server, not just to the device, so signing
/// in on a second phone does not ask the same questions again.
struct CommunicationOnboarding: View {
    @EnvironmentObject private var stores: AppStores
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var name = ""
    @State private var phoneNumber = ""
    @State private var selection: CommunicationProfile?
    @State private var isSaving = false
    @State private var errorMessage: String?

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
                    OnboardingTextField(title: "Name", placeholder: "Your name", text: $name)
                    OnboardingTextField(title: "Phone number", placeholder: "+91 98765 43210", text: $phoneNumber, keyboardType: .phonePad)

                    ForEach(CommunicationProfile.allCases) { profile in
                        CommunicationOptionCard(profile: profile, isSelected: selection == profile) {
                            selection = profile
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .padding(.top, 16)
                }

                Color.clear.frame(height: 22)

                Button {
                    Task { await save() }
                } label: {
                    Text(isSaving ? "Saving…" : "Continue")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(canContinue ? Color.blue : Color.secondary.opacity(0.35), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canContinue || isSaving)
                .accessibilityHint(canContinue ? "Saves your profile and communication preference." : "Enter your name and phone number, then select how you communicate to continue.")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
        }
    }

    private var canContinue: Bool {
        selection != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        guard let selection else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalise before it leaves the device, so the number the server
        // stores is the same form it compares against.
        let normalizedPhone: String
        do {
            normalizedPhone = try PhoneNumber.normalize(phoneNumber)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        do {
            try await stores.saveProfile(
                displayName: trimmedName,
                phone: normalizedPhone,
                communicationProfile: selection.rawValue,
                language: profileStore.language
            )
            profileStore.markOnboardingComplete()
            profileStore.setDefaultCallingInterface(selection.defaultCallingInterface)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? CallSignalingClient.SignalingError,
           case .serverError(let status, let message) = error {
            switch status {
            case 409: return message ?? "That phone number is already linked to another account."
            case 400: return message ?? "Please check the details you entered."
            case 429: return "Too many attempts. Please wait a moment and try again."
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// A labelled text field used on the onboarding screen.
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
                .textContentType(title == "Name" ? .name : .telephoneNumber)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Color(uiColor: .systemGray5).opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// One selectable communication-profile card.
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
