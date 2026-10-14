import Testing
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Region video is a present-time overlay over an
/// untouched canvas, so a dissolve repaints only the tiles that changed
/// under it; and a pinned full-screen region hands typing-sized churn back
/// to the lossless tile path.
@Suite struct VideoOverlayTests {
    /// Pinned, 640² (100 tiles): churn a 384² box (36 tiles — enough to
    /// form), then stop. Returns (harness, tile records + cache refs sent
    /// from quiesce to settle).
    private func churnThenSettle(faults: FaultConfig = .none) -> (Harness, Int) {
        var rng = SplitMix64(seed: 3101)
        let h = Harness(width: 640, height: 640, faults: faults, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 120_000))
        for _ in 0..<40 {
            h.frame.fillRect(x: 64, y: 64, w: 384, h: 384, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: 64, y: 64, width: 384, height: 384)])
            h.run(untilUS: h.now + 16_667)
        }
        #expect(h.host.stats.videoRegionsFormed >= 1, "pinned churn must form the region")
        let recordsBefore = h.host.stats.tilesSent + h.host.stats.cacheRefsSent
        h.run(untilUS: h.now + 3_000_000) // quiesce → dissolve
        #expect(h.settle(maxSimMS: 120_000))
        return (h, h.host.stats.tilesSent + h.host.stats.cacheRefsSent - recordsBefore)
    }

    @Test func dissolveRevealsUnchangedTilesAndRepaintsOnlyChanged() {
        let (h, records) = churnThenSettle()
        // 100 tiles, 36 churned: the other 64 are revealed without a byte,
        // and only the 36 that changed are repainted.
        let revealed = h.host.stats.overlayTilesRevealed
        #expect(revealed >= 60, "revealed \(revealed)")
        #expect(records <= 45, "records \(records)")
        #expect(h.canvasMatchesFrame(), "canvas exact and nothing left on the overlay")
    }

    @Test(arguments: [41, 42, 43] as [UInt64])
    func overlayGoldenUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = seed
        let (h, _) = churnThenSettle(faults: faults)
        #expect(h.canvasMatchesFrame(), "byte-exact, overlay fully handed back (seed \(seed))")
    }

    @Test func pinnedRegionDissolvesUnderTypingSizedChurn() {
        var rng = SplitMix64(seed: 3102)
        let h = Harness(width: 640, height: 640, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 120_000))
        for _ in 0..<20 {
            h.frame.fillRect(x: 0, y: 0, w: 640, h: 384, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: 0, y: 0, width: 640, height: 384)])
            h.run(untilUS: h.now + 16_667)
        }
        #expect(h.host.activeVideoRegionCount == 1)
        // "Typing": two tiles change every tick, for 8 s — never quiet, but
        // far below what forms a region. (The quick re-form after the cold
        // start's region escalates patience to its 4.5 s cap.)
        var dissolvedWhileTyping = false
        for i in 0..<480 {
            let x = (i % 8) * 64
            h.frame.fillRect(x: x, y: 512, w: 128, h: 64, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: x, y: 512, width: 128, height: 64)])
            h.run(untilUS: h.now + 16_667)
            if h.host.activeVideoRegionCount == 0 { dissolvedWhileTyping = true }
        }
        #expect(dissolvedWhileTyping, "typing must not keep a full-screen region alive (formed \(h.host.stats.videoRegionsFormed), dissolved \(h.host.stats.videoRegionsDissolved))")
        #expect(h.host.activeVideoRegionCount == 0, "and must not re-form it")
        #expect(h.settle(maxSimMS: 120_000))
        #expect(h.canvasMatchesFrame())
    }
}
