import Foundation
import GRDB

struct LocalProfileRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "local_profile"

    var id: String
    var remoteUserID: String?
    var name: String
    var phoneNumber: String
    var communicationProfile: String?
    var defaultCallingInterface: String
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
        case profileImageData = "profile_image_data"
        case hasCompletedOnboarding = "has_completed_onboarding"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct LocalContactRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "local_contact"

    var id: String
    var profileID: String
    var remoteUserID: String?
    var name: String
    var phoneNumber: String
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
        case detailsJSON = "details_json"
        case isFavorite = "is_favorite"
        case isBlocked = "is_blocked"
        case imageData = "image_data"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct RecentCallRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "recent_call"

    var id: String
    var profileID: String
    var contactID: String?
    var callSessionID: String?
    var contactName: String
    var contactPhoneNumber: String
    var callMode: String
    var direction: String
    var status: String
    var startedAt: Date?
    var endedAt: Date?
    var durationSeconds: Int
    var savedConversation: Bool
    var recordingDurationSeconds: Int?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case profileID = "profile_id"
        case contactID = "contact_id"
        case callSessionID = "call_session_id"
        case contactName = "contact_name"
        case contactPhoneNumber = "contact_phone_number"
        case callMode = "call_mode"
        case direction
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case savedConversation = "saved_conversation"
        case recordingDurationSeconds = "recording_duration_seconds"
        case createdAt = "created_at"
    }
}

struct CallMessageRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "call_message"

    var id: String
    var recentCallID: String
    var sender: String
    var body: String
    var sentAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case recentCallID = "recent_call_id"
        case sender
        case body
        case sentAt = "sent_at"
    }
}
