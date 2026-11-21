import Foundation

/// One line of a conversation.
///
/// Both the typed messages and the speech-recognition captions end up here,
/// so a saved transcript is one ordered list rather than two separate ones
/// that have to be interleaved by hand afterwards.
struct TranscriptSegment: Identifiable, Equatable {

    /// Who said it.
    enum Speaker: String, CaseIterable {
        case me
        case them
        /// Written before the app attributed messages to a speaker. Only
        /// legacy rows carry this.
        case unknown
    }

    /// How it arrived.
    enum Source: String, CaseIterable {
        /// The user typed it.
        case typed
        /// It was recognised from what the other person said.
        case asr
    }

    let id: UUID
    let speaker: Speaker
    let source: Source
    let text: String
    /// Whether this is the settled text. A partial recognition result is not
    /// final until the utterance finishes.
    let isFinal: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        speaker: Speaker,
        source: Source,
        text: String,
        isFinal: Bool = true,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.speaker = speaker
        self.source = source
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
    }
}
