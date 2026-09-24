import Foundation
import GRDB
import Testing

@testable import HearMeOut

/// Repository behavior against an in-memory database: profile lifecycle
/// (the sign-out regression), contact linkage persistence, call replace.
@Suite("GRDB repositories")
struct RepositoryTests {

    private func repos() throws -> (ProfileRepository, ContactRepository, CallRepository) {
        let db = try DatabaseQueue()
        try DatabaseMigrator.migrate(db)
        return (ProfileRepository(db: db), ContactRepository(db: db), CallRepository(db: db))
    }

    /// FK targets require the parent profile row first.
    private func seedProfile(_ profiles: ProfileRepository) throws {
        try profiles.save(LocalProfileRecord(
            id: "p", remoteUserID: nil, name: "Seed",
            phoneNumber: "+1000", communicationProfile: nil,
            defaultCallingInterface: "Text Mode", profileImageData: nil,
            hasCompletedOnboarding: true, createdAt: Date(), updatedAt: Date()
        ))
    }

    @Test("profile save/fetch/delete round-trip (sign-out regression)")
    func profileLifecycle() throws {
        let (profiles, _, _) = try repos()
        #expect(try profiles.fetch() == nil)
        try profiles.save(LocalProfileRecord(
            id: "local-profile", remoteUserID: "remote-u", name: "Sim",
            phoneNumber: "+1000", communicationProfile: nil,
            defaultCallingInterface: "Text Mode", profileImageData: nil,
            hasCompletedOnboarding: true, createdAt: Date(), updatedAt: Date()
        ))
        #expect(try profiles.fetch()?.remoteUserID == "remote-u")
        try profiles.delete()
        #expect(try profiles.fetch() == nil)
    }

    @Test("contact replaceAll preserves remoteUserID linkage")
    func contactLinkage() throws {
        let (profiles, contacts, _) = try repos()
        try seedProfile(profiles)
        let record = Contact(
            name: "Priya", phoneNumber: "+1555", isFavorite: false,
            remoteUserID: "remote-9"
        ).record(profileID: "p")
        try contacts.replaceAll([record], profileID: "p")
        let fetched = try contacts.fetchAll(profileID: "p", includingBlocked: true)
        #expect(fetched.count == 1)
        #expect(fetched[0].remoteUserID == "remote-9")
        #expect(Contact(record: fetched[0]).isCallable == true)
    }

    @Test("call save/fetch round-trip incl. callSessionID + messages")
    func callHistory() throws {
        let (profiles, _, calls) = try repos()
        try seedProfile(profiles)
        let record = RecentCallRecord(
            id: "r1", profileID: "p", contactID: nil, callSessionID: "server-1",
            contactName: "N", contactPhoneNumber: "0", callMode: "text",
            direction: "Outgoing", status: "completed",
            startedAt: Date(), endedAt: Date(), durationSeconds: 30,
            savedConversation: true, recordingDurationSeconds: nil,
            createdAt: Date()
        )
        let message = CallMessageRecord(
            id: "r1-message-0", recentCallID: "r1",
            sender: "unknown", body: "hi", sentAt: Date()
        )
        try calls.save(call: record, messages: [message])
        #expect(try calls.fetchAll(profileID: "p").first?.callSessionID == "server-1")
        #expect(try calls.fetchMessages(for: "r1").map(\.body) == ["hi"])
    }
}
