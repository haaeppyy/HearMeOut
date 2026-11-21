import SwiftUI
import UIKit

/// Contact avatar used in the contacts list: the contact's photo when there
/// is one, otherwise their initials on the shared gradient.
struct ContactAvatar: View {
    let contact: Contact
    let size: CGFloat

    private var initials: String {
        contact.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        Group {
            if let data = contact.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(ProfileAvatar.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
