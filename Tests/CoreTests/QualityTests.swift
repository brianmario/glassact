import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Adaptive video quality (§4.6): a bandwidth-pressure ladder. Bitrate is
/// a measured bandwidth lever at ~free framerate cost, so the host sheds
/// bytes on a queueing link while frames keep flowing.
@Suite struct QualityTests {
    // 512×512 (64 tiles), churning a 384² box: 36 tiles, enough to form and
    // keep a pinned region.
    private func churn(_ h: Harness, _ rng: inout SplitMix64, ticks: Int, stepMS: Int) {
        for _ in 0..<ticks {
            h.frame.fillRect(x: 64, y: 64, w: 384, h: 384, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: 64, y: 64, width: 384, height: 384)])
            h.run(untilUS: h.now + UInt64(stepMS) * 1000)
        }
    }

    /// Sustained SRTT inflation (video queuing) lowers quality.
    @Test func bandwidthPressureLowersQuality() {
        var faults = FaultConfig()
        faults.latencyMinUS = 70_000 // > videoQualitySrttUS (45 ms) → bandwidth signal
        faults.latencyMaxUS = 90_000
        faults.seed = 5
        var rng = SplitMix64(seed: 2001)
        let h = Harness(width: 512, height: 512, faults: faults, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 400_000)

        churn(h, &rng, ticks: 40, stepMS: 20) // keep the region + let SRTT settle high
        #expect(h.host.stats.videoRegionsFormed >= 1, "region must form")
        churn(h, &rng, ticks: 120, stepMS: 20) // sustained pressure → quality steps down
        #expect(h.host.stats.qualityDowngrades > 0, "bandwidth pressure must lower quality")
        #expect(h.settle(maxSimMS: 240_000))
        #expect(h.canvasMatchesFrame(), "quality is lossy-while-live; settle is byte-exact")
    }

    /// Quality is a runtime knob on the encoder (the mock records it) and
    /// resets when a region dissolves.
    @Test func qualityResetsOnDissolve() {
        var rng = SplitMix64(seed: 2002)
        var faults = FaultConfig()
        faults.latencyMinUS = 70_000
        faults.latencyMaxUS = 90_000
        faults.seed = 6
        let h = Harness(width: 512, height: 512, faults: faults, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 400_000)
        churn(h, &rng, ticks: 160, stepMS: 20)
        let downgraded = h.host.stats.qualityDowngrades
        #expect(downgraded > 0)

        // Go quiet → region dissolves → next region starts at best quality.
        h.run(untilUS: h.now + 2_000_000)
        #expect(h.settle(maxSimMS: 240_000))
        #expect(h.canvasMatchesFrame())
    }

    /// ~1 s RTT: quality degrades, the region dissolves on quiesce, and the
    /// settle converges byte-exact — slow is fine, stuck is not. (This once
    /// livelocked: un-ACKed cold repaint tiles read as churn re-formed the
    /// region from its own repaint; see `lastObservedHash` and
    /// highRTTGoldenConvergence.)
    @Test func severeLinkStillConverges() {
        var faults = FaultConfig()
        faults.latencyMinUS = 450_000 // ~1 s RTT → ack-delay above the severe threshold
        faults.latencyMaxUS = 550_000
        faults.seed = 8
        var rng = SplitMix64(seed: 2004)
        let h = Harness(width: 512, height: 512, faults: faults, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 1_500_000)
        churn(h, &rng, ticks: 160, stepMS: 20)
        #expect(h.host.stats.qualityDowngrades > 0, "pressure must degrade quality first")

        // Quiesce long enough for the dissolve + several settle-drain ticks.
        for _ in 0..<200 {
            h.encodeFrame()
            h.run(untilUS: h.now + 33_000)
        }
        #expect(h.host.stats.videoRegionsDissolved >= 1, "quiesce must dissolve the region")
        #expect(h.settle(maxSimMS: 240_000), "severe link must still converge")
        #expect(h.canvasMatchesFrame(), "settle is byte-exact even at ~1 s RTT")
    }
}
