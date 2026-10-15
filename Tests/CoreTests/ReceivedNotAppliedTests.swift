import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTestSupport

/// Received ≠ applied: the viewer ACKs every datagram it receives, and the
/// host promotes each tile on that ACK. Any record that would have won LWW
/// but could not be applied must be reported (DELTA_NACK), or the host
/// believes the tile is current while the canvas keeps stale pixels — and
/// static content never re-qualifies.
@Suite struct ReceivedNotAppliedTests {
    private func nacks(_ capture: CaptureTransport, seq: UInt32, tile: UInt16) -> Int {
        controlMessages(capture.sentControl).filter {
            if case let .deltaNack(frameSeq: s, tiles: t) = $0 { return s == seq && t == [tile] }
            return false
        }.count
    }

    private func record(seq: UInt32, tile: UInt16, opcode: UInt8, payload: [UInt8]) -> Data {
        var w = ByteWriter()
        DatagramHeader(frameSeq: seq, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        Datagram.appendRecord(opcode: opcode, tileIdx: tile, fragIdx: 0, fragCnt: 1,
                              payload: payload, into: &w)
        return Data(w.bytes)
    }

    @Test func undecodableRecordThatWouldWinIsNacked() {
        let (viewer, capture) = makeRunningViewer(width: 128, height: 64)
        // RAW of the wrong length, LZ4 garbage, WEBPL garbage, reserved opcode.
        viewer.handleDatagram(record(seq: 5, tile: 0, opcode: Opcode.raw, payload: [1, 2, 3]), nowUS: 0)
        viewer.handleDatagram(record(seq: 6, tile: 0, opcode: Opcode.lz4,
                                     payload: [UInt8](repeating: 0xAB, count: 64)), nowUS: 0)
        viewer.handleDatagram(record(seq: 7, tile: 0, opcode: Opcode.webpl,
                                     payload: [UInt8](repeating: 0xCD, count: 64)), nowUS: 0)
        viewer.handleDatagram(record(seq: 8, tile: 0, opcode: 0x05,
                                     payload: [UInt8](repeating: 0, count: 16)), nowUS: 0)
        for seq: UInt32 in 5...8 {
            #expect(nacks(capture, seq: seq, tile: 0) == 1, "seq \(seq) rejected without a NACK")
        }
        #expect(viewer.stats.recordsApplied == 0)
    }

    @Test func rejectedRecordThatLostLWWIsNotNacked() {
        var rng = SplitMix64(seed: 2401)
        let (viewer, capture) = makeRunningViewer(width: 128, height: 64)
        viewer.handleDatagram(makeDatagram(seq: 10, records: [(0, rng.bytes(64 * 64 * 4))]), nowUS: 0)
        // An older, malformed straggler: superseded anyway — the newer send
        // owns the host's in-flight slot, so no report is needed.
        viewer.handleDatagram(record(seq: 9, tile: 0, opcode: Opcode.raw, payload: [1, 2, 3]), nowUS: 0)
        #expect(nacks(capture, seq: 9, tile: 0) == 0)
    }

    @Test func cacheRefMissIsNacked() {
        let (viewer, capture) = makeRunningViewer(width: 128, height: 64)
        var w = ByteWriter()
        DatagramHeader(frameSeq: 3, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        var body: [UInt8] = [1] // REF
        withUnsafeBytes(of: UInt16(7).littleEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(0xDEAD_BEEF).littleEndian) { body.append(contentsOf: $0) }
        Datagram.appendRecord(opcode: Opcode.cache, tileIdx: 1, fragIdx: 0, fragCnt: 1,
                              payload: body, into: &w)
        viewer.handleDatagram(Data(w.bytes), nowUS: 0)
        #expect(viewer.stats.cacheRefMisses == 1)
        #expect(nacks(capture, seq: 3, tile: 1) == 1)
    }

    /// Host side of a REF miss: the repair must not REF the same slot again
    /// (it would miss again and NACK forever) — the slot is unindexed.
    @Test func refNackStopsReferencingThatSlot() {
        var rng = SplitMix64(seed: 2402)
        let (host, capture) = makeRunningHost(width: 128, height: 128) // 4 tiles
        var frameA = TestFrame(width: 128, height: 128)
        frameA.fillRandom(&rng)
        var frameB = frameA
        frameB.fillRect(x: 0, y: 0, w: 128, h: 128, &rng)
        func ackAll(_ nowUS: UInt64) {
            for ack in fullAcks(for: capture.sentDatagrams) { host.handleControl(ack, nowUS: nowUS) }
        }
        frameA.encode(host: host, nowUS: 10_000)
        ackAll(20_000)
        frameB.encode(host: host, nowUS: 30_000)
        ackAll(40_000)
        let before = capture.sentDatagrams.count
        frameA.encode(host: host, nowUS: 50_000) // revert: four REFs
        #expect(host.stats.cacheRefsSent == 4, "precondition: the revert rides REFs")
        guard let refSeq = header(of: capture.sentDatagrams[before])?.frameSeq else {
            Issue.record("no REF datagram")
            return
        }

        // The viewer missed tile 0's REF: NACK precedes the batch ACK.
        host.handleControl(Data(ControlMessage.deltaNack(frameSeq: refSeq, tiles: [0]).encoded()),
                           nowUS: 55_000)
        ackAll(60_000)
        #expect(host.stats.cacheSlotsPoisoned == 1)

        let repairStart = capture.sentDatagrams.count
        frameA.encode(host: host, nowUS: 80_000) // repair tick
        #expect(host.stats.deltaNacksRepaired == 1)
        #expect(host.stats.cacheRefsSent == 4, "the repair must not REF the slot that missed")
        let resent = decodeTilePayloads(Array(capture.sentDatagrams[repairStart...]))
        #expect(resent[0] == frameA.tightTile(0), "tile 0 must be re-sent with its content")
    }
}

@Suite struct DecodeStrictnessTests {
    /// The Compression framework returns dst.count for a stream that
    /// decodes to MORE than fits: with an exactly-sized scratch, an LZ4
    /// payload decoding to one byte past a full tile applied truncated.
    @Test func oversizeLZ4PayloadIsRejectedNotTruncated() {
        var rng = SplitMix64(seed: 2701)
        let (viewer, capture) = makeRunningViewer(width: 128, height: 64)
        let tooLong = [UInt8](repeating: 0x5A, count: 64 * 64 * 4 + 1) + rng.bytes(0)
        var compressed = [UInt8](repeating: 0, count: 64 * 64 * 8)
        let n = tooLong.withUnsafeBytes { src in
            compressed.withUnsafeMutableBytes { dst in
                LZ4Codec().encodeUnbounded(src: src, dst: dst)
            }
        }
        #expect(n > 0 && n < 64 * 64 * 4, "precondition: the stream is a valid, compact LZ4 frame")
        viewer.handleDatagram(makeDatagram(seq: 3, records: [(0, Array(compressed[0..<n]))],
                                           opcode: Opcode.lz4), nowUS: 0)
        #expect(viewer.stats.recordsApplied == 0, "an oversize stream must not apply truncated")
        let nacked = controlMessages(capture.sentControl).contains {
            if case .deltaNack(frameSeq: 3, tiles: [0]) = $0 { return true } else { return false }
        }
        #expect(nacked)
    }
}

@Suite struct ReassemblyPoolTests {
    /// Reassembly buffers are pooled; the pool doubles while partials are
    /// live (its arena is copied), so partials that began before growth must
    /// still complete byte-exactly afterwards.
    @Test func partialsSurvivePoolGrowth() {
        var rng = SplitMix64(seed: 2901)
        let (viewer, _) = makeRunningViewer(width: 1280, height: 1280) // 400 tiles
        let tiles = 300 // > 4× the initial pool
        var contents: [[UInt8]] = []
        func record(_ tile: Int, frag: Int, of cnt: Int, _ bytes: ArraySlice<UInt8>) -> Data {
            var w = ByteWriter()
            DatagramHeader(frameSeq: 7, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
            Datagram.appendRecord(opcode: Opcode.raw, tileIdx: UInt16(tile), fragIdx: UInt8(frag),
                                  fragCnt: UInt8(cnt), payload: Array(bytes), into: &w)
            return Data(w.bytes)
        }
        let half = 64 * 64 * 2
        for t in 0..<tiles { // first halves only: every tile is mid-reassembly
            let bytes = rng.bytes(64 * 64 * 4)
            contents.append(bytes)
            viewer.handleDatagram(record(t, frag: 0, of: 2, bytes[0..<half]), nowUS: 0)
        }
        for t in 0..<tiles {
            viewer.handleDatagram(record(t, frag: 1, of: 2, contents[t][half...]), nowUS: 1_000)
        }
        #expect(viewer.stats.recordsApplied == tiles)
        for t in 0..<tiles where canvasTile(viewer, t) != contents[t] {
            Issue.record("tile \(t) corrupted across pool growth")
            break
        }
    }
}
