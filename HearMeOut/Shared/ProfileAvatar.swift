import SwiftUI
import UIKit

/// The circular profile image used in the header, the profile sheet and the
/// contact editor. Falls back to a gradient disc with a person glyph.
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
