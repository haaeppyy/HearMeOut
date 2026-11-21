import Foundation

/// How a call ended.
///
/// These values line up with the status vocabulary the backend uses on the
/// `calls` row, so a device row and a server row describing the same call
/// can be compared without a translation table.
enum CallOutcome: String, CaseIterable {
    /// Both sides were connected.
    case completed
    /// It rang and nobody answered.
    case missed
    /// The other party deliberately turned it away.
    case declined
    /// This side hung up before it connected.
    case cancelled
    /// Something went wrong.
    case failed

    /// Whether the call actually connected, as the history rows show it.
    /// `nil` when the outcome doesn't distinguish the two (failed calls, for
    /// example, may or may not have connected briefly).
    var didConnect: Bool? {
        switch self {
        case .completed: return true
        case .missed, .declined, .cancelled: return false
        case .failed: return nil
        }
    }

    /// Whether the filter should show this outcome under "Missed calls".
    var countsAsMissed: Bool {
        self == .missed || self == .declined
    }
}
