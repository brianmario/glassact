/// Session-log formatting shared by the apps (the file I/O stays app-side):
/// latency percentiles and per-interval engine-counter deltas as `key=value`
/// fields — one line a human can read and a script can split.

/// n / p50 / p95 / p99 / max of a sample set (µs in, ms out).
public struct LatencySummary: Equatable, Sendable {
    public let count: Int
    public let p50US: UInt64
    public let p95US: UInt64
    public let p99US: UInt64
    public let maxUS: UInt64

    public init?(_ samples: [UInt64]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func at(_ p: Int) -> UInt64 { sorted[min(sorted.count - 1, sorted.count * p / 100)] }
        count = sorted.count
        p50US = at(50)
        p95US = at(95)
        p99US = at(99)
        maxUS = sorted[sorted.count - 1]
    }

    /// `<label>_n=… <label>_p50_ms=… …` (0.1 ms resolution).
    public func fields(_ label: String) -> String {
        func ms(_ us: UInt64) -> String {
            let tenths = (us + 50) / 100
            return "\(tenths / 10).\(tenths % 10)"
        }
        return "\(label)_n=\(count) \(label)_p50_ms=\(ms(p50US)) \(label)_p95_ms=\(ms(p95US))"
            + " \(label)_p99_ms=\(ms(p99US)) \(label)_max_ms=\(ms(maxUS))"
    }
}

public extension ViewerStats {
    /// This interval's activity (`self` − `earlier`) over `seconds`.
    func intervalFields(since earlier: ViewerStats, seconds: Double) -> String {
        let bytes = bytesIn - earlier.bytesIn
        let mbps = seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : 0
        let mbpsTenths = Int((mbps * 10).rounded())
        var f: [String] = ["rx_mbps=\(mbpsTenths / 10).\(mbpsTenths % 10)", "rx_bytes=\(bytes)"]
        func add(_ key: String, _ now: Int, _ before: Int) { f.append("\(key)=\(now - before)") }
        add("dgrams", datagramsReceived, earlier.datagramsReceived)
        add("malformed", malformedDatagrams, earlier.malformedDatagrams)
        add("records_applied", recordsApplied, earlier.recordsApplied)
        add("records_stale", recordsStale, earlier.recordsStale)
        add("records_nacked", recordsRejectedNacked, earlier.recordsRejectedNacked)
        add("reasm_expired", reasmExpired, earlier.reasmExpired)
        add("deltas", deltasApplied, earlier.deltasApplied)
        add("delta_misses", deltaBaseMisses, earlier.deltaBaseMisses)
        add("cache_refs", cacheRefsApplied, earlier.cacheRefsApplied)
        add("cache_misses", cacheRefMisses, earlier.cacheRefMisses)
        add("scrolls", scrollsApplied, earlier.scrollsApplied)
        add("video_frames", videoFramesApplied, earlier.videoFramesApplied)
        add("video_dropped", videoDropped, earlier.videoDropped)
        add("video_decode_failures", videoDecodeFailures, earlier.videoDecodeFailures)
        add("keyframes", keyframesApplied, earlier.keyframesApplied)
        add("keyframes_dropped", keyframesDropped, earlier.keyframesDropped)
        add("acks_sent", acksSent, earlier.acksSent)
        return f.joined(separator: " ")
    }
}
