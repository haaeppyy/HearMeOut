import Foundation

/// Everything worth keeping about a call that has finished.
///
/// The view model emits one of these when the call ends. It is the only
/// thing that crosses from the call screen into the call history, so the
/// history row is built from a real record of what happened rather than
/// from whatever the screen happened to know.
struct CallSummary {
    /// The backend's id for this call, when the call reached the server.
    let callId: String?
    /// Who the other side was.
    let otherPartyDisplayName: String
    /// Their phone number, when it is known.
    let otherPartyPhone: String?
    /// Their user id on the server, when it is known.
    let otherPartyRemoteUserID: String?
    /// Which side this device was on.
    let direction: CallDirection
    /// Which skin the call was on: "audio" or "text".
    let callMode: String
    /// When the call was placed.
    let startedAt: Date
    /// When the call actually connected, which is not the same as when it
    /// started.
    let connectedAt: Date?
    /// When the call ended.
    let endedAt: Date
    /// How it ended.
    let outcome: CallOutcome

    /// How long the call was connected for.
    var duration: TimeInterval {
        guard let connectedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(connectedAt))
    }
}
