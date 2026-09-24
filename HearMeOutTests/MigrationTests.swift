import Foundation
import GRDB
import Testing

@testable import HearMeOut

/// Schema-migration scaffold. Only v1 exists today, so this locks in the
/// baseline (all four tables + the columns later migrations must preserve).
/// Rule going forward: the PR that adds a `v2_...` migration extends this
/// suite with a "seed at v1 → migrate → rows survive with correct defaults"
/// test in the same PR.
@Suite("Schema migrations")
struct MigrationTests {

    @Test("v1 creates all four tables with expected columns")
    func v1Schema() throws {
        let db = try DatabaseQueue()
        try DatabaseMigrator.migrate(db)
        // Reads are hoisted out of #expect: `try` inside the read closure
        // must be handled by the enclosing throws test, not the macro.
        let tables = try db.read { database in
            try ["local_profile", "local_contact", "recent_call", "call_message"]
                .filter { try database.tableExists($0) }
        }
        #expect(tables.count == 4)

        // Columns later migrations must not drop or retype: the
        // history-reconciliation key and the FK graph.
        let recentCall = try db.read { database in try database.columns(in: "recent_call").map(\.name) }
        #expect(recentCall.contains("call_session_id"))
        #expect(recentCall.contains("contact_id"))
        #expect(recentCall.contains("status"))
        #expect(recentCall.contains("started_at"))
        let contact = try db.read { database in try database.columns(in: "local_contact").map(\.name) }
        #expect(contact.contains("remote_user_id"))
        #expect(contact.contains("profile_id"))
    }

    @Test("migrator is idempotent on an already-migrated database")
    func migrateTwice() throws {
        let db = try DatabaseQueue()
        try DatabaseMigrator.migrate(db)
        try DatabaseMigrator.migrate(db)
        let exists = try db.read { database in try database.tableExists("recent_call") }
        #expect(exists)
    }
}
