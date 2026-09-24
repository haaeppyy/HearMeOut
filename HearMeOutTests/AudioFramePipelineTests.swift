import AVFoundation
import Foundation
import Testing

@testable import HearMeOut

/// Audio-math contract for the speech pipeline: conversion bounds,
/// clipping behavior, chunk shapes, and the mirror-image deinterleave.
/// All pure — no engine, no audio thread, no recognizer.
@Suite("Audio frame pipeline")
struct AudioFramePipelineTests {

    @Test("int16From maps the nominal range onto full scale")
    func nominalRange() {
        #expect(AudioFramePipeline.int16From(float: 0) == 0)
        #expect(AudioFramePipeline.int16From(float: 1.0) == 32767)
        #expect(AudioFramePipeline.int16From(float: -1.0) == -32767)
        #expect(AudioFramePipeline.int16From(float: 0.5) == 16384)
    }

    @Test("int16From clamps instead of overflowing")
    func clamping() {
        #expect(AudioFramePipeline.int16From(float: 1.5) == 32767)
        #expect(AudioFramePipeline.int16From(float: -2.0) == -32767)
        #expect(AudioFramePipeline.int16From(float: 100) == 32767)
    }

    @Test("float → int16 → float round-trips within quantization error")
    func roundTripBounded() {
        let source: [Float] = stride(from: -1.0, through: 1.0, by: 0.01).map { Float($0) }
        let back = AudioFramePipeline.int16Samples(from: source).map { Float($0) / 32767.0 }
        for (original, recovered) in zip(source, back) {
            #expect(abs(original - recovered) <= 1.0 / 32767.0 + 1e-6)
        }
    }

    @Test("exact multiples produce full chunks, remainders a partial last chunk")
    func chunkShapes() {
        #expect(AudioFramePipeline.chunkRanges(frameCount: 160) == [0..<160])
        #expect(AudioFramePipeline.chunkRanges(frameCount: 320) == [0..<160, 160..<320])
        // The remainder IS pushed as a partial chunk (engine takes an
        // explicit count) — not held over.
        #expect(AudioFramePipeline.chunkRanges(frameCount: 400) == [0..<160, 160..<320, 320..<400])
        #expect(AudioFramePipeline.chunkRanges(frameCount: 1) == [0..<1])
        #expect(AudioFramePipeline.chunkRanges(frameCount: 0).isEmpty)
    }

    @Test("chunks tile the buffer exactly once with no gaps or overlaps")
    func chunkTiling() {
        for count in [1, 159, 160, 161, 1000] {
            let ranges = AudioFramePipeline.chunkRanges(frameCount: count)
            #expect(ranges.first?.lowerBound == 0)
            #expect(ranges.last?.upperBound == count)
            for pair in zip(ranges, ranges.dropFirst()) {
                #expect(pair.0.upperBound == pair.1.lowerBound)
            }
            for range in ranges {
                #expect(range.count <= AudioFramePipeline.samplesPer10ms)
            }
        }
    }

    @Test("mono deinterleave mirrors the forward conversion")
    func monoRoundTrip() {
        let wire: [Int16] = [0, 32767, -32768, 16384]
        let planar = wire.withUnsafeBufferPointer { buffer in
            AudioFramePipeline.deinterleaveToPlanar(
                pointer: buffer.baseAddress!, frames: wire.count, channelCount: 1
            )
        }
        #expect(planar.count == 1)
        #expect(planar[0].count == 4)
        #expect(planar[0][0] == 0)
        #expect(abs(planar[0][1] - 1.0) < 1e-6)
        #expect(abs(planar[0][2] - -1.0) < 1e-3) // -32768/32767 clamps to -1
        // Forward direction agrees: converting back gives the same wire values.
        let forth = AudioFramePipeline.int16Samples(from: planar[0])
        #expect(forth[0] == 0)
        #expect(forth[1] == 32767)
        #expect(forth[3] == 16384)
    }

    @Test("stereo interleaved input deinterleaves into planar channels")
    func stereoDeinterleave() {
        // L0, R0, L1, R1 on the wire → [L0, L1], [R0, R1] planar.
        let wire: [Int16] = [1000, -1000, 2000, -2000]
        let planar = wire.withUnsafeBufferPointer { buffer in
            AudioFramePipeline.deinterleaveToPlanar(
                pointer: buffer.baseAddress!, frames: 2, channelCount: 2
            )
        }
        #expect(planar.count == 2)
        #expect(planar[0].count == 2)
        #expect(planar[1].count == 2)
        let scale: Float = 32767.0
        #expect(abs(planar[0][0] - 1000.0 / scale) < 1e-6)
        #expect(abs(planar[1][0] - -1000.0 / scale) < 1e-6)
        #expect(abs(planar[0][1] - 2000.0 / scale) < 1e-6)
        #expect(abs(planar[1][1] - -2000.0 / scale) < 1e-6)
    }

    @Test("zero frames yields empty channels, channelCount floors at one")
    func degenerateShapes() {
        let wire: [Int16] = [1, 2]
        let empty = wire.withUnsafeBufferPointer { buffer in
            AudioFramePipeline.deinterleaveToPlanar(
                pointer: buffer.baseAddress!, frames: 0, channelCount: 2
            )
        }
        #expect(empty == [[], []])
        let floored = wire.withUnsafeBufferPointer { buffer in
            AudioFramePipeline.deinterleaveToPlanar(
                pointer: buffer.baseAddress!, frames: 1, channelCount: 0
            )
        }
        #expect(floored.count == 1)
    }
}
