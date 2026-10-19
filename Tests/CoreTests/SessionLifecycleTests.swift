import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTestSupport

/// Engine-side session lifecycle: failures are terminal AND reported (never
/// a silent wedge), video faults recover or escalate, and the ACK cadence
/// keeps reporting late datagrams under steady traffic.
@Suite struct SessionLifecycleTests {
    // MARK: - Failure is reported

    @Test func viewerRejectingInSessionHelloFailsLoudly() {
        let (viewer, _) = makeRunningViewer(width: 128, height: 64)
        var reasons: [String] = []
        viewer.onFailed = { reasons.append($0) }
        let bad = ControlMessage.hello(ver: WireVersion.current, width: 20_000, height: 64,
                                       tileSize: 64, pixfmt: PixelFormat.bgra8sRGB, caps: 0)
        viewer.handleControl(Data(bad.encoded()), nowUS: 1_000)
        #expect(viewer.state == .failed, "ignoring it wedged the host waiting for HELLO_OK")
        #expect(reasons.count == 1)
    }

    @Test func hostIncompatibleHelloOKFailsLoudly() {
        let capture = CaptureTransport()
        let host = HostEngine(width: 128, height: 64, transport: capture)
        var reasons: [String] = []
        host.onFailed = { reasons.append($0) }
        host.start(nowUS: 0)
        let helloOK = ControlMessage.helloOK(ver: 0x7F, caps: 0,
                                             geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0)
        host.handleControl(Data(helloOK.encoded()), nowUS: 1_000)
        #expect(host.state == .failed)
        #expect(reasons.count == 1)
    }

    @Test func viewerRecordsControlArrivalForLiveness() {
        let (viewer, _) = makeRunningViewer(width: 128, height: 64)
        viewer.handleControl(Data(ControlMessage.ping(nonce: 1, tUS: 5).encoded()), nowUS: 42_000)
        #expect(viewer.lastControlRxUS == 42_000)
    }

    // MARK: - Video faults

    private func makeVideoViewer() -> (ViewerEngine, CaptureTransport) {
        let capture = CaptureTransport()
        let viewer = ViewerEngine(transport: capture, videoDecoderFactory: { MockVideoDecoder() },
                                  supportedVideoCodecs: [MockVideoEncoder.mockCodecID])
        let hello = ControlMessage.hello(ver: WireVersion.current, width: 128, height: 64,
                                         tileSize: 64, pixfmt: PixelFormat.bgra8sRGB, caps: 0)
        viewer.handleControl(Data(hello.encoded()), nowUS: 0)
        let start = VideoMessage.start(region: 0, generation: 1, x: 0, y: 0, width: 128, height: 64,
                                       codec: MockVideoEncoder.mockCodecID,
                                       config: MockVideoEncoder.config(width: 128, height: 64))
        viewer.handleVideo(Data(start.encoded()), nowUS: 0)
        return (viewer, capture)
    }

    /// A malformed video stream fails the session. A private "dead" latch
    /// that ignored video and keyframes for the rest of the session would,
    /// in pinned mode, freeze the whole screen while motion lasted, with no
    /// signal.
    @Test func malformedVideoStreamFailsTheSession() {
        let (viewer, _) = makeVideoViewer()
        var reasons: [String] = []
        viewer.onFailed = { reasons.append($0) }
        // A TLV with an unknown type byte and a huge length is malformed.
        viewer.handleVideo(Data([0xEE, 0xFF, 0xFF, 0xFF, 0x7F]), nowUS: 1_000)
        #expect(viewer.state == .failed)
        #expect(reasons == ["malformed video stream"])
    }

    /// A replaced video stream must not frame its first bytes onto the old
    /// stream's partial message.
    @Test func videoStreamResetDiscardsPartialMessage() {
        let (viewer, _) = makeVideoViewer()
        let frame = VideoMessage.frame(region: 0, generation: 1, seq: 5, sync: true, captureUS: 0,
                                       data: [0] + [UInt8](repeating: 0x40, count: 128 * 64 * 4))
        let bytes = frame.encoded()
        viewer.handleVideo(Data(bytes.prefix(bytes.count / 2)), nowUS: 1_000) // stream dies mid-message
        viewer.resetVideoStream()
        viewer.handleVideo(Data(bytes), nowUS: 2_000) // replacement stream, whole message
        #expect(viewer.state == .running, "the new stream must frame cleanly")
        #expect(viewer.stats.videoFramesApplied == 1)
    }

    /// A region whose decoder keeps failing (dead hardware session, no sync
    /// frame to resync on — encoders only send them on demand) asks for a
    /// sync frame, and when none fixes it within the 2 s deadline escalates
    /// to a session failure instead of freezing indefinitely.
    @Test func persistentlyUndecodableRegionEscalates() {
        let (viewer, capture) = makeVideoViewer()
        var reasons: [String] = []
        viewer.onFailed = { reasons.append($0) }
        var t: UInt64 = 1_000
        for seq in UInt32(2)..<UInt32(100) { // ~2.4 s of garbage at 40 fps
            let garbage = VideoMessage.frame(region: 0, generation: 1, seq: seq, sync: false,
                                             captureUS: 0, data: [9, 9, 9])
            viewer.handleVideo(Data(garbage.encoded()), nowUS: t)
            t += 25_000
        }
        #expect(viewer.stats.videoDecodeFailures > 0)
        #expect(viewer.state == .failed)
        #expect(reasons.count == 1)
        // Nobody answers here: the viewer asked at most every 500 ms
        // (t = 0, 0.5, 1.0, 1.5, 2.0 s) before giving up.
        let requests = controlMessages(capture.sentControl).filter {
            if case .syncRequest(0, 1) = $0 { return true }
            return false
        }
        #expect(requests.count == 5)
        #expect(viewer.stats.videoSyncRequests == 5)
    }

    @Test func briefDecodeFailureDoesNotEscalate() {
        let (viewer, _) = makeVideoViewer()
        let garbage = VideoMessage.frame(region: 0, generation: 1, seq: 2, sync: false,
                                         captureUS: 0, data: [9])
        viewer.handleVideo(Data(garbage.encoded()), nowUS: 1_000)
        let good = VideoMessage.frame(region: 0, generation: 1, seq: 3, sync: true, captureUS: 0,
                                      data: [0] + [UInt8](repeating: 0x40, count: 128 * 64 * 4))
        viewer.handleVideo(Data(good.encoded()), nowUS: 500_000)
        viewer.handleVideo(Data(garbage.encoded()), nowUS: 1_400_000)
        #expect(viewer.state == .running, "a success resets the failure streak")
    }

    /// Encoder that delivers its first frame, then only empty deliveries —
    /// e.g. a VT session invalidated by sleep/wake.
    final class DyingEncoder: VideoRegionEncoder {
        let inner = MockVideoEncoder()
        var codecID: UInt8 { inner.codecID }
        private var onFrame: (([UInt8], Bool, [UInt8]?) -> Void)?
        private var frames = 0
        func start(width: Int, height: Int,
                   onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
            self.onFrame = onFrame
            return inner.start(width: width, height: height, onFrame: onFrame)
        }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
            frames += 1
            if frames == 1 {
                inner.encode(bgra: bgra, forceSync: forceSync, timeUS: timeUS)
            } else {
                onFrame?([], false, nil)
            }
        }
        func stop() { inner.stop() }
    }

    @Test func encoderThatStopsDeliveringDissolvesTheRegion() {
        var rng = SplitMix64(seed: 2601)
        let h = Harness(width: 640, height: 640, video: true,
                        encoderFactory: { _ in DyingEncoder() })
        h.frame.fillRandom(&rng)
        h.encodeFrame() // pinned cold start: the region carries the first paint
        #expect(h.host.activeVideoRegionCount == 1)
        let framesBefore = h.host.stats.videoFramesSent
        for _ in 0..<(HostEngine.videoMaxEmptyDeliveries + 5) {
            h.frame.fillRect(x: 0, y: 0, w: 640, h: 640, &rng)
            h.encodeFrame(dirtyRects: [DirtyRect(x: 0, y: 0, width: 640, height: 640)])
            h.run(untilUS: h.now + 16_000)
            if h.host.stats.videoEncoderFailures > 0 { break }
        }
        #expect(h.host.stats.videoFramesSent == framesBefore, "empty deliveries must never hit the wire")
        #expect(h.host.stats.videoEncoderFailures == 1, "a dead encoder must dissolve the region")
        #expect(h.settle(maxSimMS: 120_000))
        #expect(h.canvasMatchesFrame())
    }

    @Test func videoChannelResetDissolvesTheRegion() {
        var rng = SplitMix64(seed: 2602)
        let h = Harness(width: 640, height: 640, video: true)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.host.activeVideoRegionCount == 1)
        h.host.videoChannelReset()
        #expect(h.host.activeVideoRegionCount == 0)
        #expect(h.host.stats.videoChannelResets == 1)
        #expect(h.settle(maxSimMS: 120_000))
        #expect(h.canvasMatchesFrame())
    }

    // MARK: - ACK cadence

    private func acks(_ capture: CaptureTransport, seq: UInt32) -> [[UInt8]] {
        controlMessages(capture.sentControl).compactMap {
            if case let .ack(s, _, bitmap) = $0, s == seq { return bitmap }
            return nil
        }
    }

    /// An incomplete batch must keep being reported while other batches
    /// complete around it: a late datagram is ACKed promptly, and the slot
    /// gets keepalive re-ACKs. A single global "last ACK" timestamp, reset
    /// by every completion ACK, would suppress both under steady traffic.
    @Test func incompleteBatchKeepsReportingUnderSteadyTraffic() {
        var rng = SplitMix64(seed: 2603)
        let (viewer, capture) = makeRunningViewer(width: 256, height: 64) // 4 tiles
        func tile(_ i: Int) -> (UInt16, [UInt8]) { (UInt16(i), rng.bytes(64 * 64 * 4)) }
        // Batch 10: 3 datagrams, only #0 arrives now.
        viewer.handleDatagram(makeDatagram(seq: 10, dgramIdx: 0, dgramCnt: 3, records: [tile(0)]), nowUS: 0)
        var now: UInt64 = 0
        var seq: UInt32 = 11
        var lateDelivered = false
        while now < 400_000 {
            now += 5_000
            if now % 20_000 == 0 { // steady single-datagram batches completing
                viewer.handleDatagram(makeDatagram(seq: seq, records: [tile(3)]), nowUS: now)
                seq += 1
            }
            if now == 50_000 { // a late datagram for batch 10
                viewer.handleDatagram(makeDatagram(seq: 10, dgramIdx: 1, dgramCnt: 3, records: [tile(1)]), nowUS: now)
                lateDelivered = true
            }
            viewer.tick(nowUS: now)
            if lateDelivered && now == 70_000 {
                #expect(acks(capture, seq: 10).contains { $0 == [0b011] },
                        "the late datagram must be reported within ~8 ms, not at timeout")
            }
        }
        #expect(acks(capture, seq: 10).count >= 4, "keepalive re-ACKs every 100 ms for the incomplete slot")
    }

    /// With every ACK slot tracking a newer batch, a straggler from an older
    /// batch is reported on its own instead of evicting a tracked batch.
    @Test func stragglerDoesNotEvictTrackedBatches() {
        var rng = SplitMix64(seed: 2604)
        let (viewer, capture) = makeRunningViewer(width: 256, height: 64)
        for s in UInt32(20)..<UInt32(24) { // four incomplete batches fill the slots
            viewer.handleDatagram(makeDatagram(seq: s, dgramIdx: 0, dgramCnt: 2,
                                               records: [(UInt16(s - 20), rng.bytes(64 * 64 * 4))]), nowUS: 0)
        }
        viewer.handleDatagram(makeDatagram(seq: 5, dgramIdx: 1, dgramCnt: 2,
                                           records: [(0, rng.bytes(64 * 64 * 4))]), nowUS: 1_000)
        #expect(acks(capture, seq: 5) == [[0b10]], "the straggler is ACKed on its own")
        // Batch 20 completes: its earlier datagram must still be remembered.
        viewer.handleDatagram(makeDatagram(seq: 20, dgramIdx: 1, dgramCnt: 2,
                                           records: [(1, rng.bytes(64 * 64 * 4))]), nowUS: 2_000)
        #expect(acks(capture, seq: 20).contains([0b11]), "tracked batch 20 must not have been evicted")
    }

    @Test func abandonedIncompleteSlotsExpire() {
        var rng = SplitMix64(seed: 2605)
        let (viewer, capture) = makeRunningViewer(width: 256, height: 64)
        viewer.handleDatagram(makeDatagram(seq: 30, dgramIdx: 0, dgramCnt: 2,
                                           records: [(0, rng.bytes(64 * 64 * 4))]), nowUS: 0)
        viewer.handleDatagram(makeDatagram(seq: 31, records: [(1, rng.bytes(64 * 64 * 4))]), nowUS: 0)
        var now: UInt64 = 0
        while now < ViewerEngine.ackSlotExpiryUS + 1_000_000 {
            now += 10_000
            viewer.tick(nowUS: now)
        }
        let before = acks(capture, seq: 30).count
        for _ in 0..<100 {
            now += 10_000
            viewer.tick(nowUS: now)
        }
        #expect(acks(capture, seq: 30).count == before, "an expired slot is no longer re-ACKed")
    }
}

/// "Failed" is terminal and silent: once an engine fails, nothing more goes
/// out — not even for messages that arrived in the same chunk as the fault.
@Suite struct FailedIsSilentTests {
    @Test func viewerSendsNothingAfterFailingMidChunk() {
        let (viewer, capture) = makeRunningViewer(width: 128, height: 128)
        let sentBefore = capture.sentControl.count
        // One chunk: an in-session HELLO the viewer must reject (0×0), then a
        // PING that a running viewer would answer with a PONG.
        var chunk = ControlMessage.hello(ver: WireVersion.current, width: 0, height: 0,
                                         tileSize: UInt8(TileGrid.tileSize),
                                         pixfmt: PixelFormat.bgra8sRGB, caps: 0).encoded()
        chunk += ControlMessage.ping(nonce: 7, tUS: 1_000).encoded()
        viewer.handleControl(Data(chunk), nowUS: 2_000)
        #expect(viewer.state == .failed)
        #expect(capture.sentControl.count == sentBefore, "a failed engine sent \(capture.sentControl.count - sentBefore) message(s)")
    }

    /// A region undecodable for > 2 s fails the engine from inside the video
    /// loop; a keyframe later in the SAME chunk must then neither apply nor
    /// send KEYFRAME_ACK.
    @Test func viewerSendsNothingAfterVideoFailsMidChunk() {
        let capture = CaptureTransport()
        let v = ViewerEngine(transport: capture, videoDecoderFactory: { MockVideoDecoder() },
                             supportedVideoCodecs: [MockVideoEncoder.mockCodecID])
        v.handleControl(Data(ControlMessage.hello(ver: WireVersion.current, width: 128, height: 64,
                                                  tileSize: 64, pixfmt: PixelFormat.bgra8sRGB,
                                                  caps: 0).encoded()), nowUS: 0)
        #expect(v.state == .running)
        func undecodable(_ seq: UInt32) -> [UInt8] {
            VideoMessage.frame(region: 0, generation: 1, seq: seq, sync: true, captureUS: 0, data: [0xEE]).encoded()
        }
        let start = VideoMessage.start(region: 0, generation: 1, x: 0, y: 0, width: 128, height: 64,
                                       codec: MockVideoEncoder.mockCodecID,
                                       config: MockVideoEncoder.config(codecID: MockVideoEncoder.mockCodecID,
                                                                       width: 128, height: 64)).encoded()
        v.handleVideo(Data(start + undecodable(1)), nowUS: 1_000)
        #expect(v.state == .running, "one bad frame is not fatal")

        var flat = [UInt8](repeating: 0x40, count: 128 * 64 * 4)
        for i in stride(from: 3, to: flat.count, by: 4) { flat[i] = 0xFF }
        var out = [UInt8](repeating: 0, count: 128 * 64 * 4)
        let n = flat.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { WebPTile.encodeLossless(src: src, width: 128, height: 64, effort: 4, dst: $0) }
        }
        let keyframe = VideoMessage.keyframe(seq: 5, x: 0, y: 0, width: 128, height: 64,
                                             codec: KeyframeCodec.vp8lStriped,
                                             stripes: [[UInt8](out[0..<n])]).encoded()
        let sentBefore = capture.sentControl.count
        // > 2 s later: this frame escalates to .failed (and asks for no
        // sync frame); the keyframe follows in the same chunk.
        v.handleVideo(Data(undecodable(2) + keyframe), nowUS: 2_100_000)
        #expect(v.state == .failed)
        #expect(v.stats.keyframesApplied == 0, "nothing applies after the failure")
        #expect(capture.sentControl.count == sentBefore, "a failed engine sent a KEYFRAME_ACK")
    }
}

@Suite struct SendBoundsTests {
    @Test func clipboardAtTheBoundSendsAndOverItDoesNot() {
        let (host, capture) = makeRunningHost(width: 128, height: 64)
        let before = capture.sentControl.count
        host.sendClipboard(format: 1, data: [UInt8](repeating: 0x61, count: 1 << 20))
        #expect(capture.sentControl.count == before, "over the bound: dropped at the sender")
        host.sendClipboard(format: 1, data: [UInt8](repeating: 0x61, count: ControlMessage.maxClipboardBytes))
        #expect(capture.sentControl.count == before + 1)
        var d = ControlDeframer()
        d.append(capture.sentControl.last!)
        #expect(d.next() != nil)
        #expect(!d.isMalformed, "the receiver must accept the largest clipboard")
    }

    /// A switch/scale geometry request with nonsense dimensions is answered
    /// as native instead of reaching the app (which would compute a 0×0
    /// capture).
    @Test func insaneHandshakeGeometryIsTreatedAsNative() {
        let capture = CaptureTransport()
        let host = HostEngine(width: 128, height: 64, transport: capture)
        var requested: [Int] = []
        host.onResizeRequested = { mode, _, _, _ in requested.append(mode) }
        host.start(nowUS: 0)
        let helloOK = ControlMessage.helloOK(ver: WireVersion.current, caps: 0,
                                             geoMode: 2, geoWidth: 0, geoHeight: 900, geoScale: 0)
        host.handleControl(Data(helloOK.encoded()), nowUS: 1_000)
        #expect(requested == [3])
    }
}

@Suite struct BatchLimitTests {
    private func runningHost(_ w: Int, _ h: Int, maxBatch: Int = HostEngine.wireMaxBatchDatagrams)
        -> (HostEngine, CaptureTransport) {
        let capture = CaptureTransport()
        let host = HostEngine(width: w, height: h, transport: capture, maxBatchDatagrams: maxBatch)
        host.start(nowUS: 0)
        let ok = ControlMessage.helloOK(ver: WireVersion.current, caps: 0,
                                        geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0)
        host.handleControl(Data(ok.encoded()), nowUS: 1_000)
        return (host, capture)
    }

    /// dgram_cnt is a u16: a batch must stop admitting tiles before it could
    /// overflow (it would trap at 6K/8K with incompressible content), and the
    /// tiles left out must still ship on later ticks without dirty rects.
    @Test func batchStopsAtItsDatagramCapAndDefersTheRest() {
        var rng = SplitMix64(seed: 2801)
        let (host, capture) = runningHost(1280, 1280, maxBatch: 300) // 400 RAW tiles ≈ 6k datagrams
        var frame = TestFrame(width: 1280, height: 1280)
        frame.fillRandom(&rng)
        var now: UInt64 = 10_000
        var seen = Set<UInt16>()
        for tick in 0..<400 {
            let mark = capture.sentDatagrams.count
            frame.encode(host: host, dirtyRects: tick == 0 ? nil : [], nowUS: now)
            let sent = Array(capture.sentDatagrams[mark...])
            if let h = sent.first.flatMap(header(of:)) {
                #expect(Int(h.dgramCnt) <= 300, "batch exceeded its datagram cap")
            }
            for d in sent {
                _ = d.withUnsafeBytes { raw in Datagram.parse(raw) { _, rec in seen.insert(rec.tileIdx) } }
            }
            for ack in fullAcks(for: sent) { host.handleControl(ack, nowUS: now + 1_000) }
            now += 50_000
            if seen.count == 400 { break }
        }
        #expect(host.stats.batchCapDeferredTiles > 0, "the cap must have engaged")
        #expect(seen.count == 400, "every tile must eventually ship (\(seen.count)/400)")
    }

    /// QUIC reports the path's usable datagram size only once the flow is
    /// ready — after the engine exists. The budget must follow it.
    @Test func datagramBudgetFollowsTheTransport() {
        var rng = SplitMix64(seed: 2802)
        let (host, capture) = runningHost(256, 128)
        capture.maxDatagramSize = 1100 // smaller path reported after init
        var frame = TestFrame(width: 256, height: 128)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        #expect(!capture.sentDatagrams.isEmpty)
        #expect(capture.sentDatagrams.allSatisfy { $0.count <= 1100 - 32 },
                "datagrams must fit the path reported after the engine was built")
    }
}
