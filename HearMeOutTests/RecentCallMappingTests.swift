import Foundation
import Testing

@testable import HearMeOut

/// RecentCall ↔ RecentCallRecord round-trip, incl. callSessionID (the
/// dedupe key — a lost ID means duplicated history after every sync).
@Suite("RecentCall record mapping")
struct RecentCallMappingTests {

    @Test("round-trip preserves every field incl. callSessionID")
    func roundTrip() {
        let contact = Contact(name: "Priya", phoneNumber: "+1555", isFavorite: true, remoteUserID: "remote-9")
        let call = RecentCall(
            contactName: "Priya", phoneNumber: "+1555", callMode: "text",
            savedConversation: true, transcript: ["hi"], contact: contact,
            date: Date(timeIntervalSince1970: 1_700_000_000), duration: 95,
            direction: .incoming, didConnect: true,
            recordingDuration: 12, callSessionID: "server-id-1"
        )
        let record = call.record(profileID: "p")
        #expect(record.callSessionID == "server-id-1")
        #expect(record.status == "completed")
        #expect(record.contactID == contact.id.uuidString)

        let back = RecentCall(record: record, contact: contact)
        #expect(back.callSessionID == "server-id-1")
        #expect(back.contactName == "Priya")
        #expect(back.didConnect == true)
        #expect(back.duration == 95)
    }

    @Test("legacy statuses map exactly (ended stays unknown)")
    func legacyStatuses() {
        func row(_ status: String) -> RecentCall {
            RecentCall(record: RecentCallRecord(
                id: "x", profileID: "p", contactID: nil, callSessionID: nil,
                contactName: "N", contactPhoneNumber: "0", callMode: "text",
                direction: "Outgoing", status: status,
                startedAt: nil, endedAt: nil, durationSeconds: 0,
                savedConversation: false, recordingDurationSeconds: nil,
                createdAt: Date()
            ), contact: nil)
        }
        #expect(row("completed").didConnect == true)
        #expect(row("missed").didConnect == false)
        #expect(row("ended").didConnect == nil)
    }

    @Test("record() status mapping covers all didConnect states")
    func recordStatuses() {
        func status(_ connected: Bool?) -> String {
            var call = RecentCall(
                contactName: "N", phoneNumber: "0", callMode: "text",
                savedConversation: false, transcript: [], contact: nil,
                date: Date(), duration: 0, direction: .outgoing, didConnect: connected
            )
            return call.record(profileID: "p").status
        }
        #expect(status(true) == "completed")
        #expect(status(false) == "missed")
        #expect(status(nil) == "ended")
    }
}
