import Testing
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// In-session geometry renegotiation (§4.10): a window resize (or pick / fullscreen)
/// reconfigures BOTH engines' canvases on the LIVE connection — no reconnect.
/// The single monotonic `nextFrameSeq` domain, seeded across the host rebuild,
/// is what keeps LWW coherent while the viewer resets `tileSeq` on reconfigure.
/// The bar is the §7 golden: byte-exact at the NEW dimensions after settle.
@Suite struct InSessionResizeTests {
    @Test func resizeSettlesByteExactAtNewDims() {
        var rng = SplitMix64(seed: 42)
        let h = Harness(width: 320, height: 240)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())

        // Grow the "window".
        h.reconfigure(width: 512, height: 384)
        #expect(h.viewer.grid?.width == 512 && h.viewer.grid?.height == 384,
                "viewer canvas must reconfigure to the new dimensions in-session")
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "byte-exact at the grown size, no reconnect")

        // Shrink it.
        h.reconfigure(width: 192, height: 160)
        #expect(h.viewer.grid?.width == 192 && h.viewer.grid?.height == 160)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "byte-exact at the shrunk size")
    }

    /// A resize while a video region is live: the video stream spans the engine
    /// swap continuously (the viewer must NOT reset its video deframer), stale
    /// frames drop on the region generation guard, and the lossless repaint
    /// settles byte-exact at the new size.
    @Test func resizeWithVideoRegionSettlesExact() {
        var rng = SplitMix64(seed: 11)
        let h = Harness(width: 512, height: 512, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 400_000)
        for _ in 0..<40 { // churn a large area (36 tiles) → the region stays live
            h.frame.fillRect(x: 64, y: 64, w: 384, h: 384, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: 64, y: 64, width: 384, height: 384)])
            h.run(untilUS: h.now + 20_000)
        }
        #expect(h.host.activeVideoRegionCount == 1, "a region must be live before the resize")

        h.reconfigure(width: 576, height: 576)
        for _ in 0..<40 { // 36 tiles of the new 81: the new engine forms its own region
            h.frame.fillRect(x: 64, y: 64, w: 384, h: 384, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: 64, y: 64, width: 384, height: 384)])
            h.run(untilUS: h.now + 20_000)
        }
        #expect(h.host.stats.videoRegionsFormed >= 1, "video must resume at the new size")
        #expect(h.settle(maxSimMS: 240_000))
        #expect(h.canvasMatchesFrame(), "byte-exact after resizing with video active")
    }

    /// The resize converges exactly even with in-flight old-geometry stragglers
    /// under loss/dup/reorder/jitter — the LWW self-heal that the whole system
    /// rests on, here spanning a mid-session canvas swap. Seeded, zero-tolerance.
    @Test func resizeUnderFaultsSettlesExact() {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = 7
        var rng = SplitMix64(seed: 99)
        let h = Harness(width: 300, height: 220, faults: faults)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 120_000))
        #expect(h.canvasMatchesFrame())

        // Resize mid-flight, then churn so old- and new-geometry datagrams race.
        h.reconfigure(width: 448, height: 320)
        for _ in 0..<12 {
            _ = h.mutateRandomRects(&rng, count: 6)
            h.encodeFrame()
            h.run(untilUS: h.now + 20_000)
        }
        #expect(h.settle(maxSimMS: 240_000))
        #expect(h.canvasMatchesFrame(), "byte-exact after a faulted in-session resize")
    }
}
