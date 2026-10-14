import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Lossless region keyframes (§4.7): one striped-VP8L image instead of N tile
/// records, riding the reliable video stream, LWW-stamped and ACK-promoted
/// like a batch of one giant record.
@Suite struct KeyframeTests {
    /// Cold start ships as a keyframe (zero tile records, zero datagrams for
    /// pixels) and converges byte-exactly once ACKed.
    @Test func coldStartRidesKeyframe() {
        var rng = SplitMix64(seed: 901)
        let h = Harness(width: 320, height: 320)
        // Compressible content (VP8L-friendly): text-like structure.
        for i in 0..<h.frame.bytes.count {
            h.frame.bytes[i] = (i & 3) == 3 ? 0xFF : ((i / 4) % 97 == 0 ? 0xE0 : 0x20)
        }
        h.encodeFrame()
        h.run(untilUS: h.now + 300_000)
        _ = rng
        #expect(h.host.stats.keyframesSent == 1, "cold start must ship as a keyframe")
        #expect(h.host.stats.tilesSent == 0, "no tile records on a keyframed cold start")
        #expect(h.host.stats.datagramsSent == 0, "no pixel datagrams on a keyframed cold start")
        #expect(h.viewer.stats.keyframesApplied == 1)
        #expect(!h.host.keyframeInFlight, "ACK must resolve the keyframe")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "keyframed cold start must converge byte-exactly")

        // And the shadow/acked state is real: an incremental change after the
        // keyframe sends only the changed tiles.
        let tilesBefore = h.host.stats.tilesSent
        h.frame.fillRect(x: 0, y: 0, w: 64, h: 64, &rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 200_000)
        #expect(h.host.stats.tilesSent - tilesBefore == 1, "keyframe must seed the shadow map")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }

    /// Incompressible content fails the byte budget and falls back to the
    /// tile flood — the keyframe is an optimization, never a requirement.
    @Test func incompressibleColdStartFallsBack() {
        var rng = SplitMix64(seed: 902)
        let h = Harness(width: 320, height: 320)
        h.frame.fillRandom(&rng) // noise: VP8L cannot beat RAW per stripe
        h.encodeFrame()
        h.run(untilUS: h.now + 300_000)
        #expect(h.host.stats.keyframesSent == 0)
        #expect(h.host.stats.keyframeFallbacks == 1)
        #expect(h.host.stats.tilesSent == 25, "tile path must carry the cold start")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }

    /// LWW: a record sent after the keyframe (newer seq) must beat the
    /// keyframe's content at the viewer even though the keyframe applies
    /// later — and the host's bookkeeping must agree (INV-9 seq guard).
    @Test func newerRecordBeatsKeyframe() {
        let capture = CaptureTransport()
        let v = ViewerEngine(transport: capture)
        v.handleControl(Data(ControlMessage.hello(ver: WireVersion.current, width: 128, height: 64,
                                                  tileSize: 64, pixfmt: PixelFormat.bgra8sRGB,
                                                  caps: 0).encoded()), nowUS: 0)
        #expect(v.state == .running)
        var rng = SplitMix64(seed: 903)
        // A newer record for tile 0 lands first.
        let newer = rng.bytes(64 * 64 * 4)
        v.handleDatagram(makeDatagram(seq: 10, records: [(0, newer)]), nowUS: 0)

        // A keyframe stamped seq 5 covering both tiles arrives late.
        var flat = [UInt8](repeating: 0x40, count: 128 * 64 * 4)
        for i in stride(from: 3, to: flat.count, by: 4) { flat[i] = 0xFF }
        var out = [UInt8](repeating: 0, count: 128 * 64 * 4)
        let n = flat.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                WebPTile.encodeLossless(src: src, width: 128, height: 64, effort: 4, dst: dst)
            }
        }
        #expect(n > 0)
        let kf = VideoMessage.keyframe(seq: 5, x: 0, y: 0, width: 128, height: 64,
                                       codec: KeyframeCodec.vp8lStriped,
                                       stripes: [[UInt8](out[0..<n])])
        v.handleVideo(Data(kf.encoded()), nowUS: 0)
        #expect(v.stats.keyframesApplied == 1)
        #expect(canvasTile(v, 0) == newer, "tile 0: the newer record must win")
        var expectTile1 = [UInt8](repeating: 0x40, count: 64 * 64 * 4)
        for i in stride(from: 3, to: expectTile1.count, by: 4) { expectTile1[i] = 0xFF }
        #expect(canvasTile(v, 1) == expectTile1, "tile 1: the keyframe must apply")
        // ACK went out regardless (application is per-tile LWW).
        let acks = controlMessages(capture.sentControl).filter {
            if case .keyframeAck(seq: 5) = $0 { return true } else { return false }
        }
        #expect(acks.count == 1)
    }

    /// The lossy first paint precedes the lossless keyframe on the
    /// ordered stream, gives the viewer a full (approximate) picture
    /// immediately, and is completely erased by the lossless state: settle
    /// is byte-exact, and no ACK is generated for the transient paint.
    @Test func lossyFirstPaintPrecedesAndConverges() {
        let h = Harness(width: 320, height: 320)
        for i in 0..<h.frame.bytes.count { // gradient: lossy artifacts guaranteed
            h.frame.bytes[i] = (i & 3) == 3 ? 0xFF : UInt8((i / 320) & 0xFF)
        }
        h.encodeFrame()
        h.run(untilUS: h.now + 300_000)
        #expect(h.host.stats.lossyFirstPaintsSent == 1, "cold start must send the first paint")
        #expect(h.viewer.stats.lossyPaintsApplied == 1, "viewer must blit the transient paint")
        #expect(h.host.stats.keyframesSent == 1, "lossless keyframe still follows")
        #expect(h.viewer.stats.keyframesApplied == 1)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "lossy paint must be fully erased by lossless state")
    }

    /// The transient paint must lose to any real record already applied
    /// (it never advances tileSeq, and its blit is LWW-gated).
    @Test func lossyPaintNeverBeatsRealRecords() {
        var rng = SplitMix64(seed: 905)
        let (viewer, capture) = makeRunningViewer(width: 128, height: 64)
        _ = capture
        let record = rng.bytes(64 * 64 * 4)
        viewer.handleDatagram(makeDatagram(seq: 10, records: [(0, record)]), nowUS: 0)

        // A late lossy paint stamped 5 (older than the record's 10).
        var flat = [UInt8](repeating: 0x60, count: 128 * 64 * 4)
        for i in stride(from: 3, to: flat.count, by: 4) { flat[i] = 0xFF }
        var out = [UInt8](repeating: 0, count: 128 * 64 * 4)
        let n = flat.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                WebPTile.encodeLossy(src: src, width: 128, height: 64, quality: 90, dst: dst)
            }
        }
        #expect(n > 0)
        let kf = VideoMessage.keyframe(seq: 5, x: 0, y: 0, width: 128, height: 64,
                                       codec: KeyframeCodec.webpLossyStriped,
                                       stripes: [[UInt8](out[0..<n])])
        viewer.handleVideo(Data(kf.encoded()), nowUS: 0)
        #expect(viewer.stats.lossyPaintsApplied == 1)
        #expect(canvasTile(viewer, 0) == record, "tile 0: the real record must survive the paint")
        // And no keyframe ACK was sent for a transient paint.
        let acks = controlMessages(capture.sentControl).filter {
            if case .keyframeAck = $0 { return true } else { return false }
        }
        #expect(acks.isEmpty)
    }

    /// Faulted golden with keyframes in play: the keyframe rides the reliable
    /// stream (unaffected), records race it on lossy datagrams, and settle is
    /// byte-exact. Three seeds.
    @Test(arguments: [UInt64(61), 62, 63])
    func keyframeGoldenUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = seed
        var rng = SplitMix64(seed: seed &* 907)
        let h = Harness(width: 320, height: 320, faults: faults)
        for i in 0..<h.frame.bytes.count { // compressible cold start → keyframe
            h.frame.bytes[i] = (i & 3) == 3 ? 0xFF : UInt8((i / 640) & 0x7F)
        }
        h.encodeFrame()
        h.run(untilUS: h.now + 500_000)
        #expect(h.host.stats.keyframesSent >= 1, "seed \(seed): cold start keyframe")

        for _ in 0..<30 { // churn racing the keyframe's tail
            _ = h.mutateRandomRects(&rng, count: 2)
            h.encodeFrame()
            h.run(untilUS: h.now + 20_000)
        }
        #expect(h.settle(), "seed \(seed)")
        #expect(h.canvasMatchesFrame(), "seed \(seed): byte-exact with keyframes in play")
    }
}
