import Foundation
import GRDB

final class ProfileRepository {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) { self.db = db }

    func fetch() throws -> LocalProfileRecord? {
        try db.read { database in
            try LocalProfileRecord.fetchOne(database)
        }
    }

    func save(_ profile: LocalProfileRecord) throws {
        try db.write { database in
            try profile.save(database)
        }
    }

    /// Delete the local profile row. Used by sign-out so a fresh onboarding
    /// after logout actually gets a new DB row (previously the stale row
    /// survived and loadLocalData skipped creation).
    func delete() throws {
        try db.write { database in
            try LocalProfileRecord.deleteAll(database)
        }
    }
}

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

    func save(_ contact: LocalContactRecord) throws {
        try db.write { database in
            try contact.save(database)
        }
    }

    func delete(id: String) throws {
        try db.write { database in
            try LocalContactRecord.deleteOne(database, key: id)
        }
    }

    func replaceAll(_ contacts: [LocalContactRecord], profileID: String) throws {
        try db.write { database in
            let existingIDs = try LocalContactRecord
                .filter(Column("profile_id") == profileID)
                .fetchAll(database)
                .map(\.id)
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

    func save(call: RecentCallRecord, messages: [CallMessageRecord] = []) throws {
        try db.write { database in
            try call.save(database)
            for message in messages {
                try message.save(database)
            }
        }
    }

    func fetchMessages(for callID: String) throws -> [CallMessageRecord] {
        try db.read { database in
            try CallMessageRecord
                .filter(Column("recent_call_id") == callID)
                .order(Column("sent_at"))
                .fetchAll(database)
        }
    }

    func replaceAll(_ calls: [RecentCallRecord], profileID: String) throws {
        try db.write { database in
            let existing = try RecentCallRecord
                .filter(Column("profile_id") == profileID)
                .fetchAll(database)
            let incomingIDs = Set(calls.map(\.id))
            for call in existing where !incomingIDs.contains(call.id) {
                try RecentCallRecord.deleteOne(database, key: call.id)
            }
            for call in calls {
                try call.save(database)
            }
        }
    }

    func replaceAll(
        _ calls: [(record: RecentCallRecord, messages: [CallMessageRecord])],
        profileID: String
    ) throws {
        try db.write { database in
            let existing = try RecentCallRecord
                .filter(Column("profile_id") == profileID)
                .fetchAll(database)
            for call in existing {
                try CallMessageRecord
                    .filter(Column("recent_call_id") == call.id)
                    .deleteAll(database)
                try call.delete(database)
            }
            for item in calls {
                try item.record.save(database)
                for message in item.messages {
                    try message.save(database)
                }
            }
        }
    }
}
