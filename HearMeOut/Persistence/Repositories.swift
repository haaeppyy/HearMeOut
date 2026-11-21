import Foundation
import GRDB

/// Reads and writes the signed-in user's own profile row.
final class ProfileRepository {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) { self.db = db }

    func fetch() throws -> LocalProfileRecord? {
        try db.read { database in
            try LocalProfileRecord.fetchOne(database)
        }
    }

    func fetch(id: String) throws -> LocalProfileRecord? {
        try db.read { database in
            try LocalProfileRecord.fetchOne(database, key: id)
        }
    }

    func save(_ profile: LocalProfileRecord) throws {
        try db.write { database in
            try profile.save(database)
        }
    }
}

/// Reads and writes saved contacts.
final class ContactRepository {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) { self.db = db }

    func fetchAll(profileID: String, includingBlocked: Bool = false) throws -> [LocalContactRecord] {
        try db.read { database in
            var request = LocalContactRecord
                .filter(Column("profile_id") == profileID)
                .order(Column("name"))
            if !includingBlocked {
                request = request.filter(Column("is_blocked") == false)
            }
            return try request.fetchAll(database)
        }
    }

    func upsert(_ contact: LocalContactRecord) throws {
        try db.write { database in
            try contact.save(database)
        }
    }

    /// The stored row for one contact, if it exists.
    func fetch(id: String) throws -> LocalContactRecord? {
        try db.read { database in
            try LocalContactRecord.fetchOne(database, key: id)
        }
    }

    func delete(id: String) throws {
        try db.write { database in
            try LocalContactRecord.deleteOne(database, key: id)
        }
    }

    /// Upserts every incoming contact and removes the ones that are no longer
    /// in the list.
    ///
    /// This replaces the old "delete everything and rewrite it" pattern,
    /// which threw away rows the app had not loaded — including the cached
    /// `remote_user_id` link, which is expensive to re-fetch and is lost
    /// entirely if the app is killed mid-write.
    func sync(_ contacts: [LocalContactRecord], profileID: String) throws {
        try db.write { database in
            let existingIDs = try String.fetchAll(
                database,
                sql: "SELECT id FROM local_contact WHERE profile_id = ?",
                arguments: [profileID]
            )
            let incomingIDs = Set(contacts.map(\.id))
            for id in existingIDs where !incomingIDs.contains(id) {
                try LocalContactRecord.deleteOne(database, key: id)
            }
            for contact in contacts {
                try contact.save(database)
            }
        }
    }
}

/// Reads and writes call history rows and their saved transcripts.
final class CallRepository {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) { self.db = db }

    func fetchAll(profileID: String) throws -> [RecentCallRecord] {
        try db.read { database in
            try RecentCallRecord
                .filter(Column("profile_id") == profileID)
                .order(Column("created_at").desc)
                .fetchAll(database)
        }
    }

    func fetchHistory(profileID: String, phoneNumber: String) throws -> [RecentCallRecord] {
        try db.read { database in
            try RecentCallRecord
                .filter(Column("profile_id") == profileID)
                .filter(Column("contact_phone_number") == phoneNumber)
                .order(Column("created_at").desc)
                .fetchAll(database)
        }
    }

    func fetchMessages(for callID: String) throws -> [CallMessageRecord] {
        try db.read { database in
            try CallMessageRecord
                .filter(Column("recent_call_id") == callID)
                .order(Column("seq"))
                .order(Column("sent_at"))
                .fetchAll(database)
        }
    }

    /// Writes one call row and the messages that belong to it.
    func upsert(call: RecentCallRecord, messages: [CallMessageRecord] = []) throws {
        try db.write { database in
            try call.save(database)
            for message in messages {
                try message.save(database)
            }
        }
    }

    func delete(id: String) throws {
        _ = try db.write { database in
            try RecentCallRecord.deleteOne(database, key: id)
        }
    }

    /// Points the call history rows for one phone number at a contact that
    /// was added to the directory afterwards.
    func linkContact(id: String, phoneNumber: String, profileID: String) throws {
        _ = try db.write { database in
            try database.execute(
                sql: """
                    UPDATE recent_call
                    SET contact_id = ?
                    WHERE profile_id = ? AND contact_phone_number = ?
                    """,
                arguments: [id, profileID, phoneNumber]
            )
        }
    }

    /// Upserts every incoming call and removes the ones that are no longer in
    /// the list, along with the transcripts that hung off them.
    func sync(
        _ calls: [RecentCallRecord],
        messages: [String: [CallMessageRecord]],
        profileID: String
    ) throws {
        try db.write { database in
            let existingIDs = try String.fetchAll(
                database,
                sql: "SELECT id FROM recent_call WHERE profile_id = ?",
                arguments: [profileID]
            )
            let incomingIDs = Set(calls.map(\.id))
            for id in existingIDs where !incomingIDs.contains(id) {
                try CallMessageRecord
                    .filter(Column("recent_call_id") == id)
                    .deleteAll(database)
                try RecentCallRecord.deleteOne(database, key: id)
            }
            for call in calls {
                try call.save(database)
                for message in messages[call.id] ?? [] {
                    try message.save(database)
                }
            }
        }
    }
}

/// Moves device-local data from the placeholder profile id onto the real
/// Supabase user id.
///
/// `local_contact` and `recent_call` both carry a foreign key to
/// `local_profile(id)` with `ON DELETE CASCADE`, and SQLite's default
/// `ON UPDATE` behaviour is `NO ACTION` — renaming the parent row while
/// children still point at the old id is a foreign-key violation. So the
/// move runs in the only order that is legal: insert the row under the new
/// key, repoint the children, then delete the old parent.
final class AccountRepository {
    private let db: DatabaseWriter

    /// The profile id used before an account was ever adopted. Data written
    /// by an earlier build of the app lives under this id.
    static let placeholderProfileID = "local-profile"

    init(db: DatabaseWriter) { self.db = db }

    /// The id the device-local data currently belongs to.
    func currentProfileID() throws -> String? {
        try db.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM local_profile LIMIT 1")
        }
    }

    /// Adopts `userID` as the owner of the device-local data.
    ///
    /// - Returns: the profile row for the account.
    func adoptAccount(userID: String, profile: LocalProfileRecord) throws -> LocalProfileRecord {
        try db.write { database in
            if var existing = try LocalProfileRecord.fetchOne(database, key: userID) {
                existing.name = profile.name
                existing.phoneNumber = profile.phoneNumber
                existing.communicationProfile = profile.communicationProfile
                existing.defaultCallingInterface = profile.defaultCallingInterface
                existing.language = profile.language
                existing.profileImageData = profile.profileImageData ?? existing.profileImageData
                existing.hasCompletedOnboarding = true
                existing.remoteUserID = profile.remoteUserID ?? userID
                existing.updatedAt = profile.updatedAt
                try existing.update(database)
                return existing
            }

            let legacyID = Self.placeholderProfileID
            var adopted = profile
            adopted.id = userID
            adopted.remoteUserID = profile.remoteUserID ?? userID

            if let legacy = try LocalProfileRecord.fetchOne(database, key: legacyID) {
                // Carry the legacy row forward, but let the caller-supplied
                // values win — the server is the source of truth for these.
                adopted.createdAt = legacy.createdAt
                adopted.name = profile.name.isEmpty ? legacy.name : profile.name
                adopted.phoneNumber = profile.phoneNumber.isEmpty ? legacy.phoneNumber : profile.phoneNumber
                adopted.communicationProfile = profile.communicationProfile ?? legacy.communicationProfile
                adopted.defaultCallingInterface = profile.defaultCallingInterface
                adopted.language = profile.language ?? legacy.language
                adopted.profileImageData = profile.profileImageData ?? legacy.profileImageData
                adopted.hasCompletedOnboarding = profile.hasCompletedOnboarding || legacy.hasCompletedOnboarding
            }

            try adopted.insert(database)

            // Repoint the children at the new parent before the old parent
            // goes away.
            try database.execute(
                sql: "UPDATE local_contact SET profile_id = ? WHERE profile_id = ?",
                arguments: [userID, legacyID]
            )
            try database.execute(
                sql: "UPDATE recent_call SET profile_id = ? WHERE profile_id = ?",
                arguments: [userID, legacyID]
            )
            try LocalProfileRecord.deleteOne(database, key: legacyID)
            return adopted
        }
    }
}
