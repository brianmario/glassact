import Foundation
import Testing
import GlassActWire
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Per-tile handoff inside a live region (VideoClaims / REVEAL): while one
/// area keeps a pinned full-screen region alive, every tile that stops
/// changing goes back to its exact canvas copy — live 2026-10-10, minutes of
/// soft static text around one animating panel.
@Suite struct VideoHandoffTests {
    // 1280×640: 200 tiles. The strip is 40 tiles (≥ pinnedFormMinTiles, so
    // the pinned region stays up while it animates).
    static let width = 1280, height = 640
    static let strip = DirtyRect(x: 0, y: 0, width: 256, height: 640)
    static let whole = DirtyRect(x: 0, y: 0, width: 1280, height: 640)

    static func inStrip(_ grid: TileGrid, _ idx: Int) -> Bool {
        idx % grid.cols < Int(strip.width) / TileGrid.tileSize
    }

    private func animateStrip(_ h: Harness, _ rng: inout SplitMix64, seconds: Double) {
        let end = h.now + UInt64(seconds * 1_000_000)
        while h.now < end {
            h.frame.fillRect(x: 0, y: 0, w: Int(Self.strip.width), h: Int(Self.strip.height), &rng)
            h.encodeFrame(dirtyRects: [Self.strip])
            h.run(untilUS: h.now + 100_000)
        }
    }

    /// Every tile outside the strip presents its exact canvas copy, matching
    /// the host's frame; the strip itself is still video.
    private func expectStillTilesExact(_ h: Harness, sourceLocation: SourceLocation = #_sourceLocation) {
        let grid = TileGrid(width: Self.width, height: Self.height)
        var onVideo = 0, inexact = 0, stripOnVideo = 0
        for idx in 0..<grid.count {
            if Self.inStrip(grid, idx) {
                if h.viewer.tileShowsVideo(idx) { stripOnVideo += 1 }
                continue
            }
            if h.viewer.tileShowsVideo(idx) { onVideo += 1 }
            if canvasTile(h.viewer, idx) != h.frame.tightTile(idx) { inexact += 1 }
        }
        #expect(h.host.activeVideoRegionCount == 1, "the strip keeps the region up", sourceLocation: sourceLocation)
        #expect(onVideo == 0, "\(onVideo) still tiles still present video", sourceLocation: sourceLocation)
        #expect(inexact == 0, "\(inexact) still tiles differ from the host's frame", sourceLocation: sourceLocation)
        #expect(stripOnVideo == 40, "the moving strip stays on video (\(stripOnVideo)/40)", sourceLocation: sourceLocation)
    }

    /// Formation claims the whole screen; the canvas under the still part is
    /// already exact, so it comes back by REVEAL — no pixels resent.
    @Test(.tags(.slow), .notInFastLane) func stillTilesRevealWhileRegionAnimates() {
        var rng = SplitMix64(seed: 9201)
        let h = Harness(width: Self.width, height: Self.height, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 120_000), "setup: an exact canvas to start from")
        for _ in 0..<3 { h.encodeFrame(dirtyRects: []); h.run(untilUS: h.now + 16_000) }
        // (The cold start's own flood hands its region back by records.)
        let reveals = h.host.stats.overlayHandoffReveals, records = h.host.stats.overlayHandoffRecords
        animateStrip(h, &rng, seconds: 3)
        expectStillTilesExact(h)
        #expect(h.host.stats.overlayHandoffReveals - reveals >= 160, "the still 160 tiles came back by REVEAL")
        // Only the strip's own formation-tick records may count: with this
        // synchronous mock encoder the first frame shares that tick's seq,
        // and records win ties.
        #expect(h.host.stats.overlayHandoffRecords - records <= 40, "the still tiles needed no resend")
    }

    /// Content that changed under the video, then went still, comes back by
    /// a lossless record — newer than the frame that claimed it.
    @Test(.tags(.slow), .notInFastLane) func changedThenStillTilesGetLosslessRecords() {
        var rng = SplitMix64(seed: 9202)
        let h = Harness(width: Self.width, height: Self.height, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame() // pinned cold start: the region forms on the first frame
        h.run(untilUS: h.now + 100_000)
        h.frame.fillRandom(&rng) // everything changes under the video
        h.encodeFrame(dirtyRects: [Self.whole])
        h.run(untilUS: h.now + 100_000)
        animateStrip(h, &rng, seconds: 3)
        expectStillTilesExact(h)
        #expect(h.host.stats.overlayHandoffRecords >= 160, "stale canvas copies were replaced losslessly")
    }

    /// Loss, duplication, reordering and jitter on the datagram path: the
    /// handoff still converges, and the final settle is byte-exact.
    @Test(.tags(.slow), .notInFastLane, arguments: [UInt64(31), 32])
    func handoffConvergesUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = seed
        var rng = SplitMix64(seed: 9203 &+ seed)
        let h = Harness(width: Self.width, height: Self.height, faults: faults, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        h.frame.fillRandom(&rng)
        h.encodeFrame(dirtyRects: [Self.whole])
        h.run(untilUS: h.now + 100_000)
        // A lost handoff record costs a timeout and a resend: allow a few.
        animateStrip(h, &rng, seconds: 8)
        expectStillTilesExact(h)
        #expect(h.settle(maxSimMS: 240_000), "settles once the strip stops")
        #expect(h.canvasMatchesFrame(), "byte-exact, nothing presented from video")
    }

    /// A tile video keeps reclaiming soon after its record handoff (here a
    /// block that changes every 2.5 s) backs off: the record was bytes
    /// thrown away, so its threshold doubles until handoffs stop paying.
    @Test(.tags(.slow), .notInFastLane) func rechurningTilesBackOffRecordHandoffs() {
        var rng = SplitMix64(seed: 9205)
        let h = Harness(width: Self.width, height: Self.height, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        animateStrip(h, &rng, seconds: 4) // cold start handed back first
        let block = DirtyRect(x: 768, y: 256, width: 128, height: 128) // 4 tiles, outside the strip
        var perCycle: [Int] = []
        for _ in 0..<6 {
            let before = h.host.stats.overlayHandoffRecords
            h.frame.fillRect(x: block.x, y: block.y, w: block.width, h: block.height, &rng)
            h.encodeFrame(dirtyRects: [Self.strip, block])
            h.run(untilUS: h.now + 100_000)
            animateStrip(h, &rng, seconds: 2.4)
            perCycle.append(h.host.stats.overlayHandoffRecords - before)
        }
        // Thresholds 1 s, then 2 s, hand the block back; 4 s outgrows the
        // 2.5 s cycle and it stays on video.
        #expect(perCycle[0...1].allSatisfy { $0 <= 4 }, "per-cycle record handoffs \(perCycle)")
        #expect(perCycle[2...].allSatisfy { $0 == 0 }, "backed off: no more records \(perCycle)")
    }

    /// A handed-off tile that changes again goes back on video at once (the
    /// next frame claims it), and returns to exact once still again.
    @Test(.tags(.slow), .notInFastLane) func handedOffTileThatMovesAgainReturnsToVideoThenExact() {
        var rng = SplitMix64(seed: 9204)
        let h = Harness(width: Self.width, height: Self.height, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        // Record handoffs wait for 2 s without a large update.
        animateStrip(h, &rng, seconds: 4)
        expectStillTilesExact(h)

        // One tile well outside the strip changes, once, with the strip.
        let grid = TileGrid(width: Self.width, height: Self.height)
        let target = 5 * grid.cols + 12
        let (tx, ty, _, _) = grid.rect(of: target)
        h.frame.fillRect(x: 0, y: 0, w: Int(Self.strip.width), h: Int(Self.strip.height), &rng)
        h.frame.fillRect(x: tx, y: ty, w: TileGrid.tileSize, h: TileGrid.tileSize, &rng)
        h.encodeFrame(dirtyRects: [Self.strip, DirtyRect(x: tx, y: ty, width: TileGrid.tileSize,
                                                          height: TileGrid.tileSize)])
        h.run(untilUS: h.now + 100_000)
        #expect(h.viewer.tileShowsVideo(target), "the change shows at once, on video")

        animateStrip(h, &rng, seconds: 3)
        #expect(!h.viewer.tileShowsVideo(target), "still again: back to exact")
        expectStillTilesExact(h)
    }
}
