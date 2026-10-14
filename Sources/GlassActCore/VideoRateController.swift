/// Host video send control: how much encoded video may wait in the
/// transport, and what bitrate the encoder should aim for — both from the
/// rate the video stream actually drains at, so a thin link costs framerate
/// and sharpness instead of seconds of lag.
///
/// Why: the old gate allowed 4 MB (512 KB once SRTT > 50 ms) of unsent
/// video. Bytes are not time — at the 2.5 Mbps an airport Wi-Fi link
/// carried, 512 KB is ~1.6 s, and a live session read 1.6–2.2 s p50
/// glass-to-glass for 30 s at a stretch. The transport's backlog count is
/// accurate (VideoSendGateTests: it matches the stream's own
/// sentApplicationByteCount to within a frame); the limit was the bug.
///
/// - Drain rate: bytes that left the transport per window, i.e. handed −
///   Δbacklog. Only a window that stayed backlogged measures the link (the
///   congestion controller was the limit); an app-limited window is a lower
///   bound and can only raise the estimate.
/// - Gate: submit a frame only while the backlog is under
///   `rate × targetQueueUS` (floor `minQueueBytes`, so a link estimated too
///   low still moves) — newest-wins skips the rest.
/// - Network queue: the transport's smoothed − minimum RTT. Above
///   `queueHighUS` the link is buffering what we already sent: back the
///   estimate off; below `queueLowUS` on an app-limited window, probe up.
/// - Send budget: a token bucket at the estimate (burst `burstUS` of it).
///   The backlog limit alone keeps QUIC fed, and QUIC then fills the
///   bottleneck's buffer (relay test: 130–170 ms standing); handing bytes
///   no faster than the link drains them is what lets that queue empty. A
///   burst (an IDR) is paid back by skipped frames, not by queueing.
/// - Encoder bitrate cap: `capFraction` of the estimate, so the encoder
///   aims under the link and the budget rarely binds.
///
/// Engine-queue confined; plain value type, deterministic for tests.
public struct VideoRateController: Sendable {
    public static let windowUS: UInt64 = 250_000
    public static let targetQueueUS = 60_000
    public static let minQueueBytes = 16_384
    /// Before a first measurement. Small: it only decides whether the NEXT
    /// frame may go on top of what's queued — any single frame (an IDR)
    /// is submitted whenever the backlog is under it — and whatever it lets
    /// pile up is startup lag on a thin link (256 KB = 0.8 s at 2.5 Mbps).
    public static let initialQueueBytes = 64 << 10
    public static let queueHighUS: UInt64 = 60_000
    public static let queueLowUS: UInt64 = 30_000
    public static let capFraction = 0.85
    public static let burstUS = 100_000
    public static let probeFactor = 1.03
    /// CUBIC-style recovery (2026-09-29, live): after a brief network
    /// hiccup the cap sat at 0.3 Mbit/s and took ~60 s to climb back to
    /// 2.6 at the gentle 1.03/window. `pushbackRate` (CUBIC's W_max) is the
    /// rate the link last pushed back at; a cut that lands below
    /// `recoveryEnter` of it (a hiccup — the normal saw-tooth never cuts
    /// that deep) probes at `recoveryProbeFactor` until `recoveryExit` of
    /// it, then gently. (A "best clean rate" memory instead was inflated by
    /// startup bursts and overshot every cycle: relay p95 60 → 134–430 ms.)
    public static let recoveryProbeFactor = 1.15
    public static let recoveryEnter = 0.4
    public static let recoveryExit = 0.7
    /// Half-life of the pushback memory, in 250 ms windows (~60 s).
    public static let pushbackDecayPerWindow = 0.9971
    /// Backoff scales with the queue: 0.85× at the threshold, down to 0.5×
    /// (a first estimate can read ~2× the link — it measured QUIC's opening
    /// burst into the bottleneck's buffer — and fixed 0.85 steps took 3 s).
    public static let backoffFactor = 0.85
    public static let minBackoffFactor = 0.5
    /// Smoothed RTT trails the queue by a few RTTs: one backoff per this,
    /// or a draining queue would be charged again and again.
    public static let backoffHoldUS: UInt64 = 300_000
    /// 300 kbps: below this HEVC screen content is not worth showing.
    public static let minRate = 37_500
    /// The encoder's own ceiling (20 Mbps) — no point estimating past it.
    public static let maxRate = 2_500_000
    /// Startup: until the link is measured, the encoder is capped here
    /// instead of running at its 20 Mbps base (2026-09-30, live on a phone
    /// tether: the first keyframe and the frames behind it were sized for
    /// 20 Mbps, queued in the path, and the first picture showed ~1.5 s
    /// behind capture — 3 fps and 262 ms SRTT for the first seconds).
    public static let startupCapBps = 3_000_000
    /// While unmeasured, a clean window that actually used the startup cap
    /// raises it by this (3 → 20 Mbps in ~2 s of motion). The first
    /// pushback measures the link and the normal controller takes over; a
    /// link that never pushes back reaches the ceiling and runs uncapped.
    public static let startupProbeFactor = 1.25

    /// Drain estimate, bytes/s; 0 until the first backlogged window.
    public private(set) var rate = 0
    public private(set) var backoffs = 0
    /// The rate the link last pushed back at (bytes/s, decaying).
    public private(set) var pushbackRate = 0.0
    public private(set) var recovering = false
    /// The rate grew (a probe) since the last backoff — so a backoff now is
    /// the link pushing back on a probe, not the old queue still draining.
    private var grewSinceBackoff = false
    /// What was being sent in the last app-limited window (bytes/s).
    private var lastSentRate = 0
    /// Encoder cap before the first measurement (bits/s); nil once the
    /// ramp reaches the encoder's ceiling.
    public private(set) var startupCap: Int? = VideoRateController.startupCapBps

    /// Bytes/s handed in each of the last 4 windows (~1 s).
    private var offeredRing = [Int](repeating: 0, count: 4)
    private var offeredRingNext = 0
    private var windowStartUS: UInt64 = 0
    private var windowStartBacklog = 0
    private var windowHanded = 0
    private var windowAlwaysBacklogged = true
    private var lastBackoffUS: UInt64 = 0
    private var tokens = 0
    private var tokensAtUS: UInt64 = 0
    /// Recent network-queue readings (time, µs) for the jitter filter.
    private var queueRing = [(UInt64, UInt64)](repeating: (0, 0), count: 64) // ~1 s of 60 Hz ticks
    private var queueRingNext = 0
    /// The queue signal is the MINIMUM reading over this window: a queue
    /// that stands shows in every sample; cellular jitter doesn't (the
    /// tile governor filters the same way). Used before the link is
    /// measured — a raw spike must not install a cap on a fast link.
    public static let queueFilterUS: UInt64 = 1_000_000
    /// The same filter while the startup ramp probes: ~6 readings.
    public static let rampQueueFilterUS: UInt64 = 100_000


    public init() {}

    /// Bytes just handed to the transport's video channel.
    public mutating func noteHanded(_ bytes: Int) {
        windowHanded += bytes
        tokens -= bytes
    }

    /// Once per video tick. `networkQueueUS` = transport smoothed − min RTT
    /// (nil if the transport has no RTT view). Returns true when `rate`
    /// changed (the caller re-applies the encoder cap).
    @discardableResult
    public mutating func observe(nowUS: UInt64, backlogBytes: Int, networkQueueUS: UInt64?) -> Bool {
        if rate > 0, nowUS > tokensAtUS {
            let burst = max(Self.minQueueBytes, rate * Self.burstUS / 1_000_000)
            tokens = min(burst, tokens + Int((nowUS - tokensAtUS) * UInt64(rate) / 1_000_000))
        }
        tokensAtUS = nowUS
        if let q = networkQueueUS {
            queueRing[queueRingNext] = (max(nowUS, 1), q)
            queueRingNext = (queueRingNext + 1) % queueRing.count
        }
        if windowStartUS == 0 {
            startWindow(nowUS, backlogBytes)
            return false
        }
        if backlogBytes == 0 { windowAlwaysBacklogged = false }
        guard nowUS &- windowStartUS >= Self.windowUS else { return false }
        let elapsed = nowUS &- windowStartUS
        let drained = max(0, windowHanded - (backlogBytes - windowStartBacklog))
        let sample = Int(UInt64(drained) &* 1_000_000 / max(elapsed, 1))
        let backlogged = windowAlwaysBacklogged && windowStartBacklog > 0 && backlogBytes > 0
        let old = rate
        let oldStartup = startupCap
        // Measured link: the raw reading — any filter delays the backoff
        // (relay rig p95 54 → 156–475 ms even at a 300 ms window).
        // Unmeasured: the jitter-filtered one, since acting on it installs
        // the first cap at all.
        // Startup ramp in progress (grown past its first step): a queue that
        // stands now is the link pushing back on the ramp's own probe — the
        // 1 s filter's lag let the ramp fill the bottleneck's buffer (relay
        // rig p95 57–67 → 422–486 ms). A short filter still ignores
        // single-reading jitter spikes.
        let ramping = rate == 0 && startupCap.map { $0 > Self.startupCapBps } ?? true
        let queue = rate > 0 ? (networkQueueUS ?? 0)
            : standingQueueUS(nowUS: nowUS, window: ramping ? Self.rampQueueFilterUS : Self.queueFilterUS)
        // A queue we aren't feeding isn't ours to drain: with nothing backed
        // up here and well under half the rate handed, cutting again only
        // walks the cap to the floor (live: a 6 s queue at a quiet connect)
        // — hold instead. A burst that does queue backs up and cuts.
        // Over the last second, not this window: a queue in the path holds
        // what was sent up to its own depth ago, and right after a cut the
        // gate makes the current window look quiet (relay rig p95 59–64 →
        // 79–137 ms judging by one window).
        let offered = Int(UInt64(max(0, windowHanded)) &* 1_000_000 / max(elapsed, 1))
        offeredRing[offeredRingNext] = offered
        offeredRingNext = (offeredRingNext + 1) % offeredRing.count
        let notOurs = rate > 0 && !backlogged && offeredRing.max()! * 2 < rate
        if queue > Self.queueHighUS, rate > 0 || sample > 0, !notOurs {
            guard nowUS &- lastBackoffUS >= Self.backoffHoldUS else {
                startWindow(nowUS, backlogBytes)
                return false
            }
            lastBackoffUS = nowUS
            // The network is holding what we sent: whatever the drain says,
            // deliver less until it empties. Unmeasured (the host's send
            // queue never backed up — live, a 150 ms tether: `vlink
            // unmeasured`, queue standing at 80–100 ms): start from what is
            // being sent, so the encoder gets a cap at all.
            let excess = Double(queue - Self.queueHighUS) / 1_000_000
            // With a startup cap in force, cut from the cap: a quiet screen
            // sends far less than it allows, and cutting from that (live
            // 2026-09-30: ~27 KB/s at a connect with a 200 ms queue) landed
            // on the 0.3 Mbit/s floor and took minutes to probe back.
            let base = rate > 0 ? rate : max(sample, (startupCap ?? 0) / 8)
            // A pushback on a probe (or the first one) sets W_max. Repeated
            // cuts while a hiccup's queue drains don't: they would erase the
            // memory the recovery needs.
            if grewSinceBackoff || pushbackRate == 0 { pushbackRate = Double(base) }
            grewSinceBackoff = false
            rate = Int(Double(base) * max(Self.minBackoffFactor, Self.backoffFactor - excess * 2))
            if old == 0 { tokens = 0 }
            backoffs += 1
        } else if backlogged {
            rate = rate == 0 ? sample : (rate * 3 + sample) / 4
            if old == 0 { tokens = 0 }
            // A first measurement (or a drain that halves the rate) taken in
            // a stall: remember what was being sent before it.
            if old == 0 || rate * 2 < old {
                pushbackRate = max(pushbackRate, Double(max(old, lastSentRate)))
            }
        } else if rate > 0 {
            // App-limited: the link carried everything offered. A lower
            // bound — raise to it, and probe past it while the path is clean
            // and actually in use (an idle screen proves nothing). Never the
            // first estimate: until a backlogged window measures the link,
            // there is nothing to gate against (a link that never backlogs
            // is never throttled).
            let used = sample * 2 >= rate
            rate = max(rate, sample)
            lastSentRate = sample
            if used, queue < Self.queueLowUS {
                rate = Int(Double(rate) * (recovering ? Self.recoveryProbeFactor : Self.probeFactor))
                grewSinceBackoff = true
            }
        }
        if rate > 0 { rate = min(Self.maxRate, max(Self.minRate, rate)) }
        // Recovery mode: entered by a cut deep below the pushback rate (a
        // hiccup), left once most of the way back.
        pushbackRate *= Self.pushbackDecayPerWindow
        if rate > 0 && pushbackRate > 0 {
            if Double(rate) < pushbackRate * Self.recoveryEnter && rate < old { recovering = true }
            if Double(rate) >= pushbackRate * Self.recoveryExit { recovering = false }
        }
        if rate == 0 {
            lastSentRate = sample
            // Startup ramp: a clean path carrying at least half the cap.
            // Growth also needs a clean RAW reading: it must stop the window
            // a queue starts to show, before any filter agrees.
            if let cap = startupCap, !backlogged, (networkQueueUS ?? 0) < Self.queueLowUS,
               queue < Self.queueLowUS, sample * 8 * 2 >= cap {
                let next = Int(Double(cap) * Self.startupProbeFactor)
                startupCap = next >= Self.maxRate * 8 ? nil : next
            }
        }
        startWindow(nowUS, backlogBytes)
        return rate != old || (rate == 0 && startupCap != oldStartup)
    }

    /// Min of the readings in the last `window` µs (0 with none).
    private func standingQueueUS(nowUS: UInt64, window: UInt64) -> UInt64 {
        var m = UInt64.max
        for (t, q) in queueRing where t != 0 && nowUS &- t <= window { m = min(m, q) }
        return m == .max ? 0 : m
    }

    /// May a new frame be submitted with `backlogBytes` still unsent?
    public func allowsFrame(backlogBytes: Int) -> Bool {
        backlogBytes < queueLimitBytes && (rate == 0 || tokens > 0)
    }

    public var queueLimitBytes: Int {
        rate == 0 ? Self.initialQueueBytes
            : max(Self.minQueueBytes, rate * Self.targetQueueUS / 1_000_000)
    }

    /// Encoder average-bitrate cap in bits/s: from the measured rate, else
    /// the startup ramp (nil = uncapped: the ramp reached the ceiling).
    public var bitrateCap: Int? {
        rate == 0 ? startupCap : Int(Double(rate * 8) * Self.capFraction)
    }

    private mutating func startWindow(_ nowUS: UInt64, _ backlog: Int) {
        windowStartUS = nowUS
        windowStartBacklog = backlog
        windowHanded = 0
        windowAlwaysBacklogged = backlog > 0
    }
}
