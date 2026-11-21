import Foundation
import Testing
@testable import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// A fast LAN on a jittery path: Wi-Fi power save on the viewer's downlink
/// (`FaultConfig.powerSaveWakeMinUS`), so an idle path's latency swings
/// 10–120 ms and reads as a standing queue, while a busy one stays fast.
/// A tester's session on such a path (Host 26.11.3) had the tile governor
/// sit at 0.0–0.2 MB/s for minutes (#143) and the resolution rung halve the
/// capture three seconds after a resume (#144). Fixed seeds.
@Suite struct JitteryPathTests {
    static func faults(seed: UInt64) -> FaultConfig {
        var f = FaultConfig()
        f.latencyMinUS = 2_000
        f.latencyMaxUS = 4_000
        f.powerSaveWakeMinUS = 10_000
        f.powerSaveWakeMaxUS = 120_000
        f.seed = seed
        return f
    }

    /// Typing: a small change every `everyMS`, for `seconds`.
    private func type(_ h: Harness, _ rng: inout SplitMix64, seconds: Int, everyMS: Int = 150) {
        for _ in 0..<(seconds * 1000 / everyMS) {
            let x = rng.int(0..<(h.frame.width - 48)), y = rng.int(0..<(h.frame.height - 16))
            h.frame.fillRect(x: x, y: y, w: 48, h: 16, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: x, y: y, width: 48, height: 16)])
            h.run(untilUS: h.now + UInt64(everyMS) * 1000)
        }
    }

    /// Two minutes of a quiet screen (a small change every 600 ms, each
    /// finding the radio asleep): the governor keeps its rate, the
    /// app-limited spans set no link capacity, the rung never fires, and a
    /// menu-sized change then goes out whole, in one tick. Before the fixes
    /// the governor ended under 1 MB/s and deferred the menu, and the quiet
    /// screen's own rate, the path reading as queued, fired the rung.
    @Test(arguments: [UInt64(31), 32])
    func aQuietSessionKeepsItsRate(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let h = Harness(width: 512, height: 512, faults: Self.faults(seed: seed))
        var fired = false
        h.host.onScalePressureConstrained = { fired = true }
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle())
        type(h, &rng, seconds: 120, everyMS: 600)
        #expect(h.link.powerSaveWakes > 100, "the path slept between keystrokes")
        #expect(h.host.stats.governorRate >= SendGovernor.initialAutoRate / 2,
                "the rate held: \(h.host.stats.governorRate) B/s after \(h.host.stats.governorQueueCuts) cuts")
        #expect(h.host.linkCapacityBytesPerSecond == 0, "an app-limited span is no capacity reading")
        #expect(!fired, "the rung stays put on a LAN")

        // A menu: 320×256 of new pixels (20 tiles, ~330 KB raw).
        h.frame.fillRect(x: 64, y: 64, w: 320, h: 256, &rng)
        let deferredBefore = h.host.stats.governorDeferredTiles
        h.encodeFrame(dirtyRects: [DirtyRect(x: 64, y: 64, width: 320, height: 256)])
        h.run(untilUS: h.now + 16_000)
        #expect(h.host.stats.governorDeferredTiles - deferredBefore == 0,
                "the menu went out whole: \(h.host.stats.governorDeferredTiles - deferredBefore) tiles deferred")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }

    /// The viewer hides for two minutes and comes back (§4.10): nothing the
    /// paused stretch read counts toward the rung, and the spans across the
    /// pause read no capacity.
    @Test func aPauseOnAJitteryPathIsntAThinLink() {
        var rng = SplitMix64(seed: 41)
        let h = Harness(width: 512, height: 512, faults: Self.faults(seed: 41))
        var fired = false
        h.host.onScalePressureConstrained = { fired = true }
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle())
        type(h, &rng, seconds: 10)
        h.viewer.setContentPaused(true)
        h.run(untilUS: h.now + 120_000_000)
        h.viewer.setContentPaused(false)
        h.run(untilUS: h.now + 50_000)
        // Back: what changed while hidden, then typing.
        h.frame.fillRect(x: 0, y: 0, w: 512, h: 256, &rng)
        h.encodeFrame()
        type(h, &rng, seconds: 20)
        #expect(!fired, "the rung stays put after the resume")
        #expect(h.host.linkCapacityBytesPerSecond == 0)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }
}
