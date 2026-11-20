import AV1Core
import Foundation
import GlassActAV1
import GlassActAV1Decode
import GlassActCore
import GlassActHybridVideo
import GlassActTestSupport
import GlassActWire
import Testing

/// Reduced frames (§4.6, `ReducedFramesPolicy`): a region whose Viewer shows them, given a run of
/// new soft pictures (video scaled up: its half-size round trip loses far less than its coding),
/// goes to half size after its run's fourth, with a key frame, and back to its own size with a key
/// frame once a picture copies most of itself; both of a Viewer's AV1 decoders show every frame
/// at the region's size, under the region's first av1C config. Without the Viewer's bit,
/// the same pictures stay at the region's size.
@Suite(.serialized, .enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (not a VM's paravirtual one)"))
struct ReducedFramesTests {
    final class Engine: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.engine")
        let delivered = DispatchSemaphore(value: 0)
        var frames: [(data: [UInt8], sync: Bool, config: [UInt8]?)] = []
    }

    /// A soft picture: a random field of 8×8 cells, bilinear between their centres (no detail a
    /// half-size picture loses), new each seed.
    static func soft(width: Int, height: Int, seed: UInt64) -> [UInt8] {
        var rng = SplitMix64(seed: seed)
        let (gw, gh) = (width / 8 + 2, height / 8 + 2)
        let grid = (0..<(gw * gh * 3)).map { _ in Float(rng.int(30..<226)) }
        var p = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let fy = Float(y) / 8, y0 = Int(fy), ty = fy - Float(y0)
            for x in 0..<width {
                let fx = Float(x) / 8, x0 = Int(fx), tx = fx - Float(x0)
                for c in 0..<3 {
                    func g(_ i: Int, _ j: Int) -> Float { grid[((j * gw) + i) * 3 + c] }
                    let top = g(x0, y0) * (1 - tx) + g(x0 + 1, y0) * tx, bottom = g(x0, y0 + 1) * (1 - tx) + g(x0 + 1, y0 + 1) * tx
                    p[(y * width + x) * 4 + c] = UInt8(top * (1 - ty) + bottom * ty)
                }
            }
        }
        return p
    }

    @available(macOS 27, *)
    func run(reduced: Bool) throws -> (frames: [(data: [UInt8], sync: Bool, config: [UInt8]?)], streams: Int, pictures: Int) {
        let (width, height) = (640, 384)
        let engine = Engine()
        let encoder = HybridRegionEncoder(callbackQueue: engine.queue)
        encoder.fixedQindex = 200  // (coarse: coding loses far more than the soft pictures' round trip)
        let started = engine.queue.sync {
            encoder.start(width: width, height: height) { data, sync, config in
                engine.frames.append((data, sync, config))
                engine.delivered.signal()
            }
        }
        try #require(started)
        engine.queue.sync { encoder.setReducedFrames(reduced) }
        // 14 new pictures, then the last one 4 times over
        let new = (0..<14).map { Self.soft(width: width, height: height, seed: 0x5e_d0 + UInt64($0)) }
        let pictures = new + Array(repeating: new[13], count: 4)
        for (i, p) in pictures.enumerated() {
            engine.queue.sync { p.withUnsafeBytes { encoder.encode(bgra: $0, forceSync: false, timeUS: UInt64(i) * 16_667) } }
            // (one at a time: the margin, measured off the engine's queue, is back before the next)
            #expect(engine.delivered.wait(timeout: .now() + 20) == .success, "picture \(i) didn't come out")
            usleep(20_000)
        }
        let (streams, reducedPictures) = engine.queue.sync { (encoder.reducedStreams, encoder.reducedPictures) }
        engine.queue.sync { encoder.stop() }
        return (engine.queue.sync { engine.frames }, streams, reducedPictures)
    }

    @available(macOS 27, *)
    @Test func aSoftRunGoesToHalfSizeAndBack() throws {
        let (width, height) = (640, 384)
        let (frames, streams, reducedPictures) = try run(reduced: true)
        try #require(frames.count == 18 && frames.allSatisfy { !$0.data.isEmpty })
        #expect(streams == 1, "streams at half size: \(streams)")
        // half size from the run's 5th inter frame or a little after (the margin's measurement),
        // until the first repeat (which still codes at half size and ends the run) plus one
        #expect((8...12).contains(reducedPictures), "pictures at half size: \(reducedPictures)")
        let keys = frames.indices.filter { frames[$0].sync }
        #expect(keys.count == 3 && keys.first == 0, "key frames at \(keys)")
        // every key frame's sequence header is the region's size and profile (its level follows
        // its stream's tiles: a key frame may carry a new one), so the Viewer's one config holds
        let configs = keys.compactMap { AV1Config.sequenceHeaderOBU(inTemporalUnit: frames[$0].data).flatMap(AV1Config.build) }
        #expect(configs.count == keys.count && Set(configs.map { $0[1] >> 5 }).count == 1, "the key frames' profiles differ")
        let config = try #require(frames[0].config)

        // Glass Act's decoder: every frame, at the region's size
        let own = OwnAV1RegionDecoder(threads: 2)
        try #require(own.start(codec: VideoCodec.av1, config: config, width: width, height: height))
        for (i, f) in frames.enumerated() {
            var stride = 0
            #expect(own.decode(f.data, sync: f.sync) { _, s in stride = s }, "our decoder: frame \(i)")
            #expect(stride == width * 4, "our decoder: frame \(i) at stride \(stride)")
        }
        own.stop()
        // VideoToolbox, as the Viewer asks it (the region's size), where this Mac decodes AV1
        if VTRegionDecoder.canDecodeAV1 {
            let vt = VTRegionDecoder()
            try #require(vt.start(codec: VideoCodec.av1, config: config, width: width, height: height))
            for (i, f) in frames.enumerated() {
                #expect(vt.decode(f.data, sync: f.sync) { _, _ in }, "VideoToolbox: frame \(i)")
            }
            vt.stop()
        }
    }

    @available(macOS 27, *)
    @Test func withoutTheViewersBitTheRegionKeepsItsSize() throws {
        let (frames, streams, reducedPictures) = try run(reduced: false)
        try #require(frames.count == 18)
        #expect(streams == 0 && reducedPictures == 0)
        #expect(frames.indices.filter { frames[$0].sync } == [0])
    }
}
