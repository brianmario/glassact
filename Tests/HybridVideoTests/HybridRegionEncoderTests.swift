import Foundation
import GlassActAV1
import GlassActCore
import GlassActHybridVideo
import GlassActWire
import Testing

/// The hybrid behind the VideoRegionEncoder contract, as the Host's engine drives it: one delivery
/// per submit on the engine's queue, the config with the first frame, key frames on demand, and
/// regions of other sizes one after another on the one shared encoder.
@Suite(.serialized, .enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (not a VM's paravirtual one)"))
struct HybridRegionEncoderTests {
    final class Engine: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.engine")
        let delivered = DispatchSemaphore(value: 0)
        var frames: [(data: [UInt8], sync: Bool, config: [UInt8]?)] = []
    }

    static func picture(_ i: Int, width: Int, height: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                // a gradient, with a band that moves and text-like stripes
                p[o] = UInt8(truncatingIfNeeded: x + i * 8)
                p[o + 1] = UInt8(truncatingIfNeeded: y * 2)
                p[o + 2] = (x / 3 + y) % 7 == 0 ? 250 : UInt8(truncatingIfNeeded: (x + y + i * 16) / 4)
                p[o + 3] = 255
            }
        }
        return p
    }

    @available(macOS 27, *)
    @Test func deliversOncePerSubmitWithTheConfigFirst() throws {
        let engine = Engine()
        let encoder = HybridRegionEncoder(callbackQueue: engine.queue)
        for (width, height, n) in [(640, 360, 6), (334, 202, 4)] {
            engine.frames = []
            let started = engine.queue.sync {
                encoder.start(width: width, height: height) { data, sync, config in
                    engine.frames.append((data, sync, config))
                    engine.delivered.signal()
                }
            }
            try #require(started)
            for i in 0..<n {
                let p = Self.picture(i, width: width, height: height)
                engine.queue.sync {
                    p.withUnsafeBytes { encoder.encode(bgra: $0, forceSync: i == n - 1, timeUS: UInt64(i) * 16_667) }
                }
                // (each comes out alone: nothing after it is submitted until it does)
                #expect(engine.delivered.wait(timeout: .now() + 20) == .success, "\(width)×\(height): picture \(i) didn't come out")
            }
            engine.queue.sync { encoder.stop() }
            let frames = engine.queue.sync { engine.frames }
            try #require(frames.count == n)
            #expect(frames.allSatisfy { !$0.data.isEmpty })
            #expect(frames.map(\.sync) == (0..<n).map { $0 == 0 || $0 == n - 1 }, "\(width)×\(height): key frames \(frames.map(\.sync))")
            let config = try #require(frames[0].config, "the first frame carries no config")
            let header = try #require(AV1Config.sequenceHeaderOBU(inTemporalUnit: frames[0].data))
            #expect(config == AV1Config.build(sequenceHeaderOBU: header))
            #expect(frames.dropFirst().allSatisfy { $0.config == nil })
            // (the key frame on demand carries the region's sequence header again, unchanged)
            #expect(AV1Config.sequenceHeaderOBU(inTemporalUnit: frames[n - 1].data) == header)
        }
    }

    /// A picture that fails in the encoder's stream, with two more submitted behind it, as the
    /// engine pipelines them: each gets one delivery, the failed ones empty; the next picture
    /// starts a new stream with a key frame (a decoder holding only the region's START decodes
    /// from it); and the stale failures of the old stream's later pictures, delivered after that
    /// restart, don't restart it again.
    @available(macOS 27, *)
    @Test func aFailedPictureRestartsTheStreamOnceWithAKeyFrame() throws {
        let engine = Engine()
        let encoder = HybridRegionEncoder(callbackQueue: engine.queue)
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var streams = 0
        }
        let once = Once()
        encoder.configure = { e in
            // (the region's first stream only: the restart's runs `configure` again)
            e.failingPicture = once.lock.withLock { once.streams += 1; return once.streams == 1 } ? 3 : nil
        }
        let (width, height) = (640, 360)
        let pictures = (0..<8).map { Self.picture($0, width: width, height: height) }
        func submit(_ i: Int) {
            pictures[i].withUnsafeBytes { encoder.encode(bgra: $0, forceSync: false, timeUS: UInt64(i) * 16_667) }
        }
        let started = engine.queue.sync {
            encoder.start(width: width, height: height) { data, sync, config in
                engine.frames.append((data, sync, config))
                // the failure's delivery: the engine's next submit, before the old stream's later
                // failures are delivered
                if engine.frames.count == 4 { submit(6) }
                engine.delivered.signal()
            }
        }
        try #require(started)
        engine.queue.sync { for i in 0..<6 { submit(i) } }  // (0–5 in flight at once)
        for i in 0..<7 {
            try #require(engine.delivered.wait(timeout: .now() + 20) == .success, "delivery \(i) didn't come")
        }
        engine.queue.sync { submit(7) }
        try #require(engine.delivered.wait(timeout: .now() + 20) == .success, "delivery 7 didn't come")
        engine.queue.sync { encoder.stop() }
        let frames = engine.queue.sync { engine.frames }
        try #require(frames.count == 8)
        // 0–2 out, 3 failed and 4–5 behind it, 6 the restart's key frame, 7 an inter frame after it
        #expect(frames.map { !$0.data.isEmpty } == [true, true, true, false, false, false, true, true])
        #expect(frames.map(\.sync) == [true, false, false, false, false, false, true, false], "\(frames.map(\.sync))")
        #expect(frames.filter { $0.config != nil }.count == 1, "the config goes with the region's first frame only")
        let config = try #require(frames[0].config)
        let decoder = AOMRegionDecoder()
        try #require(decoder.start(codec: VideoCodec.av1, config: config, width: width, height: height))
        defer { decoder.stop() }
        for i in [6, 7] {
            #expect(decoder.decode(frames[i].data, sync: frames[i].sync) { _, _ in }, "frame \(i) doesn't decode from the restart")
        }
    }
}
