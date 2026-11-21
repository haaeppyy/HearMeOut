import Foundation

/// The conversation, as it happens.
///
/// One ordered list of segments, whether they were typed or recognised from
/// speech, so the two can be interleaved and saved in the order they
/// actually happened.
///
/// The store also handles one subtlety: when the other side types a message,
/// their device speaks it out loud, so speech recognition on this side
/// hears the same words a moment later. Those captions are dropped, or the
/// conversation would show every message twice.
final class TranscriptStore {

    /// How long a caption stays suppressed after the same words arrive as
    /// exact text. Long enough to cover the round trip of the text being
    /// sent, spoken and recognised.
    private static let suppressionWindow: TimeInterval = 15

    /// The conversation, in the order it happened.
    private(set) var segments: [TranscriptSegment] = []

    /// Messages with exact text, from either side.
    private var typedSegments: [TranscriptSegment] = []

    /// Lines recognised from the other person's speech.
    private var captionSegments: [TranscriptSegment] = []

    /// Text the other side typed, and how long its echo stays suppressed.
    private var suppressions: [(text: String, until: Date)] = []

    /// The recognition results that have already been dropped as echoes, so
    /// they stay dropped once the suppression window has passed.
    private var suppressedCaptionIDs: Set<UUID> = []

    /// Replaces the captions with the current recognition results.
    ///
    /// The recogniser replaces the line it is still working on rather than
    /// adding to it, so the captions are rebuilt from the log rather than
    /// appended to. Only settled lines are kept; the one being transcribed
    /// right now is shown separately, live.
    func updateCaptions(_ lines: [CaptionService.CaptionLine]) {
        captionSegments = lines.compactMap { line in
            guard line.isFinal else { return nil }
            guard !suppressedCaptionIDs.contains(line.id) else { return nil }
            guard !isSuppressed(line.text) else {
                suppressedCaptionIDs.insert(line.id)
                return nil
            }
            return TranscriptSegment(
                speaker: .them,
                source: .asr,
                text: line.text,
                isFinal: true,
                timestamp: line.timestamp
            )
        }
        rebuild()
    }

    /// Adds a message the user typed.
    func appendTyped(
        text: String,
        speaker: TranscriptSegment.Speaker,
        timestamp: Date = Date()
    ) {
        typedSegments.append(TranscriptSegment(
            speaker: speaker,
            source: .typed,
            text: text,
            timestamp: timestamp
        ))
        rebuild()
    }

    /// Adds text the other side typed and sent over the text channel.
    func appendRemoteText(_ text: String, timestamp: Date = Date()) {
        suppressions.append((text, timestamp.addingTimeInterval(Self.suppressionWindow)))
        typedSegments.append(TranscriptSegment(
            speaker: .them,
            source: .typed,
            text: text,
            timestamp: timestamp
        ))
        rebuild()
    }

    /// Whether a caption repeats text that already arrived as exact text.
    private func isSuppressed(_ text: String) -> Bool {
        let key = Self.normalize(text)
        guard !key.isEmpty else { return false }
        let now = Date()
        suppressions.removeAll { $0.until <= now }
        return suppressions.contains { entry in
            let other = Self.normalize(entry.text)
            guard !other.isEmpty else { return false }
            // The caption may be a fragment of the typed message, or the
            // typed message may be a fragment of what was heard.
            return other.contains(key) || key.contains(other)
        }
    }

    private func rebuild() {
        segments = (typedSegments + captionSegments).sorted { $0.timestamp < $1.timestamp }
    }

    /// Strips the parts of two messages that cannot tell them apart —
    /// case, spacing and punctuation.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
