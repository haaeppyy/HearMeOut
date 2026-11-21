import SwiftUI

/// The filter that narrows the recent-calls list.
enum CallFilter: String, CaseIterable {
    case all = "All"
    case missed = "Missed calls"
    case voicemail = "Voicemail"

    var icon: String {
        switch self {
        case .all: "phone"
        case .missed: "clock"
        case .voicemail: "recordingtape"
        }
    }
}

/// The popover that opens from the filter button in the Calls header.
struct CallFilterMenu: View {
    @Binding var selection: CallFilter
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(CallFilter.allCases, id: \.self) { filter in
                Button {
                    selection = filter
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        if selection == filter {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 16)
                        }

                        Image(systemName: filter.icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 18)

                        Text(filter.rawValue)
                            .font(.system(size: 15, weight: .regular))
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selection == filter ? Color.blue : Color.primary)
                    // Give the longest label enough room to remain on one line,
                    // while preserving the menu's existing row rhythm.
                    .frame(width: 164, height: 41, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(uiColor: .systemGray5).opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

    /// Show voicemail in filter menu based on project decision.
    /// Currently hidden for v1 — voicemail requires moderation and
    /// will be reintroduced later.
    private var showVoicemailFilter: Bool {
        false
    }

    // MARK: - VoiceOver Accessibility
    private var voiceOverLabels: some View {
        VStack {
            Label("Switch to audio", systemImage: "speaker.wave.3")
            Label("End call", systemImage: "phone.down")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Call controls: switch to audio mode, end call")
    }
