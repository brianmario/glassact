/// The tile path's send-rate policy: follow the link, or never exceed a cap.
public enum RateLimit: Equatable, Sendable {
    /// Send as fast as the path delivers without building a queue.
    case auto
    /// Never exceed this average rate (bytes/s) — a bandwidth budget.
    case capped(bytesPerSecond: Int)

    /// "Limit to N Mbit/s".
    public static func megabits(_ mbit: Int) -> RateLimit {
        .capped(bytesPerSecond: mbit * 125_000)
    }
}

/// Global tile-record send governor (§4.9): a token bucket whose refill rate
/// is the tile path's average send rate. The bucket absorbs one full-screen
/// change so ordinary workloads (typing, window scrolls, cold starts) never
/// notice the governor; the transport paces each burst onto the wire
/// (`DatagramPacing`, `PaceController`).
///
/// Admission happens where tiles qualify (HostEngine.encodeTick): a tile
/// that finds the budget spent is NOT queued — it simply fails to qualify
/// this tick and re-qualifies next tick against the CURRENT frame, so
/// overload degrades temporal resolution, never freshness.
///
/// The rate (`RateLimit.auto`) follows the path: a fixed 2.8 MB/s rate
/// (even boosted ×3 on a prompt path) would cap every LAN session — a 17 MB
/// full-screen change would take 1–5 s to settle on loopback. Auto starts
/// low (slow start, below) and then:
///  - grows ×1.25 while the governor is actually limiting (tiles deferred)
///    and the path shows no queue (< 20 ms over its baseline);
///  - drops to 0.9 × the measured delivery rate once a queue builds
///    (> 60 ms) — the bottleneck's own rate is what it just delivered;
///  - halves under a severe queue (> 200 ms) so it drains.
/// "Queue" is STANDING path delay: the minimum path delay (a confirmed
/// datagram's ACK time minus its estimated departure from the transport's
/// pacer) over the last ~200–400 ms, above its 10–20 s minimum. A short-
/// window minimum rejects jitter — if even the fastest recent datagram was
/// late, a queue stands; a mean would read 20–80 ms of random latency as
/// 30–60 ms of "queue" and collapse the rate. The per-batch ACK delay can't serve
/// either: measured from hand-off, it grows with our own pacing of a big
/// batch.
/// Encode headroom bounds it too: every byte admitted is a tile encoded,
/// and on a fast link an unbounded Auto stops subsampling heavy churn — an
/// encode-only replay of a 5K scroll trace would send 359–392 MB instead of
/// 55 MB, needing 3–14 cores of encode time. Growth requires encode duty
/// (encode time / capture interval, measured only when the host injects a
/// timer) under 50 %; above 75 % the rate shrinks ×0.85 per decision even
/// without a network signal, but not below `encodeBoundFloor` (2.8 MB/s).
/// Loss is a signal too (e.g. plane Wi-Fi): once a deep buffer holds
/// seconds of datagrams, every ACK lands after its batch timed out
/// (timeouts follow PING SRTT, which rides the uncongested control
/// connection) and is ignored — the delay signal goes silent at exactly
/// the worst moment and, on delay alone, the rate would never move. A
/// sizable batch that times out mostly unconfirmed halves the rate (at most
/// once per `lossHoldUS`), path sample or not.
/// Floor 32 KB/s (256 kbps) and a bucket of a quarter-second of the rate:
/// a 1 MB/s floor and fixed 16 MB burst would sit 4× above a 2 Mbps link.
/// Delivery rate only bounds the rate when the governor was limiting: an
/// app-limited sender's delivery rate is just what it sent (draining to it
/// would spiral the rate to the floor); otherwise a building queue backs
/// off gently (×0.9).
///
/// Stored inline in `HostEngine` and confined to its encode queue.
struct SendGovernor {
    /// ACK-delay threshold (send → first confirmation, queue included).
    /// Not the governor's signal (that is standing path delay, above); it
    /// drives auto-scale, which wants the delay the user actually
    /// experiences.
    static let severeAckDelayUS: UInt64 = 700_000
    /// 16 MB, not 2 MB: measured at 5K, a single full-screen transition is
    /// 10–25 MB coded — a 2 MB bucket would turn every window switch into a
    /// multi-second mixed-generation mosaic while the backlog trickles.
    /// Burst ceiling; the live bucket is `bucketSeconds` of the rate,
    /// between `minBucket` and this.
    static let bucketCap = 16_777_216
    static let bucketSeconds = 0.25
    static let minBucket = 65_536
    /// A timed-out batch this large, this unconfirmed, is a loss event.
    static let lossMinDatagrams = 8
    static let lossFraction = 0.5
    static let lossHoldUS: UInt64 = 200_000
    /// No growth until this long after the last loss event: ×1.25 per
    /// 25 ms decision outruns a halving per 200 ms (measured: the rate
    /// climbed straight back to 7.5 MB/s on a 250 KB/s link).
    static let growthQuietAfterLossUS: UInt64 = 1_000_000
    /// The control loop can't outrun its own sensor: the queue estimate is
    /// a 200–400 ms minimum, so growth waits that long between steps and a
    /// decrease is held that long for its effect to show. At one step per
    /// 25 ms decision the rate would go 40 KB/s → 900 KB/s before a 250 KB/s
    /// link's queue registered, then halve to the floor while it drained.
    static let growthIntervalUS: UInt64 = 200_000
    static let decreaseHoldUS: UInt64 = 400_000

    /// Slow start: 2 MB/s, doubling per growth step until the first
    /// backoff, then ×`growthFactor`. Starting at 8.4 MB/s with a full 16 MB
    /// bucket could put 10+ s of data in a plane-Wi-Fi queue before the
    /// first ACK comes back: missed PONGs, a reset, and the reconnect's cold
    /// start does it again (BENCHMARKS 'Tile governor on thin links: late
    /// ACKs, loss, slow start'). A LAN still reaches 100 MB/s in ~1.2 s.
    static let initialAutoRate = 2_000_000
    static let slowStartFactor = 2.0
    /// `fastLinkStart`: a fast-link start (8.4 MB/s, a full 16 MB
    /// bucket at every rate) for unit tests of logic that assumes one tick
    /// ships a whole frame — scrolls, webp budgets — over a capture
    /// transport with no path at all.
    static let fastStartRate = 8_400_000
    static let minAutoRate = 32_000        // 256 kbps
    static let maxAutoRate = 125_000_000     // ~gigabit
    static let growthFactor = 1.25
    static let drainFactor = 0.9
    static let queueHealthyUS: UInt64 = 20_000
    static let queueBuildingUS: UInt64 = 60_000
    static let queueSevereUS: UInt64 = 200_000
    static let dutyGrowthCeiling = 0.5
    static let dutyOverload = 0.75
    static let dutyShrinkFactor = 0.85
    static let encodeBoundFloor = 2_800_000   // encode overload never sheds below this
    /// Minimum spacing between rate decisions (one ACK round, roughly).
    static let adaptIntervalUS: UInt64 = 25_000
    /// The path-delay baseline is the minimum over a window this long (the
    /// previous window's minimum is kept too, so a route change is learned
    /// within two windows rather than never).
    static let baselineWindowUS: UInt64 = 10_000_000
    /// Standing-queue window: the queue estimate is the path-delay minimum
    /// over this window and the previous one.
    static let recentWindowUS: UInt64 = 200_000

    /// Spendable bytes; may go negative (bounded debt) after an overshoot.
    private(set) var tokens = Int(Double(SendGovernor.initialAutoRate) * SendGovernor.bucketSeconds)
    /// Until the first backoff (queue or loss), growth doubles.
    private(set) var slowStart = true
    private var fastLinkStart = false

    init() {}

    init(fastLinkStart: Bool) {
        guard fastLinkStart else { return }
        self.fastLinkStart = true
        autoRate = Self.fastStartRate
        tokens = Self.bucketCap
        slowStart = false
    }
    private var lastRefillUS: UInt64 = 0
    /// EWMA of encoded bytes per sent tile. Starts RAW-sized (conservative):
    /// admission arithmetic must bound the very first flood tick, before any
    /// learning — a low start would let a 9.7 MB cold flood through whole. For
    /// compressed workloads the EWMA falls within a few ticks and admission
    /// widens to match.
    private(set) var tileEstimate = 16_384.0
    /// Rotating admission start (a tile index): the worklist is row-major,
    /// so a fixed scan start starves the bottom of the screen under deferral
    /// pressure — measured as "the top strip of a dragged window stays
    /// fresh, everything below stays ancient". Admission starts where the
    /// last tick's budget ran out and wraps. 0 = start at the top.
    var rotor = 0

    // Auto-rate state.
    private(set) var autoRate = SendGovernor.initialAutoRate
    private(set) var pathDelayUS: UInt64 = 0 // EWMA — telemetry
    private var pathSampleFresh = false
    private var lossPending = false
    private var lastLossCutUS: UInt64 = 0
    private var lastLossEventUS: UInt64 = 0
    private var lastGrowthUS: UInt64 = 0
    private var lastDecreaseUS: UInt64 = 0
    private(set) var lossCuts = 0
    private var recentMinUS = UInt64.max
    private var previousRecentMinUS = UInt64.max
    private var recentWindowStartUS: UInt64 = 0
    private var baselineMinUS = UInt64.max
    private var previousBaselineMinUS = UInt64.max
    private var baselineWindowStartUS: UInt64 = 0
    private var deferredSinceAdapt = false
    /// EWMA of encode duty (0 = idle, 1 = encoding the whole interval);
    /// nil until the host measures it.
    private(set) var encodeDuty: Double?
    private var lastAdaptUS: UInt64 = 0
    private var deliveredBytes = 0
    private var deliveryRing = [(timeUS: UInt64, bytes: Int)](repeating: (0, 0), count: 16)
    private var deliveryHead = 0
    private var deliveryCount = 0

    /// Per-tile admission charge for this tick.
    var admissionEstimate: Int { max(256, Int(tileEstimate)) }

    /// Standing path queue over the baseline (0 until measured).
    var queueDelayUS: UInt64 {
        let base = min(baselineMinUS, previousBaselineMinUS)
        let recent = min(recentMinUS, previousRecentMinUS)
        guard base != .max, recent != .max, recent > base else { return 0 }
        return recent - base
    }

    /// The rate the bucket refills at under `limit`.
    func rate(_ limit: RateLimit) -> Int {
        switch limit {
        case .auto: autoRate
        case let .capped(cap): min(autoRate, cap)
        }
    }

    // MARK: Signals

    /// A confirmed datagram's path delay: its ACK time minus its estimated
    /// departure from the pacer.
    mutating func notePathDelay(_ sampleUS: UInt64, nowUS: UInt64) {
        pathDelayUS = pathDelayUS == 0 ? sampleUS : (pathDelayUS &* 3 &+ sampleUS) / 4
        pathSampleFresh = true
        if baselineWindowStartUS == 0 || nowUS &- baselineWindowStartUS > Self.baselineWindowUS {
            previousBaselineMinUS = baselineMinUS
            baselineMinUS = .max
            baselineWindowStartUS = nowUS
        }
        baselineMinUS = min(baselineMinUS, sampleUS)
        if recentWindowStartUS == 0 || nowUS &- recentWindowStartUS > Self.recentWindowUS {
            previousRecentMinUS = recentMinUS
            recentMinUS = .max
            recentWindowStartUS = nowUS
        }
        recentMinUS = min(recentMinUS, sampleUS)
    }

    /// A batch resolved by timeout with `lost` of its `datagrams` never
    /// confirmed.
    /// Only batches sent after the last cut count: the ones already queued
    /// when the rate dropped describe the old rate, and charging each of
    /// them would collapse Auto to its floor while the old queue drains.
    /// (Still losing at all — even on those — holds growth off.)
    mutating func noteTimeout(datagrams: Int, lost: Int, sentUS: UInt64, nowUS: UInt64) {
        guard datagrams >= Self.lossMinDatagrams,
              Double(lost) >= Double(datagrams) * Self.lossFraction else { return }
        lastLossEventUS = nowUS
        if sentUS > lastLossCutUS { lossPending = true }
    }

    /// Bytes the viewer just confirmed.
    mutating func noteDelivered(_ bytes: Int, nowUS: UInt64) {
        deliveredBytes += bytes
        let newest = deliveryCount == 0 ? 0 : deliveryRing[(deliveryHead + deliveryCount - 1) % deliveryRing.count].timeUS
        guard deliveryCount == 0 || nowUS &- newest >= 20_000 else { return }
        if deliveryCount == deliveryRing.count {
            deliveryHead = (deliveryHead + 1) % deliveryRing.count
            deliveryCount -= 1
        }
        deliveryRing[(deliveryHead + deliveryCount) % deliveryRing.count] = (nowUS, deliveredBytes)
        deliveryCount += 1
    }

    /// Confirmed bytes/s over the recent window (≥ 100 ms of samples).
    var deliveryRate: Int? {
        guard deliveryCount >= 2 else { return nil }
        let oldest = deliveryRing[deliveryHead]
        let newest = deliveryRing[(deliveryHead + deliveryCount - 1) % deliveryRing.count]
        let span = newest.timeUS &- oldest.timeUS
        guard span >= 100_000 else { return nil }
        return Int(UInt64(newest.bytes - oldest.bytes) &* 1_000_000 / span)
    }

    /// One encode tick took `durationUS` of real time out of a capture
    /// interval of `intervalUS`.
    mutating func noteEncode(durationUS: UInt64, intervalUS: UInt64) {
        guard intervalUS > 0 else { return }
        let sample = min(Double(durationUS) / Double(intervalUS), 4)
        encodeDuty = encodeDuty.map { $0 * 7 / 8 + sample / 8 } ?? sample
    }

    /// Admission held tiles back this tick: the rate is binding.
    mutating func noteDeferred() {
        deferredSinceAdapt = true
    }

    // MARK: Rate + bucket

    /// Auto-rate decision on a fresh path sample, at most once per
    /// `adaptIntervalUS`; `ceiling` is the transport's pace (sending faster
    /// than the pacer releases only queues on the host).
    mutating func adapt(nowUS: UInt64, ceiling: Int) {
        let overloaded = (encodeDuty ?? 0) > Self.dutyOverload
        guard pathSampleFresh || overloaded || lossPending,
              nowUS &- lastAdaptUS >= Self.adaptIntervalUS else { return }
        pathSampleFresh = false
        lastAdaptUS = nowUS
        if lossPending {
            lossPending = false
            if (lastLossCutUS == 0 || nowUS &- lastLossCutUS >= Self.lossHoldUS)
                && (lastDecreaseUS == 0 || nowUS &- lastDecreaseUS >= Self.decreaseHoldUS) {
                lastLossCutUS = nowUS
                lastDecreaseUS = nowUS
                lossCuts += 1
                slowStart = false
                autoRate = max(Self.minAutoRate, autoRate / 2)
                deferredSinceAdapt = false
                return
            }
        }
        let queue = queueDelayUS
        let cap = max(Self.minAutoRate, min(Self.maxAutoRate, ceiling))
        if overloaded {
            // The host can't encode what it admits: shrink, but never below
            // `encodeBoundFloor` (2.8 MB/s).
            let floor = min(autoRate, Self.encodeBoundFloor)
            autoRate = max(floor, Int(Double(autoRate) * Self.dutyShrinkFactor))
            deferredSinceAdapt = false
            return
        }
        let encodeHeadroom = (encodeDuty ?? 0) < Self.dutyGrowthCeiling
        let decreaseHeld = lastDecreaseUS != 0 && nowUS &- lastDecreaseUS < Self.decreaseHoldUS
        if queue > Self.queueSevereUS {
            if !decreaseHeld {
                // Halve, or straight to what the link just delivered if
                // that's lower (late ACKs keep it honest under a deep queue).
                var next = autoRate / 2
                if let delivered = deliveryRate, delivered > 0 {
                    next = min(next, Int(Double(delivered) * Self.drainFactor))
                }
                autoRate = next
                lastDecreaseUS = nowUS
                slowStart = false
            }
        } else if queue > Self.queueBuildingUS {
            if !decreaseHeld {
                if deferredSinceAdapt, let delivered = deliveryRate {
                    autoRate = min(autoRate, Int(Double(delivered) * Self.drainFactor))
                } else {
                    autoRate = Int(Double(autoRate) * Self.drainFactor)
                }
                lastDecreaseUS = nowUS
                slowStart = false
            }
        } else if queue < Self.queueHealthyUS && deferredSinceAdapt && encodeHeadroom
                    && (lastLossEventUS == 0 || nowUS &- lastLossEventUS >= Self.growthQuietAfterLossUS)
                    && (lastGrowthUS == 0 || nowUS &- lastGrowthUS >= Self.growthIntervalUS) {
            autoRate = Int(Double(autoRate) * (slowStart ? Self.slowStartFactor : Self.growthFactor))
            lastGrowthUS = nowUS
        }
        autoRate = max(Self.minAutoRate, min(cap, autoRate))
        deferredSinceAdapt = false
    }

    /// Refill for the time since the last call (at most 2 s' worth).
    mutating func refill(nowUS: UInt64, limit: RateLimit) {
        if lastRefillUS == 0 {
            lastRefillUS = nowUS
            return
        }
        let dt = nowUS &- lastRefillUS
        lastRefillUS = nowUS
        guard dt > 0 else { return }
        let refill = Int(min(dt, 2_000_000)) * rate(limit) / 1_000_000
        tokens = min(tokens + refill, bucketCapacity(limit))
    }

    /// A quarter-second of the current rate: a LAN (rate climbs within
    /// ~0.5 s) still takes a full-screen change in one burst; a thin link
    /// gets paced instead of seconds of network queue.
    func bucketCapacity(_ limit: RateLimit) -> Int {
        if fastLinkStart { return Self.bucketCap }
        return min(Self.bucketCap, max(Self.minBucket, Int(Double(rate(limit)) * Self.bucketSeconds)))
    }

    /// Settlement: admission deducted estimates from a scratch budget; the
    /// real spend is the packed batch. Debt is allowed (an overshooting
    /// batch borrows from future refill) but bounded, and the per-tile
    /// estimate tracks reality so admission counts stay honest across codec
    /// mixes (RAW vs delta/REF).
    mutating func settle(batchBytes: Int, tilesSent: Int) {
        tokens = max(tokens - batchBytes, -Self.bucketCap)
        // (Debt stays bounded by the ceiling: an overshooting batch is paid
        // back at the rate, however low.)
        if tilesSent > 0 {
            tileEstimate = 0.9 * tileEstimate + 0.1 * Double(batchBytes) / Double(tilesSent)
        }
    }
}
