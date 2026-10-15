import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActTestSupport

@Suite struct HandshakeTests {
    @Test func handshakeCompletesAndSeedsSRTT() {
        let harness = Harness()
        #expect(harness.host.state == .running)
        #expect(harness.viewer.state == .running)
        #expect(harness.viewer.grid?.count == 20) // 320×240 → 5×4
    }

    @Test func hostFailsOnIncompatibleHelloOKVersion() {
        let capture = CaptureTransport()
        let host = HostEngine(width: 64, height: 64, transport: capture)
        host.start(nowUS: 0)
        let badVersion = ControlMessage.helloOK(ver: WireVersion.current &+ 1, caps: 0, geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0)
        host.handleControl(Data(badVersion.encoded()), nowUS: 1_000)
        #expect(host.state == .failed)
        var frame = TestFrame(width: 64, height: 64)
        var rng = SplitMix64(seed: 1)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        #expect(capture.sentDatagrams.isEmpty) // a failed engine never sends pixels
    }

    @Test func viewerFailsOnIncompatibleHelloButStillReportsItsVersion() {
        let capture = CaptureTransport()
        let viewer = ViewerEngine(transport: capture)
        let badHello = ControlMessage.hello(ver: WireVersion.current &+ 1, width: 64, height: 64,
                                            tileSize: 64, pixfmt: PixelFormat.bgra8sRGB, caps: 0)
        viewer.handleControl(Data(badHello.encoded()), nowUS: 0)
        #expect(viewer.state == .failed)
        // The reply carries the viewer's own version so the host also learns
        // of the mismatch and fails symmetrically.
        guard case let .helloOK(ver, _, _, _, _, _)? = controlMessages(capture.sentControl).first else {
            Issue.record("expected HELLO_OK reply")
            return
        }
        #expect(ver == WireVersion.current)
    }

    @Test func viewerRejectsUnreasonableGeometry() {
        let capture = CaptureTransport()
        let viewer = ViewerEngine(transport: capture)
        let hostile = ControlMessage.hello(ver: WireVersion.current, width: 65_535, height: 65_535,
                                           tileSize: 64, pixfmt: PixelFormat.bgra8sRGB, caps: 0)
        viewer.handleControl(Data(hostile.encoded()), nowUS: 0) // 17 GB canvas ask (INV-6)
        #expect(viewer.state == .failed)
    }
}

@Suite struct AckCadenceTests {
    @Test func completionAckIsImmediate() {
        let (viewer, capture) = makeRunningViewer(width: 128, height: 64)
        var rng = SplitMix64(seed: 5)
        let payload = rng.bytes(64 * 64 * 4)
        viewer.handleDatagram(makeDatagram(seq: 7, records: [(0, payload)]), nowUS: 1_000)
        let acks = controlMessages(capture.sentControl).filter {
            if case .ack = $0 { return true } else { return false }
        }
        guard case let .ack(seq, cnt, bitmap)? = acks.first else {
            Issue.record("expected completion ACK")
            return
        }
        #expect(seq == 7 && cnt == 1 && bitmap == [0b1])
    }

    @Test func partialAckAfter8msForIncompleteBatch() {
        let (viewer, capture) = makeRunningViewer(width: 128, height: 64)
        var rng = SplitMix64(seed: 6)
        let payload = rng.bytes(64 * 64 * 4)
        // Datagram 0 of a 2-datagram batch; datagram 1 never arrives.
        viewer.handleDatagram(makeDatagram(seq: 9, dgramIdx: 0, dgramCnt: 2,
                                           records: [(0, payload)]), nowUS: 1_000)
        viewer.tick(nowUS: 5_000) // < 8 ms after first datagram
        #expect(controlMessages(capture.sentControl).allSatisfy {
            if case .ack = $0 { return false } else { return true }
        })
        viewer.tick(nowUS: 9_500) // ≥ 8 ms
        let acks = controlMessages(capture.sentControl).compactMap { m -> (UInt32, UInt16, [UInt8])? in
            if case let .ack(s, c, b) = m { return (s, c, b) } else { return nil }
        }
        #expect(acks.count == 1)
        #expect(acks.first?.0 == 9)
        #expect(acks.first?.2 == [0b01]) // partial bitmap: only datagram 0
    }

    @Test func keepaliveReAcksLatestBatchEvery100ms() {
        let (viewer, capture) = makeRunningViewer(width: 128, height: 64)
        var rng = SplitMix64(seed: 8)
        let payload = rng.bytes(64 * 64 * 4)
        viewer.handleDatagram(makeDatagram(seq: 4, records: [(0, payload)]), nowUS: 1_000)
        for ms in stride(from: 2, through: 350, by: 1) {
            viewer.tick(nowUS: UInt64(ms) * 1_000)
        }
        let ackCount = controlMessages(capture.sentControl).count {
            if case .ack(4, _, _) = $0 { return true } else { return false }
        }
        #expect(ackCount >= 4) // completion + ≥ 3 keepalives over 350 ms
    }
}

@Suite struct FragmentationTests {
    @Test func fragmentedTilesReassembleAllOrNothing() {
        var rng = SplitMix64(seed: 15)
        let (host, hostCapture) = makeRunningHost(width: 64, height: 64)
        var frame = TestFrame(width: 64, height: 64)
        frame.fillRandom(&rng) // noise → RAW → ~14 fragments at budget 1200
        frame.encode(host: host, nowUS: 10_000)
        let datagrams = hostCapture.sentDatagrams
        #expect(datagrams.count > 1)

        // Withhold one datagram: the tile must not apply at all.
        let (viewer, _) = makeRunningViewer(width: 64, height: 64)
        for d in datagrams.dropLast() {
            viewer.handleDatagram(d, nowUS: 1_000)
        }
        #expect(viewer.stats.recordsApplied == 0)
        #expect(canvasTile(viewer, 0) == [UInt8](repeating: 0, count: 64 * 64 * 4))

        // Deliver the withheld datagram (out of order is fine): tile applies.
        viewer.handleDatagram(datagrams.last!, nowUS: 2_000)
        #expect(canvasTile(viewer, 0) == frame.tightTile(0))
    }

    @Test func duplicateAndReorderedFragmentsAreHarmless() {
        var rng = SplitMix64(seed: 16)
        let (host, hostCapture) = makeRunningHost(width: 64, height: 64)
        var frame = TestFrame(width: 64, height: 64)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        var datagrams = hostCapture.sentDatagrams
        datagrams.shuffle(using: &rng)
        let (viewer, _) = makeRunningViewer(width: 64, height: 64)
        for d in datagrams + datagrams { // every datagram delivered twice
            viewer.handleDatagram(d, nowUS: 1_000)
        }
        #expect(canvasTile(viewer, 0) == frame.tightTile(0))
    }

    @Test func expiredPartialsAreDiscarded() {
        var rng = SplitMix64(seed: 17)
        let (host, hostCapture) = makeRunningHost(width: 64, height: 64)
        var frame = TestFrame(width: 64, height: 64)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        let datagrams = hostCapture.sentDatagrams
        let (viewer, _) = makeRunningViewer(width: 64, height: 64)
        viewer.handleDatagram(datagrams[0], nowUS: 1_000)
        viewer.tick(nowUS: 300_000) // > 250 ms: partial expires
        for d in datagrams.dropFirst() {
            viewer.handleDatagram(d, nowUS: 301_000)
        }
        // First fragment expired, so the tile stays unapplied (host-side
        // timeout re-encodes in real operation).
        #expect(viewer.stats.recordsApplied == 0)
    }
}

@Suite struct ResizeTests {
    /// RESIZE reaches the host app hook, so a request can't silently vanish
    /// (this pins the engine half of the path).
    @Test func resizeRequestSurfacesToApp() {
        let (host, _) = makeRunningHost(width: 128, height: 64)
        var got: (Int, Int, Int, Int)?
        host.onResizeRequested = { got = ($0, $1, $2, $3) }
        let tlv = Data(ControlMessage.resize(mode: 1, width: 1470, height: 956, scale: 2).encoded())
        host.handleControl(tlv, nowUS: 5_000)
        #expect(got?.0 == 1 && got?.1 == 1470 && got?.2 == 956 && got?.3 == 2)
    }
}
