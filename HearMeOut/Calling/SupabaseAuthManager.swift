import Combine
import Foundation
import Supabase

/// Wraps supabase-swift auth. Owns the session, exposes the user id and a
/// fresh bearer token for CallAPIClient, and keeps `public.users` in sync
/// (display name from signup metadata via the DB trigger, phone via
/// `syncProfile` — email signup carries no phone in auth).
///
/// Verified against supabase-swift 2.55.x: signUp(email:password:data:
/// [String: JSONValue]), signIn(email:password:) -> Session,
/// currentSession/currentUser, `session` (refreshing, async throws),
/// AuthResponse enum (.session/.user), User.id: UUID.
@MainActor
final class SupabaseAuthManager: ObservableObject {
    @Published private(set) var userID: String?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var displayName: String?

    let client: SupabaseClient

    /// Nonisolated so the app graph can be built in HearMeOutApp.init.
    /// Session restore is deliberately NOT here — call restore() (or
    /// coordinator.activate()) from a MainActor context after init.
    nonisolated init() {
        let url = AppConfig.supabaseURL ?? URL(string: "https://localhost")!
        let key = AppConfig.supabaseAnonKey ?? ""
        client = SupabaseClient(supabaseURL: url, supabaseKey: key)
    }

    /// Pick up an already-persisted session (supabase-swift stores it in
    /// UserDefaults under a namespaced key).
    func restore() {
        if let session = client.auth.currentSession {
            apply(session: session)
        } else {
            clear()
        }
    }

    enum AuthError: LocalizedError {
        case emailConfirmationPending
        case noSessionAfterSignIn

        var errorDescription: String? {
            switch self {
            case .emailConfirmationPending:
                return "Check your email to confirm the account, then sign in."
            case .noSessionAfterSignIn:
                return "Signed up, but no session was created. Try signing in."
            }
        }
    }

    /// Sign up, then fall back to sign-in when the project creates the
    /// session immediately. Throws AuthError.emailConfirmationPending when
    /// the project requires confirmation first.
    func signUp(name: String, email: String, phone: String, password: String) async throws {
        let response = try await client.auth.signUp(
            email: email,
            password: password,
            data: ["display_name": .string(name)]
        )
        switch response {
        case .session(let session):
            apply(session: session)
            try await syncProfile(name: name, phone: phone)
        case .user:
            // No session minted: email confirmation is on. The trigger row
            // exists, but we are not authenticated yet — sync runs on the
            // first sign-in instead.
            throw AuthError.emailConfirmationPending
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await client.auth.signIn(email: email, password: password)
        apply(session: session)
    }

    /// Reconcile display name/phone into public.users after sign-in (covers
    /// the confirmation-pending path where signUp could not sync).
    func syncProfileAfterSignIn(name: String, phone: String) async throws {
        try await syncProfile(name: name, phone: phone)
        displayName = name
    }

    func signOut() async throws {
        try await client.auth.signOut()
        clear()
    }

    /// Fresh bearer token for CallAPIClient. Refreshes the session first so
    /// calls never go out with an expired JWT.
    func accessToken() async throws -> String {
        try await client.auth.session.accessToken
    }

    // MARK: - public.users sync (plain REST, no PostgREST builder dependency)

    private func syncProfile(name: String, phone: String) async throws {
        guard let base = AppConfig.supabaseURL,
              let anon = AppConfig.supabaseAnonKey,
              let uid = userID else { return }
        let token = try await accessToken()
        var request = URLRequest(url: base.appendingPathComponent("/rest/v1/users"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anon, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Insert-or-update on the PK: the signup trigger usually wins the
        // race and creates the row first; merge-duplicates covers either order.
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        let body: [String: String?] = ["id": uid, "display_name": name, "phone": normalizedPhone(phone)]
        request.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CallAPIError.server(message: "Failed to sync profile", status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// E.164-ish normalization both sides of users-lookup must agree on:
    /// strip everything but digits and a single leading +.
    /// Nonisolated: pure function, callable from tests and any thread.
    nonisolated static func normalizePhone(_ raw: String) -> String {
        var digits = raw.filter(\.isWholeNumber)
        let hadPlus = raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        if !hadPlus, digits.count == 10 {
            // Bare 10-digit NANP number without a country code.
            digits = "1" + digits
        }
        return "+" + digits
    }

    private func normalizedPhone(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return Self.normalizePhone(trimmed)
    }

    // MARK: - state

    private func apply(session: Session) {
        userID = session.user.id.uuidString
        isAuthenticated = true
        if case .string(let name) = session.user.userMetadata["display_name"], !name.isEmpty {
            displayName = name
        }
    }

    private func clear() {
        userID = nil
        isAuthenticated = false
        displayName = nil
    }
}
