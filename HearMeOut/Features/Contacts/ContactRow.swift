import SwiftUI

/// One contact row in the contacts list.
struct ContactRow: View {
    let contact: Contact
    var showFavoriteIcon = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ContactAvatar(contact: contact, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(.system(size: 16))
                        .foregroundStyle(.black)
                }

                Spacer()

                if showFavoriteIcon {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Self.favoriteGradient)
                        .padding(.trailing, 8)
                }
            }
            .padding(.horizontal, 14)
            .frame(width: 343, height: 62)
            .background(Color(uiColor: .systemGray5).opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private static let favoriteGradient = LinearGradient(
        colors: [
            .red,
            Color(red: 0.78, green: 0, blue: 0.08)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}
