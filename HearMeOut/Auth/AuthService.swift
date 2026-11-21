import Foundation
import Supabase

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published private(set) var session: Session?
    @Published private(set) var isRestoringSession = true

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: Secrets.supabaseURL)!,
            supabaseKey: Secrets.supabaseAnonKey
        )

        Task { await restoreSession() }
    }

    var userID: UUID? { session?.user.id }

    func restoreSession() async {
        defer { isRestoringSession = false }
        do {
            session = try await client.auth.session
        } catch {
            session = nil
        }
    }

    func signIn(email: String, password: String) async throws {
        session = try await client.auth.signIn(email: email, password: password)
    }

    /// If email confirmation is enabled in Supabase, this creates the user
    /// but leaves `session` nil until they verify their email and sign in.
    func signUp(email: String, password: String) async throws -> Bool {
        let result = try await client.auth.signUp(email: email, password: password)
        session = result.session
        return result.session != nil
    }

    func signOut() async throws {
        try await client.auth.signOut()
        session = nil
    }

    func accessToken() async throws -> String {
        // Supabase persists and refreshes the authenticated session as needed.
        // Do not force a refresh for every signaling request: during a call
        // that creates needless network traffic and can race concurrent joins.
        if let session { return session.accessToken }
        let restoredSession = try await client.auth.session
        session = restoredSession
        return restoredSession.accessToken
    }
}
