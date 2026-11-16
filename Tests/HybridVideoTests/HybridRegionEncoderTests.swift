import Foundation
import GlassActAV1
import GlassActCore
import GlassActHybridVideo
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
}
