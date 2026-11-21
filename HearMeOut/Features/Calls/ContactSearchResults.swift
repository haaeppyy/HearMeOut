import SwiftUI

/// Search results shown over the Calls list while the search field is active.
struct ContactSearchResults: View {
    let contacts: [Contact]
    let call: (Contact) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ForEach(contacts) { contact in
                HStack(spacing: 12) {
                    ContactCallAvatar(contact: contact, fallbackName: contact.name)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(contact.name)
                            .font(.system(size: 16, weight: .medium))
                        Text(contact.phoneNumber)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button { call(contact) } label: {
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
                .background(Color(uiColor: .systemGray5).opacity(0.96), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
        }
    }
}
