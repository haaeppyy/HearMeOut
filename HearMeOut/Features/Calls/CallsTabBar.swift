import SwiftUI

/// One entry in the Calls tab bar.
struct TabItem: View {
    let tab: Tab
    @Binding var selection: Tab

    var body: some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(tab == .contacts ? .monochrome : .hierarchical)
                Text(tab.rawValue)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(selection == tab ? Color.blue : Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background {
                if selection == tab {
                    Capsule().fill(Color.white.opacity(0.88))
                }
            }
        }
        .buttonStyle(.plain)
    }
}
