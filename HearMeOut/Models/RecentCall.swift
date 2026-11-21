import Foundation

/// Which side of the call this device was on.
enum CallDirection: String {
    case incoming = "Incoming"
    case outgoing = "Outgoing"
}

/// One row in the call history list.
///
/// This is the in-memory view of a `recent_call` row plus the pieces that
/// only make sense while the list is on screen (the resolved contact and
/// the transcript).
struct RecentCall: Identifiable, Equatable {
    let id: UUID
    var contactName: String
    let phoneNumber: String
    let callMode: String
    let savedConversation: Bool
    var transcript: [String]
    var contact: Contact?
    let date: Date
    let duration: TimeInterval
    let direction: CallDirection
    /// How the call ended.
    var status: CallOutcome
    var voicemail: String? = nil
    var recordingDuration: TimeInterval? = nil
    /// The backend's `calls.id` for this call, when it came from a real call.
    var callSessionID: String?
    /// The other party's user id, when known.
    var remoteUserID: String?
    /// When the call actually connected, which is not the same as when it
    /// started.
    var connectedAt: Date?
    /// A more specific reason than the status itself, when there is one.
    var endReason: String?

    /// Whether the call connected, as shown in the history rows.
    var didConnect: Bool? { status.didConnect }

    init(
        id: UUID = UUID(),
        contactName: String,
        phoneNumber: String,
        callMode: String,
        savedConversation: Bool,
        transcript: [String],
        contact: Contact?,
        date: Date,
        duration: TimeInterval,
        direction: CallDirection,
        status: CallOutcome = .failed,
        voicemail: String? = nil,
        recordingDuration: TimeInterval? = nil,
        callSessionID: String? = nil,
        remoteUserID: String? = nil,
        connectedAt: Date? = nil,
        endReason: String? = nil
    ) {
        self.id = id
        self.contactName = contactName
        self.phoneNumber = phoneNumber
        self.callMode = callMode
        self.savedConversation = savedConversation
        self.transcript = transcript
        self.contact = contact
        self.date = date
        self.duration = duration
        self.direction = direction
        self.status = status
        self.voicemail = voicemail
        self.recordingDuration = recordingDuration
        self.callSessionID = callSessionID
        self.remoteUserID = remoteUserID
        self.connectedAt = connectedAt
        self.endReason = endReason
    }
}

extension RecentCall {

    init(record: RecentCallRecord, contact: Contact?) {
        self.init(
            id: UUID(uuidString: record.id) ?? UUID(),
            contactName: record.contactName,
            phoneNumber: record.contactPhoneNumber,
            callMode: record.callMode,
            savedConversation: record.savedConversation,
            transcript: [],
            contact: contact,
            date: record.createdAt,
            duration: TimeInterval(record.durationSeconds),
            direction: CallDirection(rawValue: record.direction) ?? .outgoing,
            status: record.outcome,
            recordingDuration: record.recordingDurationSeconds.map(TimeInterval.init),
            callSessionID: record.callSessionID,
            remoteUserID: record.remoteUserID,
            connectedAt: record.connectedAt,
            endReason: record.endReason
        )
    }

    func record(profileID: String) -> RecentCallRecord {
        return RecentCallRecord(
            id: id.uuidString,
            profileID: profileID,
            contactID: contact?.id.uuidString,
            callSessionID: callSessionID,
            remoteUserID: remoteUserID,
            contactName: contactName,
            contactPhoneNumber: phoneNumber,
            callMode: callMode,
            direction: direction.rawValue,
            status: status.rawValue,
            startedAt: date,
            connectedAt: connectedAt,
            endedAt: date.addingTimeInterval(duration),
            endReason: endReason,
            durationSeconds: max(0, Int(duration)),
            savedConversation: savedConversation,
            recordingDurationSeconds: recordingDuration.map { max(0, Int($0)) },
            createdAt: date
        )
    }
}
