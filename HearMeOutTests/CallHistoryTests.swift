import Foundation
import Testing
@testable import HearMeOut

/// A finished call has to leave exactly one history row behind, with the
/// right outcome and — when the user asked for it — a transcript that says
/// who said what.
@Suite("Call history")
@MainActor
struct CallHistoryTests {

    private func makeStore() throws -> (CallHistoryStore, ContactsStore, AccountScope) {
        let database = try AppDatabase(inMemory: ())
        let scope = AccountScope()
        let contacts = ContactsStore(repository: database.contacts, scope: scope)
        let history = CallHistoryStore(
            repository: database.calls,
            scope: scope,
            contactsStore: contacts
        )
        scope.adopt("user-abc")
        try database.profiles.save(
            LocalProfileRecord(
                id: "user-abc", remoteUserID: "user-abc", name: "Anush", phoneNumber: "+919999999999",
                communicationProfile: nil, defaultCallingInterface: "Text Mode", language: nil,
                profileImageData: nil, hasCompletedOnboarding: true,
                createdAt: Date(), updatedAt: Date()
            )
        )
        return (history, contacts, scope)
    }

    private func summary(
        outcome: CallOutcome,
        callId: String? = "11111111-1111-1111-1111-111111111111",
        connectedAt: Date? = nil
    ) -> CallSummary {
        let started = Date().addingTimeInterval(-60)
        return CallSummary(
            callId: callId,
            otherPartyDisplayName: "Ridhhi",
            otherPartyPhone: "+919876543210",
            otherPartyRemoteUserID: "remote-1",
            direction: .outgoing,
            callMode: "text",
            startedAt: started,
            connectedAt: connectedAt,
            endedAt: started.addingTimeInterval(60),
            outcome: outcome
        )
    }

    @Test("A finished call becomes one history row")
    func finishedCallIsRecorded() throws {
        let (history, _, _) = try makeStore()
        history.record(summary: summary(outcome: .completed, connectedAt: Date().addingTimeInterval(-30)))
        #expect(history.calls.count == 1)

        let call = history.calls[0]
        #expect(call.contactName == "Ridhhi")
        #expect(call.phoneNumber == "+919876543210")
        #expect(call.status == .completed)
        #expect(call.callSessionID == "11111111-1111-1111-1111-111111111111")
        #expect(call.remoteUserID == "remote-1")
        #expect(call.callMode == "text")
        #expect(call.direction == .outgoing)
    }

    @Test("A call that never connected has no duration")
    func neverConnectedCallHasNoDuration() throws {
        let (history, _, _) = try makeStore()
        history.record(summary: summary(outcome: .cancelled, connectedAt: nil))
        #expect(history.calls.first?.status == .cancelled)
        #expect(history.calls.first?.duration == 0)
    }

    @Test("The transcript keeps who said what, and in what order")
    func transcriptKeepsSpeakers() throws {
        let (history, _, _) = try makeStore()
        let started = Date().addingTimeInterval(-60)
        history.record(
            summary: summary(outcome: .completed, connectedAt: started),
            transcript: [
                TranscriptSegment(speaker: .me, source: .typed, text: "hello", timestamp: started),
                TranscriptSegment(speaker: .them, source: .asr, text: "hi there", timestamp: started.addingTimeInterval(2)),
            ]
        )

        let messages = history.messages(for: history.calls[0].id)
        #expect(messages.count == 2)
        #expect(messages.map(\.body) == ["hello", "hi there"])
        #expect(messages.map(\.speaker) == [.me, .them])
        #expect(messages.map(\.origin) == [.typed, .asr])
        #expect(messages.map(\.seq) == [0, 1])
        #expect(history.calls[0].savedConversation)
    }

    @Test("A call with no transcript is not marked as a saved conversation")
    func callWithoutTranscriptIsNotSaved() throws {
        let (history, _, _) = try makeStore()
        history.record(summary: summary(outcome: .completed))
        #expect(!history.calls[0].savedConversation)
    }

    @Test("The same call written twice does not create two rows")
    func writingTheSameCallTwiceIsIdempotent() throws {
        let (history, _, _) = try makeStore()
        history.record(summary: summary(outcome: .completed))
        history.record(summary: summary(outcome: .completed))
        #expect(history.calls.count == 1)
    }

    @Test("A saved call is linked to the contact with the same number")
    func savedCallIsLinkedToItsContact() throws {
        let (history, contacts, _) = try makeStore()
        contacts.upsert(Contact(name: "Ridhhi", phoneNumber: "9876543210", isFavorite: false))
        history.record(summary: summary(outcome: .completed))
        #expect(history.calls.first?.contact?.name == "Ridhhi")
    }
}

/// The server is the authority on which calls happened and how they ended.
/// The device is the authority on contact names and on transcripts the user
/// chose to keep.
@Suite("History reconciliation")
@MainActor
struct HistoryReconciliationTests {

    private func makeStore() throws -> (CallHistoryStore, ContactsStore) {
        let database = try AppDatabase(inMemory: ())
        let scope = AccountScope()
        let contacts = ContactsStore(repository: database.contacts, scope: scope)
        let history = CallHistoryStore(
            repository: database.calls,
            scope: scope,
            contactsStore: contacts
        )
        scope.adopt("user-abc")
        try database.profiles.save(
            LocalProfileRecord(
                id: "user-abc", remoteUserID: "user-abc", name: "Anush", phoneNumber: "+919999999999",
                communicationProfile: nil, defaultCallingInterface: "Text Mode", language: nil,
                profileImageData: nil, hasCompletedOnboarding: true,
                createdAt: Date(), updatedAt: Date()
            )
        )
        return (history, contacts)
    }

    private func entry(
        callId: String = "11111111-1111-1111-1111-111111111111",
        status: CallOutcome = .completed,
        displayName: String? = "Ridhhi",
        phone: String? = "+919876543210"
    ) -> ServerCallEntry {
        let started = Date().addingTimeInterval(-120)
        return ServerCallEntry(
            callId: callId,
            direction: .outgoing,
            otherPartyId: "remote-1",
            otherPartyPhone: phone,
            otherPartyDisplayName: displayName,
            status: status,
            startedAt: started,
            connectedAt: started.addingTimeInterval(5),
            endedAt: started.addingTimeInterval(65)
        )
    }

    @Test("A call the device never saw is added to the history")
    func missingCallIsAdded() throws {
        let (history, _) = try makeStore()
        #expect(history.calls.isEmpty)

        history.reconcile(with: [entry()])
        #expect(history.calls.count == 1)

        let call = history.calls[0]
        #expect(call.contactName == "Ridhhi")
        #expect(call.phoneNumber == "+919876543210")
        #expect(call.status == .completed)
        #expect(call.duration == 60)
    }

    @Test("A call that was missed while the app was closed shows up")
    func missedCallIsAdded() throws {
        let (history, _) = try makeStore()
        history.reconcile(with: [entry(status: .missed)])
        #expect(history.calls.first?.status == .missed)
        #expect(history.calls.first?.didConnect == false)
    }

    @Test("Reconciling the same call twice does not duplicate it")
    func reconcilingTwiceIsIdempotent() throws {
        let (history, _) = try makeStore()
        history.reconcile(with: [entry()])
        history.reconcile(with: [entry()])
        #expect(history.calls.count == 1)
    }

    @Test("A transcript the user chose to keep survives the reconciliation")
    func localTranscriptSurvives() throws {
        let (history, _) = try makeStore()
        let started = Date().addingTimeInterval(-120)
        history.record(
            summary: summary(outcome: .completed, connectedAt: started),
            transcript: [
                TranscriptSegment(speaker: .me, source: .typed, text: "hello", timestamp: started)
            ]
        )
        #expect(history.calls.first?.savedConversation)

        history.reconcile(with: [entry()])
        #expect(history.calls.count == 1)
        #expect(history.calls.first?.savedConversation)
        #expect(history.messages(for: history.calls[0].id).map(\.body) == ["hello"])
    }

    @Test("The server's status wins over the one the device recorded")
    func serverStatusWins() throws {
        let (history, _) = try makeStore()
        history.record(summary: summary(outcome: .cancelled))
        #expect(history.calls.first?.status == .cancelled)

        history.reconcile(with: [entry(status: .completed)])
        #expect(history.calls.first?.status == .completed)
    }

    @Test("A call is matched to its contact by phone number")
    func callIsMatchedToItsContact() throws {
        let (history, contacts) = try makeStore()
        contacts.upsert(Contact(name: "Ridhhi Sharma", phoneNumber: "9876543210", isFavorite: false))
        history.reconcile(with: [entry()])
        #expect(history.calls.first?.contact?.name == "Ridhhi Sharma")
    }
}

/// The rules that decide what the app tells the user when a call cannot be
/// placed.
@Suite("Call routing")
@MainActor
struct CallRoutingTests {

    @Test("A 404 from the server means the number is not on HearMeOut")
    func notFoundIsDetected() {
        let notFound = CallSignalingClient.SignalingError.serverError(status: 404, message: "User not found")
        #expect(CallRouter.isNotFound(notFound))
    }

    @Test("Other failures are not mistaken for a missing account")
    func otherFailuresAreNotNotFound() {
        let rateLimited = CallSignalingClient.SignalingError.serverError(status: 429, message: nil)
        let serverError = CallSignalingClient.SignalingError.serverError(status: 500, message: nil)
        #expect(!CallRouter.isNotFound(rateLimited))
        #expect(!CallRouter.isNotFound(serverError))
        #expect(!CallRouter.isNotFound(SignalingErrorFixture.malformed))
    }

    @Test("The message shown for a failure is the one the server sent")
    func serverMessageIsUsed() {
        let error = CallSignalingClient.SignalingError.serverError(
            status: 409,
            message: "That phone number is already linked to another account"
        )
        #expect(CallRouter.message(for: error) == "That phone number is already linked to another account")
    }

    @Test("A rate-limited lookup tells the user to wait")
    func rateLimitMessage() {
        let error = CallSignalingClient.SignalingError.serverError(status: 429, message: nil)
        #expect(CallRouter.message(for: error).contains("Too many attempts"))
    }
}

private enum SignalingErrorFixture {
    static let malformed = CallSignalingClient.SignalingError.malformedResponse
}

/// How a call ended maps onto what the history shows.
@Suite("Call outcomes")
struct CallOutcomeTests {

    @Test("Only a completed call counts as having connected")
    func didConnect() {
        #expect(CallOutcome.completed.didConnect == true)
        #expect(CallOutcome.missed.didConnect == false)
        #expect(CallOutcome.declined.didConnect == false)
        #expect(CallOutcome.cancelled.didConnect == false)
        #expect(CallOutcome.failed.didConnect == nil)
    }

    @Test("Both missed and declined calls show under the missed filter")
    func missedFilter() {
        #expect(CallOutcome.missed.countsAsMissed)
        #expect(CallOutcome.declined.countsAsMissed)
        #expect(!CallOutcome.completed.countsAsMissed)
        #expect(!CallOutcome.cancelled.countsAsMissed)
        #expect(!CallOutcome.failed.countsAsMissed)
    }
}
