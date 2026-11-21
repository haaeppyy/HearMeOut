import SwiftUI

/// A titled group of settings rows.
struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            SettingsCard(content: { content })
        }
    }
}

/// The frosted card that groups settings rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(.white.opacity(0.8), lineWidth: 1)
        }
    }
}

/// One tappable settings row with an optional value and a chevron.
struct SettingsRow: View {
    let title: String
    var value: String? = nil
    var accessory: String = "chevron.right"

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.black)

            Spacer()

            if let value {
                Text(value)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }

            Image(systemName: accessory)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 57)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.65)
                .padding(.horizontal, 5)
        }
    }
}

/// The row that shows and changes the default calling interface.
struct CallModeRow: View {
    @Binding var mode: String
    let showPicker: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Default Call Mode")
                .font(.system(size: 16))
                .foregroundStyle(.black)

            Spacer()

            Text(mode)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            Button(action: showPicker) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 57)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.65)
                .padding(.horizontal, 5)
        }
    }
}

/// The popover listing "Text Mode" and "Audio Mode".
struct CallModePicker: View {
    @Binding var selection: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(["Text Mode", "Audio Mode"], id: \.self) { mode in
                Button {
                    selection = mode
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if selection == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 16, height: 16)

                        Text(mode)
                            .font(.system(size: 16))

                        Spacer()
                    }
                    .foregroundStyle(selection == mode ? Color.blue : Color.primary)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 218)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.8), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
    }
}
