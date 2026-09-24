import Foundation

extension Contact {
    init(record: LocalContactRecord) {
        self.init(
            id: UUID(uuidString: record.id) ?? UUID(),
            name: record.name,
            phoneNumber: record.phoneNumber,
            isFavorite: record.isFavorite,
            details: (try? JSONDecoder().decode([String: String].self, from: Data(record.detailsJSON.utf8))) ?? [:],
            imageData: record.imageData,
            isBlocked: record.isBlocked,
            remoteUserID: record.remoteUserID
        )
    }

    func record(profileID: String, existingID: String? = nil) -> LocalContactRecord {
        let now = Date()
        return LocalContactRecord(
            id: existingID ?? id.uuidString,
            profileID: profileID,
            remoteUserID: remoteUserID,
            name: name,
            phoneNumber: phoneNumber,
            detailsJSON: (try? String(data: JSONEncoder().encode(details), encoding: .utf8)) ?? "{}",
            isFavorite: isFavorite,
            isBlocked: isBlocked,
            imageData: imageData,
            createdAt: now,
            updatedAt: now
        )
    }
}
