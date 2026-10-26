import Testing
import GlassActCore

/// VideoRateController: the video send gate is time at the measured drain
/// rate, not bytes; the network-queue signal backs it off; an idle screen
/// does not inflate it.
@Suite struct VideoRateControllerTests {
    /// Drives a sender at `offered` B/s into a link draining `link` B/s for
    /// `seconds`, frames of `frameBytes` at 60 Hz, submitting only when the
    /// gate allows. Returns (controller, worst backlog in link-seconds).
    private func simulate(offered: Int, link: Int, frameBytes: Int, seconds: Double,
                          queueUS: (Int) -> UInt64? = { _ in 0 }) -> (VideoRateController, Double) {
        var c = VideoRateController()
        var backlog = 0
        var worst = 0.0
        let tickUS: UInt64 = 16_667
        var now: UInt64 = 1_000_000
        let ticks = Int(seconds * 60)
        let offeredPerTick = offered / 60
        var credit = 0
        for t in 0..<ticks {
            now += tickUS
            backlog = max(0, backlog - link / 60)
            c.observe(nowUS: now, backlogBytes: backlog, networkQueueUS: queueUS(t))
            credit += offeredPerTick
            if credit >= frameBytes, c.allowsFrame(backlogBytes: backlog) {
                credit -= frameBytes
                backlog += frameBytes
                c.noteHanded(frameBytes)
            } else if credit >= frameBytes {
                credit = 0 // newest-wins: the skipped frame is superseded
            }
            if t > 120 { worst = max(worst, Double(backlog) / Double(link)) } // steady state
        }
        return (c, worst)
    }

    @Test func thinLinkQueueStaysNearTarget() {
        // A remote session on a thin link: ~10 Mbps of HEVC offered into a
        // 2.5 Mbps link.
        let (c, worst) = simulate(offered: 1_250_000, link: 312_500, frameBytes: 20_000, seconds: 10)
        #expect(c.rate > 250_000 && c.rate < 400_000, "rate \(c.rate)")
        // ≤ target + one frame of queueing, never the 1.6 s a byte gate allows.
        #expect(worst < 0.2, "worst backlog \(worst) s")
        #expect(c.bitrateCap! < 2_500_000, "cap \(c.bitrateCap!) bps")
    }

    @Test func fastLinkIsNotThrottled() {
        let (c, worst) = simulate(offered: 1_250_000, link: 12_500_000, frameBytes: 20_000, seconds: 10)
        #expect(worst < 0.01)
        // App-limited: the estimate climbs past what's offered (probe), so
        // the encoder cap never binds below the offered 10 Mbps.
        #expect(c.bitrateCap ?? .max >= 10_000_000, "cap \(String(describing: c.bitrateCap))")
    }

    @Test func networkQueueBacksOffOncePerHold() {
        // Link measured at 2.5 Mbps, then the network reports a standing
        // queue: back off, but no faster than once per hold period.
        var (c, _) = simulate(offered: 1_250_000, link: 312_500, frameBytes: 20_000, seconds: 5)
        let before = c.rate
        var now: UInt64 = 100_000_000
        for _ in 0..<8 { // 2 s of 250 ms windows at 200 ms queue
            now += VideoRateController.windowUS
            c.observe(nowUS: now, backlogBytes: 1000, networkQueueUS: 200_000)
        }
        #expect(c.rate < before)
        #expect(c.backoffs <= 5, "backoffs \(c.backoffs) in 2 s (hold 500 ms)")
    }

    /// The smoothed queue lags a burst that already drained: a fresh PING
    /// reading of an empty queue stops the cuts it would keep making.
    @Test func aFreshEmptyQueueStopsTheCuts() {
        var (c, _) = simulate(offered: 1_250_000, link: 312_500, frameBytes: 20_000, seconds: 5)
        let backoffs = c.backoffs
        var now: UInt64 = 100_000_000
        for _ in 0..<8 {
            now += VideoRateController.windowUS
            c.observe(nowUS: now, backlogBytes: 1000, networkQueueUS: 200_000, freshQueueUS: 5_000)
        }
        #expect(c.backoffs == backoffs)
    }

    /// …but never lets it grow: one PING can land between bursts while the
    /// link fills, so growth waits for the smoothed queue to clear.
    @Test func aFreshEmptyQueueDoesntGrowIt() {
        var (c, _) = simulate(offered: 1_250_000, link: 312_500, frameBytes: 20_000, seconds: 5)
        let before = c.rate
        var now: UInt64 = 100_000_000
        for _ in 0..<8 { // carrying all of the rate, smoothed queue 45 ms
            now += VideoRateController.windowUS
            c.noteHanded(before / 4)
            c.observe(nowUS: now, backlogBytes: 0, networkQueueUS: 45_000, freshQueueUS: 0)
        }
        #expect(c.rate == before)
    }

    /// What the viewer received caps the estimate, and the startup ramp.
    @Test func linkCapacityCapsTheRate() {
        var (c, _) = simulate(offered: 1_250_000, link: 12_500_000, frameBytes: 20_000, seconds: 3)
        var now: UInt64 = 100_000_000
        for _ in 0..<4 {
            now += VideoRateController.windowUS
            c.observe(nowUS: now, backlogBytes: 0, networkQueueUS: 0, linkCapacity: 500_000)
        }
        if c.rate > 0 {
            #expect(c.rate <= 450_000, "rate \(c.rate)")
        } else {
            #expect(c.startupCap ?? .max <= 3_600_000, "startup cap \(String(describing: c.startupCap))")
        }
    }

    @Test func idleScreenDoesNotInflateTheEstimate() {
        var (c, _) = simulate(offered: 1_250_000, link: 312_500, frameBytes: 20_000, seconds: 5)
        let measured = c.rate
        var now: UInt64 = 100_000_000
        for _ in 0..<40 { // 10 s of static screen
            now += VideoRateController.windowUS
            c.observe(nowUS: now, backlogBytes: 0, networkQueueUS: 0)
        }
        #expect(c.rate == measured)
    }

    @Test func beforeMeasurementTheAllowanceIsSmall() {
        let c = VideoRateController()
        #expect(c.bitrateCap == VideoRateController.startupCapBps)
        #expect(c.allowsFrame(backlogBytes: 60_000))
        #expect(!c.allowsFrame(backlogBytes: 70_000))
    }
}

/// Startup: the encoder starts at 3 Mbps, not its 20 Mbps base, and ramps
/// only on a clean path that is actually carrying the cap (an uncapped start
/// puts a tether's first picture ~1.5 s behind capture).
@Suite struct VideoStartupTests {
    /// 60 Hz, frames sized to the current cap when `busy`, into a link of
    /// `link` B/s whose queue is visible as network queue.
    private func run(seconds: Double, link: Double, busy: Bool = true)
        -> (VideoRateController, [(t: Double, cap: Int?)], worstQueueS: Double) {
        var c = VideoRateController()
        var backlog = 0.0, worst = 0.0
        var now: UInt64 = 1_000_000
        var trace: [(Double, Int?)] = []
        for i in 0..<Int(seconds * 60) {
            let t = Double(i) / 60
            now += 16_667
            backlog = max(0, backlog - link / 60)
            c.observe(nowUS: now, backlogBytes: Int(backlog), networkQueueUS: UInt64(backlog / link * 1_000_000))
            if c.allowsFrame(backlogBytes: Int(backlog)) {
                let cap = c.bitrateCap ?? 20_000_000
                let frame = busy ? cap / 8 / 60 : 200
                backlog += Double(frame)
                c.noteHanded(frame)
            }
            worst = max(worst, backlog / link)
            trace.append((t, c.bitrateCap))
        }
        return (c, trace, worst)
    }

    @Test func startsAtThreeMegabits() {
        #expect(VideoRateController().bitrateCap == 3_000_000)
    }

    @Test func aFastLinkRampsToUncappedInSeconds() {
        let (c, trace, _) = run(seconds: 5, link: 12_500_000) // 100 Mbps
        let uncapped = trace.first { $0.cap == nil }
        #expect(uncapped != nil && uncapped!.t < 3, "uncapped at \(uncapped.map { String($0.t) } ?? "never") s")
        #expect(c.rate == 0 && c.bitrateCap == nil) // a LAN is never throttled
    }

    @Test func aStaticScreenDoesNotRamp() {
        let (c, _, _) = run(seconds: 5, link: 12_500_000, busy: false)
        #expect(c.bitrateCap == VideoRateController.startupCapBps)
    }

    @Test func aQueueAtAQuietStartKeepsAUsableCap() {
        // A connect can see a 200 ms queue while video sends ~27 KB/s; a cut
        // from that sample alone would hit the 0.3 Mbit/s floor.
        var c = VideoRateController()
        var now: UInt64 = 1_000_000
        for _ in 0..<120 {
            now += 16_667
            c.noteHanded(450)
            c.observe(nowUS: now, backlogBytes: 0, networkQueueUS: 200_000)
        }
        #expect(c.rate > 0, "a standing queue must cap")
        #expect(c.bitrateCap! >= 1_000_000, "cap \(c.bitrateCap!) bps")
    }

    @Test func aThinLinkIsCaughtBeforeTheQueueGrows() {
        // 6 Mbps tether: the ramp overshoots it once (to ~9 Mbps at 1.25 s),
        // the pushback measures it, and the cap rides the controller's
        // normal saw-tooth around the link (5.6–6.3 Mbps).
        let (c, trace, worst) = run(seconds: 10, link: 750_000)
        #expect(c.rate > 0, "never measured")
        let late = trace.filter { $0.t > 6 }.compactMap(\.cap)
        #expect(!late.isEmpty && late.allSatisfy { $0 < 6_600_000 }, "late caps \(late.max() ?? 0)")
        #expect(worst < 0.2, "worst queue \(worst) s")
    }
}

/// The network-queue signal: jitter-filtered, and able to act before the
/// link is measured (e.g. a 150 ms tether: `vlink unmeasured`, 80–100 ms
/// standing queue, video uncapped).
@Suite struct VideoQueueSignalTests {
    /// 60 Hz ticks for `seconds`, sending `perTick` bytes (never backlogged).
    private func drive(_ c: inout VideoRateController, from t0: UInt64, seconds: Double,
                       perTick: Int, queue: (Int) -> UInt64) -> UInt64 {
        var now = t0
        for i in 0..<Int(seconds * 60) {
            now += 16_667
            c.noteHanded(perTick)
            c.observe(nowUS: now, backlogBytes: 0, networkQueueUS: queue(i))
        }
        return now
    }

    @Test func aStandingQueueCapsAnUnmeasuredLink() {
        var c = VideoRateController()
        _ = drive(&c, from: 1_000_000, seconds: 3, perTick: 6_250, queue: { _ in 100_000 }) // 3 Mbps, 100 ms queue
        #expect(c.rate > 0 && c.rate < 375_000, "rate \(c.rate) B/s from a 375 KB/s send")
        #expect(c.bitrateCap != nil)
    }

    @Test func jitterAloneNeverCapsIt() {
        var c = VideoRateController()
        // Cellular-style: most readings clean, spikes to 250 ms.
        _ = drive(&c, from: 1_000_000, seconds: 5, perTick: 6_250, queue: { $0 % 7 == 0 ? 250_000 : 5_000 })
        #expect(c.rate == 0, "jitter read as a queue: rate \(c.rate)")
    }

    @Test func noQueueNoCap() {
        var c = VideoRateController()
        _ = drive(&c, from: 1_000_000, seconds: 3, perTick: 6_250, queue: { _ in 10_000 })
        #expect(c.rate == 0)
    }
}

/// Recovery after a brief hiccup (without it, a two-second network stall on
/// a ~3 Mbit/s path leaves the cap stuck at 0.3 Mbit/s for ~60 s).
@Suite struct VideoRecoveryTests {
    /// 60 Hz encoder offering 10 Mbit/s (frames shrink to the cap) into a
    /// link whose rate follows `link(t)`; the queue sits in the path, so
    /// the controller sees it both as backlog and as network queue.
    private func run(seconds: Double, link: (Double) -> Int) -> [(t: Double, rate: Int)] {
        var c = VideoRateController()
        var backlog = 0.0
        var now: UInt64 = 1_000_000
        var trace: [(Double, Int)] = []
        for i in 0..<Int(seconds * 60) {
            let t = Double(i) / 60
            now += 16_667
            let l = Double(link(t))
            backlog = max(0, backlog - l / 60)
            let queueUS = UInt64(backlog / l * 1_000_000)
            c.observe(nowUS: now, backlogBytes: Int(backlog), networkQueueUS: queueUS)
            if c.allowsFrame(backlogBytes: Int(backlog)) {
                let frame = c.bitrateCap.map { min(20_000, max(1_000, $0 / 8 / 60)) } ?? 20_000
                backlog += Double(frame)
                c.noteHanded(frame)
            }
            trace.append((t, c.rate))
        }
        return trace
    }

    @Test func aBriefHiccupRecoversInSeconds() {
        let trace = run(seconds: 20) { $0 >= 5 && $0 < 7 ? 37_500 : 375_000 } // 3 Mbps, 0.3 for 2 s
        let before = trace.last { $0.t < 5 }!.rate
        let low = trace.filter { $0.t >= 5 && $0.t < 8 }.map(\.rate).min()!
        #expect(low < before / 2, "the hiccup must cut the rate (before \(before), low \(low))")
        let back = trace.first { $0.t >= 7 && $0.rate >= before * 7 / 10 }
        #expect(back != nil && back!.t < 11, "recovered at \(back.map { String($0.t) } ?? "never") s (hiccup ended at 7 s; before \(before) B/s)")
    }

    @Test func aLinkThatReallySlowedIsNotOverProbed() {
        // 3 Mbps, then permanently 1 Mbps: after settling, the rate stays
        // near the new link instead of re-climbing to the old one.
        let trace = run(seconds: 30) { $0 >= 5 ? 125_000 : 375_000 }
        let late = trace.filter { $0.t > 20 }.map(\.rate)
        let mean = late.reduce(0, +) / late.count
        #expect(mean < 180_000, "late mean \(mean) B/s on a 125 KB/s link")
    }
}
