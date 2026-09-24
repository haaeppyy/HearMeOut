import Foundation
import Testing

@testable import HearMeOut

/// History-reconciliation matrix: every merge branch driven deterministically.
@Suite("HistoryMerger")
struct HistoryMergerTests {

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func entry(
        _ callId: String,
        status: String = "ended",
        direction: String = "outgoing",
        otherPartyId: String? = "remote-1",
        startedAt: Date? = base,
        endedAt: Date? = nil
    ) -> CallHistoryEntry {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var dict: [String: Any?] = [
            "callId": callId,
            "direction": direction,
            "otherPartyId": otherPartyId,
            "status": status,
        ]
        dict["startedAt"] = startedAt.map { iso.string(from: $0) }
        dict["endedAt"] = endedAt.map { iso.string(from: $0) }
        let data = try! JSONSerialization.data(withJSONObject: dict.compactMapValues { $0 })
        return try! JSONDecoder().decode(CallHistoryEntry.self, from: data)
    }

    private static func localRow(_ callSessionID: String?, date: Date = base) -> RecentCall {
        RecentCall(
            contactName: "Local", phoneNumber: "+1000", callMode: "text",
            savedConversation: false, transcript: [], contact: nil,
            date: date, duration: 60, direction: .outgoing, didConnect: nil,
            callSessionID: callSessionID
        )
    }

    @Test("known row refreshes outcome without duplicating")
    func knownRowRefresh() {
        let merged = HistoryMerger.merge(
            entries: [Self.entry("abc", status: "ended", startedAt: Self.base, endedAt: Self.base.addingTimeInterval(120))],
            into: [Self.localRow("abc")],
            contacts: [],
            defaultAudioMode: false
        )
        #expect(merged.count == 1)
        #expect(merged[0].didConnect == true)
        #expect(merged[0].duration == 120)
    }

    @Test("ringing outcome stays unknown, missed maps false, failed maps false")
    func statusMapping() {
        #expect(RecentCall.didConnect(forServerStatus: "ringing") == nil)
        #expect(RecentCall.didConnect(forServerStatus: "bridging") == nil)
        #expect(RecentCall.didConnect(forServerStatus: "active") == nil)
        #expect(RecentCall.didConnect(forServerStatus: "created") == nil)
        #expect(RecentCall.didConnect(forServerStatus: "ended") == true)
        #expect(RecentCall.didConnect(forServerStatus: "completed") == true)
        #expect(RecentCall.didConnect(forServerStatus: "missed") == false)
        #expect(RecentCall.didConnect(forServerStatus: "failed") == false)
    }

    @Test("unknown incoming row is inserted with contact resolved")
    func unknownIncomingInsert() {
        let contact = Contact(name: "Priya", phoneNumber: "+15550002222", isFavorite: false, remoteUserID: "remote-9")
        let merged = HistoryMerger.merge(
            entries: [Self.entry("new-1", status: "missed", direction: "incoming", otherPartyId: "remote-9")],
            into: [],
            contacts: [contact],
            defaultAudioMode: false
        )
        #expect(merged.count == 1)
        #expect(merged[0].contactName == "Priya")
        #expect(merged[0].direction == .incoming)
        #expect(merged[0].didConnect == false)
        #expect(merged[0].callSessionID == "new-1")
        #expect(merged[0].callMode == "text")
    }

    @Test("unresolvable party becomes Unknown caller, audio mode respected")
    func unknownCallerFallback() {
        let merged = HistoryMerger.merge(
            entries: [Self.entry("new-2", status: "ringing", direction: "incoming", otherPartyId: nil)],
            into: [],
            contacts: [],
            defaultAudioMode: true
        )
        #expect(merged[0].contactName == "Unknown caller")
        #expect(merged[0].callMode == "audio")
        #expect(merged[0].didConnect == nil)
    }

    @Test("result sorts newest-first and never duplicates ids")
    func sortAndDedupe() {
        let old = Self.localRow("old", date: Self.base.addingTimeInterval(-5000))
        let merged = HistoryMerger.merge(
            entries: [
                Self.entry("old", status: "ended", startedAt: Self.base.addingTimeInterval(-5000), endedAt: Self.base.addingTimeInterval(-4900)),
                Self.entry("fresh", status: "ended", startedAt: Self.base, endedAt: Self.base.addingTimeInterval(30)),
            ],
            into: [old],
            contacts: [],
            defaultAudioMode: false
        )
        #expect(merged.count == 2)
        #expect(merged[0].callSessionID == "fresh")
        #expect(merged[1].callSessionID == "old")
    }

    @Test("fractional-second timestamps decode")
    func fractionalDates() {
        let json = """
        {"callId":"f","direction":"outgoing","otherPartyId":null,"status":"ended",\
        "startedAt":"2026-09-23T20:12:14.858625+00:00","endedAt":"2026-09-23T20:12:27.427+00:00"}
        """.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(CallHistoryEntry.self, from: json)
        #expect(decoded.startedAt != nil)
        #expect(decoded.endedAt != nil)
        #expect(decoded.endedAt! > decoded.startedAt!)
    }
}
