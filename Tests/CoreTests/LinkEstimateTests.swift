import Testing
@testable import GlassActCore

/// The link's delivered rate from the viewer's RECEIVED reports (§4.9).
@Suite struct LinkEstimateTests {
    /// Reports every 250 ms of `bytesPerReport` each, from viewer time `t0`.
    private func feed(_ e: inout LinkEstimate, from t0: UInt64, reports: Int, bytesPerReport: [UInt64],
                      startBytes: UInt64 = 0, queued: Bool = true) -> (UInt64, UInt64) {
        var bytes = startBytes, t = t0
        for i in 0..<reports {
            t += 250_000
            bytes += bytesPerReport[i % bytesPerReport.count]
            e.noteReceived(bytes: bytes, viewerTUS: t, nowUS: t, queued: queued)
        }
        return (bytes, t)
    }

    @Test func aSteadyLinkReadsItsRate() {
        var e = LinkEstimate()
        let (_, t) = feed(&e, from: 0, reports: 20, bytesPerReport: [62_500]) // 2 Mbit/s
        #expect(e.deliveredBytesPerSecond(nowUS: t) == 250_000)
        #expect(e.capacityBytesPerSecond(nowUS: t) == 250_000)
    }

    /// A whole message landing in one 250 ms report (0, then 2×) reads as
    /// the link over the one-second span, not twice it.
    @Test func aBurstInOneReportDoesntDoubleIt() {
        var e = LinkEstimate()
        let (_, t) = feed(&e, from: 0, reports: 40, bytesPerReport: [0, 125_000])
        #expect(e.deliveredBytesPerSecond(nowUS: t) <= 250_000 * 5 / 4)
    }

    /// The short window forgets after 10 s; the capacity keeps a minute.
    @Test func windowsAgeOut() {
        var e = LinkEstimate()
        var (bytes, t) = feed(&e, from: 0, reports: 12, bytesPerReport: [125_000]) // 4 Mbit/s
        (bytes, t) = feed(&e, from: t, reports: 60, bytesPerReport: [2_500], startBytes: bytes) // a quiet 15 s
        #expect(e.deliveredBytesPerSecond(nowUS: t) < 50_000)
        #expect(e.capacityBytesPerSecond(nowUS: t) == 500_000)
        _ = feed(&e, from: t, reports: 260, bytesPerReport: [2_500], startBytes: bytes)
        #expect(e.capacityBytesPerSecond(nowUS: t + 260 * 250_000) < 50_000)
    }

    /// Delivery with no queue on the path is the sender's own rate, not the
    /// link's: it never sets the capacity, so a ceiling can't ratchet down
    /// on what it let through. A span needs a queue at both ends.
    @Test func onlyAQueuedPathSetsTheCapacity() {
        var e = LinkEstimate()
        var (bytes, t) = feed(&e, from: 0, reports: 20, bytesPerReport: [62_500], queued: false)
        #expect(e.deliveredBytesPerSecond(nowUS: t) == 250_000)
        #expect(e.capacityBytesPerSecond(nowUS: t) == 0)
        (bytes, t) = feed(&e, from: t, reports: 2, bytesPerReport: [62_500], startBytes: bytes)
        #expect(e.capacityBytesPerSecond(nowUS: t) == 0, "the span's base report wasn't queued")
        _ = feed(&e, from: t, reports: 4, bytesPerReport: [62_500], startBytes: bytes)
        #expect(e.capacityBytesPerSecond(nowUS: t + 4 * 250_000) == 250_000)
    }

    /// A reconnect restarts the viewer's counters: no negative or bogus rate.
    @Test func aNewSessionsCountersStartOver() {
        var e = LinkEstimate()
        let (_, t) = feed(&e, from: 0, reports: 8, bytesPerReport: [62_500])
        _ = feed(&e, from: 0, reports: 8, bytesPerReport: [62_500])
        #expect(e.deliveredBytesPerSecond(nowUS: t) == 250_000)
    }
}
