import SwiftUI
import PhotosUI
import UIKit

/// The profile sheet: the user's own details, communication preferences and
/// the sign-out action.
struct ProfileView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @Binding var profileImage: UIImage?
    let logout: () -> Void
    let dismiss: () -> Void
    @State private var notificationsEnabled = true
    @State private var isShowingCallModePicker = false
    @State private var selectedPhoto: PhotosPickerItem?

    private var userName: String { profileStore.displayName }
    private var userPhoneNumber: String { profileStore.phoneNumber }

    /// The default calling interface, bound to the store so a change is
    /// written straight through.
    private var callMode: Binding<String> {
        Binding(
            get: { profileStore.defaultCallingInterface },
            set: { profileStore.setDefaultCallingInterface($0) }
        )
    }

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
                            CallModeRow(mode: callMode) {
                                isShowingCallModePicker = true
                            }
                            .popover(
                                isPresented: $isShowingCallModePicker,
                                attachmentAnchor: .rect(.bounds),
                                arrowEdge: .bottom
                            ) {
                                CallModePicker(selection: callMode) {
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

                        Button(action: logout) {
                            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .frame(height: 57)
                                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Signs you out and returns to the sign-in screen.")
                    }
                    .padding(.top, 28)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                }
            }

        }
        .animation(.easeOut(duration: 0.18), value: isShowingCallModePicker)
    }

    private func persistProfile() {
        do {
            try profileStore.update { record in
                record.profileImageData = profileImage?.jpegData(compressionQuality: 0.9)
            }
        } catch {
            print("Unable to save profile: \(error)")
        }
    }
}
