import Foundation

/// The id every device-local row is keyed by.
///
/// It is the Supabase user id once the user has signed in and the account
/// has been adopted. Before that it may be the placeholder id used by an
/// earlier build of the app.
///
/// The stores share one of these rather than holding references to each
/// other, so none of them has to know how the others are wired.
@MainActor
final class AccountScope: ObservableObject {
    @Published private(set) var profileID: String?

    func adopt(_ id: String) {
        profileID = id
    }

    func clear() {
        profileID = nil
    }
}
