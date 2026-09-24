import Combine
import Foundation

/// Single source of truth for "what call is happening right now", shared by
/// CallsView, AudioCallView, TextCallView, CallKit and Agora. Replaces the
/// fake per-view state (ActiveAudioCall/ActiveTextCall + 0.8s timers) for any
/// call that goes through the backend.
@MainActor
final class ActiveCall: ObservableObject {
    enum Direction {
        case outgoing
        case incoming
    }

    enum Phase: Equatable {
        /// startCall sent, waiting on the Edge Function response.
        case starting
        /// Ringing. pushDelivered=false means the callee's phone almost
        /// certainly won't ring (no token / APNs misconfigured) — the UI
        /// must say so instead of spinning forever.
        case ringing(pushDelivered: Bool)
        /// Both sides joined (RTC joined locally counts as active for the
        /// outgoing side; the callee flips to active on call-join).
        case active
        case ended(status: String)
    }

    @Published var callId: String?
    @Published var channel: String?
    @Published var agoraUID: UInt?
    @Published var direction: Direction?
    @Published var contactName: String = ""
    @Published var contact: Contact?
    @Published var phase: Phase?
    @Published var connectedAt: Date?
    @Published var callUUID = UUID()
    @Published var errorMessage: String?

    /// Nonisolated so the app graph can be built in HearMeOutApp.init.
    /// (Plain class — no superclass, so no override/super needed.)
    nonisolated init() {}

    var isLive: Bool {
        guard let phase else { return false }
        switch phase {
        case .starting, .ringing, .active: return true
        case .ended: return false
        }
    }

    func configureOutgoing(contactName: String, contact: Contact?) {
        reset()
        self.contactName = contactName
        self.contact = contact
        direction = .outgoing
        phase = .starting
    }

    func configureIncoming(callId: String, channel: String, contactName: String) {
        reset()
        self.callId = callId
        self.channel = channel
        self.contactName = contactName
        direction = .incoming
        // Incoming ringing is reported by CallKit immediately from the push;
        // the server row is already `ringing` (calls/ created it).
        phase = .ringing(pushDelivered: true)
    }

    func started(callId: String, channel: String, uid: Int, pushDelivered: Bool) {
        self.callId = callId
        self.channel = channel
        agoraUID = UInt(max(0, uid))
        phase = .ringing(pushDelivered: pushDelivered)
    }

    func joined(channel: String, uid: Int) {
        self.channel = channel
        agoraUID = UInt(max(0, uid))
        phase = .active
        if connectedAt == nil { connectedAt = Date() }
    }

    func markActive() {
        phase = .active
        if connectedAt == nil { connectedAt = Date() }
    }

    func fail(_ message: String) {
        errorMessage = message
        phase = .ended(status: "failed")
    }

    func end(status: String = "ended") {
        phase = .ended(status: status)
    }

    func reset() {
        callId = nil
        channel = nil
        agoraUID = nil
        direction = nil
        contactName = ""
        contact = nil
        phase = nil
        connectedAt = nil
        callUUID = UUID()
        errorMessage = nil
    }
}
