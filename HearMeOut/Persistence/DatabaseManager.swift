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

        // v2 makes the device-local data account-scoped and self-describing.
        //
        // The important change is not a column but a key: `local_profile.id`
        // becomes the Supabase user id, and every other table already keys
        // off it through `profile_id`. That is what stops two accounts on one
        // phone from seeing each other's contacts. The re-key itself cannot
        // live in a migration — the user id is not known until someone signs
        // in — so it happens in `AccountRepository.adoptAccount`, which does
        // the move in one transaction.
        migrator.registerMigration("v2_account_scoped_schema") { database in
            // The profile caches the language the user picked, so captions
            // and text-to-speech work without a round trip.
            try database.alter(table: "local_profile") { table in
                table.add(column: "language", .text)
            }

            // Contacts gain a digits-only key to match on, and the cached
            // answer to "is this number on HearMeOut?".
            try database.alter(table: "local_contact") { table in
                table.add(column: "normalized_phone", .text)
                table.add(column: "registration_state", .text)
                table.add(column: "checked_at", .datetime)
            }
            try database.create(
                index: "local_contact_normalized_phone",
                on: "local_contact",
                columns: ["normalized_phone"]
            )
            try database.create(
                index: "local_contact_registration_state",
                on: "local_contact",
                columns: ["registration_state"]
            )
            // Backfill the matching key for contacts saved before it existed.
            try database.execute(sql: """
                UPDATE local_contact
                SET normalized_phone = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    REPLACE(REPLACE(REPLACE(phone_number, ' ', ''), '-', ''), '(', ''),
                    ')', ''), '+', ''), '.', ''), '/', ''), ',', '')
                WHERE normalized_phone IS NULL
                """)

            // Call rows link back to the server call, and say how the call
            // ended and when it actually connected.
            try database.alter(table: "recent_call") { table in
                table.add(column: "connected_at", .datetime)
                table.add(column: "remote_user_id", .text)
                table.add(column: "end_reason", .text)
            }
            // Legacy rows never carried a server call id, but clear any
            // duplicates before the unique index is created so the migration
            // cannot fail on a device that somehow has them.
            try database.execute(sql: """
                UPDATE recent_call
                SET call_session_id = NULL
                WHERE call_session_id IS NOT NULL
                  AND call_session_id IN (
                      SELECT call_session_id FROM recent_call
                      WHERE call_session_id IS NOT NULL
                      GROUP BY call_session_id
                      HAVING COUNT(*) > 1
                  )
                """)
            try database.create(
                index: "recent_call_call_session_id",
                on: "recent_call",
                columns: ["call_session_id"],
                unique: true
            )

            // Messages gain speaker provenance, an ordering key and a
            // final/non-final flag so a saved transcript can be replayed
            // exactly as it happened.
            try database.alter(table: "call_message") { table in
                table.add(column: "source", .text)
                table.add(column: "seq", .integer)
                table.add(column: "is_final", .boolean).notNull().defaults(to: true)
            }
            // The legacy writer only ever stored the user's own typed
            // replies, so that is what those rows are.
            try database.execute(sql: """
                UPDATE call_message SET source = 'typed' WHERE source IS NULL
                """)
            // Number each message within its own call, in the order it was
            // sent, so the sequence is dense and per-call.
            try database.execute(sql: """
                UPDATE call_message
                SET seq = (
                    SELECT COUNT(*) - 1
                    FROM call_message AS earlier
                    WHERE earlier.recent_call_id = call_message.recent_call_id
                      AND (
                          earlier.sent_at < call_message.sent_at
                          OR (earlier.sent_at = call_message.sent_at AND earlier.rowid <= call_message.rowid)
                      )
                )
                WHERE seq IS NULL
                """)
            try database.create(
                index: "call_message_recent_call_seq",
                on: "call_message",
                columns: ["recent_call_id", "seq"]
            )
        }

        try migrator.migrate(writer)
    }
}
