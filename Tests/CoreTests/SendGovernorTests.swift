import Testing
@testable import GlassActCore

/// SendGovernor in isolation: the auto rate's growth / drain / severe rules,
/// the limit, the refill cap, bounded debt.
@Suite struct SendGovernorTests {
    typealias G = SendGovernor

    /// Baseline path delay 10 ms, then `queueUS` of STANDING queue: every
    /// sample in the current and previous short windows carries it.
    private func sample(_ g: inout SendGovernor, queueUS: UInt64, at nowUS: UInt64) {
        g.notePathDelay(10_000, nowUS: 1)
        let earlier = nowUS > G.recentWindowUS + 2 ? nowUS - G.recentWindowUS - 1 : 2
        g.notePathDelay(10_000 + queueUS, nowUS: earlier)
        g.notePathDelay(10_000 + queueUS, nowUS: nowUS)
    }

    @Test func jitterIsNotAQueue() {
        var g = SendGovernor()
        var rng = UInt64(7)
        var t: UInt64 = 0
        for _ in 0..<400 { // 20–80 ms uniform latency, one sample per 5 ms
            rng = rng &* 6_364_136_223_846_793_005 &+ 1
            t += 5_000
            g.notePathDelay(20_000 + (rng >> 33) % 60_000, nowUS: t)
        }
        #expect(g.queueDelayUS < G.queueHealthyUS, "jitter read as \(g.queueDelayUS) µs of queue")
    }

    @Test func lanStillReaches100MegabytesPerSecondInSlowStart() {
        var g = SendGovernor()
        g.start(roundTripUS: 10_000, nowUS: 10_000)
        #expect(g.autoRate == G.initialAutoRate)
        for step in 1...6 {
            let now = UInt64(step) * 200_000
            g.notePathDelay(10_000, nowUS: now)
            g.noteDeferred()
            g.adapt(nowUS: now, ceiling: G.maxAutoRate)
        }
        #expect(g.autoRate >= 100_000_000, "a LAN still climbs in 1.2 s")
    }

    @Test func highRTTBoundsTheInitialFlight() {
        var g = SendGovernor()
        g.start(roundTripUS: 700_000, nowUS: 700_000)
        #expect(g.autoRate < 50_000, "a long path starts with a small flight, not 16 Mbit/s")
        #expect(g.tokens >= g.admissionEstimate, "one RAW tile can ship immediately")
        #expect(g.tokens <= 37_500 / 2, "the burst is under half a second at 0.3 Mbit/s")
        g.refill(nowUS: 1_000_000, limit: .auto)
        g.refill(nowUS: 5_000_000, limit: .auto)
        #expect(g.tokens <= 37_500 / 2, "waiting for the first capture must not restore a LAN burst")
    }

    @Test func firstCongestedAckDoesNotDefineAHealthyPath() {
        var g = SendGovernor()
        g.start(roundTripUS: 175_000, nowUS: 175_000)
        let before = g.autoRate
        g.notePathDelay(700_000, nowUS: 1_000_000)
        g.noteDeferred()
        g.adapt(nowUS: 1_000_000, ceiling: G.maxAutoRate)
        #expect(g.queueDelayUS > G.queueSevereUS)
        #expect(g.autoRate < before && !g.slowStart, "the handshake predates this queue")
    }

    @Test func growthWaitsForTheLongPathsFeedback() {
        var g = SendGovernor()
        g.start(roundTripUS: 700_000, nowUS: 700_000)
        g.notePathDelay(700_000, nowUS: 1_400_000)
        g.noteDeferred()
        g.adapt(nowUS: 1_400_000, ceiling: G.maxAutoRate)
        let after = g.autoRate
        for now in stride(from: UInt64(1_600_000), through: 2_000_000, by: 200_000) {
            g.notePathDelay(700_000, nowUS: now)
            g.noteDeferred()
            g.adapt(nowUS: now, ceiling: G.maxAutoRate)
            #expect(g.autoRate == after, "do not grow several times within one RTT")
        }
        g.notePathDelay(700_000, nowUS: 2_100_000)
        g.noteDeferred()
        g.adapt(nowUS: 2_100_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate > after, "a clean long path still probes upward")
    }

    @Test func aQuietGapExpiresOldCleanSamples() {
        var g = SendGovernor()
        g.notePathDelay(10_000, nowUS: 100_000)
        g.notePathDelay(510_000, nowUS: 1_000_000)
        g.noteDeferred()
        g.adapt(nowUS: 1_000_000, ceiling: G.maxAutoRate)
        #expect(g.queueDelayUS > G.queueSevereUS, "the clean sample is older than both recent windows")
        #expect(g.autoRate < G.initialAutoRate, "back off on the new queue instead of growing")
    }

    @Test func theBaselineCanStillLearnAHigherRTTRoute() {
        var g = SendGovernor()
        g.start(roundTripUS: 175_000, nowUS: 175_000)
        for step in 1...120 {
            g.notePathDelay(700_000, nowUS: 1_000_000 + UInt64(step) * 250_000)
        }
        #expect(g.queueDelayUS < G.queueHealthyUS, "pinning the baseline forever mistakes a route change for a queue")
    }

    @Test func backoffHoldsGrowthToo() {
        var g = SendGovernor()
        sample(&g, queueUS: 100_000, at: 1_000_000)
        g.adapt(nowUS: 1_000_000, ceiling: G.maxAutoRate)
        let after = g.autoRate
        g.notePathDelay(10_000, nowUS: 1_100_000)
        g.noteDeferred()
        g.adapt(nowUS: 1_100_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate == after, "a clean ACK cannot immediately undo the cut")
        g.notePathDelay(10_000, nowUS: 1_500_000)
        g.noteDeferred()
        g.adapt(nowUS: 1_500_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate > after)
    }

    @Test func autoGrowsOnlyWhileLimitingOnAnUnqueuedPath() {
        var g = SendGovernor()
        sample(&g, queueUS: 0, at: 100_000)
        g.adapt(nowUS: 100_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate == G.initialAutoRate, "not limiting: hold")
        sample(&g, queueUS: 0, at: 300_000)
        g.noteDeferred()
        g.adapt(nowUS: 300_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate == Int(Double(G.initialAutoRate) * G.slowStartFactor), "slow start doubles")
        sample(&g, queueUS: 0, at: 400_000)
        g.noteDeferred()
        g.adapt(nowUS: 400_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate == Int(Double(G.initialAutoRate) * G.slowStartFactor),
                "one growth step per \(G.growthIntervalUS) µs — the queue sensor's lag")
        sample(&g, queueUS: 0, at: 600_000)
        g.noteDeferred()
        g.adapt(nowUS: 600_000, ceiling: 5_000_000)
        #expect(g.autoRate == 5_000_000, "never above the transport's pace")
    }

    @Test func slowStartEndsAtTheFirstBackoff() {
        var g = SendGovernor()
        var t: UInt64 = 0
        for _ in 0..<3 { // 2 → 4 → 8 → 16 MB/s
            t += G.growthIntervalUS
            sample(&g, queueUS: 0, at: t)
            g.noteDeferred()
            g.adapt(nowUS: t, ceiling: G.maxAutoRate)
        }
        #expect(g.autoRate == 16_000_000 && g.slowStart)
        t += G.growthIntervalUS
        sample(&g, queueUS: 100_000, at: t) // a building queue
        g.adapt(nowUS: t, ceiling: G.maxAutoRate)
        #expect(!g.slowStart)
        let after = g.autoRate
        t += G.baselineWindowUS * 3 // a fresh, clean path
        sample(&g, queueUS: 0, at: t)
        g.noteDeferred()
        g.adapt(nowUS: t, ceiling: G.maxAutoRate)
        #expect(g.autoRate == Int(Double(after) * G.growthFactor), "then ×1.25, not ×2")
    }

    @Test func aBuildingQueueDrainsToTheDeliveryRate() {
        var g = SendGovernor()
        var t: UInt64 = 0
        while g.autoRate < 40_000_000 { // climb first: limiting on a clean path
            t += 30_000
            sample(&g, queueUS: 0, at: t)
            g.noteDeferred()
            g.adapt(nowUS: t, ceiling: G.maxAutoRate)
        }
        for i in 0...16 { // the bottleneck delivers 20 MB/s
            g.noteDelivered(500_000, nowUS: t + UInt64(i) * 25_000)
        }
        let delivered = g.deliveryRate ?? 0
        #expect(abs(delivered - 20_000_000) < 1_000_000, "delivery rate \(delivered)")
        t += 500_000
        sample(&g, queueUS: 100_000, at: t)
        g.noteDeferred() // limiting: delivery is the bottleneck's rate, not ours
        g.adapt(nowUS: t, ceiling: G.maxAutoRate)
        #expect(g.autoRate == Int(Double(delivered) * G.drainFactor), "drains to 0.9 × delivered")
    }

    @Test func severeQueueHalvesOncePerHoldAndTheFloorHolds() {
        var g = SendGovernor()
        sample(&g, queueUS: 500_000, at: 1_000_000)
        g.adapt(nowUS: 1_000_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate == G.initialAutoRate / 2)
        sample(&g, queueUS: 500_000, at: 1_100_000)
        g.adapt(nowUS: 1_100_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate == G.initialAutoRate / 2, "held: the queue it just cut for is still draining")
        var t: UInt64 = 1_100_000
        for _ in 0..<60 {
            t += 100_000
            sample(&g, queueUS: 500_000, at: t)
            g.adapt(nowUS: t, ceiling: G.maxAutoRate)
        }
        #expect(g.autoRate == G.minAutoRate, "down to the 256 kbps floor, no lower")
    }

    /// Once a deep queue outlasts the timeout, every batch "times out":
    /// loss is the signal left. Only batches sent after the last cut count.
    @Test func timeoutLossCutsOncePerFreshBatch() {
        var g = SendGovernor()
        g.noteTimeout(datagrams: 20, lost: 18, sentUS: 50_000, nowUS: 100_000)
        g.adapt(nowUS: 100_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate == G.initialAutoRate / 2 && g.lossCuts == 1)
        // Sent BEFORE that cut: describes the old rate — ignored.
        g.noteTimeout(datagrams: 20, lost: 18, sentUS: 90_000, nowUS: 700_000)
        g.adapt(nowUS: 700_000, ceiling: G.maxAutoRate)
        #expect(g.lossCuts == 1)
        // Small or mostly-delivered batches aren't loss events.
        g.noteTimeout(datagrams: 4, lost: 4, sentUS: 800_000, nowUS: 1_400_000)
        g.noteTimeout(datagrams: 20, lost: 5, sentUS: 800_000, nowUS: 1_400_000)
        g.adapt(nowUS: 1_400_000, ceiling: G.maxAutoRate)
        #expect(g.lossCuts == 1)
        // No growth for a second after a loss event.
        sample(&g, queueUS: 0, at: 1_500_000)
        g.noteDeferred()
        g.adapt(nowUS: 1_500_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate == G.initialAutoRate / 2)
    }

    @Test func encodeOverloadShrinksToTheOldBaseButNoFurther() {
        var g = SendGovernor(fastLinkStart: true) // starts above the 2.8 MB/s base
        for _ in 0..<8 { g.noteEncode(durationUS: 15_000, intervalUS: 16_000) } // ~94 % duty
        var t: UInt64 = 0
        for _ in 0..<40 {
            t += 30_000
            g.adapt(nowUS: t, ceiling: G.maxAutoRate) // no path sample needed
        }
        #expect(g.autoRate == G.encodeBoundFloor)
    }

    @Test func midDutyBlocksGrowthLowDutyAllowsIt() {
        var g = SendGovernor()
        for _ in 0..<16 { g.noteEncode(durationUS: 10_000, intervalUS: 16_000) } // ~62 %
        sample(&g, queueUS: 0, at: 300_000)
        g.noteDeferred()
        g.adapt(nowUS: 300_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate == G.initialAutoRate, "no headroom: hold")
        for _ in 0..<32 { g.noteEncode(durationUS: 2_000, intervalUS: 16_000) } // ~12 %
        sample(&g, queueUS: 0, at: 700_000)
        g.noteDeferred()
        g.adapt(nowUS: 700_000, ceiling: G.maxAutoRate)
        #expect(g.autoRate > G.initialAutoRate, "headroom: grow")
    }

    @Test func limitCapsTheAutoRate() {
        let g = SendGovernor(fastLinkStart: true) // 8.4 MB/s: above the 25 Mbit cap
        #expect(g.rate(.auto) == G.fastStartRate)
        #expect(g.rate(.megabits(25)) == 3_125_000)
        #expect(g.rate(.capped(bytesPerSecond: 100_000_000)) == G.fastStartRate, "a cap is a ceiling, not a target")
    }

    /// The bucket is a quarter-second of the rate: idle time never banks a
    /// burst the link can't take (16 MB at 2 Mbps would be a minute of
    /// queue).
    @Test func bucketIsAQuarterSecondOfTheRate() {
        var g = SendGovernor()
        #expect(g.tokens == Int(Double(G.initialAutoRate) * G.bucketSeconds))
        g.settle(batchBytes: g.tokens, tilesSent: 1)
        #expect(g.tokens == 0)
        g.refill(nowUS: 1_000_000, limit: .auto)
        g.refill(nowUS: 11_000_000, limit: .auto) // 10 s idle
        #expect(g.tokens == g.bucketCapacity(.auto))
        #expect(g.bucketCapacity(.auto) == 500_000)
        for i in 0..<60 { // severe queue → floor rate → floor bucket
            sample(&g, queueUS: 500_000, at: 20_000_000 + UInt64(i) * 500_000)
            g.adapt(nowUS: 20_000_000 + UInt64(i) * 500_000, ceiling: G.maxAutoRate)
        }
        #expect(g.bucketCapacity(.auto) == G.minBucket)
    }

    @Test func refillIsCappedAtTwoSecondsAndTheBucket() {
        var g = SendGovernor(fastLinkStart: true) // the fixed 16 MB bucket
        g.settle(batchBytes: G.bucketCap, tilesSent: 1) // drain
        #expect(g.tokens == 0)
        let limit = RateLimit.megabits(25)
        g.refill(nowUS: 1_000_000, limit: limit)          // first call only anchors
        #expect(g.tokens == 0)
        g.refill(nowUS: 11_000_000, limit: limit)         // 10 s idle → at most 2 s of refill
        #expect(g.tokens == 2 * 3_125_000)
        for t in 2...20 { g.refill(nowUS: 11_000_000 + UInt64(t) * 2_000_000, limit: limit) }
        #expect(g.tokens == G.bucketCap)
    }

    @Test func debtIsBoundedAndTheEstimateLearns() {
        var g = SendGovernor()
        g.settle(batchBytes: 10 * G.bucketCap, tilesSent: 0)
        #expect(g.tokens == -G.bucketCap, "debt is bounded")
        let before = g.admissionEstimate
        for _ in 0..<50 { g.settle(batchBytes: 1_000 * 100, tilesSent: 1_000) } // 100 B per tile
        #expect(g.admissionEstimate < before && g.admissionEstimate >= 256, "estimate tracks reality, floored")
    }
}
