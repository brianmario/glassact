import Testing
@testable import GlassActCore

@Suite struct SessionTelemetryTests {
    @Test func percentilesAndFormatting() {
        let s = LatencySummary((1...100).map { UInt64($0) * 1_000 })!
        #expect(s.count == 100 && s.p50US == 51_000 && s.p95US == 96_000 && s.p99US == 100_000 && s.maxUS == 100_000)
        #expect(s.fields("g2g") == "g2g_n=100 g2g_p50_ms=51.0 g2g_p95_ms=96.0 g2g_p99_ms=100.0 g2g_max_ms=100.0")
        #expect(LatencySummary([]) == nil)
        #expect(LatencySummary([1_234])!.fields("x").contains("x_p50_ms=1.2"))
    }

    @Test func intervalFieldsAreDeltas() {
        var a = ViewerStats()
        a.bytesIn = 1_000_000
        a.recordsApplied = 10
        var b = a
        b.bytesIn += 2_500_000 // 2.5 MB in 2 s = 10 Mbit/s
        b.recordsApplied += 7
        b.videoFramesApplied = 120
        let line = b.intervalFields(since: a, seconds: 2)
        #expect(line.hasPrefix("rx_mbps=10.0 rx_bytes=2500000"))
        #expect(line.contains("records_applied=7") && line.contains("video_frames=120") && line.contains("malformed=0"))
    }
}
