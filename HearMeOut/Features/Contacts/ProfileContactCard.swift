import SwiftUI
import UIKit

/// The "My profile" row at the top of the contacts list.
struct ProfileContactCard: View {
    let image: UIImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ProfileAvatar(size: 38, image: image)
                Text("My profile")
                    .font(.system(size: 16))
                    .foregroundStyle(.black)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(width: 343, height: 62)
            .background(Color(uiColor: .systemGray5).opacity(0.78), in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
