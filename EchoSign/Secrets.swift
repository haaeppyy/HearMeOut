import Foundation

/// Paste your real credentials here in one place.
///
/// - App ID:  Agora Console > Project Management > your project > App ID.
/// - Temp token: Agora Console > Project Management > your project > "Generate Temp RTC Token".
///   Enter the SAME channel name you intend to test with, or the join will fail.
///
/// NOTE: temp tokens expire (~24h) and are tied to a specific channel name.
/// Regenerate from Agora Console if testing breaks after a day, and use the same
/// channel ID on both phones.
enum Secrets {
    static let agoraAppID = "ea7a5318808c457e8b7e38115e65abb6"
    static let agoraTempToken = "007eJxTYAhmFHd7tYzB7MEs/r8X1OqPONxmmnwwZYtvrM1h/1mS4rcUGFITzRNNjQ0tLAwskk1MzVMtksxTjS0MDU1TzUwTk5LMLB8VZTUEMjJsa3vGwsgAgSA+C0NIanEJAwMA4tgenw=="

    /// Temp tokens are bound to one channel name — the call always joins this one.
    static let agoraChannelName = "Test"

    /// Leave `nil` when `AGORA_APP_ID` / `AGORA_TEMP_TOKEN` have been substituted,
    /// to fail fast instead of stumbling into credentials that secure the channel.
    static var hasRealCredentials: Bool {
        agoraAppID != "AGORA_APP_ID" && !agoraTempToken.isEmpty
    }
}