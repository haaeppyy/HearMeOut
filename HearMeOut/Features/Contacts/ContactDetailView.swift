import SwiftUI

/// The contact detail sheet: photo, quick actions, phone, extra details and
/// the call history for that contact.
struct ContactDetailView: View {
    let contact: Contact
    let close: () -> Void
    let update: (Contact) -> Void
    let delete: (Contact) -> Void
    let startAudioCall: (Contact) -> Void
    @State private var isEditing = false

    private var additionalDetailRows: [(label: String, value: String)] {
        contact.details
            .filter {
                !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !["First name", "Last name", "Company"].contains($0.key) &&
                $0.value != contact.phoneNumber
            }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    ContactAvatar(contact: contact, size: 194)
                        .padding(.top, 86)
                    Text(contact.name)
                        .font(.system(size: 30, weight: .semibold))
                        .padding(.top, 32)

                    HStack(spacing: 40) {
                        ContactQuickAction(symbol: "square.and.arrow.up", title: "Share") { }
                        ContactQuickAction(symbol: contact.isFavorite ? "heart.fill" : "heart", title: "Favourite") {
                            var revised = contact
                            revised.isFavorite.toggle()
                            update(revised)
                        }
                        ContactQuickAction(symbol: "phone", title: "Call") { startAudioCall(contact) }
                        ContactQuickAction(symbol: "recordingtape", title: "Voicemail") { }
                    }
                    .padding(.top, 28)

                    VStack(alignment: .leading, spacing: 0) {
                        Divider()
                        Text("Phone")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                        Text(contact.phoneNumber)
                            .font(.system(size: 20, weight: .medium))
                            .padding(.top, 8)
                            .padding(.bottom, 24)

                        if !additionalDetailRows.isEmpty {
                            Divider()
                            ForEach(additionalDetailRows, id: \.label) { row in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(row.label)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(row.value)
                                        .font(.system(size: 20, weight: .medium))
                                }
                                .padding(.vertical, 19)
                            }
                        }
                        Divider()
                        Text("Call History")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                            .padding(.bottom, 16)
                        ContactCallHistory()
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 40)
                    .padding(.bottom, 36)
                }
            }
            ZStack {
                CircleActionButton(symbol: "chevron.left", action: close)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit") { isEditing = true }
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 25)
                    .frame(height: 46)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(.white.opacity(0.9), lineWidth: 0.8) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if isEditing {
                NewContactView(
                    contactToEdit: contact,
                    cancel: { isEditing = false },
                    save: { update($0); isEditing = false },
                    deleteContact: { delete(contact) },
                    blockContact: {
                        var revised = contact
                        revised.isBlocked = true
                        update(revised)
                        isEditing = false
                    }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isEditing)
    }
}

/// One of the round quick-action buttons under the contact's name.
private struct ContactQuickAction: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(Color(uiColor: .systemGray5).opacity(0.85), in: Circle())
                Text(title).font(.system(size: 14)).foregroundStyle(.black)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Placeholder call-history block shown on the contact detail sheet.
private struct ContactCallHistory: View {
    private let entries = [("Outgoing ↗ · 5 mins", "arrow.up.right"), ("Incoming ↙ · 5 mins", "arrow.down.left"), ("Didn't connect", "phone.down")]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Sept 1, 2026").font(.system(size: 18, weight: .medium))
                        Text(entry.0).font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("11:27 AM").font(.system(size: 17, weight: .medium))
                }
                .padding(.vertical, 12)
                if index < entries.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 26)
        .background(Color(uiColor: .systemGray5).opacity(0.86), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(width: 353, height: 234)
    }
}
