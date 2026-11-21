import Foundation

/// How the user says they prefer to communicate. This drives the default
/// calling interface, which is the first thing the app asks for.
enum CommunicationProfile: String, CaseIterable, Identifiable {
    case hearAndSpeak
    case hearOnly
    case partialHearing
    case speakOnly
    case textOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hearAndSpeak: "I can hear & speak"
        case .hearOnly: "I can hear, but I can’t speak"
        case .partialHearing: "I have partial hearing"
        case .speakOnly: "I can speak, but I can’t hear"
        case .textOnly: "I can’t hear or speak"
        }
    }

    var description: String {
        switch self {
        case .hearAndSpeak: "Use voice calling as your default."
        case .hearOnly: "Use text-first calling to reply without speaking."
        case .partialHearing: "Use text-first calling with optional audio when it helps."
        case .speakOnly: "Use text-first calling with visual responses."
        case .textOnly: "Use text-first calling for every conversation."
        }
    }

    var symbol: String {
        switch self {
        case .hearAndSpeak: "waveform"
        case .hearOnly: "ear.and.waveform"
        case .partialHearing: "ear.badge.waveform"
        case .speakOnly: "mouth"
        case .textOnly: "text.bubble"
        }
    }

    /// Everyone but "I can hear & speak" gets a text-first default.
    var defaultCallingInterface: String {
        self == .hearAndSpeak ? "Audio Mode" : "Text Mode"
    }
}
