import Foundation
import SwiftUI
import GRDB

@MainActor
final class AppDatabase: ObservableObject {
    let manager: DatabaseManager
    let profiles: ProfileRepository
    let contacts: ContactRepository
    let calls: CallRepository

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
    }
}
