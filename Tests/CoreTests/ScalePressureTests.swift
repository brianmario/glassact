import Testing
@testable import GlassActCore

/// §4.9 resolution rung: which seconds of evidence add up to "constrained".
/// The video rule runs against the real `VideoRateController` over a
/// simulated link, as the engine wires them: only a window in which video
/// stayed backlogged is evidence about the link.
@Suite struct ScalePressureTests {
    static let severe: UInt64 = 700_000
    static let capture = 2900 * 1572 // a laptop Viewer's window

    /// Video at `offered` B/s into a link draining `link` B/s (60 Hz frames,
    /// submitted only when the gate allows), evaluated once a second.
    final class Rig {
        var c = VideoRateController()
        var p = ScalePressure()
        var backlog = 0
        var now: UInt64 = 1_000_000
        var second = 0
        let pixels: Int
        init(pixels: Int = ScalePressureTests.capture) { self.pixels = pixels }

        /// The second (counting from the rig's start) it fired, or nil.
        @discardableResult
        func run(seconds: Int, offered: Int, link: Int, frameBytes: Int = 20_000,
                 queueUS: UInt64 = 0) -> Int? {
            var credit = 0
            var fired: Int?
            for _ in 0..<seconds {
                for _ in 0..<60 {
                    now += 16_667
                    backlog = max(0, backlog - link / 60)
                    c.observe(nowUS: now, backlogBytes: backlog, networkQueueUS: queueUS)
                    credit += offered / 60
                    if credit >= frameBytes {
                        credit -= frameBytes
                        if c.allowsFrame(backlogBytes: backlog) {
                            backlog += frameBytes
                            c.noteHanded(frameBytes)
                        }
                    }
                }
                second += 1
                if p.noteSecond(ackSampleUS: 0, ackDelayUS: 0, severeAckDelayUS: ScalePressureTests.severe,
                                videoLinkMeasurements: c.linkMeasurements, videoRateBytesPerSecond: c.rate,
                                videoLastDrainBytesPerSecond: c.lastLinkDrain, pixels: pixels) {
                    fired = second
                }
            }
            return fired
        }
    }

    /// The viewer's reports: a link whose queued spans carry 0.3 Mbit/s (an
    /// airport lounge) fires after `thinVideoSeconds` of readings, even with
    /// no video backlog measurement at all; seconds without a reading hold
    /// the streak, and a roomy reading resets it.
    @Test func aThinReportedLinkFires() {
        func second(_ p: inout ScalePressure, capacity: Int) -> Bool {
            p.noteSecond(ackSampleUS: 0, ackDelayUS: 0, severeAckDelayUS: Self.severe,
                         videoLinkMeasurements: 0, videoRateBytesPerSecond: 0, videoLastDrainBytesPerSecond: 0,
                         linkCapacityBytesPerSecond: capacity, pixels: Self.capture)
        }
        let thin = 300_000 / 8, roomy = 20_000_000 / 8
        var p = ScalePressure()
        let fired = (0..<ScalePressure.thinVideoSeconds).map { _ in second(&p, capacity: thin) }
        #expect(fired == Array(repeating: false, count: ScalePressure.thinVideoSeconds - 1) + [true])

        var q = ScalePressure()
        for _ in 0..<(ScalePressure.thinVideoSeconds - 1) { _ = second(&q, capacity: thin) }
        _ = second(&q, capacity: 0) // no reading: holds
        let completed = second(&q, capacity: thin)
        #expect(completed, "the held streak completes")

        var r = ScalePressure()
        for _ in 0..<(ScalePressure.thinVideoSeconds - 1) { _ = second(&r, capacity: thin) }
        _ = second(&r, capacity: roomy) // resets
        let afterReset = second(&r, capacity: thin)
        #expect(!afterReset)
    }

    /// What the engine hands the rule: a stall right after a fast stretch
    /// (data queued, almost nothing arriving) isn't a thin link, because the
    /// link just delivered more; a link that stays thin still reads thin.
    @Test func aStallAfterAFastStretchIsntThin() {
        func evidence(fast: Bool) -> Int {
            let (host, _) = makeRunningHost(width: 256, height: 192)
            var bytes: UInt64 = 0, t: UInt64 = 0
            func report(_ add: UInt64, queued: Bool) {
                t += 250_000
                bytes += add
                host.linkEstimate.noteReceived(bytes: bytes, viewerTUS: t, nowUS: t, queued: queued)
            }
            if fast {
                for _ in 0..<32 { report(5_400_000 / 8 / 4, queued: false) } // 8 s at 5.4 Mbit/s
                for _ in 0..<20 { report(100, queued: true) }                // a 5 s stall
            } else {
                for _ in 0..<52 { report(300_000 / 8 / 4, queued: true) }    // 13 s at 0.3 Mbit/s
            }
            return host.thinLinkEvidence(nowUS: t)
        }
        #expect(evidence(fast: true) * 8 >= 5_000_000, "the link just delivered 5.4 Mbit/s")
        #expect(evidence(fast: false) * 8 < 400_000, "a link that stays thin")
    }

    /// Back up the rung (`ScaleRecovery`): after the hold, 30 seconds in
    /// which the path wasn't queued and the link's capacity was unmeasured
    /// or room for the full capture. A queued second, or a capacity short
    /// of room, restarts the count.
    @Test func theFullCaptureIsTriedAgainAfterTheHold() {
        let full = Self.capture // 2900×1572: thin under 3.4 Mbit/s, room at 6.8
        let roomy = 7_000_000 / 8, short = 2_000_000 / 8
        // A quiet screen that never queued (no capacity reading): the hold
        // sets the time.
        var r = ScaleRecovery(fullPixels: full, holdUS: 60_000_000)
        var fired: Int?
        for s in 1...90 where fired == nil {
            if r.noteSecond(nowUS: UInt64(s) * 1_000_000, linkCapacityBytesPerSecond: 0, queued: false) { fired = s }
        }
        #expect(fired == 61, "the hold, not the 30 s, set the time: \(String(describing: fired))")

        var t: UInt64 = 0
        func run(_ r: inout ScaleRecovery, _ capacity: Int, queued: Bool = false) -> Bool {
            t += 1_000_000
            return r.noteSecond(nowUS: t, linkCapacityBytesPerSecond: capacity, queued: queued)
        }
        for (name, capacity, queued) in [("queued", 0, true), ("short of room", short, false)] {
            var q = ScaleRecovery(fullPixels: full, holdUS: 0)
            for _ in 0..<29 { _ = run(&q, roomy) }
            _ = run(&q, capacity, queued: queued) // starts over
            var early = false
            for _ in 0..<29 { early = early || run(&q, 0) }
            #expect(!early, "a second \(name) restarts the 30")
            #expect(run(&q, 0))
        }

        // Plane Wi-Fi: every reading short of room, so it never tries.
        var plane = ScaleRecovery(fullPixels: full, holdUS: 0)
        var tried = false
        for _ in 0..<300 { tried = tried || run(&plane, short) }
        #expect(!tried)
    }

    /// The engine reports it once, from the viewer's reports.
    @Test func theEngineTriesTheFullCaptureAgain() {
        let (host, _) = makeRunningHost(width: 256, height: 192)
        var reports = 0
        host.onLinkRoomForFullResolution = { reports += 1 }
        host.armScaleRecovery(fullPixels: Self.capture, holdUS: 5_000_000)
        var bytes: UInt64 = 0, t: UInt64 = 1_000_000
        for _ in 0..<(45 * 4) { // 45 s of a quiet 0.5 Mbit/s, 250 ms reports, no queue
            t += 250_000
            bytes += 500_000 / 8 / 4
            host.linkEstimate.noteReceived(bytes: bytes, viewerTUS: t, nowUS: t, queued: false)
            host.tick(nowUS: t)
        }
        #expect(reports == 1)
        #expect(host.scaleReason.contains("capacity unmeasured"), "\(host.scaleReason)")
    }

    /// The log says which evidence moved the rung.
    @Test func itSaysWhichRuleFired() {
        var p = ScalePressure()
        for _ in 0..<ScalePressure.thinVideoSeconds {
            _ = p.noteSecond(ackSampleUS: 0, ackDelayUS: 0, severeAckDelayUS: Self.severe,
                             videoLinkMeasurements: 0, videoRateBytesPerSecond: 0, videoLastDrainBytesPerSecond: 0,
                             linkCapacityBytesPerSecond: 300_000 / 8, pixels: Self.capture)
        }
        #expect(p.constrained && p.firedBy == .thinLink)
    }

    /// A link that queued at 2 Mbit/s in the last minute stays halved.
    @Test func theEngineKeepsAThinLinkHalved() {
        let (host, _) = makeRunningHost(width: 256, height: 192)
        var reports = 0
        host.onLinkRoomForFullResolution = { reports += 1 }
        host.armScaleRecovery(fullPixels: Self.capture, holdUS: 5_000_000)
        var bytes: UInt64 = 0, t: UInt64 = 1_000_000
        for i in 0..<(90 * 4) { // a 2 s queued burst at 2 Mbit/s every 20 s
            t += 250_000
            let burst = i % 80 < 8
            bytes += (burst ? 2_000_000 : 200_000) / 8 / 4
            host.linkEstimate.noteReceived(bytes: bytes, viewerTUS: t, nowUS: t, queued: burst)
            host.tick(nowUS: t)
        }
        #expect(reports == 0)
    }

    /// 4 Mbit/s and over is never thin, whatever the capture: halving a 5K
    /// capture on ordinary home Wi-Fi is the person's call.
    @Test func aReportedLinkAboveTheCeilingNeverFires() {
        var p = ScalePressure()
        var fired = false
        for _ in 0..<30 {
            fired = fired || p.noteSecond(ackSampleUS: 0, ackDelayUS: 0, severeAckDelayUS: Self.severe,
                                          videoLinkMeasurements: 0, videoRateBytesPerSecond: 0,
                                          videoLastDrainBytesPerSecond: 0, linkCapacityBytesPerSecond: 5_000_000 / 8,
                                          pixels: 5120 * 2880)
        }
        #expect(!fired)
    }

    /// Plane Wi-Fi: video backed up behind a 2 Mbit/s link fires within
    /// seconds, not 45 s later, and once.
    @Test func aThinVideoLinkFires() {
        let rig = Rig()
        let fired = rig.run(seconds: 15, offered: 1_000_000, link: 250_000)
        #expect(fired != nil && fired! <= 10, "fired at \(fired.map(String.init) ?? "never")")
        #expect(rig.run(seconds: 10, offered: 1_000_000, link: 250_000) == nil, "latched")
    }

    /// Busy video on a fast link never backs up long enough to read as thin.
    @Test func aFastLinkNeverFires() {
        let rig = Rig()
        #expect(rig.run(seconds: 30, offered: 2_000_000, link: 12_500_000) == nil)
    }

    /// 5K on 10 Mbit/s home Wi-Fi is under 0.75 bit/s per pixel but not a
    /// thin link: it keeps native resolution.
    @Test func ordinaryWiFiKeepsAFiveKCapture() {
        let rig = Rig(pixels: 5120 * 2880)
        #expect(rig.run(seconds: 30, offered: 3_000_000, link: 1_250_000) == nil)
    }

    /// A queue at a quiet connect sets the controller's estimate by a
    /// backoff from the startup cap, with nothing backlogged. That's no
    /// evidence about the link, and once the queue clears a light workload
    /// never raises the estimate: it must not shrink the capture.
    @Test func aBackoffWithoutBacklogIsNotEvidence() {
        let rig = Rig()
        rig.run(seconds: 2, offered: 27_000, link: 12_500_000, frameBytes: 450, queueUS: 200_000)
        #expect(rig.c.rate > 0 && rig.c.linkMeasurements == 0)
        #expect(rig.run(seconds: 30, offered: 27_000, link: 12_500_000, frameBytes: 450) == nil)
    }

    /// Seconds without a fresh measurement (a paused or quiet region) hold
    /// the streak; they don't count toward it.
    @Test func staleSecondsHold() {
        let rig = Rig()
        #expect(rig.run(seconds: 3, offered: 1_000_000, link: 250_000) == nil)
        #expect(rig.run(seconds: 30, offered: 0, link: 250_000) == nil, "paused: no new measurements")
        #expect(rig.run(seconds: 10, offered: 1_000_000, link: 250_000) != nil)
    }

    /// The ACK-delay rule counts only fresh samples.
    @Test func severeAckDelayCountsFreshSamplesOnly() {
        var p = ScalePressure()
        func ack(_ sample: UInt64, _ delay: UInt64) -> Bool {
            p.noteSecond(ackSampleUS: sample, ackDelayUS: delay, severeAckDelayUS: Self.severe,
                         videoLinkMeasurements: 0, videoRateBytesPerSecond: 0,
                         videoLastDrainBytesPerSecond: 0, pixels: Self.capture)
        }
        for s in 1...5 { #expect(!ack(UInt64(s), 900_000)) }
        for _ in 0..<10 { #expect(!ack(5, 900_000), "a stale sample doesn't count") }
        #expect(ack(6, 900_000))
    }
}
