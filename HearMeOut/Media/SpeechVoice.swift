import AVFoundation

/// Picks the voice to speak a language with.
///
/// The exact locale is tried first, then the base language, so a device
/// without an Indian English voice installed still speaks English rather
/// than falling back to whatever the system default happens to be.
enum SpeechVoice {

    static func best(for language: String) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: language) {
            return exact
        }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        return AVSpeechSynthesisVoice(language: base)
    }
}
