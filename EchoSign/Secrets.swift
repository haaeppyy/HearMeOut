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

    /// Agora temp token for direct-testing (no backend). Rotates daily from
    /// Agora Console → Project Management → join channel tab.
    static let agoraTempToken = "007e7xTYPiovfDj8pd77LzjZCTszQWzJni0/TuY/iq5Xnu6jf8vu68KDKmJ5ommxoYWFgYWySam5qkWSeapxhaGhqapZqaJSUlmJxJnZDUEMjK0XnnPwAiFID4LQ0hqcQkDAwBs8SBq"

    /// Backend signaling service URL. Replace with your actual Supabase
    /// Edge Functions URL.
    static let backendBaseURL = "https://YOUR_PROJECT.supabase.co/functions/v1"

    /// Channel name used for direct-testing mode (when no backend is available).
    static let agoraChannelName = "Test"

    /// Whether the app has real credentials configured.
    static var hasRealCredentials: Bool {
        agoraAppID != "AGORA_APP_ID"
    }

    /// Whether a real backend is configured (not the placeholder).
    static var hasRealBackend: Bool {
        !backendBaseURL.contains("YOUR_PROJECT")
    }

    /// TODO: wire to your real Supabase Auth session — this is a
    /// placeholder so `CallSignalingClient` has
    /// somewhere concrete to call rather than a silent gap. Replace with
    /// something like `SupabaseClient.shared.auth.session.accessToken`
    /// once the app's auth flow is wired up.
    static func currentUserAuthToken() async throws -> String {
        return "dev-token"
    }
}