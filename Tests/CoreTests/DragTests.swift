import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// 2-D window-drag shift detection (§4.8): window drags move diagonally
/// (dx and dy at once — dragscan finds byte-rigid (+106, +32) shifts
/// between consecutive real frames), which defeats both 1-D signature
/// passes. The probe-based 2-D pass must find the shift and ship the drag
/// as one scroll op plus edge residuals.
@Suite struct DragTests {
    /// Build a frame: `background` everywhere, `winContent` painted at
    /// (ax, ay).
    private func paint(background: [UInt8], winContent: [UInt8],
                       frameW: Int, winW: Int, winH: Int,
                       ax: Int, ay: Int) -> [UInt8] {
        var out = background
        winContent.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for row in 0..<winH {
                    dst.baseAddress!.advanced(by: ((ay + row) * frameW + ax) * 4)
                        .copyMemory(from: src.baseAddress!.advanced(by: row * winW * 4),
                                    byteCount: winW * 4)
                }
            }
        }
        return out
    }

    /// A diagonal window drag ships as one scroll op: the moved interior is
    /// satisfied by the shift, only the revealed strip and window edges ride
    /// as residuals, and the canvas converges byte-exactly.
    @Test func diagonalWindowDragShipsOneOp() {
        var rng = SplitMix64(seed: 1201)
        let h = Harness(width: 640, height: 640) // 10×10 tiles
        let winW = 448, winH = 448
        let ax = 64, ay = 96
        let mx = 48, my = 32 // diagonal, non-tile-aligned
        h.frame.fillRandom(&rng)
        let background = h.frame.bytes
        let winContent = rng.bytes(winW * winH * 4)
        h.frame.bytes = paint(background: background, winContent: winContent,
                              frameW: 640, winW: winW, winH: winH, ax: ax, ay: ay)
        h.encodeFrame()
        h.run(untilUS: h.now + 400_000)
        #expect(h.settle())

        h.frame.bytes = paint(background: background, winContent: winContent,
                              frameW: 640, winW: winW, winH: winH, ax: ax + mx, ay: ay + my)
        let scrollsBefore = h.host.stats.scrollsSent
        let bytesBefore = h.host.stats.bytesOut
        h.encodeFrame(dirtyRects: [DirtyRect(x: ax, y: ay, width: winW + mx, height: winH + my)])
        h.run(untilUS: h.now + 300_000)
        #expect(h.host.stats.scrollsSent == scrollsBefore + 1, "diagonal drag must ship as one op")
        #expect(h.viewer.stats.scrollsApplied == h.host.stats.scrollsSent)
        // The moved interior must be satisfied by the shift, not re-shipped:
        // 448×448 of noise is ~49 RAW tiles ≈ 800 KB if the op didn't pay.
        #expect(h.host.stats.scrollSatisfiedTiles >= 25,
                "satisfied \(h.host.stats.scrollSatisfiedTiles) — the interior must ride the op")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "drag must converge byte-exactly")
        let cost = h.host.stats.bytesOut - bytesBefore
        #expect(cost < 500_000, "one drag should cost far less than re-encoding the window (got \(cost))")
    }

    /// A FAST drag: steps land quicker than ACKs, so the shadow lags and the
    /// frame-vs-shadow offset is cumulative (reaching ±224, which starves a
    /// narrow search). The widened search plus relaxed verification must
    /// still ship scroll ops, and settle stays byte-exact.
    @Test func fastDragWithLaggedShadowStillShipsOps() {
        var faults = FaultConfig()
        faults.latencyMinUS = 15_000 // real-ish RTT: ACKs lag the drag steps
        faults.latencyMaxUS = 25_000
        faults.seed = 7
        var rng = SplitMix64(seed: 1301)
        let h = Harness(width: 640, height: 640, faults: faults)
        let winW = 448, winH = 448
        h.frame.fillRandom(&rng)
        let background = h.frame.bytes
        let winContent = rng.bytes(winW * winH * 4)
        var ax = 16, ay = 16
        h.frame.bytes = paint(background: background, winContent: winContent,
                              frameW: 640, winW: winW, winH: winH, ax: ax, ay: ay)
        h.encodeFrame()
        h.run(untilUS: h.now + 600_000)
        #expect(h.settle(maxSimMS: 120_000))

        for _ in 0..<8 { // 16 ms between steps: several steps per ACK round trip
            ax += 18
            ay += 12
            h.frame.bytes = paint(background: background, winContent: winContent,
                                  frameW: 640, winW: winW, winH: winH, ax: ax, ay: ay)
            h.encodeFrame(dirtyRects: [DirtyRect(x: ax - 18, y: ay - 12,
                                                 width: winW + 18, height: winH + 12)])
            h.run(untilUS: h.now + 16_000)
        }
        #expect(h.host.stats.scrollsSent > 0, "a lag-accumulated drag must still ship as ops")
        #expect(h.settle(maxSimMS: 120_000))
        #expect(h.canvasMatchesFrame(), "byte-exact regardless of how the drag shipped")
    }

    /// A repeated diagonal drag through the faulted loop: realistic faults,
    /// engagement asserted, byte-exact at settle.
    @Test(arguments: [UInt64(91), 92])
    func dragGoldenUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 10       // realistic: 1 % loss
        faults.dupPermille = 5
        faults.reorderPermille = 50
        faults.latencyMinUS = 5_000
        faults.latencyMaxUS = 15_000
        faults.seed = seed
        var rng = SplitMix64(seed: seed &* 1217)
        // Window must be big enough that its fully-covered interior beats the
        // satisfied threshold (25 tiles on a 10×10 grid): 448×448 gives ~36.
        let h = Harness(width: 640, height: 640, faults: faults)
        let winW = 448, winH = 448
        h.frame.fillRandom(&rng)
        let background = h.frame.bytes
        let winContent = rng.bytes(winW * winH * 4)
        var ax = 32, ay = 32
        h.frame.bytes = paint(background: background, winContent: winContent,
                              frameW: 640, winW: winW, winH: winH, ax: ax, ay: ay)
        h.encodeFrame()
        h.run(untilUS: h.now + 600_000)
        #expect(h.settle(maxSimMS: 120_000), "seed \(seed): cold start must converge first")

        for _ in 0..<6 {
            ax += 24
            ay += 16
            h.frame.bytes = paint(background: background, winContent: winContent,
                                  frameW: 640, winW: winW, winH: winH, ax: ax, ay: ay)
            h.encodeFrame(dirtyRects: [DirtyRect(x: ax - 24, y: ay - 16,
                                                 width: winW + 24, height: winH + 16)])
            h.run(untilUS: h.now + 150_000) // ACKs land between steps (sources quiesce)
        }
        #expect(h.host.stats.scrollsSent > 0, "seed \(seed): the drag must engage the 2-D detector")
        // Digest repairs MAY fire here: under drop/reorder a scroll can race
        // a mid-heal window, and detecting + demoting is the mechanism
        // working (byte-exact settle below is the real bar). The no-false-
        // fire assertion lives in the clean-link scroll test.
        #expect(h.settle(maxSimMS: 120_000), "seed \(seed)")
        #expect(h.canvasMatchesFrame(), "seed \(seed): byte-exact after drags under faults")
        #expect(h.viewer.stats.cacheRefMisses == 0, "seed \(seed)")
    }
}
