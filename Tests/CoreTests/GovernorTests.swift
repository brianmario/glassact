import Foundation
import Testing
import GlassActWire
@testable import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// The global tile-record send governor (§4.9) and the full-screen region
/// snap. Pacing is safe by construction: a deferred tile is not queued, it
/// re-qualifies next tick against the CURRENT frame — overload degrades
/// temporal resolution, never freshness or exactness.
@Suite struct GovernorTests {
    /// A cold-start flood larger than the burst bucket is paced across ticks
    /// and still converges byte-exactly.
    @Test(.tags(.slow), .notInFastLane) func floodIsPacedAndConverges() {
        var rng = SplitMix64(seed: 1401)
        let h = Harness(width: 2560, height: 2560) // 1600 tiles ≈ 26 MB RAW flood
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        // One tick: the send must respect bucket + estimate slack, and the
        // remainder must be visibly pending (settle must not think it's done).
        let firstTick = h.host.stats.tileBytesOut // the governed path (the lossy
        // first paint rides the video stream and is one-shot cold-start UX)
        #expect(firstTick <= HostEngine.governorBucketCap + HostEngine.governorBucketCap / 4,
                "first tick sent \(firstTick) B of tiles — bucket is \(HostEngine.governorBucketCap)")
        #expect(h.host.stats.governorDeferredTiles > 0, "the flood must be deferred, not sent")
        #expect(h.host.stats.lastTickQualifiedTiles > 0, "deferred work must count as pending")
        #expect(h.settle(maxSimMS: 120_000), "paced flood must still converge")
        #expect(h.canvasMatchesFrame(), "pacing must never cost exactness")
    }

    /// Interactive edits after convergence are under the burst bucket and
    /// ship the same tick — the governor is invisible to normal work.
    @Test(.tags(.slow), .notInFastLane) func interactiveEditsShipImmediately() {
        var rng = SplitMix64(seed: 1402)
        let h = Harness(width: 2560, height: 2560)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 120_000))
        h.run(untilUS: h.now + 1_000_000) // refill the bucket after the flood

        let deferredBefore = h.host.stats.governorDeferredTiles
        let tilesBefore = h.host.stats.tilesSent
        h.frame.fillRect(x: 200, y: 200, w: 30, h: 30, &rng)
        h.encodeFrame(dirtyRects: [DirtyRect(x: 200, y: 200, width: 30, height: 30)])
        #expect(h.host.stats.tilesSent > tilesBefore, "a keystroke-sized edit ships the same tick")
        #expect(h.host.stats.governorDeferredTiles == deferredBefore,
                "small edits never hit the governor")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }

    /// A bandwidth limit binds: after the bucket is spent, one simulated
    /// second of a sustained flood sends about the cap — never more.
    @Test(.tags(.slow), .notInFastLane) func limitCapsTheSustainedRate() {
        var rng = SplitMix64(seed: 1403)
        let h = Harness(width: 2560, height: 2560)
        h.host.rateLimit = .megabits(25)
        let cap = 25 * 125_000
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        let start = h.host.stats.bytesOut
        let t0 = h.now
        while h.now < t0 + 1_000_000 { // keep re-encoding the same frame for 1 s
            h.run(untilUS: h.now + 16_000)
            h.encodeFrame()
        }
        let sent = h.host.stats.bytesOut - start
        #expect(sent > cap / 2, "drain too slow: \(sent) B in 1 s (cap \(cap))")
        #expect(sent < cap * 3 / 2, "limit exceeded: \(sent) B in 1 s (cap \(cap))")
    }

    /// Auto on an uncongested path: the governor stops being the bottleneck
    /// of a sustained flood — its rate climbs well past the old fixed
    /// 8.4 MB/s ceiling and the flood settles far sooner than a 25 Mbit cap.
    @Test(.tags(.slow), .notInFastLane) func autoFollowsAFastPath() {
        func settleTime(_ limit: RateLimit) -> (UInt64, Int) {
            var rng = SplitMix64(seed: 1404)
            let h = Harness(width: 2560, height: 2560)
            h.host.rateLimit = limit
            h.frame.fillRandom(&rng)
            h.encodeFrame()
            h.run(untilUS: h.now + 3_000_000) // spend and refill the bucket once
            h.frame.fillRandom(&rng)
            let t0 = h.now
            #expect(h.settle(maxSimMS: 120_000))
            #expect(h.canvasMatchesFrame())
            return (h.now - t0, h.host.stats.governorRate)
        }
        let (capped, _) = settleTime(.megabits(25))
        let (auto, rate) = settleTime(.auto)
        #expect(rate > SendGovernor.initialAutoRate, "auto rate \(rate) never grew")
        #expect(auto * 3 < capped, "auto settled in \(auto) µs vs \(capped) µs capped")
    }

    /// Auto against a real bottleneck (20 MB/s behind a deep 8 MB buffer,
    /// so excess shows up as queueing delay, not loss): the rate settles
    /// near the bottleneck with headroom, and no STANDING queue remains.
    /// (Each full-screen change is still admitted whole from the bucket, so
    /// a transient queue per burst is inherent — those bytes take as long on
    /// a 20 MB/s link wherever they wait.)
    @Test(.tags(.slow), .notInFastLane) func autoSettlesNearABottleneck() {
        var rng = SplitMix64(seed: 1405)
        let h = Harness(width: 2560, height: 2560)
        let drain = 20_000_000
        h.link.bottleneck = .init(bytesPerSecond: drain, bufferBytes: 8 << 20)
        var rates: [Int] = []
        var backlogs: [UInt64] = [] // network queue just before each next change
        for _ in 0..<6 { // sustained: a full-screen change every ~0.75 s
            h.frame.fillRandom(&rng)
            for _ in 0..<45 {
                h.encodeFrame()
                h.run(untilUS: h.now + 16_000)
            }
            rates.append(h.host.stats.governorRate)
            backlogs.append(h.link.bottleneckBacklogUS)
        }
        #expect(h.settle(maxSimMS: 120_000) && h.canvasMatchesFrame())
        // Auto saw-tooths around the link (one ×1.25 step per 200 ms, cut on
        // a queue): judge the late rounds' average, not one sample.
        let late = rates.suffix(3).reduce(0, +) / 3
        #expect(late > drain / 2 && late <= drain * 5 / 4, "late mean \(late) vs bottleneck \(drain); history \(rates)")
        // No standing queue: before each change the backlog stays below the
        // buffer's 400 ms (never parked full), and it doesn't ratchet up —
        // the late rounds average no worse than a quarter-second.
        let bufferUS = UInt64((8 << 20) * 1_000_000 / drain)
        #expect(backlogs.allSatisfy { $0 < bufferUS * 9 / 10 }, "network backlog before each change: \(backlogs) µs")
        let lateMean = backlogs.suffix(3).reduce(0, +) / 3
        #expect(lateMean < 250_000, "network backlog before each change: \(backlogs) µs")
    }

    /// Plane Wi-Fi (live 2026-09-28): ~2 Mbps with a deep buffer. Auto
    /// must follow the link DOWN — its old 1 MB/s floor sat 4× above it, a
    /// dissolve repaint queued seconds in the network, datagrams timed out
    /// into re-encodes, and control starved until the session reset. Also
    /// no fixed 16 MB burst: the bucket is a quarter-second of the rate.
    @Test(.tags(.slow), .notInFastLane) func autoFollowsAThinLinkDown() {
        var rng = SplitMix64(seed: 1407)
        let h = Harness(width: 1280, height: 768)
        let drain = 250_000 // 2 Mbps
        h.link.bottleneck = .init(bytesPerSecond: drain, bufferBytes: 500_000) // 2 s of buffer
        var worst: [UInt64] = [] // worst network backlog per round
        for _ in 0..<8 {
            h.frame.fillRect(x: 320, y: 192, w: 640, h: 384, &rng) // 60 incompressible tiles ≈ 1 MB
            var roundWorst: UInt64 = 0
            for _ in 0..<150 { // 2.4 s per round
                h.encodeFrame()
                h.run(untilUS: h.now + 16_000)
                roundWorst = max(roundWorst, h.link.bottleneckBacklogUS)
            }
            worst.append(roundWorst)
        }
        let rate = h.host.stats.governorRate
        print("thin link: rate \(rate) B/s, worst backlog per round \(worst.map { $0 / 1000 }) ms, bottleneck drops \(h.link.bottleneckDroppedDatagrams)")
        #expect(rate <= drain * 3 / 2, "rate \(rate) vs link \(drain)")
        // Late rounds: the queue stays well under the 2 s buffer.
        #expect(worst.suffix(4).allSatisfy { $0 < 800_000 }, "worst backlog per round: \(worst) µs")
        #expect(h.settle(maxSimMS: 240_000) && h.canvasMatchesFrame())
    }

    /// Auto bounded by encode headroom: on a fast, queue-free link with a
    /// scripted encode cost (1 ms of "encode" per tile sent), Auto must stop
    /// where encoding would saturate the capture interval — without the
    /// timer it runs away toward the ceiling.
    @Test(.tags(.slow), .notInFastLane) func autoStopsAtEncodeHeadroom() {
        final class CostModel: @unchecked Sendable {
            weak var host: HostEngine?
            func now() -> UInt64 { UInt64(host?.stats.tilesSent ?? 0) * 1_000 }
        }
        func run(timed: Bool) -> (rate: Int, duty: Int) {
            var rng = SplitMix64(seed: 1406)
            let cost = CostModel()
            var timer: (@Sendable () -> UInt64)?
            if timed { timer = { cost.now() } }
            let h = Harness(width: 2560, height: 2560, encodeTimer: timer)
            cost.host = h.host
            for _ in 0..<6 {
                h.frame.fillRandom(&rng)
                for _ in 0..<45 {
                    h.encodeFrame()
                    h.run(untilUS: h.now + 16_000)
                }
            }
            return (h.host.stats.governorRate, h.host.stats.encodeDutyPercent)
        }
        let free = run(timed: false)
        let bounded = run(timed: true)
        #expect(free.rate > 40_000_000, "setup: unbounded Auto should run away (\(free.rate))")
        #expect(bounded.rate < free.rate / 3, "bounded \(bounded.rate) vs free \(free.rate)")
        #expect(bounded.rate >= SendGovernor.encodeBoundFloor)
        #expect(bounded.duty < 100, "encode duty \(bounded.duty) %")
    }

    /// Cold start with video (§4.3): with pinned video negotiated, the first paint IS the
    /// video stream — the region forms on the very first tick, and neither
    /// the WebP lossy paint, nor the lossless keyframe, nor a tile flood
    /// goes out ahead of it. Exactness restores via the usual dissolve →
    /// pendingRepaint → governed settle.
    @Test func pinnedColdStartRidesVideoStream() {
        var rng = SplitMix64(seed: 1406)
        let h = Harness(width: 640, height: 640, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.host.stats.videoColdStarts == 1, "cold start must form the pinned region")
        #expect(h.host.stats.videoRegionsFormed == 1)
        #expect(h.host.stats.keyframesSent == 0, "no lossless keyframe ahead of the video stream")
        #expect(h.host.stats.lossyFirstPaintsSent == 0, "no WebP first paint ahead of the video stream")
        #expect(h.host.stats.datagramsSent == 0, "no tile flood on a video cold start")
        h.run(untilUS: h.now + 100_000)
        #expect(h.viewer.stats.videoStarts == 1)
        #expect(h.viewer.stats.videoFramesApplied >= 1, "the sync frame is the first paint")
        #expect(h.settle(maxSimMS: 240_000), "dissolve + governed repaint must drain")
        #expect(h.canvasMatchesFrame(), "video cold start must settle byte-exact")
    }

    /// The settle drain probes VP8L even when the governor's burst bucket
    /// admits the whole repaint in one tick larger than the 60 Hz live
    /// limit (webpTileLimit 320): the all-or-nothing probe gate was
    /// shipping ENTIRE dissolve repaints as LZ4 (~3× the bytes on text —
    /// BENCHMARKS.md "Settle coalescing").
    @Test func settleDrainProbesVP8LBeyondLiveTickLimit() {
        var rng = SplitMix64(seed: 1407)
        let h = Harness(width: 1216, height: 1216, video: true) // 361 tiles > 320
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.host.stats.videoColdStarts == 1, "cold start rides the pinned video stream")
        h.run(untilUS: h.now + 100_000)
        let probesBefore = h.host.stats.webpProbes
        #expect(h.settle(maxSimMS: 240_000), "dissolve + governed repaint must drain")
        #expect(h.canvasMatchesFrame(), "settle stays byte-exact")
        #expect(h.host.stats.webpProbes - probesBefore >= 361,
                "settle drain must VP8L-probe every repaint tile, not gate out at webpTileLimit")
    }

    /// The ack-delay EWMA must track the path, not the viewer's ACK
    /// cadence. Keepalive re-ACKs of incomplete batches (every 100 ms)
    /// confirm nothing new; sampling them made loss inflate the EWMA, which
    /// raised the timeout floor (2 × ackDelay), which let more re-ACKs land
    /// before timeout — 120 ms RTT at 5 % loss read ~275 ms (past the
    /// degraded threshold), vs ~127 ms sampling only confirming ACKs.
    @Test func ackDelayIgnoresKeepaliveReAcks() {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.latencyMinUS = 60_000
        faults.latencyMaxUS = 60_000
        faults.seed = 12
        var rng = SplitMix64(seed: 2301)
        let h = Harness(width: 640, height: 480, faults: faults)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 60_000))
        // Sparse edits: pauses let the viewer's keepalive re-ACKs fire for
        // every batch that lost a datagram.
        for _ in 0..<60 {
            let r = DirtyRect(x: rng.int(0..<560), y: rng.int(0..<400), width: 80, height: 80)
            h.frame.fillRect(x: r.x, y: r.y, w: r.width, h: r.height, &rng)
            h.encodeFrame(dirtyRects: [r])
            h.run(untilUS: h.now + 400_000)
        }
        #expect(h.host.ackDelayUS < 180_000,
                "ack delay \(h.host.ackDelayUS) µs on a 120 ms RTT path — keepalive re-ACKs leaking in")
    }

    /// Pinned re-form must key on churn, not qualification. A dissolve
    /// repaint's cold tiles qualify for their whole ACK round trip, and with
    /// loss the timed-out ones re-qualify en masse — counting them re-formed
    /// the full-screen region from its own repaint on a static screen
    /// (3 forms and ~10.8 s to settle here, vs 1 form and ~2.3 s).
    @Test func pinnedSettleUnderLossDoesNotReformFromRepaint() {
        var faults = FaultConfig()
        faults.dropPermille = 30
        faults.seed = 11
        var rng = SplitMix64(seed: 2201)
        let h = Harness(width: 1216, height: 1216, faults: faults, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        let formed = h.host.stats.videoRegionsFormed
        #expect(formed == 1, "cold start forms the pinned region")
        #expect(h.settle(maxSimMS: 240_000))
        #expect(h.host.stats.videoRegionsFormed == formed,
                "a static screen's lossy repaint must not re-form the region")
        #expect(h.canvasMatchesFrame())
    }

    /// Pinned video (§4.6): any churn burst forms a full-screen region
    /// immediately and dissolve-on-quiesce still restores
    /// byte-exactness. The motion layer is video; exactness is unchanged.
    @Test func pinnedModeFormsImmediatelyAndSettlesExact() {
        var rng = SplitMix64(seed: 1405)
        let h = Harness(width: 640, height: 640, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 400_000)
        // The cold flood itself may pin (motion layer paints fast, settle
        // restores exactness) — settle() waits out the dissolve either way.
        #expect(h.settle(maxSimMS: 240_000), "cold start settles byte-exact")
        #expect(h.canvasMatchesFrame())
        let formedAfterCold = h.host.stats.videoRegionsFormed
        // With per-tile handoff the static screen is exact before the region
        // dissolves, so settle() returns right at the dissolve — step past
        // the 3-tick re-form guard (same-instant thrash), as real time would.
        for _ in 0..<3 {
            h.encodeFrame(dirtyRects: [])
            h.run(untilUS: h.now + 16_000)
        }

        // A churn burst (≥ pinnedFormMinTiles tiles) → immediate region.
        h.frame.fillRect(x: 64, y: 64, w: 384, h: 384, &rng)
        h.encodeFrame(dirtyRects: [DirtyRect(x: 64, y: 64, width: 384, height: 384)])
        #expect(h.host.stats.videoRegionsFormed == formedAfterCold + 1,
                "pinned mode forms on the first burst")
        guard let rect = h.host.activeVideoRegionRect else {
            Issue.record("region must be active")
            return
        }
        #expect(rect.width == 640 && rect.height == 640, "pinned region is full-screen")

        // Keep churning through the region, then quiesce: byte-exact settle.
        for _ in 0..<20 {
            h.frame.fillRect(x: 100, y: 100, w: 300, h: 300, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: 100, y: 100, width: 300, height: 300)])
            h.run(untilUS: h.now + 20_000)
        }
        #expect(h.settle(maxSimMS: 240_000))
        #expect(h.canvasMatchesFrame(), "pinned mode must still settle byte-exact")
    }

    /// A governor-deferred COLD tile (ackedHash == 0) must re-arm
    /// pendingRepaint: its pixels are already on screen, so no future dirty
    /// rect will ever volunteer it, and while captures stay continuously
    /// active the app's quiet-gap synthetic full scans never fire. Without
    /// the re-arm it depends entirely on luck-of-the-dirty-rects and can
    /// stay stale on the viewer indefinitely (e.g. video churning in one
    /// corner while a deferred repaint drains elsewhere).
    @Test func deferredColdTilesReArmPendingRepaint() {
        var rng = SplitMix64(seed: 1408)
        let (host, capture) = makeRunningHost(width: 2560, height: 2560) // 1600 tiles ≈ 26 MB RAW > 16 MB bucket
        var frame = TestFrame(width: 2560, height: 2560)
        var now: UInt64 = 10_000
        var covered = Set<UInt16>()
        func drainSent() {
            for d in capture.sentDatagrams {
                _ = d.withUnsafeBytes { raw in
                    Datagram.parse(raw) { _, rec in covered.insert(rec.tileIdx) }
                }
            }
            for ack in fullAcks(for: capture.sentDatagrams) {
                host.handleControl(ack, nowUS: now)
            }
            capture.sentDatagrams.removeAll()
        }

        // Cold-start flood: every tile qualifies; the bucket admits ~1024
        // (estimate starts RAW-sized), the rest defer — and must re-arm.
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: now)
        #expect(host.stats.governorDeferredTiles > 0, "the flood must exceed the bucket")
        #expect(host.pendingRepaintTiles > 0,
                "deferred cold tiles must re-arm pendingRepaint")

        // Continuously-active captures whose dirty rects avoid every deferred
        // tile: only the top-left tile is ever reported dirty. The deferred
        // cold tiles must still drain via the pending-repaint volunteer path.
        // 33 ms ticks: fatter refills (fewer ticks to drain the backlog, less
        // wall time) while ACK delay stays under the healthy-boost threshold.
        let allTiles = 40 * 40
        for _ in 0..<300 {
            now += 33_000
            drainSent()
            frame.encode(host: host,
                         dirtyRects: [DirtyRect(x: 0, y: 0, width: 64, height: 64)],
                         nowUS: now)
            if covered.count == allTiles && host.pendingRepaintTiles == 0 { break }
        }
        now += 33_000
        drainSent()
        #expect(covered.count == allTiles,
                "deferred cold tiles must still be sent under dirty rects that avoid them (covered \(covered.count)/\(allTiles))")
        #expect(host.pendingRepaintTiles == 0, "the re-arm loop must terminate once sent")
    }
}

/// Fresh before owed: what the user just changed ships ahead of a backlog of
/// owed repaint tiles (live, a 150 ms tether: keystrokes queued behind up to
/// 1.8 s of dissolve repaint).
@Suite struct AdmissionPriorityTests {
    @Test func freshChangeShipsAheadOfOwedRepaint() {
        var rng = SplitMix64(seed: 2901)
        let capture = CaptureTransport()
        let host = HostEngine(width: 640, height: 640, transport: capture) // slow-start budget
        host.start(nowUS: 0)
        let helloOK = ControlMessage.helloOK(ver: WireVersion.current, caps: 0,
                                             geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0)
        host.handleControl(Data(helloOK.encoded()), nowUS: 1_000)
        var frame = TestFrame(width: 640, height: 640)
        frame.fillRandom(&rng) // 100 incompressible tiles ≈ 1.6 MB: far over the first budget
        frame.encode(host: host, nowUS: 10_000)
        #expect(host.pendingRepaintTiles > 50, "precondition: a backlog of owed tiles")

        // The user changes tile 0: already sent once, so the admission rotor
        // (resuming where the budget ran out) reaches it last.
        frame.fillRect(x: 0, y: 0, w: 64, h: 64, &rng)
        let before = capture.sentDatagrams.count
        frame.encode(host: host, dirtyRects: [DirtyRect(x: 0, y: 0, width: 64, height: 64)], nowUS: 26_667)
        let sent = decodeTilePayloads(Array(capture.sentDatagrams[before...]))
        #expect(sent[0] != nil, "the fresh tile must ship this tick; sent \(sent.keys.sorted())")
    }
}
