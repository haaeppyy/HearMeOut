import Foundation
import Testing

@testable import HearMeOut

/// ActiveCall state-machine contract: every entry path, every terminal path,
/// and the exact reset semantics CallCoordinator's guards depend on.
///
/// No dependencies to fake — the whole suite runs against a fresh instance
/// per test. The suite is @MainActor because ActiveCall is.
@Suite("ActiveCall state machine")
@MainActor
struct ActiveCallTests {

    private func outgoing(contactName: String = "Priya") -> (ActiveCall, Contact) {
        let call = ActiveCall()
        let contact = Contact(name: contactName, phoneNumber: "+1555", isFavorite: false, remoteUserID: "remote-9")
        call.configureOutgoing(contactName: contactName, contact: contact)
        return (call, contact)
    }

    @Test("fresh instance is idle")
    func freshIsIdle() {
        let call = ActiveCall()
        #expect(call.isLive == false)
        #expect(call.phase == nil)
        #expect(call.callId == nil)
        #expect(call.channel == nil)
        #expect(call.connectedAt == nil)
    }

    @Test("configureOutgoing enters starting and counts as live")
    func configureOutgoingStarts() {
        let (call, _) = outgoing()
        #expect(call.phase == .starting)
        #expect(call.isLive == true)
        #expect(call.contactName == "Priya")
        #expect(call.contact?.remoteUserID == "remote-9")
        if case .outgoing = call.direction {
        } else {
            Issue.record("expected outgoing direction")
        }
    }

    @Test("configureOutgoing clears previous-call state first")
    func configureOutgoingResetsFirst() {
        let (call, _) = outgoing()
        call.started(callId: "old", channel: "old-ch", uid: 3, pushDelivered: true)
        call.markActive()
        let firstUUID = call.callUUID
        call.configureOutgoing(contactName: "Amar", contact: nil)
        #expect(call.phase == .starting)
        #expect(call.callId == nil)
        #expect(call.channel == nil)
        #expect(call.agoraUID == nil)
        #expect(call.connectedAt == nil)
        #expect(call.contactName == "Amar")
        #expect(call.callUUID != firstUUID)
    }

    @Test("outgoing path: started → markActive converges to active")
    func outgoingConvergesToActive() {
        let (call, _) = outgoing()
        call.started(callId: "c-1", channel: "ch-1", uid: 7, pushDelivered: false)
        #expect(call.callId == "c-1")
        #expect(call.channel == "ch-1")
        #expect(call.agoraUID == 7)
        #expect(call.phase == .ringing(pushDelivered: false))
        #expect(call.isLive == true)
        #expect(call.connectedAt == nil)
        call.markActive()
        #expect(call.phase == .active)
        #expect(call.isLive == true)
        #expect(call.connectedAt != nil)
    }

    @Test("incoming path converges to the same active shape as outgoing")
    func incomingConvergesToActive() {
        let incoming = ActiveCall()
        incoming.configureIncoming(callId: "c-9", channel: "ch-9", contactName: "Amar")
        #expect(incoming.phase == .ringing(pushDelivered: true))
        #expect(incoming.isLive == true)
        incoming.joined(channel: "ch-9", uid: 11)
        #expect(incoming.phase == .active)
        #expect(incoming.connectedAt != nil)

        // Same observable shape an outgoing call reaches after markActive.
        let (call, _) = outgoing()
        call.started(callId: "c-1", channel: "ch-1", uid: 7, pushDelivered: true)
        call.markActive()
        #expect(incoming.phase == call.phase)
        #expect(incoming.isLive == call.isLive)
    }

    @Test("started clamps negative uid to zero")
    func startedClampsNegativeUID() {
        let (call, _) = outgoing()
        call.started(callId: "c-1", channel: "ch-1", uid: -3, pushDelivered: true)
        #expect(call.agoraUID == 0)
    }

    @Test("fail from every intermediate state ends the call but preserves ids")
    func failFromEveryState() {
        let states: [(String, (ActiveCall) -> Void)] = [
            ("starting", { _ in }),
            ("ringing", { $0.started(callId: "c", channel: "ch", uid: 1, pushDelivered: true) }),
            ("active", { $0.started(callId: "c", channel: "ch", uid: 1, pushDelivered: true); $0.markActive() }),
        ]
        for (name, advance) in states {
            let (call, _) = outgoing()
            advance(call)
            call.fail("boom")
            #expect(call.phase == .ended(status: "failed"), "from \(name)")
            #expect(call.isLive == false, "from \(name)")
            #expect(call.errorMessage == "boom", "from \(name)")
            // Asserted as-is (deliberate): fail flips the phase but does not
            // clear the ids — the busy-guard reads isLive, not callId.
            if name != "starting" {
                #expect(call.callId == "c", "from \(name)")
                #expect(call.channel == "ch", "from \(name)")
            }
        }
    }

    @Test("end then configureOutgoing starts cleanly (busy-guard precondition)")
    func endThenRestart() {
        let (call, _) = outgoing()
        call.started(callId: "c-1", channel: "ch-1", uid: 7, pushDelivered: true)
        call.markActive()
        call.end()
        #expect(call.phase == .ended(status: "ended"))
        #expect(call.isLive == false)
        // This is what guards CallCoordinator.startOutgoing's "already on
        // a call" check: a fresh configure must be possible again.
        call.configureOutgoing(contactName: "Priya", contact: nil)
        #expect(call.isLive == true)
        #expect(call.phase == .starting)
        #expect(call.callId == nil)
        #expect(call.errorMessage == nil)
    }

    @Test("end carries a custom status")
    func endCustomStatus() {
        let (call, _) = outgoing()
        call.end(status: "missed")
        #expect(call.phase == .ended(status: "missed"))
        #expect(call.isLive == false)
    }

    @Test("reset fully clears state including identity")
    func resetClearsAll() {
        let (call, _) = outgoing()
        call.started(callId: "c-1", channel: "ch-1", uid: 7, pushDelivered: true)
        call.markActive()
        let firstUUID = call.callUUID
        call.reset()
        #expect(call.callId == nil)
        #expect(call.channel == nil)
        #expect(call.agoraUID == nil)
        #expect(call.direction == nil)
        #expect(call.contactName == "")
        #expect(call.contact == nil)
        #expect(call.phase == nil)
        #expect(call.connectedAt == nil)
        #expect(call.errorMessage == nil)
        #expect(call.isLive == false)
        #expect(call.callUUID != firstUUID)
    }
}
