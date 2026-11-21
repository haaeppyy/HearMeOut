import SwiftUI

/// The list of recent calls shown on the Calls tab.
struct RecentCallsList: View {
    let calls: [RecentCall]
    let open: (RecentCall) -> Void
    let redial: (RecentCall) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ForEach(calls) { call in
                HStack(spacing: 12) {
                    Button { open(call) } label: {
                        HStack(spacing: 12) {
                            ContactCallAvatar(contact: call.contact, fallbackName: call.contactName)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(call.contact?.name ?? call.contactName)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.black)
                                Text(call.savedConversation ? "↙ mobile · Conversation saved" : "↙ mobile")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(call.date.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { redial(call) } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 32, height: 32)
                            .background(Color.blue.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .frame(width: 342, height: 75)
                .background(Color(uiColor: .systemGray5).opacity(0.9), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 30)
    }
}
