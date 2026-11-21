import SwiftUI

/// Shown in place of the list when there are no recent calls yet.
struct EmptyCallsState: View {
    let defaultCallingInterface: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: defaultCallingInterface == "Audio Mode" ? "phone.badge.clock.fill" : "text.bubble.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.56))

            Text("No recent calls")
                .font(.system(size: 15))
                .foregroundStyle(Color.secondary.opacity(0.55))

            Text("Your default is \(defaultCallingInterface).")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary.opacity(0.55))
        }
    }
}
