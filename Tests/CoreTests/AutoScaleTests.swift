import Foundation
import Testing
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Auto-scale pressure (the airplane-wifi story): resolution is the adaptive
/// ladder's rung below quality. Sustained severe ack-delay fires a
/// once-per-session "constrained" suggestion (the app halves the capture);
/// the rung latches — restoration happens on disconnect, never mid-session.
/// The engine only suggests — geometry itself is app policy.
@Suite struct AutoScaleTests {
    private func churn(_ h: Harness, _ rng: inout SplitMix64, simMS: Int) {
        let end = h.now + UInt64(simMS) * 1000
        while h.now < end {
            h.frame.fillRect(x: 64, y: 64, w: 192, h: 192, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: 64, y: 64, width: 192, height: 192)])
            h.run(untilUS: h.now + 33_000)
        }
    }

    @Test(.tags(.slow), .notInFastLane) func sustainedSevereSuggestsDownscaleAndLatches() {
        var faults = FaultConfig()
        faults.latencyMinUS = 450_000 // ~1 s RTT → ack-delay above severe (700 ms)
        faults.latencyMaxUS = 550_000
        faults.seed = 9
        var rng = SplitMix64(seed: 3001)
        let h = Harness(width: 320, height: 320, faults: faults)
        var fired = 0
        h.host.onScalePressureConstrained = { fired += 1 }
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 400_000)

        // Severe link + continuous send activity: the streak must reach the
        // threshold and fire exactly once (edge-triggered, no repeats).
        churn(h, &rng, simMS: (HostEngine.autoScaleSevereSeconds + 6) * 1000)
        #expect(fired == 1,
                "sustained severe must suggest downscale exactly once (fired \(fired))")

        // Link recovers mid-run: the rung must LATCH — no mid-session restore
        // (restoration is the app's disconnect path), and no re-fire either.
        var healthy = FaultConfig()
        healthy.latencyMinUS = 5_000
        healthy.latencyMaxUS = 10_000
        healthy.seed = 9
        h.link.faults = healthy
        churn(h, &rng, simMS: 40_000)
        #expect(fired == 1,
                "constrained latches for the session — no mid-session restore (fired \(fired))")

        // And a second severe stretch must not re-fire the latched engine.
        h.link.faults = faults
        churn(h, &rng, simMS: (HostEngine.autoScaleSevereSeconds + 6) * 1000)
        #expect(fired == 1, "the suggestion fires at most once per engine (fired \(fired))")
    }

    @Test(.tags(.slow), .notInFastLane) func healthyLinkNeverSuggestsDownscale() {
        var faults = FaultConfig()
        faults.latencyMinUS = 5_000
        faults.latencyMaxUS = 10_000
        faults.seed = 10
        var rng = SplitMix64(seed: 3002)
        let h = Harness(width: 320, height: 320, faults: faults)
        var fired = 0
        h.host.onScalePressureConstrained = { fired += 1 }
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 400_000)
        churn(h, &rng, simMS: (HostEngine.autoScaleSevereSeconds + 10) * 1000)
        #expect(fired == 0, "a healthy link must never suggest scaling (fired \(fired))")
    }

    /// A stale reading must not build the streak. ackDelay only updates on
    /// tile-batch ACKs, but video bytes kept the "activity" gate open — so
    /// one congested settle, followed by a recovered link carrying only
    /// pinned video (no tile batches), counted the frozen severe value every
    /// second and downscaled the session.
    @Test(.tags(.slow), .notInFastLane) func staleSevereReadingDoesNotBuildStreak() {
        var severe = FaultConfig()
        severe.latencyMinUS = 450_000 // ~1 s RTT → ack-delay above severe
        severe.latencyMaxUS = 550_000
        severe.seed = 13
        var rng = SplitMix64(seed: 3003)
        let h = Harness(width: 384, height: 384, faults: severe, video: true)
        var fired = 0
        h.host.onScalePressureConstrained = { fired += 1 }
        h.frame.fillRandom(&rng)
        h.encodeFrame() // pinned cold start: the region carries the first paint

        // Quiesce: dissolve → lossless repaint over the severe link, until
        // the first tile ACK lands a severe reading.
        let deadline = h.now + 20_000_000
        while h.host.ackDelayUS <= HostEngine.governorSevereAckDelayUS && h.now < deadline {
            h.encodeFrame(dirtyRects: [])
            h.run(untilUS: h.now + 33_000)
        }
        #expect(h.host.ackDelayUS > HostEngine.governorSevereAckDelayUS, "setup: severe reading")
        #expect(fired == 0, "setup: the streak must not already have fired")

        // Link recovers; pinned video carries all motion — no tile batches,
        // so no fresh ack-delay reading, however long this runs.
        var healthy = severe
        healthy.latencyMinUS = 5_000
        healthy.latencyMaxUS = 10_000
        h.link.faults = healthy
        // 10 fps keeps the (debug-build) mock codec cheap; the streak is
        // evaluated on the 1 Hz PING cadence, independent of tick rate.
        let end = h.now + UInt64(HostEngine.autoScaleSevereSeconds + 3) * 1_000_000
        while h.now < end {
            h.frame.fillRect(x: 0, y: 0, w: 384, h: 384, &rng) // 36 tiles ≥ pinnedFormMinTiles
            h.encodeFrame(dirtyRects: [DirtyRect(x: 0, y: 0, width: 384, height: 384)])
            h.run(untilUS: h.now + 100_000)
        }
        #expect(h.host.activeVideoRegionCount == 1, "setup: motion rides the pinned region")
        #expect(fired == 0, "a frozen reading must not downscale the session (fired \(fired))")
    }
}
