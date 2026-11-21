import Foundation
import Combine

/// The call history, and the transcripts saved with it.
///
/// Like `ContactsStore`, this is the only thing that touches the
/// `recent_call` and `call_message` tables.
@MainActor
final class CallHistoryStore: ObservableObject {

    /// The call history, newest first.
    @Published private(set) var calls: [RecentCall] = []

    private let repository: CallRepository
    private let scope: AccountScope
    private let contactsStore: ContactsStore

    init(repository: CallRepository, scope: AccountScope, contactsStore: ContactsStore) {
        self.repository = repository
        self.scope = scope
        self.contactsStore = contactsStore
    }

    /// Loads the call history for the current account.
    func load() {
        guard let profileID = scope.profileID else {
            calls = []
            return
        }
        do {
            let contactsByID = Dictionary(
                uniqueKeysWithValues: contactsStore.contacts.map { ($0.id.uuidString, $0) }
            )
            calls = try repository.fetchAll(profileID: profileID).map { record in
                var call = RecentCall(
                    record: record,
                    contact: record.contactID.flatMap { contactsByID[$0] }
                )
                if record.savedConversation {
                    call.transcript = try repository
                        .fetchMessages(for: record.id)
                        .map(\.body)
                }
                return call
            }
        } catch {
            print("Unable to load call history: \(error)")
        }
    }

    /// Writes one call into the history, along with any transcript.
    func record(_ call: RecentCall, transcript: [CallMessageRecord] = []) {
        guard let profileID = scope.profileID else { return }
        do {
            try repository.upsert(call: call.record(profileID: profileID), messages: transcript)
        } catch {
            print("Unable to save call history: \(error)")
            return
        }
        replace(call)
    }

    /// Writes a finished call into the history.
    ///
    /// The row is keyed by the server's id for the call when there is one,
    /// so the same call is never written twice — once when it ends, and
    /// again when the history is reconciled with the server.
    func record(summary: CallSummary, transcript: [TranscriptSegment] = []) {
        guard let profileID = scope.profileID else { return }

        let contact = summary.otherPartyPhone.flatMap { contactsStore.contact(matching: $0) }
        let id = summary.callId.flatMap { UUID(uuidString: $0) } ?? UUID()
        let call = RecentCall(
            id: id,
            contactName: summary.otherPartyDisplayName,
            phoneNumber: summary.otherPartyPhone ?? "",
            callMode: summary.callMode,
            savedConversation: !transcript.isEmpty,
            transcript: transcript.map(\.text),
            contact: contact,
            date: summary.startedAt,
            duration: summary.duration,
            direction: summary.direction,
            status: summary.outcome,
            callSessionID: summary.callId,
            remoteUserID: summary.otherPartyRemoteUserID,
            connectedAt: summary.connectedAt
        )

        let messages = transcript.enumerated().map { index, segment in
            CallMessageRecord(
                id: "\(call.id.uuidString)-message-\(index)",
                recentCallID: call.id.uuidString,
                sender: segment.speaker.rawValue,
                body: segment.text,
                source: segment.source.rawValue,
                seq: index,
                isFinal: segment.isFinal,
                sentAt: segment.timestamp
            )
        }

        do {
            try repository.upsert(call: call.record(profileID: profileID), messages: messages)
        } catch {
            print("Unable to save call history: \(error)")
            return
        }
        replace(call)
    }

    /// Merges the server's record of calls into the local history.
    ///
    /// The server is authoritative about which calls happened and how they
    /// ended — it is the only thing that knows about a call that happened
    /// while the app was closed. The device is authoritative about contact
    /// names and about transcripts the user chose to keep, so those are
    /// carried over untouched.
    func reconcile(with entries: [ServerCallEntry]) {
        guard let profileID = scope.profileID else { return }

        for entry in entries {
            let call = makeCall(from: entry)
            do {
                try repository.upsert(call: call.record(profileID: profileID))
            } catch {
                print("Unable to reconcile call history: \(error)")
                continue
            }
            replace(call)
        }

        calls.sort { $0.date > $1.date }
    }

    /// Builds the local row for one server call, keeping anything only the
    /// device knows.
    private func makeCall(from entry: ServerCallEntry) -> RecentCall {
        let id = UUID(uuidString: entry.callId) ?? UUID()
        let existing = calls.first { $0.id == id }

        // Match the contact by phone number first, then by the user id the
        // server knows them by.
        let contact = entry.otherPartyPhone.flatMap { contactsStore.contact(matching: $0) }
            ?? contactsStore.contacts.first { $0.remoteUserID == entry.otherPartyId }

        let duration: TimeInterval
        if let connectedAt = entry.connectedAt, let endedAt = entry.endedAt {
            duration = max(0, endedAt.timeIntervalSince(connectedAt))
        } else {
            duration = existing?.duration ?? 0
        }

        return RecentCall(
            id: id,
            contactName: contact?.name
                ?? entry.otherPartyDisplayName
                ?? existing?.contactName
                ?? "",
            phoneNumber: entry.otherPartyPhone ?? existing?.phoneNumber ?? "",
            callMode: existing?.callMode ?? "audio",
            savedConversation: existing?.savedConversation ?? false,
            transcript: existing?.transcript ?? [],
            contact: contact,
            date: entry.startedAt ?? existing?.date ?? Date(),
            duration: duration,
            direction: entry.direction,
            status: entry.status,
            callSessionID: entry.callId,
            remoteUserID: entry.otherPartyId,
            connectedAt: entry.connectedAt ?? existing?.connectedAt,
            endReason: existing?.endReason
        )
    }

    /// Removes a call and the transcript that hung off it.
    func delete(id: UUID) {
        do {
            try repository.delete(id: id.uuidString)
        } catch {
            print("Unable to delete call: \(error)")
            return
        }
        calls.removeAll { $0.id == id }
    }

    /// The saved transcript for one call, in the order it happened.
    func messages(for callID: UUID) -> [CallMessageRecord] {
        (try? repository.fetchMessages(for: callID.uuidString)) ?? []
    }

    /// Links the calls for one phone number to a contact that was added to
    /// the directory after those calls happened.
    func link(contact: Contact) {
        guard let profileID = scope.profileID else { return }
        do {
            try repository.linkContact(
                id: contact.id.uuidString,
                phoneNumber: contact.phoneNumber,
                profileID: profileID
            )
        } catch {
            print("Unable to link call history to contact: \(error)")
        }
        for index in calls.indices where calls[index].phoneNumber == contact.phoneNumber {
            calls[index].contact = contact
            calls[index].contactName = contact.name
        }
    }

    private func replace(_ call: RecentCall) {
        if let index = calls.firstIndex(where: { $0.id == call.id }) {
            calls[index] = call
        } else {
            calls.insert(call, at: 0)
        }
    }
}
