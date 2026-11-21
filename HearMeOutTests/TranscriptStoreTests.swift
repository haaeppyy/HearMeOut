import Foundation
import Testing
@testable import HearMeOut

/// The conversation has to read the way the call happened: what was typed
/// and what was heard, interleaved, with no message appearing twice.
@Suite("Transcript store")
struct TranscriptStoreTests {

    private func caption(
        _ text: String,
        isFinal: Bool = true,
        at timestamp: Date = Date(),
        id: UUID = UUID()
    ) -> CaptionService.CaptionLine {
        CaptionService.CaptionLine(id: id, text: text, isFinal: isFinal, timestamp: timestamp)
    }

    @Test("A typed message and a caption are kept in the order they happened")
    func typedAndCaptionedMessagesInterleave() {
        let store = TranscriptStore()
        let start = Date()

        store.appendTyped(text: "hello", speaker: .me, timestamp: start)
        store.updateCaptions([caption("hi there", at: start.addingTimeInterval(2))])
        store.appendTyped(text: "how are you", speaker: .me, timestamp: start.addingTimeInterval(4))

        #expect(store.segments.count == 3)
        #expect(store.segments.map(\.text) == ["hello", "hi there", "how are you"])
        #expect(store.segments.map(\.speaker) == [.me, .them, .me])
        #expect(store.segments.map(\.source) == [.typed, .asr, .typed])
    }

    @Test("A caption that is still being transcribed is not part of the conversation yet")
    func partialCaptionsAreNotSaved() {
        let store = TranscriptStore()
        store.updateCaptions([caption("hel", isFinal: false)])
        #expect(store.segments.isEmpty)
    }

    @Test("A caption that repeats what the other side typed is dropped")
    func echoedCaptionIsDropped() {
        let store = TranscriptStore()
        // The other side typed this; their device also speaks it, so our
        // recogniser hears it a moment later.
        store.appendRemoteText("I am on my way")
        store.updateCaptions([caption("I am on my way")])

        #expect(store.segments.count == 1)
        #expect(store.segments[0].source == .typed)
        #expect(store.segments[0].speaker == .them)
    }

    @Test("A caption that is only part of the typed message is dropped")
    func partialEchoIsDropped() {
        let store = TranscriptStore()
        store.appendRemoteText("I am on my way to the meeting")
        store.updateCaptions([caption("I am on my way")])
        #expect(store.segments.count == 1)
    }

    @Test("A caption that says something else is kept")
    func unrelatedCaptionIsKept() {
        let store = TranscriptStore()
        store.appendRemoteText("I am on my way")
        store.updateCaptions([caption("can you hear me")])
        #expect(store.segments.count == 2)
        #expect(store.segments.map(\.source) == [.typed, .asr])
    }

    @Test("A dropped caption stays dropped")
    func droppedCaptionStaysDropped() {
        let store = TranscriptStore()
        store.appendRemoteText("I am on my way")
        store.updateCaptions([caption("I am on my way")])
        #expect(store.segments.count == 1)

        // The recogniser rebuilds its log as it goes; the same caption must
        // not come back later.
        store.updateCaptions([caption("I am on my way"), caption("hello")])
        #expect(store.segments.count == 2)
        #expect(store.segments.map(\.text) == ["I am on my way", "hello"])
    }

    @Test("Text from this side is never confused with text from the other side")
    func ownTypedTextIsNotSuppressed() {
        let store = TranscriptStore()
        store.appendTyped(text: "I am on my way", speaker: .me)
        store.updateCaptions([caption("I am on my way")])
        // The caption is the other person saying the same thing, so it stays.
        #expect(store.segments.count == 2)
    }
}
