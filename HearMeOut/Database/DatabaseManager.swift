import Foundation
import GRDB

final class DatabaseManager {
    let writer: DatabaseWriter

    init(filename: String = "hearmeout.sqlite") throws {
        let fileManager = FileManager.default
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let databaseURL = directory.appendingPathComponent(filename)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true

        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try DatabaseMigrator.migrate(queue)
        writer = queue
    }

    #if DEBUG
    init(writer: DatabaseWriter) throws {
        self.writer = writer
        try DatabaseMigrator.migrate(writer)
    }
    #endif
}

enum DatabaseMigrator {
    static func migrate(_ writer: DatabaseWriter) throws {
        var migrator = GRDB.DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { database in
            try database.create(table: "local_profile") { table in
                table.column("id", .text).primaryKey()
                table.column("remote_user_id", .text)
                table.column("name", .text).notNull()
                table.column("phone_number", .text).notNull()
                table.column("communication_profile", .text)
                table.column("default_calling_interface", .text).notNull()
                table.column("profile_image_data", .blob)
                table.column("has_completed_onboarding", .boolean).notNull().defaults(to: false)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try database.create(table: "local_contact") { table in
                table.column("id", .text).primaryKey()
                table.column("profile_id", .text).notNull()
                    .references("local_profile", onDelete: .cascade)
                table.column("remote_user_id", .text)
                table.column("name", .text).notNull()
                table.column("phone_number", .text).notNull()
                table.column("details_json", .text).notNull().defaults(to: "{}")
                table.column("is_favorite", .boolean).notNull().defaults(to: false)
                table.column("is_blocked", .boolean).notNull().defaults(to: false)
                table.column("image_data", .blob)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try database.create(index: "local_contact_profile_id", on: "local_contact", columns: ["profile_id"])
            try database.create(index: "local_contact_name", on: "local_contact", columns: ["name"])
            try database.create(index: "local_contact_phone_number", on: "local_contact", columns: ["phone_number"])

            try database.create(table: "recent_call") { table in
                table.column("id", .text).primaryKey()
                table.column("profile_id", .text).notNull()
                    .references("local_profile", onDelete: .cascade)
                table.column("contact_id", .text)
                    .references("local_contact", onDelete: .setNull)
                table.column("call_session_id", .text)
                table.column("contact_name", .text).notNull()
                table.column("contact_phone_number", .text).notNull()
                table.column("call_mode", .text).notNull()
                table.column("direction", .text).notNull()
                table.column("status", .text).notNull()
                table.column("started_at", .datetime)
                table.column("ended_at", .datetime)
                table.column("duration_seconds", .integer).notNull().defaults(to: 0)
                table.column("saved_conversation", .boolean).notNull().defaults(to: false)
                table.column("recording_duration_seconds", .integer)
                table.column("created_at", .datetime).notNull()
            }
            try database.create(index: "recent_call_profile_id", on: "recent_call", columns: ["profile_id"])
            try database.create(index: "recent_call_contact_id", on: "recent_call", columns: ["contact_id"])
            try database.create(index: "recent_call_status", on: "recent_call", columns: ["status"])
            try database.create(index: "recent_call_created_at", on: "recent_call", columns: ["created_at"])

            try database.create(table: "call_message") { table in
                table.column("id", .text).primaryKey()
                table.column("recent_call_id", .text).notNull()
                    .references("recent_call", onDelete: .cascade)
                table.column("sender", .text).notNull()
                table.column("body", .text).notNull()
                table.column("sent_at", .datetime).notNull()
            }
            try database.create(index: "call_message_call_id", on: "call_message", columns: ["recent_call_id"])
            try database.create(index: "call_message_sent_at", on: "call_message", columns: ["sent_at"])
        }

        try migrator.migrate(writer)
    }
}
