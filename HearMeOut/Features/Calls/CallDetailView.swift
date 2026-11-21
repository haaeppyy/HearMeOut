import SwiftUI

/// The per-call detail sheet: who it was, how it went, and the redial and
/// save-contact actions.
struct CallDetailView: View {
    let call: RecentCall
    let history: [RecentCall]
    let redial: () -> Void
    let saveContact: (Contact) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var contact: Contact?
    @State private var isAddingContact = false
    @State private var isShowingContactCard = false
    @State private var showsSavedItem = false

    init(call: RecentCall, history: [RecentCall], redial: @escaping () -> Void, saveContact: @escaping (Contact) -> Void) {
        self.call = call
        self.history = history
        self.redial = redial
        self.saveContact = saveContact
        _contact = State(initialValue: call.contact)
    }

    private var durationText: String {
        let seconds = max(0, Int(call.duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var hasSavedItem: Bool {
        !(call.voicemail?.isEmpty ?? true) || call.recordingDuration != nil || call.savedConversation
    }

    private var actionSize: CGFloat { 48 }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ContactCallAvatar(contact: contact, fallbackName: call.contactName, size: 112)
                        .frame(width: 112, height: 112)
                        .padding(.top, 70)
                    Text(contact?.name ?? call.contactName)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.top, 18)
                    if let contact {
                        Text(contact.phoneNumber)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                    }

                    HStack(spacing: 72) {
                        detailAction(symbol: "phone", title: "Call", action: redialCall)
                        if contact != nil {
                            detailAction(symbol: "person.crop.circle", title: "Contact Card") {
                                isShowingContactCard = true
                            }
                        } else {
                            detailAction(symbol: "person.crop.circle.badge.plus", title: "Add Contact") {
                                isAddingContact = true
                            }
                        }
                    }
                    .padding(.top, 22)

                    callSummaryCard
                        .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Call History")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                        callHistoryCard
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
                    .padding(.bottom, 36)
                }
            }
            CircleActionButton(symbol: "chevron.left") { dismiss() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 28)
                .padding(.top, 14)

            if isAddingContact {
                NewContactView(
                    initialPhoneNumber: contact?.phoneNumber ?? call.contactName,
                    cancel: { isAddingContact = false },
                    save: { newContact in
                        saveContact(newContact)
                        contact = newContact
                        isAddingContact = false
                    }
                )
                .transition(.move(edge: .trailing))
            }

            if isShowingContactCard, let contact {
                contactCardOverlay(contact)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if showsSavedItem {
                savedItemOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isAddingContact)
        .animation(.easeInOut(duration: 0.22), value: isShowingContactCard)
        .animation(.easeInOut(duration: 0.22), value: showsSavedItem)
    }

    private var callSummaryCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(call.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 14, weight: .regular))
                Spacer()
                Text(call.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 14, weight: .regular))
            }
            HStack(spacing: 5) {
                Text(call.direction.rawValue)
                if let didConnect = call.didConnect {
                    Text("·")
                    Text(didConnect ? durationText : "Didn’t connect")
                } else {
                    Text("·")
                    Text(durationText)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.top, 4)

            if hasSavedItem {
                Divider().padding(.top, 13)
                HStack(spacing: 10) {
                    if !(call.voicemail?.isEmpty ?? true) {
                        savedContentAction(symbol: "recordingtape", title: "Voicemail", duration: nil)
                    }
                    if let recordingDuration = call.recordingDuration {
                        savedContentAction(symbol: "record.circle", title: "Call recording", duration: recordingDuration)
                    }
                    if call.savedConversation {
                        savedContentAction(symbol: "text.bubble", title: "Saved conversation", duration: nil)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(.top, 7)
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 353, height: hasSavedItem ? 149 : 84)
        .background(Color(uiColor: .systemGray5).opacity(0.88), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var callHistoryCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(history.sorted { $0.date > $1.date }.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 14, weight: .regular))
                        HStack(spacing: 5) {
                            Text(entry.direction.rawValue)
                            if let didConnect = entry.didConnect {
                                Text("·")
                                Text(didConnect ? durationText(for: entry.duration) : "Didn’t connect")
                            } else {
                                Text("·")
                                Text(durationText(for: entry.duration))
                            }
                        }
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 14, weight: .regular))
                        if entry.savedConversation {
                            Label("Saved conversation", systemImage: "text.bubble")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else if entry.recordingDuration != nil {
                            Label("Saved Call", systemImage: "record.circle")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else if !(entry.voicemail?.isEmpty ?? true) {
                            Label("Voicemail", systemImage: "recordingtape")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 12)
                if index < history.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 353)
        .background(Color(uiColor: .systemGray5).opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func detailAction(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.black)
                    .frame(width: actionSize, height: actionSize)
                    .background(Color(uiColor: .systemGray4).opacity(0.55), in: Circle())
                Text(title)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.black)
            }
            .frame(minWidth: 92)
        }
        .buttonStyle(.plain)
    }

    private func savedContentAction(symbol: String, title: String, duration: TimeInterval?) -> some View {
        Button { showsSavedItem = true } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 14, weight: .regular)).foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let duration {
                    Text(humanDuration(duration))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func contactCardOverlay(_ contact: Contact) -> some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { isShowingContactCard = false }
            VStack(spacing: 14) {
                ContactCallAvatar(contact: contact, fallbackName: contact.name, size: 72)
                Text(contact.name).font(.system(size: 20, weight: .semibold))
                Text(contact.phoneNumber).font(.system(size: 15)).foregroundStyle(.secondary)
                Button("Done") { isShowingContactCard = false }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 280)
            .background(Color(uiColor: .systemGray6), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    @ViewBuilder
    private var savedItemOverlay: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { showsSavedItem = false }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(savedItemTitle).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button { showsSavedItem = false } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                    }
                }
                if call.savedConversation {
                    ForEach(Array(call.transcript.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 15))
                    }
                } else if let voicemail = call.voicemail, !voicemail.isEmpty {
                    Text(voicemail).font(.system(size: 15))
                } else if let recordingDuration = call.recordingDuration {
                    Text("\(durationText(for: recordingDuration)) recording")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(width: 300, alignment: .leading)
            .background(Color(uiColor: .systemGray6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var savedItemTitle: String {
        if call.savedConversation { return "Saved conversation" }
        if call.recordingDuration != nil { return "Call recording" }
        return "Voicemail"
    }

    private func durationText(for duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func humanDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return "\(remainder) sec" }
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) sec"
    }

    private func redialCall() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: redial)
    }
}
