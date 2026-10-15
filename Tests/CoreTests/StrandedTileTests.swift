import Foundation
import Testing
import GlassActWire
import GlassActCore
import GlassActTestSupport

/// Stale-tile regressions: states where the host believes the viewer is
/// wrong (or right) and nothing ever re-sends the tile. `Harness.settle()`
/// full-scans every tick, which re-volunteers every tile and so masks all
/// of these — each test here drives explicit dirty rects, the way live SCK
/// capture does, and only checks convergence after the capture goes quiet.
@Suite struct StrandedTileTests {
    /// Ticks with dirty rects confined to `busy` (content animating
    /// elsewhere), then quiet ticks that report no dirty rects at all.
    private func driveBusyThenQuiet(_ h: Harness, _ rng: inout SplitMix64,
                                    busy: DirtyRect, busyMS: Int, quietMS: Int) {
        var elapsed = 0
        while elapsed < busyMS {
            h.frame.fillRect(x: busy.x, y: busy.y, w: busy.width, h: busy.height, &rng)
            h.encodeFrame(dirtyRects: [busy])
            h.run(untilUS: h.now + 16_000)
            elapsed += 16
        }
        elapsed = 0
        while elapsed < quietMS {
            h.encodeFrame(dirtyRects: [])
            h.run(untilUS: h.now + 16_000)
            elapsed += 16
        }
    }

    /// DELTA_NACK repair must schedule the tile, not just forget its ACKed
    /// hash: dirty rects never report a tile whose pixels did not change,
    /// so a cold-but-unscheduled tile stays wrong on the viewer forever.
    @Test func deltaNackRepairResendsOnStaticScreen() {
        var rng = SplitMix64(seed: 2102)
        let h = Harness(width: 320, height: 240)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())

        // The viewer failed to apply tile 0 (e.g. a DELTA whose base it no
        // longer had) and NACKed it: its canvas there is garbage.
        let tile = 0
        _ = h.viewer.withCanvas { canvas in
            UnsafeMutableRawPointer(mutating: canvas.baseAddress!)
                .initializeMemory(as: UInt8.self, repeating: 0xA5, count: 64 * 4)
        }
        #expect(canvasTile(h.viewer, tile) != h.frame.tightTile(tile))
        let nack = ControlMessage.deltaNack(frameSeq: h.host.currentFrameSeq &- 1,
                                            tiles: [UInt16(tile)])
        h.host.handleControl(Data(nack.encoded()), nowUS: h.now)

        // Content animates far from tile 0, then the capture goes quiet.
        driveBusyThenQuiet(h, &rng, busy: DirtyRect(x: 256, y: 192, width: 48, height: 40),
                           busyMS: 500, quietMS: 500)
        #expect(canvasTile(h.viewer, tile) == h.frame.tightTile(tile),
                "NACKed tile must be re-sent without any dirty rect covering it")
    }

    /// A WARM tile (previously ACKed) that changed once and lost the
    /// governor's budget must still ship later, even while dirty rects keep
    /// reporting activity only elsewhere.
    @Test(.tags(.slow), .notInFastLane) func governorDeferredWarmTilesAreNotStranded() {
        var rng = SplitMix64(seed: 2103)
        let h = Harness(width: 2560, height: 2560) // full-frame change ≫ burst bucket
        h.encodeFrame() // flat frame: a cheap cold start, every tile warm after
        #expect(h.settle(maxSimMS: 120_000))
        h.run(untilUS: h.now + 7_000_000) // refill the bucket to its cap

        // One full-frame change, reported once: every tile is warm and
        // qualifies; ~26 MB of RAW-ish records against a 16 MB bucket, so
        // ~10 MB is deferred — which drains at the base rate in ~4 s.
        let deferredBefore = h.host.stats.governorDeferredTiles
        h.frame.fillRandom(&rng)
        h.encodeFrame(dirtyRects: [DirtyRect(x: 0, y: 0, width: 2560, height: 2560)])
        #expect(h.host.stats.governorDeferredTiles > deferredBefore,
                "the change must exceed the bucket for this test to mean anything")

        driveBusyThenQuiet(h, &rng, busy: DirtyRect(x: 0, y: 0, width: 32, height: 32),
                           busyMS: 8_000, quietMS: 1_000)
        #expect(h.canvasMatchesFrame(),
                "deferred warm tiles must re-volunteer without new dirty rects")
    }
}
