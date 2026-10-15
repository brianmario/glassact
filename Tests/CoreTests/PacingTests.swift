import Foundation
import Testing
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Adaptive datagram pacing: the controller's rules in isolation, then the
/// whole loop against a modeled receiver (InProcLink.Bottleneck — a drain
/// rate behind a finite buffer, like the viewer's UDP socket).
@Suite struct PaceControllerTests {
    private let big = PaceController.probeMinBytes

    @Test func heavyLossMovesTowardTheDrainRateButAtMostHalves() {
        var pace = PaceController()
        let start = pace.rate
        // 30 % lost: the receiver took ~70 % → 0.7 × 0.9 = 0.63 of the rate.
        let cut = pace.observe(sentAtRate: start, datagrams: 1000, bytes: big, lost: 300)
        #expect(cut)
        #expect(pace.rate == Int(Double(start) * 0.63))
        // 90 % lost: the estimate says 0.09×, but one batch may only halve.
        let second = pace.rate
        let halved = pace.observe(sentAtRate: second, datagrams: 1000, bytes: big, lost: 900)
        #expect(halved)
        #expect(pace.rate == second / 2)
        #expect(pace.decreases == 2)
    }

    @Test func batchesSentAtAnOlderRateAreIgnored() {
        var pace = PaceController()
        let start = pace.rate
        let cut = pace.observe(sentAtRate: start, datagrams: 1000, bytes: big, lost: 500)
        #expect(cut)
        // The next batch was already in flight at the old rate: same
        // overflow, already accounted for — no second cut.
        let again = pace.observe(sentAtRate: start, datagrams: 1000, bytes: big, lost: 500)
        #expect(!again)
        #expect(pace.decreases == 1)
    }

    @Test func randomLossBandHoldsAndCleanBatchesProbeUp() {
        var pace = PaceController()
        let start = pace.rate
        let held = pace.observe(sentAtRate: start, datagrams: 1000, bytes: big, lost: 50) // 5 %
        #expect(!held)
        #expect(pace.rate == start)
        let probed = pace.observe(sentAtRate: start, datagrams: 1000, bytes: big, lost: 0)
        #expect(probed)
        #expect(pace.rate == start + start / 16)
    }

    @Test func unpacedBatchesSayNothing() {
        var pace = PaceController()
        let start = pace.rate
        // Within the instant burst, or too few datagrams for a fraction.
        let burst = pace.observe(sentAtRate: start, datagrams: 1000, bytes: DatagramPacing.burstBytes, lost: 900)
        let tiny = pace.observe(sentAtRate: start, datagrams: PaceController.minDatagrams - 1, bytes: big, lost: 40)
        #expect(!burst && !tiny)
        #expect(pace.rate == start)
        // Clean but small enough to fit a receive buffer at any pace: no probe.
        let small = pace.observe(sentAtRate: start, datagrams: 1000, bytes: PaceController.probeMinBytes - 1, lost: 0)
        #expect(!small)
        // …while heavy loss on it still counts.
        let lossy = pace.observe(sentAtRate: start, datagrams: 1000, bytes: PaceController.probeMinBytes - 1, lost: 500)
        #expect(lossy && pace.rate < start)
    }

    @Test func rateStaysWithinBounds() {
        var pace = PaceController()
        for _ in 0..<64 { pace.observe(sentAtRate: pace.rate, datagrams: 1000, bytes: big, lost: 1000) }
        #expect(pace.rate == PaceController.minRate)
        for _ in 0..<256 { pace.observe(sentAtRate: pace.rate, datagrams: 1000, bytes: big, lost: 0) }
        #expect(pace.rate == PaceController.maxRate)
    }
}

@Suite struct AdaptivePacingTests {
    /// Full-screen changes separated by idle (so the governor's bucket
    /// refills and each change goes out as one big paced batch), every
    /// round settled byte-exactly. Returns bottleneck drops per round.
    private func rounds(_ h: Harness, count: Int, seed: UInt64) -> [Int] {
        var rng = SplitMix64(seed: seed)
        var drops: [Int] = []
        for round in 0..<count {
            let before = h.link.bottleneckDroppedDatagrams
            h.frame.fillRandom(&rng)
            #expect(h.settle(maxSimMS: 60_000), "round \(round) must converge")
            #expect(h.canvasMatchesFrame(), "round \(round) must be byte-exact")
            drops.append(h.link.bottleneckDroppedDatagrams - before)
            h.run(untilUS: h.now + 3_000_000) // idle: the governor bucket refills
        }
        return drops
    }

    /// INV-4 extended to the pacer: while a full-screen batch is still
    /// leaving (well over 20 ms of backlog), the next capture is skipped
    /// instead of queued behind it — over QUIC, a queued second batch would
    /// overflow the pacer queue at cold start and drop the first batch's
    /// head.
    @Test func encoderWaitsOutThePacerBacklog() {
        var rng = SplitMix64(seed: 5105)
        let h = Harness(width: 1280, height: 1280, fastLink: true) // ~6.5 MB in one burst: ~130 ms at 50 MB/s
        h.link.bottleneck = .init(bytesPerSecond: 500_000_000, bufferBytes: 64 << 20)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.link.a.queuedDatagramBytes > 4 << 20, "the batch must still be leaving")
        h.frame.fillRandom(&rng) // every tile qualifies again
        h.run(untilUS: h.now + 16_000)
        h.encodeFrame()
        #expect(h.host.stats.pacerBacklogSkips == 1)
        #expect(h.host.openBatchCount == 1, "nothing may queue behind the backlog")
        #expect(h.settle(maxSimMS: 60_000) && h.canvasMatchesFrame())
    }

    /// A viewer that drains at 15 MB/s behind a 768 KB buffer, fed at the
    /// initial 50 MB/s pace: the first full-screen batch mostly overflows.
    /// The pace must come down to the drain rate and the overflow with it.
    @Test func slowViewerPullsThePaceDown() {
        let h = Harness(width: 1280, height: 1280, fastLink: true) // 400 tiles, ~6.5 MB RAW per change, one burst each
        let drain = 15_000_000
        h.link.bottleneck = .init(bytesPerSecond: drain, bufferBytes: 786_896)
        let drops = rounds(h, count: 6, seed: 5101)
        let rate = h.host.stats.datagramPaceRate
        #expect(h.host.stats.paceDecreases > 0)
        #expect(rate < drain * 3 / 2 && rate >= PaceController.minRate,
                "pace \(rate) should settle near the \(drain) B/s drain")
        let late = drops.suffix(3).reduce(0, +)
        #expect(late * 4 < drops[0], "overflow must fall well below the first round's: \(drops)")
    }

    /// 5 % random loss on a fast path is noise, not overflow: the pace holds.
    @Test func randomLossDoesNotCollapseThePace() {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.seed = 5102
        let h = Harness(width: 1280, height: 1280, faults: faults)
        h.link.bottleneck = .init(bytesPerSecond: 500_000_000, bufferBytes: 64 << 20)
        _ = rounds(h, count: 3, seed: 5103)
        #expect(h.host.stats.paceDecreases == 0)
        #expect(h.host.stats.datagramPaceRate >= PaceController.initialRate)
    }

    /// A receiver faster than the initial pace: clean big batches probe up.
    @Test func fastViewerLetsThePaceRise() {
        let h = Harness(width: 1280, height: 1280)
        h.link.bottleneck = .init(bytesPerSecond: 500_000_000, bufferBytes: 64 << 20)
        _ = rounds(h, count: 3, seed: 5104)
        #expect(h.host.stats.paceDecreases == 0)
        #expect(h.host.stats.paceIncreases > 0)
        #expect(h.host.stats.datagramPaceRate > PaceController.initialRate)
    }
}
