import Foundation

/// Build-time backend configuration, substituted from Config.xcconfig into
/// Info.plist. `isConfigured` is false until real values replace the
/// REPLACE_ME placeholders — the app then runs its original local-only flow
/// so a missing backend never breaks the build or the simulator experience.
enum AppConfig {
    private static func string(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var supabaseURL: URL? {
        if let override = stagingURLOverride { return override }
        let raw = string("HearMeOutSupabaseURL")
        guard !raw.isEmpty, !raw.contains("REPLACE_ME"), let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }

    static var supabaseAnonKey: String? {
        if let override = stagingAnonKeyOverride { return override }
        let raw = string("HearMeOutSupabaseAnonKey")
        guard !raw.isEmpty, !raw.contains("REPLACE_ME") else { return nil }
        return raw
    }

    static var agoraAppID: String? {
        let raw = string("HearMeOutAgoraAppID")
        guard !raw.isEmpty, !raw.contains("REPLACE_ME") else { return nil }
        return raw
    }

    /// Test seam: `--uitest-local-backend-off` launch argument forces the
    /// local-only flow in UI tests (no network, hermetic). Set once at
    /// launch from HearMeOutApp.init; never in production code.
    static var forceLocalOnly = false

    /// Staging overrides for backend-configured UI tests: `--staging-url`
    /// <url> `--staging-key` <key> launch arguments redirect the client to
    /// a disposable backend (the local Supabase stack). Deliberately NOT
    /// `--uitest-`-prefixed (see the literal-prefix note in
    /// HearMeOutApp.init). Never set in production code.
    static var stagingURLOverride: URL?
    static var stagingAnonKeyOverride: String?

    /// Pre-minted session for backend-configured UI tests (`--staging-session`
    /// <access> `--staging-refresh` <refresh>): adopted in
    /// CallCoordinator.activate() so tests start signed-in without typing
    /// credentials. Never set in production code.
    static var stagingSessionAccessToken: String?
    static var stagingSessionRefreshToken: String?

    /// True only when Supabase URL + anon key are real. Auth, API calls,
    /// push registration and contact lookup all gate on this.
    static var isBackendConfigured: Bool {
        !forceLocalOnly && supabaseURL != nil && supabaseAnonKey != nil
    }

    /// True only when the Agora App ID is real. Audio/RTM join gates on this.
    static var isAgoraConfigured: Bool {
        agoraAppID != nil
    }
}
