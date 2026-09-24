import Foundation
import Testing

@testable import HearMeOut

/// PushKitManager.parse contract, driven with plain dictionary literals —
/// no PKPushPayload, no registry, no entitlements.
@Suite("Push payload parsing")
struct PushPayloadParsingTests {

    private func fullPayload() -> [AnyHashable: Any] {
        ["callId": "c-1", "channelName": "ch-1",
         "callerId": "u-9", "callerName": "Amar"]
    }

    @Test("all keys present parses fully")
    func happyPath() {
        let push = PushKitManager.parse(fullPayload())
        #expect(push?.callId == "c-1")
        #expect(push?.channelName == "ch-1")
        #expect(push?.callerId == "u-9")
        #expect(push?.callerName == "Amar")
    }

    @Test("any missing required key returns nil")
    func missingKeys() {
        for key in ["callId", "channelName", "callerId"] {
            var payload = fullPayload()
            payload.removeValue(forKey: key)
            #expect(PushKitManager.parse(payload) == nil, "missing \(key)")
        }
    }

    @Test("wrong-typed values return nil, not a crash")
    func wrongTypes() {
        var payload = fullPayload()
        payload["callId"] = 42
        #expect(PushKitManager.parse(payload) == nil)
    }

    @Test("missing/empty/blank callerName falls back to Unknown caller")
    func callerNameFallback() {
        var missing = fullPayload()
        missing.removeValue(forKey: "callerName")
        #expect(PushKitManager.parse(missing)?.callerName == "Unknown caller")

        var empty = fullPayload()
        empty["callerName"] = ""
        #expect(PushKitManager.parse(empty)?.callerName == "Unknown caller")

        var blank = fullPayload()
        blank["callerName"] = "   \n  "
        #expect(PushKitManager.parse(blank)?.callerName == "Unknown caller")
    }

    @Test("present callerName is used trimmed")
    func callerNameUsed() {
        var payload = fullPayload()
        payload["callerName"] = "  Priya  "
        #expect(PushKitManager.parse(payload)?.callerName == "Priya")
    }

    @Test("extra keys are ignored")
    func extraKeys() {
        var payload = fullPayload()
        payload["aps"] = ["content-available": 1]
        payload["anything"] = ["nested": true]
        #expect(PushKitManager.parse(payload)?.callId == "c-1")
    }
}
