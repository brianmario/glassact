import Foundation
import Testing
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// PAUSE_HINT: an occluded viewer pauses content (keep-alives only) and
/// resumes it when visible again. The protocol's core property makes this
/// safe: a state synchronizer is allowed to fall behind, and catching up is
/// one ordinary tick.
@Suite struct PauseHintTests {
    /// The video sessions run 512×512 (64 tiles); a 384² box is 36 tiles —
    /// enough churn to form and keep a pinned region.
    static let videoSide = 512
    static let videoBox = DirtyRect(x: 64, y: 64, width: 384, height: 384)

    private func churn(_ h: Harness, _ rng: inout SplitMix64, ticks: Int,
                       box: DirtyRect = DirtyRect(x: 64, y: 64, width: 192, height: 192)) {
        for _ in 0..<ticks {
            h.frame.fillRect(x: box.x, y: box.y, w: box.width, h: box.height, &rng)
            h.encodeFrame(dirtyRects: [box])
            h.run(untilUS: h.now + 20_000)
        }
    }

    /// Paused, every encode tick is skipped and no pixel bytes ship; the
    /// damage from those ticks isn't lost — after resume the content
    /// converges exactly, and ticks run again.
    @Test func pauseSkipsTicksAndResumeConverges() {
        var rng = SplitMix64(seed: 801)
        let h = Harness(width: 320, height: 320)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle())

        h.viewer.setContentPaused(true)
        h.run(untilUS: h.now + 100_000) // hint rides control latency
        #expect(h.host.contentPaused)
        let ticksBefore = h.host.stats.ticksPaused
        let bytesBefore = h.host.stats.bytesOut
        churn(h, &rng, ticks: 50)
        #expect(h.host.stats.ticksPaused - ticksBefore == 50, "every tick is skipped while paused")
        #expect(h.host.stats.bytesOut == bytesBefore, "paused content must ship zero bytes")

        h.viewer.setContentPaused(false)
        h.run(untilUS: h.now + 100_000)
        #expect(!h.host.contentPaused, "resume must clear the paused state")
        // No new changes after resume: the paused ticks' damage alone must
        // re-qualify.
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "damage from paused ticks must converge after resume")
        let ticksAtResume = h.host.stats.ticksPaused
        churn(h, &rng, ticks: 20)
        #expect(h.host.stats.ticksPaused == ticksAtResume, "resumed: no tick is skipped for pause")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }

    /// Paused, an active video region idles WITHOUT dissolving (no settle
    /// repaint for an invisible window), and resume converges.
    @Test func pausedRegionIdlesUndissolved() {
        var rng = SplitMix64(seed: 804)
        let h = Harness(width: Self.videoSide, height: Self.videoSide, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 200_000)
        churn(h, &rng, ticks: 40, box: Self.videoBox)
        #expect(h.host.activeVideoRegionCount == 1, "region forms while live")
        let dissolvesBefore = h.host.stats.videoRegionsDissolved

        h.viewer.setContentPaused(true)
        h.run(untilUS: h.now + 100_000) // hint rides control latency
        #expect(h.host.contentPaused, "the hint must latch the paused state")
        let bytesBefore = h.host.stats.bytesOut
        churn(h, &rng, ticks: 50, box: Self.videoBox)
        h.run(untilUS: h.now + 3_000_000) // long quiet: quiescence dissolve must not fire
        #expect(h.host.stats.bytesOut == bytesBefore, "paused content must ship zero bytes")
        #expect(h.host.activeVideoRegionCount == 1, "paused region idles un-dissolved")
        #expect(h.host.stats.videoRegionsDissolved == dissolvesBefore)

        h.viewer.setContentPaused(false)
        h.run(untilUS: h.now + 100_000)
        #expect(!h.host.contentPaused, "resume must clear the paused state")
        churn(h, &rng, ticks: 20, box: Self.videoBox)
        #expect(h.settle(maxSimMS: 120_000))
        #expect(h.canvasMatchesFrame(), "post-resume sync must converge exactly")
    }

    /// Faulted golden across a full pause cycle: churn → pause mid-churn →
    /// more churn while paused → resume → settle byte-exact.
    @Test(arguments: [UInt64(51), 52])
    func pauseCycleGoldenUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = seed
        var rng = SplitMix64(seed: seed &* 811)
        let h = Harness(width: Self.videoSide, height: Self.videoSide, faults: faults, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 500_000)

        churn(h, &rng, ticks: 40, box: Self.videoBox) // region live
        h.viewer.setContentPaused(true)
        churn(h, &rng, ticks: 40, box: Self.videoBox) // keeps changing while the pause lands
        h.viewer.setContentPaused(false)
        churn(h, &rng, ticks: 20, box: Self.videoBox)
        #expect(h.settle(maxSimMS: 120_000), "seed \(seed)")
        #expect(h.canvasMatchesFrame(), "seed \(seed): byte-exact across a pause cycle")
    }
}
