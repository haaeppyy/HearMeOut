import SwiftUI
import UIKit

/// Read-only view of the signed-in user's own profile, reached from the
/// contacts list.
struct MyProfileContactDetailView: View {
    let image: UIImage?
    let close: () -> Void
    @AppStorage("userName") private var userName = ""
    @AppStorage("userPhoneNumber") private var userPhoneNumber = ""
    @AppStorage("communicationProfile") private var communicationProfile = ""

    private var communicationDescription: String? {
        switch communicationProfile {
        case "hearAndSpeak": "I can hear & speak"
        case "hearOnly": "I can hear, but I can’t speak"
        case "partialHearing": "I have partial hearing"
        case "speakOnly": "I can speak, but I can’t hear"
        case "textOnly": "I can’t hear or speak"
        default: nil
        }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ProfileAvatar(size: 194, image: image)
                        .padding(.top, 86)
                    Text(userName)
                        .font(.system(size: 30, weight: .semibold))
                        .padding(.top, 32)

                    VStack(alignment: .leading, spacing: 0) {
                        Divider()
                        profileDetail(label: "Phone", value: userPhoneNumber)

                        if let communicationDescription {
                            Divider()
                            profileDetail(label: "Communication", value: communicationDescription)
                        }
                        Divider()
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 40)
                    .padding(.bottom, 36)
                }
            }

            CircleActionButton(symbol: "chevron.left", action: close)
                .padding(.leading, 28)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func profileDetail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .medium))
        }
        .padding(.vertical, 19)
    }
}
