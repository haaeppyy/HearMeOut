import Foundation
import Combine

/// Owns the three device-local stores and wires them together.
///
/// The app holds one of these and hands the individual stores to the views
/// as environment objects, so a view can read and write the data it needs
/// without ever reaching for the database.
@MainActor
final class AppStores: ObservableObject {

    let scope: AccountScope
    let profile: ProfileStore
    let contacts: ContactsStore
    let callHistory: CallHistoryStore

    private let signaling: CallSignalingClient

    init(database: AppDatabase, signaling: CallSignalingClient) {
        let scope = AccountScope()
        let profile = ProfileStore(
            profiles: database.profiles,
            accounts: database.accounts,
            scope: scope
        )
        let contacts = ContactsStore(
            repository: database.contacts,
            scope: scope,
            signaling: signaling
        )
        self.signaling = signaling
        self.scope = scope
        self.profile = profile
        self.contacts = contacts
        self.callHistory = CallHistoryStore(
            repository: database.calls,
            scope: scope,
            contactsStore: contacts
        )
    }

    /// Builds the stores on top of the on-device database.
    static func make(signaling: CallSignalingClient) -> AppStores {
        AppStores(database: AppDatabase.make(), signaling: signaling)
    }

    /// Loads everything, in the order the stores depend on each other: the
    /// profile first, because it decides which account the rest of the data
    /// belongs to.
    func loadAll() {
        profile.load()
        contacts.load()
        callHistory.load()
    }

    /// Clears the signed-out account's data from the screen.
    ///
    /// The rows stay on the device — they are keyed by account, so the
    /// next sign-in finds them again.
    func resetForSignOut() {
        profile.reset()
        contacts.load()
        callHistory.load()
    }

    /// Loads the signed-in account's profile from the server and applies it
    /// to the device.
    ///
    /// This is what makes onboarding a property of the account rather than
    /// of the device: a second phone signing into the same account finds
    /// the profile already filled in and goes straight to the app.
    func loadProfile(for userID: String) async {
        do {
            let server = try await signaling.fetchProfile()
            try profile.apply(serverProfile: server, userID: userID)
        } catch let error as CallSignalingClient.SignalingError {
            if case .serverError(let status, _) = error, status == 404 {
                // No profile on the server: this account has never been
                // through onboarding.
                profile.markProfileMissing(userID: userID)
            } else {
                print("Unable to load the profile: \(error.localizedDescription)")
                profile.markProfileUnavailable()
            }
        } catch {
            print("Unable to load the profile: \(error.localizedDescription)")
            profile.markProfileUnavailable()
        }
        contacts.load()
        callHistory.load()
    }

    /// Saves onboarding profile details to the server and refreshes the local copy.
    func saveProfile(
        displayName: String,
        phone: String,
        communicationProfile: String,
        language: String
    ) async throws {
        let saved = try await signaling.saveProfile(body: [
            "display_name": displayName,
            "phone": phone,
            "communication_profile": communicationProfile,
            "language": language
        ])
        try profile.apply(serverProfile: saved, userID: saved.id)
    }

    /// Reconciles the call history with the server.
    ///
    /// This is how a call that happened while the app was closed — one
    /// that was missed, or one that was answered on another device —
    /// turns up in the recents.
    func syncHistory() async {
        do {
            let entries = try await signaling.fetchCallHistory()
            callHistory.reconcile(with: entries)
        } catch {
            print("Unable to sync the call history: \(error.localizedDescription)")
        }
    }
}
