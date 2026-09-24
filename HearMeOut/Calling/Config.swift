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
        let raw = string("HearMeOutSupabaseURL")
        guard !raw.isEmpty, !raw.contains("REPLACE_ME"), let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }

    static var supabaseAnonKey: String? {
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
