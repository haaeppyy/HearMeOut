import AVFoundation
import Foundation

/// Pure audio-math for the speech pipeline, extracted from AgoraCallManager
/// (+ CaptionService's mirror-image conversion) so it can be unit-tested
/// without the engine, the audio thread, or the recognizer.
///
/// All three call sites share one format: 16 kHz mono, Float32 in-app,
/// Int16 on the Agora wire. The functions below are the entire conversion
/// layer — the managers only move buffers and pointers around them.
enum AudioFramePipeline {
    static let sampleRate = 16000
    static let samplesPer10ms = sampleRate / 100 // 160

    /// Float32 (-1.0...1.0 nominal) → Int16 with clamping. Values outside
    /// the nominal range clamp instead of overflowing/wrapping.
    static func int16From(float: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, float))
        return Int16((clamped * 32767.0).rounded())
    }

    /// Whole-buffer conversion (outgoing/TTS path).
    static func int16Samples(from floats: [Float]) -> [Int16] {
        floats.map(int16From(float:))
    }

    /// Split a frame count into 10 ms chunk ranges for
    /// pushExternalAudioFrameRawData. A remainder produces a final partial
    /// range — it IS pushed, not held over (matches the engine call, which
    /// takes an explicit sample count per call).
    static func chunkRanges(frameCount: Int, perChunk: Int = samplesPer10ms) -> [Range<Int>] {
        guard frameCount > 0, perChunk > 0 else { return [] }
        return stride(from: 0, to: frameCount, by: perChunk).map { start in
            start..<(min(start + perChunk, frameCount))
        }
    }

    /// Interleaved Int16 wire frames → planar Float32 channels
    /// (incoming/caption path, mirror image of int16Samples). Deinterleaves
    /// multi-channel input; clamps defensively like the forward direction.
    static func deinterleaveToPlanar(
        pointer: UnsafePointer<Int16>,
        frames: Int,
        channelCount: Int
    ) -> [[Float]] {
        let channels = max(channelCount, 1)
        guard frames > 0 else { return Array(repeating: [], count: channels) }
        var planar = Array(repeating: [Float](repeating: 0, count: frames), count: channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let sample = pointer[frame * channels + channel]
                planar[channel][frame] = max(-1.0, min(1.0, Float(sample) / 32767.0))
            }
        }
        return planar
    }
}

/// Lock-protected telemetry safe to touch from the audio thread.
/// (Moved here from AgoraCallManager.swift; internal so TelemetryBoxTests
/// can exercise the lock under contention. Behavior unchanged.)
final class TelemetryBox: Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var attempts = 0
    private var failures = 0

    func noteFrame() -> Int {
        lock.lock()
        defer { lock.unlock() }
        frames += 1
        return frames
    }

    func noteAttempt() {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
    }

    func noteFailure() {
        lock.lock()
        defer { lock.unlock() }
        failures += 1
    }

    func snapshot() -> (playbackFrames: Int, pushAttempts: Int, pushFailures: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, attempts, failures)
    }
}
