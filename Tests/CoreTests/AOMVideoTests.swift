import Foundation
import Testing
import GlassActWire
@testable import GlassActCore
import GlassActTestSupport

/// Software AV1 (vendored libaom, arm64) through the region codec
/// interfaces. Lossy like HEVC: the bar is structural (the av1C config on
/// the first frame, a key frame first, one delivery per submit) plus a PSNR
/// floor; byte exactness is the dissolve repaint's job.
@Suite(.enabled(if: AOMRegionEncoder.isAvailable, "libaom is arm64 only"))
struct AOMVideoTests {
    struct Delivered {
        var data: [UInt8]
        var sync: Bool
        var config: [UInt8]?
    }

    /// Encodes `frames` and waits for every delivery. Paced like the engine
    /// (one frame in flight); unpaced, submits outrun the encoder.
    private func encode(_ frames: [[UInt8]], width: Int, height: Int, paced: Bool = true,
                        configure: (AOMRegionEncoder) -> Void = { _ in }) throws -> [Delivered] {
        let encoder = AOMRegionEncoder(callbackQueue: DispatchQueue(label: "test.av1.callback"))
        var delivered: [Delivered] = []
        let lock = NSLock()
        let arrived = DispatchSemaphore(value: 0)
        try #require(encoder.start(width: width, height: height) { data, sync, config in
            lock.withLock { delivered.append(Delivered(data: data, sync: sync, config: config)) }
            arrived.signal()
        })
        configure(encoder)
        var waited = 0
        for (i, frame) in frames.enumerated() {
            frame.withUnsafeBytes { encoder.encode(bgra: $0, forceSync: false, timeUS: UInt64(i) * 16_667) }
            if paced {
                #expect(arrived.wait(timeout: .now() + 30) == .success, "frame \(i) must be delivered")
                waited += 1
            }
        }
        while waited < frames.count {
            #expect(arrived.wait(timeout: .now() + 30) == .success, "the encoder must deliver every frame")
            waited += 1
        }
        encoder.stop()
        return lock.withLock { delivered }
    }

    @Test func av1RoundTrip() throws {
        let width = 640, height = 384, count = 12
        let frames = VTVideoTests.makeFrames(width: width, height: height, count: count)
        let out = try encode(frames, width: width, height: height)
        try #require(out.count == count)
        let config = try #require(out[0].config, "the first frame carries the av1C record")
        #expect(out.dropFirst().allSatisfy { $0.config == nil })
        #expect(out[0].sync, "the first frame is a key frame, though nobody forced it")
        #expect(out.dropFirst().allSatisfy { !$0.sync }, "no periodic key frames")
        #expect(out.allSatisfy { !$0.data.isEmpty })
        // av1C: marker and version, profile 0, 8-bit 4:2:0, then the sequence
        // header OBU (type 1).
        #expect(config[0] == 0x81 && config[1] >> 5 == 0 && config[2] & 0x7F == 0x0C)
        #expect((config[4] >> 3) & 0x0F == 1)

        let decoder = AOMRegionDecoder()
        try #require(decoder.start(codec: VideoCodec.av1, config: config, width: width, height: height))
        var decoded = 0
        var lastPSNR = 0.0
        for (i, d) in out.enumerated() {
            decoder.decode(d.data, sync: d.sync) { pixels, bytesPerRow in
                decoded += 1
                lastPSNR = VTVideoTests.psnr(frames[i], tightPixels(pixels, bytesPerRow: bytesPerRow,
                                                                    width: width, height: height), width: width)
            }
        }
        decoder.stop()
        #expect(decoded == count, "every frame decodes")
        #expect(lastPSNR > 30, "predictable content decodes close to the source (PSNR \(lastPSNR))")
        #expect(!AOMRegionDecoder().start(codec: VideoCodec.hevc, config: config, width: width, height: height))
    }

    /// The engine's pacing counts one delivery per submit, so a starved
    /// buffer pool still answers (with an empty frame).
    @Test func everySubmitIsAnswered() throws {
        let width = 320, height = 192
        let frames = VTVideoTests.makeFrames(width: width, height: height, count: 40)
        let out = try encode(frames, width: width, height: height, paced: false)
        #expect(out.count == frames.count)
        #expect(out.contains { !$0.data.isEmpty })
    }

    /// A lower quality level and a link cap spend fewer bytes; a tighter
    /// frame-QP ceiling spends more.
    @Test func rateControlFollowsTheEngine() throws {
        let width = 640, height = 384
        let frames = VTVideoTests.makeFrames(width: width, height: height, count: 30)
        func bytes(_ configure: @escaping (AOMRegionEncoder) -> Void) throws -> Int {
            try encode(frames, width: width, height: height, configure: configure).reduce(0) { $0 + $1.data.count }
        }
        let base = try bytes { _ in }
        let capped = try bytes { $0.setBitrateCap(400_000) }
        let lowest = try bytes { $0.setQualityLevel(3) }
        #expect(capped < base, "cap \(capped) vs \(base)")
        #expect(lowest < base, "level 3 \(lowest) vs \(base)")
    }

    @Test func frameQPMapsOntoLibaomsScale() {
        #expect(AOMRegionEncoder.quantizer(forFrameQP: 34) == 42)
        #expect(AOMRegionEncoder.quantizer(forFrameQP: 28) == 35)
        #expect(AOMRegionEncoder.quantizer(forFrameQP: 51) == 63)
        #expect(AOMRegionEncoder.quantizer(forFrameQP: 0) == 0)
    }

    @Test func av1CRejectsWhatIsntASequenceHeader() {
        #expect(AV1Config.build(sequenceHeaderOBU: []) == nil)
        #expect(AV1Config.build(sequenceHeaderOBU: [0x12, 0x00]) == nil) // a temporal delimiter
    }
}
