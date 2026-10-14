import Foundation
import Testing
import GlassActWire
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Video regions (§4.6): pinned full-screen formation, quarantine,
/// lifecycle, and the golden bar (lossy while live, byte-exact after
/// dissolve + repaint).
@Suite struct VideoRegionTests {
    /// 512×512: 64 tiles. The churn box (64, 64, 384², tiles 1–6 × 1–6) is
    /// 36 tiles — enough to form a region (≥ 32).
    static let side = 512
    static let box = DirtyRect(x: 64, y: 64, width: 384, height: 384)

    /// A session whose cold start (a region carrying the first paint) has
    /// already dissolved and settled byte-exact.
    private func settledSession(_ rng: inout SplitMix64, faults: FaultConfig = .none) -> Harness {
        let h = Harness(width: Self.side, height: Self.side, faults: faults, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 120_000), "cold start must settle")
        return h
    }

    private func churnTicks(_ h: Harness, _ rng: inout SplitMix64, ticks: Int) {
        let box = Self.box
        for _ in 0..<ticks {
            h.frame.fillRect(x: box.x, y: box.y, w: box.width, h: box.height, &rng)
            h.encodeFrame(dirtyRects: [box])
            h.run(untilUS: h.now + 20_000)
        }
    }

    @Test func fullScreenRegionFormsOnChurn() {
        var rng = SplitMix64(seed: 601)
        let h = settledSession(&rng)
        let formedBefore = h.host.stats.videoRegionsFormed
        let startsBefore = h.viewer.stats.videoStarts

        churnTicks(h, &rng, ticks: 2)
        #expect(h.host.stats.videoRegionsFormed == formedBefore + 1, "churn on ≥ 32 tiles must form a region")
        #expect(h.host.activeVideoRegionCount == 1)
        let rect = h.host.activeVideoRegionRect
        #expect(rect?.x == 0 && rect?.y == 0 && rect?.width == Self.side && rect?.height == Self.side,
                "the region covers the full screen (got \(String(describing: rect)))")
        #expect(h.viewer.stats.videoStarts == startsBefore + 1)
        #expect(h.viewer.stats.videoFramesApplied > 0)
        // Quarantine: while active, region churn ships zero tile records.
        let tilesBefore = h.host.stats.tilesSent
        churnTicks(h, &rng, ticks: 10)
        #expect(h.host.stats.tilesSent == tilesBefore, "region tiles must not ride the record path")
    }

    /// Churn below the formation threshold stays on the tile path.
    @Test func smallChurnDoesNotFormRegion() {
        var rng = SplitMix64(seed: 602)
        let h = settledSession(&rng)
        let formedBefore = h.host.stats.videoRegionsFormed
        for _ in 0..<60 {
            h.frame.fillRect(x: 64, y: 64, w: 192, h: 192, &rng) // 9 tiles
            h.encodeFrame(dirtyRects: [DirtyRect(x: 64, y: 64, width: 192, height: 192)])
            h.run(untilUS: h.now + 20_000)
        }
        #expect(h.host.stats.videoRegionsFormed == formedBefore)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }

    /// Quiescence dissolves the region; the repaint restores byte-exactness
    /// even though the viewer verifiably showed lossy video while the region
    /// was live.
    @Test func dissolveRepaintsToByteExact() {
        var rng = SplitMix64(seed: 603)
        let h = settledSession(&rng)
        let dissolvedBefore = h.host.stats.videoRegionsDissolved
        let stopsBefore = h.viewer.stats.videoStops

        churnTicks(h, &rng, ticks: 40)
        #expect(h.host.activeVideoRegionCount == 1)
        // While live: the mock quantizes to 5 bits — the presented picture
        // must differ (this is what makes the final exactness assertion
        // meaningful).
        h.run(untilUS: h.now + 100_000)
        #expect(!h.canvasMatchesFrame(), "mock codec is lossy; live region must diverge")

        #expect(h.settle(), "settle must drain the region (dissolve + repaint)")
        #expect(h.host.stats.videoRegionsDissolved == dissolvedBefore + 1)
        #expect(h.viewer.stats.videoStops == stopsBefore + 1)
        #expect(h.canvasMatchesFrame(), "post-dissolve repaint must restore byte-exactness")
    }

    /// Saturated ticks (INV-4 drops) during an un-ACKed dissolve repaint
    /// must not re-form the region. They carry no hashes, so they have no
    /// churn evidence — at high RTT a multi-batch repaint keeps both slots
    /// open for ~a full RTT of them (the app's synthetic ticks pass nil
    /// dirty rects), and formation there would re-form the region from its
    /// own repaint.
    @Test func saturatedRepaintTicksDoNotReformRegion() {
        var rng = SplitMix64(seed: 606)
        let capture = CaptureTransport()
        let side = Self.side
        let host = HostEngine(width: side, height: side, transport: capture,
                              videoEncoderFactory: { MockVideoEncoder(codecID: $0) },
                              videoCodecPreference: [MockVideoEncoder.mockCodecID])
        host.start(nowUS: 0)
        host.handleControl(Data(ControlMessage.helloOK(
            ver: WireVersion.current,
            caps: WireCaps.bit(forVideoCodec: MockVideoEncoder.mockCodecID),
            geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0).encoded()), nowUS: 1_000)
        var frame = TestFrame(width: side, height: side)
        var now: UInt64 = 10_000
        func ackAll() {
            for ack in fullAcks(for: capture.sentDatagrams) {
                host.handleControl(ack, nowUS: now)
            }
            capture.sentDatagrams.removeAll()
        }

        // Healthy phase: the cold start forms the region; churn keeps it up.
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: now)
        now += 20_000
        ackAll()
        for _ in 0..<40 {
            frame.fillRect(x: Self.box.x, y: Self.box.y, w: Self.box.width, h: Self.box.height, &rng)
            frame.encode(host: host, dirtyRects: [Self.box], nowUS: now)
            now += 20_000
            ackAll()
        }
        #expect(host.stats.videoRegionsFormed == 1, "the cold start must form the region")

        // Quiesce until the dissolve lands (stop the loop there — the repaint
        // must stay un-ACKed to model the high-RTT window).
        // (A full-screen region's quiet limit starts at 90 ticks / ~2.1 s.)
        for _ in 0..<150 where host.activeVideoRegionCount == 1 {
            frame.encode(host: host, nowUS: now)
            host.tick(nowUS: now)
            now += 33_000
            ackAll()
        }
        #expect(host.stats.videoRegionsDissolved == 1, "quiesce must dissolve")
        #expect(host.pendingRepaintTiles > 0, "dissolve must queue the repaint")
        capture.sentDatagrams.removeAll()

        // High-RTT window: the repaint goes out but no ACK ever returns, and
        // one tile keeps genuinely churning so a second batch opens — every
        // further capture is an INV-4-dropped (saturated) tick with nil
        // dirty rects, exactly the app's synthetic-tick shape. The static
        // dissolved screen must NOT re-form a region.
        for i in 0..<100 {
            if i % 2 == 0 {
                frame.fillRect(x: 0, y: 0, w: 64, h: 64, &rng)
            }
            frame.encode(host: host, nowUS: now)
            now += 16_000
        }
        #expect(host.stats.batchesDropped > 0, "the window must actually saturate")
        #expect(host.stats.videoRegionsFormed == 1,
                "a cold repaint must not re-form the region from saturated ticks")
    }

    /// INV-10 after dissolve: once repainted and idle, zero further bytes.
    @Test func idleAfterDissolveIsZeroBytes() {
        var rng = SplitMix64(seed: 604)
        let h = settledSession(&rng)
        churnTicks(h, &rng, ticks: 40)
        #expect(h.host.stats.videoRegionsFormed >= 2, "churn must re-form the region")
        #expect(h.settle())
        let bytes = h.host.stats.bytesOut
        for _ in 0..<30 {
            h.encodeFrame()
            h.run(untilUS: h.now + 16_000)
        }
        #expect(h.host.stats.bytesOut == bytes, "idle after dissolve must send nothing")
    }

    /// The full golden bar under faults: drop/dup/reorder/jitter on datagrams
    /// while a region lives and dies. Byte-exact at settle, three seeds.
    @Test(arguments: [UInt64(31), 32, 33])
    func videoGoldenUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = seed
        var rng = SplitMix64(seed: seed &* 977)
        let h = Harness(width: Self.side, height: Self.side, faults: faults, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 500_000)

        // Phase 1: video churn interleaved with small changes in the corner
        // (records + video frames in flight together; handoff records for
        // still tiles race the frames that re-claim them).
        let box = Self.box
        for i in 0..<50 {
            h.frame.fillRect(x: box.x, y: box.y, w: box.width, h: box.height, &rng)
            if i % 5 == 0 {
                h.frame.fillRect(x: 0, y: 0, w: 48, h: 48, &rng)
            }
            h.encodeFrame()
            h.run(untilUS: h.now + 20_000)
        }
        #expect(h.host.stats.videoRegionsFormed >= 1, "seed \(seed): churn must form a region")
        // Phase 2: churn stops; settle must dissolve, repaint, and converge.
        #expect(h.settle(), "seed \(seed): settle")
        #expect(h.canvasMatchesFrame(), "seed \(seed): canvas must be byte-identical after settle")
    }

    /// The cross-channel race: a video frame arriving AFTER the dissolve
    /// repaint record for the same tile must lose (per-tile LWW stamp), or
    /// the tile would keep presenting lossy video over verified lossless
    /// pixels.
    @Test func straggleVideoFrameLosesToRepaint() {
        var rng = SplitMix64(seed: 605)
        let (viewer, _) = makeRunningViewer(width: 128, height: 128) // needs video factory — build manually below
        _ = viewer
        // Manual viewer with mock decoder:
        let capture = CaptureTransport()
        let v = ViewerEngine(transport: capture, videoDecoderFactory: { MockVideoDecoder() })
        v.handleControl(Data(ControlMessage.hello(ver: WireVersion.current, width: 128, height: 128,
                                                  tileSize: 64, pixfmt: PixelFormat.bgra8sRGB,
                                                  caps: WireCaps.videoHEVC).encoded()), nowUS: 0)
        #expect(v.state == .running)

        let regionPixels = rng.bytes(128 * 128 * 4)
        let start = VideoMessage.start(region: 0, generation: 1, x: 0, y: 0, width: 128, height: 128,
                                       codec: MockVideoEncoder.mockCodecID,
                                       config: MockVideoEncoder.config(width: 128, height: 128))
        v.handleVideo(Data(start.encoded()), nowUS: 0)
        #expect(v.stats.videoStarts == 1)

        // A repaint record for tile 0 with seq 10 lands first.
        let repaint = rng.bytes(64 * 64 * 4)
        v.handleDatagram(makeDatagram(seq: 10, records: [(0, repaint)]), nowUS: 0)
        #expect(canvasTile(v, 0) == repaint)

        // A straggler video frame stamped seq 5 (older) arrives afterwards.
        var enc = [UInt8]()
        let encFrame: [UInt8] = {
            var quant = regionPixels
            for i in 0..<quant.count { quant[i] = (i & 3) == 3 ? 0xFF : quant[i] & 0xF8 }
            var f: [UInt8] = [0]
            f.append(contentsOf: quant)
            return f
        }()
        enc = encFrame
        let frame = VideoMessage.frame(region: 0, generation: 1, seq: 5, sync: true, captureUS: 0, data: enc)
        v.handleVideo(Data(frame.encoded()), nowUS: 0)
        #expect(v.stats.videoFramesApplied == 1)
        // Tile 0 (record seq 10 > stamp 5) must keep showing the repaint;
        // tiles 1-3 (tileSeq 0) must show the video. The canvas itself is
        // never written by video (INV-8).
        #expect(canvasTile(v, 0) == repaint)
        #expect(!v.tileShowsVideo(0), "stale video frame must lose to the newer record")
        #expect(v.tileShowsVideo(1) && v.tileShowsVideo(2) && v.tileShowsVideo(3),
                "unblocked tiles must show the video")
        #expect(canvasTile(v, 1) == [UInt8](repeating: 0, count: 64 * 64 * 4),
                "video never writes the canvas")
    }

    /// Generation guard: frames from a dissolved generation are dropped even
    /// if a new region with the same id has started.
    @Test func staleGenerationFramesAreDropped() {
        let capture = CaptureTransport()
        let v = ViewerEngine(transport: capture, videoDecoderFactory: { MockVideoDecoder() })
        v.handleControl(Data(ControlMessage.hello(ver: WireVersion.current, width: 128, height: 64,
                                                  tileSize: 64, pixfmt: PixelFormat.bgra8sRGB,
                                                  caps: WireCaps.videoHEVC).encoded()), nowUS: 0)
        let start2 = VideoMessage.start(region: 0, generation: 2, x: 0, y: 0, width: 64, height: 64,
                                        codec: MockVideoEncoder.mockCodecID,
                                        config: MockVideoEncoder.config(width: 64, height: 64))
        v.handleVideo(Data(start2.encoded()), nowUS: 0)
        var quant = [UInt8](repeating: 0x77, count: 64 * 64 * 4)
        for i in 0..<quant.count { quant[i] = (i & 3) == 3 ? 0xFF : quant[i] & 0xF8 }
        var payload: [UInt8] = [0]
        payload.append(contentsOf: quant)
        // Generation 1 frame: stale → dropped.
        v.handleVideo(Data(VideoMessage.frame(region: 0, generation: 1, seq: 3, sync: true, captureUS: 0,
                                              data: payload).encoded()), nowUS: 0)
        #expect(v.stats.videoFramesApplied == 0)
        #expect(v.stats.videoDropped == 1)
        // Generation 2 frame: applies.
        v.handleVideo(Data(VideoMessage.frame(region: 0, generation: 2, seq: 3, sync: true, captureUS: 0,
                                              data: payload).encoded()), nowUS: 0)
        #expect(v.stats.videoFramesApplied == 1)
    }

    /// A scroll whose rect overlaps an active region must not be emitted:
    /// the viewer shows lossy video there, not the host's shadow, so the
    /// SCROLL_ACK digest can only mismatch and demote the whole rect (a guaranteed
    /// full-rect repaint). Setup tempts the scroll detector: the box reverts
    /// to its pre-formation pixels, so the ACKed belief for region tiles
    /// looks like a valid scroll source.
    @Test func scrollOverlappingActiveRegionShipsTiles() {
        var rng = SplitMix64(seed: 2501)
        let h = Harness(width: 640, height: 640, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 60_000))
        let original = h.frame.bytes
        let box = DirtyRect(x: 128, y: 128, width: 384, height: 384) // 36 tiles: forms
        for _ in 0..<60 where h.host.activeVideoRegionCount == 0 {
            h.frame.fillRect(x: box.x, y: box.y, w: box.width, h: box.height, &rng)
            h.encodeFrame(dirtyRects: [box])
            h.run(untilUS: h.now + 20_000)
        }
        #expect(h.host.activeVideoRegionCount == 1, "setup: region must form")
        h.frame.bytes = original // revert: video now carries the original pixels
        for _ in 0..<2 {
            h.encodeFrame(dirtyRects: [box])
            h.run(untilUS: h.now + 30_000)
        }
        // Whole screen scrolls up 64 px while the region is still active.
        let rowBytes = 640 * 4
        let shifted = h.frame.bytes
        h.frame.bytes.withUnsafeMutableBytes { dst in
            shifted.withUnsafeBytes { src in
                dst.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: 64 * rowBytes),
                                            byteCount: (640 - 64) * rowBytes)
            }
        }
        h.frame.fillRect(x: 0, y: 576, w: 640, h: 64, &rng)
        h.encodeFrame(dirtyRects: [DirtyRect(x: 0, y: 0, width: 640, height: 640)])
        h.run(untilUS: h.now + 200_000)
        #expect(h.host.activeVideoRegionCount == 1, "setup: region still active at the scroll")
        #expect(h.host.stats.scrollDigestRepairs == 0,
                "a scroll over an active region can only fail its digest")
        #expect(h.settle(maxSimMS: 60_000))
        #expect(h.canvasMatchesFrame())
    }
}
