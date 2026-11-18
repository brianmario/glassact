import Foundation
import GlassActAV1
@testable import GlassActHybridVideo
import Testing

/// A Host between sessions doesn't keep a stream's buffers: once no stream has run for
/// `Shared.idleTrimAfter`, the shared encoder is replaced by a fresh one and the old one (with its
/// pictures' buffers) is released. A stream that starts within the delay keeps the encoder.
extension HybridRegionEncoderTests {
    @available(macOS 27, *)
    @Test func anIdleEncoderIsReplacedAndReleased() throws {
        let shared = try #require(HybridRegionEncoder.Shared.instance)
        let saved = HybridRegionEncoder.Shared.idleTrimAfter
        defer { HybridRegionEncoder.Shared.idleTrimAfter = saved }
        HybridRegionEncoder.Shared.idleTrimAfter = 0.3

        func run(frames n: Int) throws {
            let engine = Engine()
            let encoder = HybridRegionEncoder(callbackQueue: engine.queue)
            let started = engine.queue.sync {
                encoder.start(width: 640, height: 360) { _, _, _ in engine.delivered.signal() }
            }
            try #require(started)
            for i in 0..<n {
                let p = Self.picture(i, width: 640, height: 360)
                engine.queue.sync { p.withUnsafeBytes { encoder.encode(bgra: $0, forceSync: false, timeUS: UInt64(i) * 16_667) } }
                try #require(engine.delivered.wait(timeout: .now() + 20) == .success)
            }
            engine.queue.sync { encoder.stop() }
        }
        func trims() -> Int { shared.control.sync { shared.trims } }
        func waitForTrim(after count: Int) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if trims() > count { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }

        // a stream, then nothing: the encoder that coded it is swapped out and freed
        try run(frames: 3)
        weak let used = shared.control.sync { shared.encoder }
        let before = trims()
        #expect(waitForTrim(after: before), "the idle encoder wasn't replaced")
        #expect(used == nil, "the replaced encoder (and its buffers) is still alive")

        // a stream starting within the delay: the trim scheduled by the last one is dropped
        try run(frames: 2)
        let afterFirst = trims()
        try run(frames: 2)  // (started well within 0.3 s of the stream before it ending)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(trims() == afterFirst, "a trim ran while streams kept starting")
        // and the fresh encoder codes as the first one did (a stream after a trim is a stream)
        #expect(waitForTrim(after: afterFirst))
        try run(frames: 3)
    }
}
