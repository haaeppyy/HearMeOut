import AVFoundation
import Foundation
import Testing

@testable import HearMeOut

/// The one thing worth testing about lock-protected counters: the lock
/// holds under contention, not just single-threaded.
@Suite("TelemetryBox counters")
struct TelemetryBoxTests {

    @Test("single-threaded notes accumulate exactly")
    func singleThreaded() {
        let box = TelemetryBox()
        box.noteAttempt()
        box.noteAttempt()
        box.noteFailure()
        #expect(box.noteFrame() == 1)
        #expect(box.noteFrame() == 2)
        let snap = box.snapshot()
        #expect(snap.playbackFrames == 2)
        #expect(snap.pushAttempts == 2)
        #expect(snap.pushFailures == 1)
    }

    @Test("concurrent notes produce exact totals")
    func concurrent() {
        let box = TelemetryBox()
        let perWorker = 500
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<perWorker {
                box.noteAttempt()
                _ = box.noteFrame()
            }
        }
        let snap = box.snapshot()
        #expect(snap.pushAttempts == 8 * perWorker)
        #expect(snap.playbackFrames == 8 * perWorker)
        #expect(snap.pushFailures == 0)
    }
}

/// TTSStats is a pure value type; the service's live counters are only
/// reachable through real synthesis (slow/flaky in unit tests), so this
/// suite locks the value contract plus the service's zero-state —
///
/// not the pipeline stages themselves.
@Suite("TTSStats bookkeeping")
struct TTSStatsTests {

    /// Minimal sink so TTSService can be constructed without audio.
    private final class StubSink: TTSAudioSink {
        let preferredFormat = AVAudioFormat(
            standardFormatWithSampleRate: 16000, channels: 1
        )!
        var onFramesPushed: ((AVAudioFrameCount) -> Void)?
        private(set) var begins = 0
        func begin() { begins += 1 }
        func emit(_ buffer: AVAudioPCMBuffer) {}
        func end() {}
        func flush() {}
    }

    @Test("zero value has all counters at zero")
    func zeroValue() {
        let stats = TTSStats()
        #expect(stats.rawCallbacks == 0)
        #expect(stats.pcmBuffers == 0)
        #expect(stats.sourceFrames == 0)
        #expect(stats.emittedFrames == 0)
    }

    @Test("fields mutate independently and equality tracks them")
    func valueSemantics() {
        var a = TTSStats()
        var b = TTSStats()
        #expect(a == b)
        a.rawCallbacks = 3
        #expect(a != b)
        b.rawCallbacks = 3
        #expect(a == b)
        a.emittedFrames = 160
        #expect(a != b)
        #expect(b.emittedFrames == 0)
    }

    @Test("fresh service snapshots zero stats")
    func freshServiceZero() {
        let service = TTSService(sink: StubSink())
        #expect(service.snapshotStats() == TTSStats())
    }
}
