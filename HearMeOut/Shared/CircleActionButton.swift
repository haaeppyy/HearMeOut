import SwiftUI

/// Frosted circular button used as a back / confirm control in the sheets.
struct CircleActionButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "checkmark" ? 27 : 25, weight: .medium))
                .foregroundStyle(.black)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 0.8) }
        }
        .buttonStyle(.plain)
    }
}
