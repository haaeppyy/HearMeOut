import SwiftUI

/// Small frosted circular button used in the calls header.
struct RoundIconButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: systemName == "person.fill" ? 20 : 19, weight: .medium))
                .foregroundStyle(systemName == "person.fill" ? .white : .black)
                .frame(width: size, height: size)
                .background {
                    if systemName == "person.fill" {
                        Circle().fill(ProfileAvatar.gradient)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 0.8) }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}
