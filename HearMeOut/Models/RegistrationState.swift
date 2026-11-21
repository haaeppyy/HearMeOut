import Foundation

/// Whether the server knows this contact's phone number.
///
/// The answer is cached per contact so the app can show "On HearMeOut" or
/// "Not on HearMeOut" without a network round trip on every list render.
///
/// The `blocked` state is local-only: it means the current user has blocked
/// this contact on the server, so the contact cannot start or receive calls.
enum RegistrationState: String, CaseIterable {
    /// Never checked, or the number was edited since the last check.
    case unknown
    /// The server has a user with this number.
    case registered
    /// The server has no user with this number.
    case notOnApp = "not_on_app"
    /// The current user has blocked this contact.
    case blocked

    var label: String? {
        switch self {
        case .unknown: return nil
        case .registered: return "On HearMeOut"
        case .notOnApp: return "Not on HearMeOut"
        case .blocked: return "Blocked"
        }
    }
}
