import Foundation
import Combine

/// The signed-in user's own profile, and the owner of the account's local
/// data.
///
/// This is the only store that knows about the account itself: it is where
/// the Supabase user id is adopted, which is what re-keys every other
/// device-local table.
@MainActor
final class ProfileStore: ObservableObject {

    /// The cached profile. `nil` until the store has loaded.
    @Published private(set) var profile: LocalProfileRecord?

    /// Whether this account still has to go through onboarding.
    ///
    /// This is a property of the account, not of the device: a second
    /// device signing into the same account does not ask the questions
    /// again.
    @Published private(set) var needsOnboarding: Bool = true

    /// Whether the account's profile has been resolved — either loaded from
    /// the server, or found to be absent. Until this is true the app cannot
    /// tell whether onboarding is needed.
    @Published private(set) var isProfileLoaded: Bool = false

    private let profiles: ProfileRepository
    private let accounts: AccountRepository
    private let scope: AccountScope

    init(profiles: ProfileRepository, accounts: AccountRepository, scope: AccountScope) {
        self.profiles = profiles
        self.accounts = accounts
        self.scope = scope
    }

    /// The id the device-local data is currently keyed by.
    var profileID: String? { profile?.id }

    /// The id the account is keyed by.
    var accountID: String? { profile?.remoteUserID }

    /// The user's display name.
    var displayName: String { profile?.name ?? "" }

    /// The user's phone number, in the E.164 form the server stores.
    var phoneNumber: String { profile?.phoneNumber ?? "" }

    /// The language captions and text-to-speech should use.
    var language: String { profile?.language ?? "en-IN" }

    /// How the user says they prefer to communicate.
    var communicationProfile: String? { profile?.communicationProfile }

    /// Which calling interface the app opens by default.
    ///
    /// This is a device-local preference, but it lives on the profile row
    /// rather than in `UserDefaults` so that two accounts on one phone do
    /// not inherit each other's setting.
    var defaultCallingInterface: String {
        profile?.defaultCallingInterface ?? "Text Mode"
    }

    /// Loads the cached profile, if there is one.
    func load() {
        do {
            let loaded = try profiles.fetch()
            profile = loaded
            if let id = loaded?.id {
                scope.adopt(id)
            }
            needsOnboarding = !(loaded?.hasCompletedOnboarding ?? false)
        } catch {
            print("Unable to load profile: \(error)")
        }
    }

    /// Applies a profile that came from the server, adopting the account
    /// onto the device-local data at the same time.
    func apply(serverProfile: ServerProfile?, userID: String) throws {
        let existing = profile
        let communicationProfile = serverProfile?.communicationProfile ?? existing?.communicationProfile
        let completed = serverProfile?.hasCompletedOnboarding ?? (existing?.hasCompletedOnboarding ?? false)

        _ = try adoptAccount(
            userID: userID,
            name: serverProfile?.displayName ?? existing?.name ?? "",
            phoneNumber: serverProfile?.phone ?? existing?.phoneNumber ?? "",
            communicationProfile: communicationProfile,
            defaultCallingInterface: existing?.defaultCallingInterface ?? "Text Mode",
            language: serverProfile?.language ?? existing?.language ?? "en-IN",
            profileImageData: existing?.profileImageData,
            hasCompletedOnboarding: completed
        )

        needsOnboarding = !completed
        isProfileLoaded = true
    }

    /// Records that the account has no server profile yet, which means it
    /// has not been through onboarding.
    func markProfileMissing(userID: String) {
        do {
            try adoptAccount(
                userID: userID,
                name: profile?.name ?? "",
                phoneNumber: profile?.phoneNumber ?? "",
                communicationProfile: profile?.communicationProfile,
                defaultCallingInterface: profile?.defaultCallingInterface ?? "Text Mode",
                language: profile?.language ?? "en-IN",
                profileImageData: profile?.profileImageData,
                hasCompletedOnboarding: profile?.hasCompletedOnboarding ?? false
            )
            needsOnboarding = true
            isProfileLoaded = true
        } catch {
            print("Unable to adopt account: \(error)")
            isProfileLoaded = true
        }
    }

    /// Adopts a signed-in account, moving any data an earlier build wrote
    /// under the placeholder profile id onto the account's own id.
    @discardableResult
    func adoptAccount(
        userID: String,
        name: String,
        phoneNumber: String,
        communicationProfile: String?,
        defaultCallingInterface: String,
        language: String?,
        profileImageData: Data? = nil,
        hasCompletedOnboarding: Bool = true
    ) throws -> LocalProfileRecord {
        let now = Date()
        let adopted = try accounts.adoptAccount(
            userID: userID,
            profile: LocalProfileRecord(
                id: userID,
                remoteUserID: userID,
                name: name,
                phoneNumber: phoneNumber,
                communicationProfile: communicationProfile,
                defaultCallingInterface: defaultCallingInterface,
                language: language,
                profileImageData: profileImageData,
                hasCompletedOnboarding: hasCompletedOnboarding,
                createdAt: now,
                updatedAt: now
            )
        )
        profile = adopted
        scope.adopt(adopted.id)
        return adopted
    }

    /// Records that the server could not be reached.
    ///
    /// The cached profile is kept — the user has already done this work, and
    /// a network problem is not a reason to ask again.
    func markProfileUnavailable() {
        needsOnboarding = !(profile?.hasCompletedOnboarding ?? false)
        isProfileLoaded = true
    }

    /// Applies a change to the cached profile and writes it back.
    func update(_ mutate: (inout LocalProfileRecord) -> Void) throws {
        guard var current = profile else { return }
        mutate(&current)
        current.updatedAt = Date()
        try profiles.save(current)
        profile = current
    }

    /// Changes which calling interface the app opens by default.
    func setDefaultCallingInterface(_ value: String) {
        try? update { $0.defaultCallingInterface = value }
    }

    /// Records that the account has finished onboarding.
    func markOnboardingComplete() {
        needsOnboarding = false
        try? update { $0.hasCompletedOnboarding = true }
    }

    /// Clears the cached profile when the user signs out.
    ///
    /// The rows themselves stay on the device — the next account to sign in
    /// gets its own, keyed by its own id, and the next sign-in by the same
    /// account finds its data again.
    func reset() {
        profile = nil
        needsOnboarding = true
        isProfileLoaded = false
        scope.clear()
    }
}
