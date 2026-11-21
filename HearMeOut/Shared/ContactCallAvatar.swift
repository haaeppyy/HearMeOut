import SwiftUI
import UIKit

/// Contact avatar used in the call history and search results, where the
/// contact may be missing and only a display name is known. Falls back to
/// first-and-last initials rather than the first two letters.
struct ContactCallAvatar: View {
    let contact: Contact?
    let fallbackName: String
    var size: CGFloat = 48

    private var initials: String {
        let parts = fallbackName.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first?.first else { return "?" }
        guard let last = parts.dropFirst().last?.first else { return String(first).uppercased() }
        return "\(String(first).uppercased())\(String(last).uppercased())"
    }

    var body: some View {
        Group {
            if let data = contact?.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ProfileAvatar.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
