/// What the link delivers, measured where it arrives (§4.9): the viewer's
/// RECEIVED reports (bytes received, at its own clock). The host's own
/// readings only see bytes leave it; on a deep-buffered path they leave
/// 2–3× faster than the link carries them, into its buffer, and every
/// estimate built on them runs high.
///
/// - `deliveredBytesPerSecond`: the most delivered over any span in the
///   last ~10 s. A lower bound on the link: a quiet screen delivers little,
///   which says nothing about it.
/// - `capacityBytesPerSecond`: the same over the last ~60 s, counting only
///   spans queued at both ends: the path held a standing queue and the host
///   had more to send than went (`HostEngine.hostLimited`). Only then is
///   the bottleneck busy and what arrives the link's rate; spans the sender
///   left room in would read its own rate back, and a ceiling built on them
///   ratchets down (video under 0.9 × the ceiling, so the next minute's
///   ceiling under that). The path's queue alone isn't enough: on a Wi-Fi
///   radio in power save an idle path's RTT swings 15–130 ms, and in replay
///   a typing session's 0.04 Mbit/s read as the link's capacity (#144). 0
///   with no queued span: no ceiling.
/// - `recentCapacityBytesPerSecond`: the capacity over the last ~10 s, for
///   noticing a link that just got thinner (AV1 → HEVC).
///
/// Plain value type; the engine feeds it from the control queue.
struct LinkEstimate {
    static let shortWindowUS: UInt64 = 10_000_000
    static let longWindowUS: UInt64 = 60_000_000
    /// Each rate spans at least this much of the viewer's clock: bytes
    /// arrive in bursts (a whole video message at once, a batch of
    /// datagrams), and over one 250 ms report a burst reads as up to twice
    /// the link.
    static let spanUS: UInt64 = 1_000_000

    /// `atUS`: when it reached the host (the host's clock).
    private struct Report { var tUS: UInt64 = 0, atUS: UInt64 = 0, bytes: UInt64 = 0, queued = false }
    private struct Sample { var atUS: UInt64 = 0, rate = 0, queued = false }

    /// Recent reports, oldest overwritten.
    private var reportsRing = [Report](repeating: Report(), count: 16)
    private var reportsNext = 0
    /// One per report with a span behind it, oldest overwritten (host time).
    private var samples = [Sample](repeating: Sample(), count: 256)
    private var next = 0
    private(set) var reports = 0
    /// Capacity readings (queued samples) so far.
    private(set) var queuedSamples = 0

    /// `queued`: when this report arrived, the host saw a standing queue on
    /// the path and was holding back what it had to send, as it has been
    /// without a break since `limitedSinceUS` (host time; 0: no bound). A
    /// span is queued only if it lies inside that stretch: one reaching back
    /// across a quiet stretch reads the quiet, not the link. The viewer
    /// reports only when bytes arrived, so after minutes of pause the first
    /// report back, measured against the last one before it, reads close to
    /// nothing: a capacity that would floor the video ceiling and fire the
    /// resolution rung on a LAN (#144).
    mutating func noteReceived(bytes: UInt64, viewerTUS: UInt64, nowUS: UInt64, queued: Bool,
                               limitedSinceUS: UInt64 = 0) {
        reports += 1
        let last = reportsRing[(reportsNext + reportsRing.count - 1) % reportsRing.count]
        if last.tUS != 0, bytes < last.bytes || viewerTUS < last.tUS { // a new session's counters
            for i in reportsRing.indices { reportsRing[i] = Report() }
        }
        reportsRing[reportsNext] = Report(tUS: viewerTUS, atUS: nowUS, bytes: bytes, queued: queued)
        reportsNext = (reportsNext + 1) % reportsRing.count
        // The newest report at least `spanUS` older than this one.
        var base: Report?
        for r in reportsRing where r.tUS != 0 && viewerTUS > r.tUS && viewerTUS - r.tUS >= Self.spanUS {
            if base == nil || r.tUS > base!.tUS { base = r }
        }
        guard let base, bytes >= base.bytes else { return }
        let rate = Int((bytes - base.bytes) &* 1_000_000 / (viewerTUS - base.tUS))
        let spanQueued = queued && base.queued && base.atUS >= limitedSinceUS
        samples[next] = Sample(atUS: max(nowUS, 1), rate: rate, queued: spanQueued)
        next = (next + 1) % samples.count
        if spanQueued { queuedSamples += 1 }
    }

    /// Bytes/s; 0 with no reading in the window.
    func deliveredBytesPerSecond(nowUS: UInt64) -> Int {
        maxRate(nowUS: nowUS, window: Self.shortWindowUS, queuedOnly: false)
    }
    func capacityBytesPerSecond(nowUS: UInt64) -> Int {
        maxRate(nowUS: nowUS, window: Self.longWindowUS, queuedOnly: true)
    }
    func recentCapacityBytesPerSecond(nowUS: UInt64) -> Int {
        maxRate(nowUS: nowUS, window: Self.shortWindowUS, queuedOnly: true)
    }

    private func maxRate(nowUS: UInt64, window: UInt64, queuedOnly: Bool) -> Int {
        var best = 0
        for s in samples where s.atUS != 0 && nowUS &- s.atUS <= window && (s.queued || !queuedOnly) {
            best = max(best, s.rate)
        }
        return best
    }
}
