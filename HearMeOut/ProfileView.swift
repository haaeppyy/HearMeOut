import SwiftUI
import PhotosUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var auth: SupabaseAuthManager
    @Binding var profileImage: UIImage?
    let logout: () -> Void
    let dismiss: () -> Void
    @State private var notificationsEnabled = true
    @AppStorage("defaultCallingInterface") private var callMode = "Text Mode"
    @AppStorage("userName") private var userName = ""
    @AppStorage("userPhoneNumber") private var userPhoneNumber = ""
    @AppStorage("communicationProfile") private var communicationProfile = ""
    @State private var isShowingCallModePicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isShowingEngineTest = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack {
                        Button(action: dismiss) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(.black)
                                .frame(width: 46, height: 46)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 0.8) }
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)

                    VStack(spacing: 8) {
                        ZStack(alignment: .bottomTrailing) {
                            ProfileAvatar(size: 84, image: profileImage)

                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 23, height: 23)
                                    .background(Color(uiColor: .systemGray))
                                    .clipShape(Circle())
                                    .overlay { Circle().stroke(Color(uiColor: .systemGray6), lineWidth: 2) }
                            }
                        }
                        .onChange(of: selectedPhoto) { _, newPhoto in
                            Task {
                                guard let newPhoto,
                                      let data = try? await newPhoto.loadTransferable(type: Data.self),
                                      let image = UIImage(data: data) else { return }
                                await MainActor.run {
                                    profileImage = image
                                    persistProfile()
                                }
                            }
                        }

                        Text(userName)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(.black)
                            .padding(.top, 10)

                        Text(userPhoneNumber)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, -2)

                    VStack(spacing: 25) {
                        SettingsCard {
                            Toggle("Notifications", isOn: $notificationsEnabled)
                                .font(.system(size: 16))
                                .tint(.green)
                                .frame(minHeight: 57)
                        }

                        SettingsSection(title: "Communication", icon: "phone.bubble") {
                            SettingsRow(title: "My Voice", value: "Voice 1 : Female")
                            CallModeRow(mode: $callMode) {
                                isShowingCallModePicker = true
                            }
                            .popover(
                                isPresented: $isShowingCallModePicker,
                                attachmentAnchor: .rect(.bounds),
                                arrowEdge: .bottom
                            ) {
                                CallModePicker(selection: $callMode) {
                                    isShowingCallModePicker = false
                                }
                                // Keep the compact iPhone presentation anchored
                                // to this row rather than adapting to a sheet.
                                .presentationCompactAdaptation(.popover)
                            }
                        }

                        SettingsSection(title: "Usage & Billing", icon: "indianrupeesign.circle") {
                            SettingsRow(title: "Usage this month")
                            SettingsRow(title: "Payment History")
                        }

                        SettingsSection(title: "Privacy", icon: "lock.shield") {
                            SettingsRow(title: "Privacy and Data")
                        }

                        SettingsSection(title: "Support", icon: "questionmark.circle") {
                            SettingsRow(title: "Help Center")
                            SettingsRow(title: "Contact Support")
                            SettingsRow(title: "About")
                        }

                        Button(action: signOut) {
                            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .frame(height: 57)
                                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Clears your profile and returns to onboarding.")

                        Button(action: { isShowingEngineTest = true }) {
                            Label("Speech Engine Test", systemImage: "waveform.badge.mic")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.blue)
                                .frame(maxWidth: .infinity)
                                .frame(height: 57)
                                .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Tests speech recognition and synthesis without a call.")
                    }
                    .padding(.top, 28)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                }
            }

        }
        .animation(.easeOut(duration: 0.18), value: isShowingCallModePicker)
        .fullScreenCover(isPresented: $isShowingEngineTest) {
            NavigationStack {
                EngineTestView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { isShowingEngineTest = false }
                        }
                    }
            }
        }
        .onChange(of: userName) { _, _ in persistProfile() }
        .onChange(of: userPhoneNumber) { _, _ in persistProfile() }
        .onChange(of: communicationProfile) { _, _ in persistProfile() }
        .onChange(of: callMode) { _, _ in persistProfile() }
    }

    private func signOut() {
        // Server session first (best effort — local wipe happens regardless).
        Task { try? await auth.signOut() }
        // Delete the local GRDB profile row so a fresh onboarding after
        // logout actually gets a new DB row instead of reusing stale state.
        try? database.profiles.delete()
        profileImage = nil
        userName = ""
        userPhoneNumber = ""
        communicationProfile = ""
        callMode = "Text Mode"
        logout()
    }

    private func persistProfile() {
        do {
            let existing = try database.profiles.fetch()
            let now = Date()
            try database.profiles.save(LocalProfileRecord(
                id: existing?.id ?? "local-profile",
                remoteUserID: existing?.remoteUserID,
                name: userName,
                phoneNumber: userPhoneNumber,
                communicationProfile: communicationProfile.isEmpty ? nil : communicationProfile,
                defaultCallingInterface: callMode,
                profileImageData: profileImage?.jpegData(compressionQuality: 0.9),
                hasCompletedOnboarding: true,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            ))
        } catch {
            print("Unable to save profile: \(error)")
        }
    }
}

struct ProfileAvatar: View {
    let size: CGFloat
    let image: UIImage?

    static let gradient = LinearGradient(
        colors: [Color(red: 40 / 255, green: 40 / 255, blue: 40 / 255), Color(red: 142 / 255, green: 142 / 255, blue: 142 / 255)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    init(size: CGFloat = 40, image: UIImage? = nil) {
        self.size = size
        self.image = image
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.52, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(ProfileAvatar.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            SettingsCard(content: { content })
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(.white.opacity(0.8), lineWidth: 1)
        }
    }
}

private struct SettingsRow: View {
    let title: String
    var value: String? = nil
    var accessory: String = "chevron.right"

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.black)

            Spacer()

            if let value {
                Text(value)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }

            Image(systemName: accessory)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 57)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.65)
                .padding(.horizontal, 5)
        }
    }
}

private struct CallModeRow: View {
    @Binding var mode: String
    let showPicker: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Default Call Mode")
                .font(.system(size: 16))
                .foregroundStyle(.black)

            Spacer()

            Text(mode)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            Button(action: showPicker) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 57)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.65)
                .padding(.horizontal, 5)
        }
    }
}

private struct CallModePicker: View {
    @Binding var selection: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(["Text Mode", "Audio Mode"], id: \.self) { mode in
                Button {
                    selection = mode
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if selection == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 16, height: 16)

                        Text(mode)
                            .font(.system(size: 16))

                        Spacer()
                    }
                    .foregroundStyle(selection == mode ? Color.blue : Color.primary)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 218)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.8), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
    }
}

#Preview {
    ProfileView(profileImage: .constant(nil), logout: { }) { }
        .environmentObject(AppDatabase.make())
}
