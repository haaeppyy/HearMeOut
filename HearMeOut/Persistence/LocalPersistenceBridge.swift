import Foundation
import GRDB

extension Contact {

    /// Rebuilds a contact from its stored row.
    init(record: LocalContactRecord) {
        self.init(
            id: UUID(uuidString: record.id) ?? UUID(),
            name: record.name,
            phoneNumber: record.phoneNumber,
            isFavorite: record.isFavorite,
            details: (try? JSONDecoder().decode([String: String].self, from: Data(record.detailsJSON.utf8))) ?? [:],
            imageData: record.imageData,
            isBlocked: record.isBlocked,
            remoteUserID: record.remoteUserID,
            registrationState: record.registration,
            checkedAt: record.checkedAt
        )
    }

    /// Builds the row for this contact.
    ///
    /// `existing` carries the values that must survive a save: the row id,
    /// when the contact already exists, and the cached server link and
    /// registration answer. Writing a fresh id here would orphan the
    /// contact's call history, and dropping `remoteUserID` would force the
    /// next call to look the number up again.
    func record(
        profileID: String,
        existingID: String? = nil,
        existingRemoteUserID: String? = nil,
        existingCreatedAt: Date? = nil,
        existingCheckedAt: Date? = nil,
        existingRegistrationState: RegistrationState = .unknown
    ) -> LocalContactRecord {
        let now = Date()
        let remoteUserID = self.remoteUserID ?? existingRemoteUserID
        let registrationState = self.registrationState == .unknown
            ? existingRegistrationState
            : self.registrationState
        let checkedAt = self.checkedAt ?? existingCheckedAt
        return LocalContactRecord(
            id: existingID ?? id.uuidString,
            profileID: profileID,
            remoteUserID: remoteUserID,
            name: name,
            phoneNumber: phoneNumber,
            normalizedPhone: PhoneNumber.matchingKey(phoneNumber),
            registrationState: registrationState.rawValue,
            checkedAt: checkedAt,
            detailsJSON: (try? String(data: JSONEncoder().encode(details), encoding: .utf8)) ?? "{}",
            isFavorite: isFavorite,
            isBlocked: isBlocked,
            imageData: imageData,
            createdAt: existingCreatedAt ?? now,
            updatedAt: now
        )
    }
}
