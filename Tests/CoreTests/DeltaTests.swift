import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Hash-pinned DELTA records (§4.8): encode the difference against the ACKed
/// shadow, pinned by the base's hash. Legal residual coding: the base is
/// ACK-confirmed, hash-verified content (INV-1's letter, INV-3's discipline).
@Suite struct DeltaTests {
    /// A small edit to a quiescent-acked tile ships as a delta (much smaller
    /// than the full tile) and converges byte-exactly.
    @Test func smallEditRidesDelta() {
        var rng = SplitMix64(seed: 1001)
        let h = Harness(width: 320, height: 320)
        for i in 0..<h.frame.bytes.count { // structured, VP8L-friendly base
            h.frame.bytes[i] = (i & 3) == 3 ? 0xFF : UInt8((i / 1280) & 0x3F)
        }
        h.encodeFrame()
        h.run(untilUS: h.now + 300_000) // cold start (keyframe) + ACK

        // One keystroke-sized change: 24×20 pixels inside tile 6.
        let bytesBefore = h.host.stats.bytesOut
        for py in 80..<100 {
            for px in 90..<114 {
                let o = (py * 320 + px) * 4
                h.frame.bytes[o] = UInt8(truncatingIfNeeded: rng.next())
                h.frame.bytes[o + 1] = 0x10
                h.frame.bytes[o + 2] = 0xE0
                h.frame.bytes[o + 3] = 0xFF
            }
        }
        h.encodeFrame(dirtyRects: [DirtyRect(x: 90, y: 80, width: 24, height: 20)])
        h.run(untilUS: h.now + 200_000)
        #expect(h.host.stats.deltasSent == 1, "quiescent-acked small edit must ship as a delta")
        #expect(h.viewer.stats.deltasApplied == 1)
        #expect(h.viewer.stats.deltaBaseMisses == 0)
        let editBytes = h.host.stats.bytesOut - bytesBefore
        #expect(editBytes < 1200, "keystroke-sized delta should be small (got \(editBytes) B)")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "delta apply must be byte-exact")
    }

    /// Deltas only fire against quiescent-acked bases: a tile with an
    /// in-flight send keeps using absolute payloads.
    @Test func inflightTilesNeverDelta() {
        var rng = SplitMix64(seed: 1002)
        let (host, capture) = makeRunningHost(width: 128, height: 64, deltas: true)
        var frame = TestFrame(width: 128, height: 64)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        for ack in fullAcks(for: capture.sentDatagrams) { host.handleControl(ack, nowUS: 20_000) }
        // Settled base: a small edit rides a delta…
        frame.fillRect(x: 0, y: 0, w: 8, h: 8, &rng)
        frame.encode(host: host, nowUS: 40_000)
        #expect(host.stats.deltasSent == 1, "a small edit to a settled tile rides a delta")
        // …but while that send is still in flight, the next edit is absolute.
        #expect(host.inflight(forTile: 0).seq != 0)
        frame.fillRect(x: 0, y: 0, w: 8, h: 8, &rng)
        frame.encode(host: host, nowUS: 50_000)
        #expect(host.inflight(forTile: 0).seq != 0)
        #expect(host.stats.deltasSent == 1, "no delta against a base with a send in flight")
    }

    /// Base-mismatch is a clean drop: forged/stale base hash must not apply,
    /// must count, must not advance the tile — and must be REPORTED, because
    /// the host's bitmap ACK promotes on receipt and would otherwise cement
    /// a base the viewer never had.
    @Test func baseMismatchDropsCleanlyAndNacks() {
        var rng = SplitMix64(seed: 1003)
        let (viewer, capture) = makeRunningViewer(width: 128, height: 64)
        let content = rng.bytes(64 * 64 * 4)
        viewer.handleDatagram(makeDatagram(seq: 5, records: [(0, content)]), nowUS: 0)
        #expect(canvasTile(viewer, 0) == content)

        // Delta pinned to a wrong base hash.
        var payload: [UInt8] = [0] // mode 0 XOR
        withUnsafeBytes(of: UInt64(0xDEAD_BEEF).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(Opcode.raw)
        payload.append(contentsOf: [UInt8](repeating: 0xFF, count: 64 * 64 * 4))
        var w = ByteWriter()
        DatagramHeader(frameSeq: 9, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        Datagram.appendRecord(opcode: Opcode.delta, tileIdx: 0, fragIdx: 0, fragCnt: 1,
                              payload: payload, into: &w)
        viewer.handleDatagram(Data(w.bytes), nowUS: 0)
        #expect(viewer.stats.deltaBaseMisses == 1)
        #expect(viewer.stats.deltasApplied == 0)
        #expect(canvasTile(viewer, 0) == content, "mismatched delta must not touch the canvas")
        let nacks = controlMessages(capture.sentControl).filter {
            if case .deltaNack(frameSeq: 9, tiles: [0]) = $0 { return true } else { return false }
        }
        #expect(nacks.count == 1, "the miss must be reported (received ≠ applied)")
    }

    /// Host repair: a DELTA_NACK demotes the tile (acked hash zeroed, slot
    /// cleared under the INV-9 seq guard) so the bitmap ACK for the same send
    /// cannot promote the never-applied hash, and the next send is absolute.
    /// Both arrival orders (NACK→ACK and ACK→NACK) must end identically —
    /// without this, one base-miss cements a permanently diverged tile
    /// (measured on the photos loop replay).
    @Test(arguments: [true, false])
    func deltaNackDemotesAndHealsAbsolute(nackFirst: Bool) {
        var rng = SplitMix64(seed: 1004)
        let (host, capture) = makeRunningHost(width: 128, height: 64, deltas: true)
        var frame = TestFrame(width: 128, height: 64)
        for i in 0..<frame.bytes.count { // structured: delta-eligible content
            frame.bytes[i] = (i & 3) == 3 ? 0xFF : UInt8((i / 512) & 0x3F)
        }
        frame.encode(host: host, nowUS: 10_000)
        for ack in fullAcks(for: capture.sentDatagrams) { host.handleControl(ack, nowUS: 20_000) }

        // Small edit → the tile ships as a delta.
        let datagramsBefore = capture.sentDatagrams.count
        frame.fillRect(x: 8, y: 8, w: 12, h: 10, &rng)
        frame.encode(host: host, nowUS: 40_000)
        let sent = Array(capture.sentDatagrams[datagramsBefore...])
        #expect(host.stats.deltasSent == 1, "precondition: the edit must ride a delta")
        guard let deltaSeq = header(of: sent[0])?.frameSeq else {
            Issue.record("unparseable delta datagram")
            return
        }

        // The viewer reports base-miss; the bitmap ACK races it either way.
        let nack = Data(ControlMessage.deltaNack(frameSeq: deltaSeq, tiles: [0]).encoded())
        let acks = fullAcks(for: sent)
        if nackFirst {
            host.handleControl(nack, nowUS: 50_000)
            for a in acks { host.handleControl(a, nowUS: 51_000) }
        } else {
            for a in acks { host.handleControl(a, nowUS: 50_000) }
            host.handleControl(nack, nowUS: 51_000)
        }
        #expect(host.stats.deltaNacksRepaired == 1)

        // Same frame, next tick: the tile must re-qualify and ship ABSOLUTE.
        let before = capture.sentDatagrams.count
        frame.encode(host: host, nowUS: 80_000)
        var resent: [(tile: UInt16, opcode: UInt8)] = []
        for d in capture.sentDatagrams[before...] {
            _ = d.withUnsafeBytes { raw in
                Datagram.parse(raw) { _, rec in
                    if rec.fragIdx == 0 { resent.append((rec.tileIdx, rec.opcode)) }
                }
            }
        }
        #expect(resent.count == 1, "demoted tile must re-qualify (got \(resent.count) records)")
        #expect(resent.first?.opcode != Opcode.delta,
                "the heal must be an absolute record, not another pinned delta")
    }

    /// The full golden gauntlet with deltas active: typing-like small edits
    /// under faults, byte-exact at settle. Three seeds.
    @Test(arguments: [UInt64(71), 72, 73])
    func deltaGoldenUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = seed
        var rng = SplitMix64(seed: seed &* 1013)
        let h = Harness(width: 320, height: 320, faults: faults)
        for i in 0..<h.frame.bytes.count {
            h.frame.bytes[i] = (i & 3) == 3 ? 0xFF : UInt8((i / 640) & 0x7F)
        }
        h.encodeFrame()
        h.run(untilUS: h.now + 500_000)

        for _ in 0..<60 { // keystroke-sized edits at random positions
            let x = rng.int(0..<300)
            let y = rng.int(0..<300)
            h.frame.fillRect(x: x, y: y, w: rng.int(4..<20), h: rng.int(4..<20), &rng)
            h.encodeFrame()
            h.run(untilUS: h.now + 20_000)
        }
        #expect(h.host.stats.deltasSent > 0, "seed \(seed): deltas must engage")
        #expect(h.settle(), "seed \(seed)")
        #expect(h.canvasMatchesFrame(), "seed \(seed): byte-exact with deltas under faults")
        #expect(h.viewer.stats.deltaBaseMisses == 0, "seed \(seed): quiescent discipline must hold")
    }
}
