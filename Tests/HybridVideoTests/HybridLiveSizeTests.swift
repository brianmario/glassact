import Foundation
import GlassActAV1
@testable import GlassActHybridVideo
import Testing

/// A region the size a live 5K session's is (5080×2502: a 2540×1251 pt virtual display at 2×, not
/// a multiple of 8 either way): the first picture, a key frame, comes out well inside the engine's
/// stall limit (`HostEngine.videoEncoderStallUS`, 3 s), and so do the ones after it. Live
/// (26.11.1, 2026-11-17) the first AV1 region of a session never delivered and the Host gave up
/// video for the session.
extension HybridRegionEncoderTests {
    @available(macOS 27, *)
    @Test func aLive5KRegionDeliversInsideTheStallLimit() throws {
        let (width, height, n) = (5080, 2502, 6)
        let engine = Engine()
        let encoder = HybridRegionEncoder(callbackQueue: engine.queue)
        var times: [Double] = []
        let started = engine.queue.sync {
            encoder.start(width: width, height: height) { data, _, _ in
                engine.frames.append((data, false, nil))
                engine.delivered.signal()
            }
        }
        try #require(started)
        for i in 0..<n {
            let p = Self.picture(i, width: width, height: height)
            let t0 = Date()
            engine.queue.sync { p.withUnsafeBytes { encoder.encode(bgra: $0, forceSync: false, timeUS: UInt64(i) * 16_667) } }
            try #require(engine.delivered.wait(timeout: .now() + 30) == .success, "picture \(i) didn't come out in 30 s")
            times.append(Date().timeIntervalSince(t0))
        }
        engine.queue.sync { encoder.stop() }
        print("5080×2502 deliveries (s):", times.map { String(format: "%.3f", $0) }.joined(separator: " "),
              "bytes:", engine.queue.sync { engine.frames.map(\.data.count) })
        #expect(engine.queue.sync { engine.frames.allSatisfy { !$0.data.isEmpty } }, "an empty delivery")
        #expect(times.allSatisfy { $0 < 1.5 }, "a delivery took \(times.max() ?? 0) s")
    }
}
