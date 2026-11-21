import Foundation
import GRDB
import Testing
@testable import HearMeOut

/// Tests for the device-local database: the v2 schema, and the account
/// re-keying that makes the data account-scoped.
@Suite("Device-local persistence")
@MainActor
struct PersistenceTests {

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(inMemory: ())
    }

    private func legacyProfile() -> LocalProfileRecord {
        let now = Date()
        return LocalProfileRecord(
            id: AccountRepository.placeholderProfileID,
            remoteUserID: nil,
            name: "An earlier build",
            phoneNumber: "+919876543210",
            communicationProfile: "hearAndSpeak",
            defaultCallingInterface: "Audio Mode",
            language: nil,
            profileImageData: nil,
            hasCompletedOnboarding: true,
            createdAt: now,
            updatedAt: now
        )
    }

    @Test("The v2 migration adds the registration columns to a contact")
    func migrationAddsRegistrationColumns() throws {
        let database = try makeDatabase()
        let columns = try database.manager.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(local_contact)").compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("normalized_phone"))
        #expect(columns.contains("registration_state"))
        #expect(columns.contains("checked_at"))
    }

    @Test("The v2 migration adds the call outcome columns to a call row")
    func migrationAddsCallColumns() throws {
        let database = try makeDatabase()
        let columns = try database.manager.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(recent_call)").compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("connected_at"))
        #expect(columns.contains("remote_user_id"))
        #expect(columns.contains("end_reason"))
    }

    @Test("The v2 migration numbers the messages within their call")
    func migrationNumbersMessagesWithinTheirCall() throws {
        let database = try makeDatabase()
        let now = Date()
        try database.profiles.save(legacyProfile())
        try database.calls.upsert(
            call: RecentCallRecord(
                id: "call-1",
                profileID: AccountRepository.placeholderProfileID,
                contactID: nil,
                callSessionID: nil,
                remoteUserID: nil,
                contactName: "Someone",
                contactPhoneNumber: "+919876543210",
                callMode: "text",
                direction: "Outgoing",
                status: "completed",
                startedAt: now,
                connectedAt: nil,
                endedAt: nil,
                endReason: nil,
                durationSeconds: 0,
                savedConversation: true,
                recordingDurationSeconds: nil,
                createdAt: now
            ),
            messages: [
                CallMessageRecord(
                    id: "m1", recentCallID: "call-1", sender: "me", body: "one",
                    source: "typed", seq: 0, isFinal: true, sentAt: now
                ),
                CallMessageRecord(
                    id: "m2", recentCallID: "call-1", sender: "them", body: "two",
                    source: "typed", seq: 1, isFinal: true, sentAt: now.addingTimeInterval(1)
                ),
            ]
        )
        let messages = try database.calls.fetchMessages(for: "call-1")
        #expect(messages.map(\.body) == ["one", "two"])
        #expect(messages.map(\.seq) == [0, 1])
        #expect(messages.map(\.speaker) == [.me, .them])
    }

    @Test("Adopting an account re-keys the profile and everything under it")
    func adoptingAnAccountReKeysEverything() throws {
        let database = try makeDatabase()
        try database.profiles.save(legacyProfile())
        try database.contacts.upsert(
            LocalContactRecord(
                id: "contact-1",
                profileID: AccountRepository.placeholderProfileID,
                remoteUserID: "remote-1",
                name: "Ridhhi",
                phoneNumber: "+919876543210",
                normalizedPhone: "919876543210",
                registrationState: RegistrationState.registered.rawValue,
                checkedAt: Date(),
                detailsJSON: "{}",
                isFavorite: true,
                isBlocked: false,
                imageData: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        )

        let accounts = AccountRepository(db: database.manager.writer)
        let adopted = try accounts.adoptAccount(
            userID: "user-abc",
            profile: LocalProfileRecord(
                id: "user-abc",
                remoteUserID: "user-abc",
                name: "Anush",
                phoneNumber: "+919999999999",
                communicationProfile: "hearAndSpeak",
                defaultCallingInterface: "Audio Mode",
                language: "en-IN",
                profileImageData: nil,
                hasCompletedOnboarding: true,
                createdAt: Date(),
                updatedAt: Date()
            )
        )

        #expect(adopted.id == "user-abc")
        #expect(adopted.name == "Anush")

        // The placeholder profile is gone, and the contact moved with it.
        #expect(try database.profiles.fetch(id: AccountRepository.placeholderProfileID) == nil)
        #expect(try database.profiles.fetch(id: "user-abc") != nil)

        let moved = try database.contacts.fetchAll(profileID: "user-abc", includingBlocked: true)
        #expect(moved.count == 1)
        #expect(moved.first?.id == "contact-1")
        // The cached server link survives the move.
        #expect(moved.first?.remoteUserID == "remote-1")
    }

    @Test("Two accounts on one phone do not see each other's contacts")
    func twoAccountsDoNotShareContacts() throws {
        let database = try makeDatabase()
        let accounts = AccountRepository(db: database.manager.writer)

        _ = try accounts.adoptAccount(
            userID: "user-a",
            profile: LocalProfileRecord(
                id: "user-a", remoteUserID: "user-a", name: "A", phoneNumber: "+911111111111",
                communicationProfile: nil, defaultCallingInterface: "Text Mode", language: nil,
                profileImageData: nil, hasCompletedOnboarding: true,
                createdAt: Date(), updatedAt: Date()
            )
        )
        try database.contacts.upsert(
            LocalContactRecord(
                id: "a-contact", profileID: "user-a", remoteUserID: nil, name: "A's contact",
                phoneNumber: "+911111111111", normalizedPhone: "911111111111", registrationState: nil,
                checkedAt: nil, detailsJSON: "{}", isFavorite: false, isBlocked: false,
                imageData: nil, createdAt: Date(), updatedAt: Date()
            )
        )

        _ = try accounts.adoptAccount(
            userID: "user-b",
            profile: LocalProfileRecord(
                id: "user-b", remoteUserID: "user-b", name: "B", phoneNumber: "+912222222222",
                communicationProfile: nil, defaultCallingInterface: "Text Mode", language: nil,
                profileImageData: nil, hasCompletedOnboarding: true,
                createdAt: Date(), updatedAt: Date()
            )
        )

        #expect(try database.contacts.fetchAll(profileID: "user-a").count == 1)
        #expect(try database.contacts.fetchAll(profileID: "user-b").isEmpty)
    }

    @Test("A contact keeps its server link and creation date across an edit")
    func contactEditKeepsServerLink() throws {
        let database = try makeDatabase()
        let scope = AccountScope()
        let store = ContactsStore(repository: database.contacts, scope: scope)
        scope.adopt("user-abc")
        try database.profiles.save(
            LocalProfileRecord(
                id: "user-abc", remoteUserID: "user-abc", name: "Anush", phoneNumber: "+919999999999",
                communicationProfile: nil, defaultCallingInterface: "Text Mode", language: nil,
                profileImageData: nil, hasCompletedOnboarding: true,
                createdAt: Date(), updatedAt: Date()
            )
        )

        var contact = Contact(name: "Ridhhi", phoneNumber: "9876543210", isFavorite: false)
        store.upsert(contact)
        #expect(store.contacts.count == 1)

        // The lookup finds the contact and caches the server's answer.
        store.setRegistration(.registered, for: contact)
        contact = store.contacts[0]
        #expect(contact.remoteUserID == nil)

        // Now pretend the app learned the server id, and save the contact
        // again after renaming it. Both the id and the creation date must
        // survive.
        contact.remoteUserID = "remote-1"
        store.upsert(contact)
        let stored = try database.contacts.fetch(id: contact.id.uuidString)
        #expect(stored?.remoteUserID == "remote-1")
        #expect(stored?.createdAt == stored?.createdAt)

        var renamed = store.contacts[0]
        renamed.name = "Ridhhi Sharma"
        renamed.remoteUserID = nil
        store.upsert(renamed)
        let afterEdit = try database.contacts.fetch(id: contact.id.uuidString)
        #expect(afterEdit?.name == "Ridhhi Sharma")
        // The cached id is not wiped by an edit that does not mention it.
        #expect(afterEdit?.remoteUserID == "remote-1")
    }

    @Test("A dialled number matches a contact saved in a different format")
    func matchingIgnoresFormatting() throws {
        let database = try makeDatabase()
        let scope = AccountScope()
        let store = ContactsStore(repository: database.contacts, scope: scope)
        scope.adopt("user-abc")
        try database.profiles.save(
            LocalProfileRecord(
                id: "user-abc", remoteUserID: "user-abc", name: "Anush", phoneNumber: "+919999999999",
                communicationProfile: nil, defaultCallingInterface: "Text Mode", language: nil,
                profileImageData: nil, hasCompletedOnboarding: true,
                createdAt: Date(), updatedAt: Date()
            )
        )

        store.upsert(Contact(name: "Ridhhi", phoneNumber: "9876543210", isFavorite: false))
        #expect(store.contacts.count == 1)
        #expect(store.contact(matching: "+91 98765 43210")?.name == "Ridhhi")
        #expect(store.contact(matching: "9876543210")?.name == "Ridhhi")
        #expect(store.contact(matching: "98765 43210")?.name == "Ridhhi")
        #expect(store.contact(matching: "1111111111") == nil)
    }
}
