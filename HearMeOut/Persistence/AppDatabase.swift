import Foundation
import SwiftUI
import GRDB

/// Owns the database and the repositories built on top of it.
///
/// This is the only place the app talks to GRDB directly. Everything else
/// goes through the stores in `Stores/`.
@MainActor
final class AppDatabase: ObservableObject {
    let manager: DatabaseManager
    let profiles: ProfileRepository
    let contacts: ContactRepository
    let calls: CallRepository
    let accounts: AccountRepository

    static func make() -> AppDatabase {
        do {
            return try AppDatabase()
        } catch {
            // A database that cannot be opened means the app cannot safely
            // load or save user data. Fail at startup instead of silently
            // reverting to an in-memory store and losing data.
            fatalError("Unable to open HearMeOut database: \(error)")
        }
    }

    init() throws {
        manager = try DatabaseManager()
        profiles = ProfileRepository(db: manager.writer)
        contacts = ContactRepository(db: manager.writer)
        calls = CallRepository(db: manager.writer)
        accounts = AccountRepository(db: manager.writer)
    }

    #if DEBUG
    /// An in-memory database, for tests.
    init(inMemory: Void) throws {
        manager = try DatabaseManager(writer: try DatabaseQueue())
        profiles = ProfileRepository(db: manager.writer)
        contacts = ContactRepository(db: manager.writer)
        calls = CallRepository(db: manager.writer)
        accounts = AccountRepository(db: manager.writer)
    }
    #endif
}
