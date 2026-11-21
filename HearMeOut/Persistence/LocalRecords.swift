import Foundation
import GRDB

/// The signed-in user's own profile, cached on the device.
///
/// `id` is the Supabase user id. Every other device-local table is keyed by
/// it through `profile_id`, which is what stops two accounts on one phone
/// from seeing each other's contacts.
struct LocalProfileRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "local_profile"

    var id: String
    var remoteUserID: String?
    var name: String
    var phoneNumber: String
    var communicationProfile: String?
    var defaultCallingInterface: String
    var language: String?
    var profileImageData: Data?
    var hasCompletedOnboarding: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case remoteUserID = "remote_user_id"
        case name
        case phoneNumber = "phone_number"
        case communicationProfile = "communication_profile"
        case defaultCallingInterface = "default_calling_interface"
        case language
        case profileImageData = "profile_image_data"
        case hasCompletedOnboarding = "has_completed_onboarding"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// One saved contact.
struct LocalContactRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "local_contact"

    var id: String
    var profileID: String
    var remoteUserID: String?
    var name: String
    var phoneNumber: String
    /// The digits-only form of `phoneNumber`, used to match a dialed number
    /// against a contact regardless of how the number was typed.
    var normalizedPhone: String?
    /// Whether the server knows this number. See `RegistrationState`.
    var registrationState: String?
    /// When `registrationState` was last refreshed from the server.
    var checkedAt: Date?
    var detailsJSON: String
    var isFavorite: Bool
    var isBlocked: Bool
    var imageData: Data?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case profileID = "profile_id"
        case remoteUserID = "remote_user_id"
        case name
        case phoneNumber = "phone_number"
        case normalizedPhone = "normalized_phone"
        case registrationState = "registration_state"
        case checkedAt = "checked_at"
        case detailsJSON = "details_json"
        case isFavorite = "is_favorite"
        case isBlocked = "is_blocked"
        case imageData = "image_data"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// The registration state as a typed value, defaulting to "not checked yet".
    var registration: RegistrationState {
        RegistrationState(rawValue: registrationState ?? "") ?? .unknown
    }
}

/// One row in the call history.
struct RecentCallRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "recent_call"

    var id: String
    var profileID: String
    var contactID: String?
    /// The backend's `calls.id` for this call, when it came from a real call.
    var callSessionID: String?
    /// The other party's user id, when known.
    var remoteUserID: String?
    var contactName: String
    var contactPhoneNumber: String
    var callMode: String
    var direction: String
    /// One of `CallOutcome`'s raw values.
    var status: String
    var startedAt: Date?
    var connectedAt: Date?
    var endedAt: Date?
    /// Why the call ended, when there is a more specific reason than the
    /// status itself (for example "no answer" or "busy").
    var endReason: String?
    var durationSeconds: Int
    var savedConversation: Bool
    var recordingDurationSeconds: Int?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case profileID = "profile_id"
        case contactID = "contact_id"
        case callSessionID = "call_session_id"
        case remoteUserID = "remote_user_id"
        case contactName = "contact_name"
        case contactPhoneNumber = "contact_phone_number"
        case callMode = "call_mode"
        case direction
        case status
        case startedAt = "started_at"
        case connectedAt = "connected_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
        case durationSeconds = "duration_seconds"
        case savedConversation = "saved_conversation"
        case recordingDurationSeconds = "recording_duration_seconds"
        case createdAt = "created_at"
    }

    var outcome: CallOutcome {
        CallOutcome(rawValue: status) ?? .failed
    }
}

/// One message in a saved conversation.
struct CallMessageRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "call_message"

    var id: String
    var recentCallID: String
    /// "me" or "them". Legacy rows written before speaker attribution existed
    /// hold "unknown".
    var sender: String
    var body: String
    /// How the message arrived: "typed" or "asr".
    var source: String?
    /// Position of this message within its call, so the transcript can be
    /// replayed in the order it actually happened.
    var seq: Int
    /// Whether the message is final. Partial speech recognition results are
    /// not final until the utterance settles.
    var isFinal: Bool
    var sentAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case recentCallID = "recent_call_id"
        case sender
        case body
        case source
        case seq
        case isFinal = "is_final"
        case sentAt = "sent_at"
    }

    /// The speaker as a typed value.
    var speaker: TranscriptSegment.Speaker {
        TranscriptSegment.Speaker(rawValue: sender) ?? .unknown
    }

    /// How the message arrived, as a typed value.
    var origin: TranscriptSegment.Source {
        TranscriptSegment.Source(rawValue: source ?? "") ?? .asr
    }
}
