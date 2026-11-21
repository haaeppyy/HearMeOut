import Foundation

/// Paste your real credentials here in one place.
///
/// - App ID:  Agora Console > Project Management > your project > App ID.
/// - Backend URL: Your Supabase Edge Functions URL for signaling.
///
/// NOTE: Agora tokens are now fetched from the backend signaling service,
/// not hardcoded here. The backend generates time-limited tokens per call.
enum Secrets {
    static let agoraAppID = "ea7a5318808c457e8b7e38115e65abb6"

    /// Project URL and publishable/anon key from Supabase Dashboard > Connect.
    /// Do not put a service-role key or an Agora App Certificate in this app.
    static let supabaseURL = "https://moxklalfnzslttsvpmrr.supabase.co"
    static let supabaseAnonKey = "sb_publishable_7Y5EDPgSkp1irMzBk7FHlw_zo4_wWyT"

    static let backendBaseURL = "\(supabaseURL)/functions/v1"

    /// Fetches a usable Supabase access token. This deliberately throws while
    /// signed out instead of falling back to a development token.
    static func currentUserAuthToken() async throws -> String {
        try await AuthService.shared.accessToken()
    }
}
