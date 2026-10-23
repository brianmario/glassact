import Testing
@testable import GlassActCore

/// §4.9 resolution rung: which seconds of evidence add up to "constrained".
@Suite struct ScalePressureTests {
    static let severe: UInt64 = 700_000
    static let capture = 2900 * 1572 // a laptop Viewer's window

    /// One second of video-only evidence (no new ACK-delay sample).
    func video(_ p: inout ScalePressure, mbit: Double, active: Bool = true, pixels: Int = capture) -> Bool {
        p.noteSecond(ackSampleUS: 0, ackDelayUS: 0, severeAckDelayUS: Self.severe, videoActive: active,
                     videoDrainBytesPerSecond: Int(mbit * 1_000_000 / 8), pixels: pixels)
    }

    /// The plane session: video draining at 0.3–2.3 Mbit/s for a 2900×1572
    /// capture fires after `thinVideoSeconds`, not 45 s later.
    @Test func thinVideoFiresAfterItsStreak() {
        var p = ScalePressure()
        let drains = [2.29, 1.13, 0.63, 0.34, 0.30]
        let fired = drains.map { video(&p, mbit: $0) }
        #expect(fired == [false, false, false, false, true])
        #expect(p.constrained)
        #expect(!video(&p, mbit: 0.3), "fires once, then latches")
    }

    @Test func aHealthySecondResetsTheStreak() {
        var p = ScalePressure()
        for _ in 0..<4 { #expect(!video(&p, mbit: 1)) }
        #expect(!video(&p, mbit: 6))
        for _ in 0..<4 { #expect(!video(&p, mbit: 1)) }
        #expect(video(&p, mbit: 1))
    }

    /// Seconds without video (or before the link is measured) prove nothing:
    /// they neither count nor reset.
    @Test func secondsWithoutAMeasuredVideoLinkHold() {
        var p = ScalePressure()
        for _ in 0..<3 { #expect(!video(&p, mbit: 1)) }
        #expect(!video(&p, mbit: 1, active: false))
        #expect(!video(&p, mbit: 0))
        #expect(!video(&p, mbit: 1))
        #expect(video(&p, mbit: 1))
    }

    /// 5K on 10 Mbit/s home Wi-Fi is under 0.75 bit/s per pixel but not a
    /// thin link: it keeps native resolution.
    @Test func ordinaryWiFiKeepsAFiveKCapture() {
        var p = ScalePressure()
        for _ in 0..<30 { #expect(!video(&p, mbit: 10, pixels: 5120 * 2880)) }
        // A small capture on a link that carries it easily.
        for _ in 0..<30 { #expect(!video(&p, mbit: 3, pixels: 1470 * 956)) }
    }

    /// The ACK-delay rule counts only fresh samples.
    @Test func severeAckDelayCountsFreshSamplesOnly() {
        var p = ScalePressure()
        func ack(_ sample: UInt64, _ delay: UInt64) -> Bool {
            p.noteSecond(ackSampleUS: sample, ackDelayUS: delay, severeAckDelayUS: Self.severe,
                         videoActive: false, videoDrainBytesPerSecond: 0, pixels: Self.capture)
        }
        for s in 1...5 { #expect(!ack(UInt64(s), 900_000)) }
        for _ in 0..<10 { #expect(!ack(5, 900_000), "a stale sample doesn't count") }
        #expect(ack(6, 900_000))
    }
}
