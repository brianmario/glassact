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
