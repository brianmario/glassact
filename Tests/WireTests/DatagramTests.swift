import Testing
import GlassActWire
import GlassActTestSupport

@Suite struct DatagramTests {
    struct Rec: Equatable {
        var opcode: UInt8
        var tileIdx: UInt16
        var fragIdx: UInt8
        var fragCnt: UInt8
        var payload: [UInt8]
    }

    private func parseAll(_ bytes: [UInt8]) -> (ok: Bool, header: DatagramHeader?, records: [Rec]) {
        var header: DatagramHeader?
        var records: [Rec] = []
        let ok = Datagram.parse(bytes, { h, r in
            header = h
            records.append(Rec(opcode: r.opcode, tileIdx: r.tileIdx, fragIdx: r.fragIdx,
                               fragCnt: r.fragCnt, payload: [UInt8](r.payload)))
        })
        return (ok, header, records)
    }

    @Test func headerRoundTrip() {
        let h = DatagramHeader(frameSeq: 0xDEAD_BEEF, dgramIdx: 3, dgramCnt: 9,
                               captureTimestampUS: 0x0123_4567_89AB_CDEF)
        var w = ByteWriter()
        h.encode(into: &w)
        #expect(w.bytes.count == DatagramHeader.byteSize)
        #expect(w.bytes[0] == WireVersion.current << 4) // ver in high nibble, reserved low nibble 0
        let parsed = w.bytes.withUnsafeBytes { raw -> DatagramHeader? in
            var r = ByteReader(raw)
            return DatagramHeader.parse(&r)
        }
        #expect(parsed == h)
    }

    @Test func headerRejectsWrongVersionNibble() {
        var w = ByteWriter()
        DatagramHeader(frameSeq: 1, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        var bytes = w.bytes
        bytes[0] = (WireVersion.current &+ 1) << 4
        #expect(parseAll(bytes).ok == false)
    }

    @Test func headerIgnoresReservedFlagNibble() {
        var w = ByteWriter()
        DatagramHeader(frameSeq: 42, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        Datagram.appendRecord(opcode: Opcode.raw, tileIdx: 7, fragIdx: 0, fragCnt: 1,
                              payload: [1, 2, 3] as [UInt8], into: &w)
        var bytes = w.bytes
        bytes[0] = (WireVersion.current << 4) | 0x0F // reserved low-nibble bits set: must still parse
        let (ok, header, records) = parseAll(bytes)
        #expect(ok)
        #expect(header?.frameSeq == 42)
        #expect(records.first?.payload == [1, 2, 3])
    }

    @Test func headerRejectsBadDatagramCounts() {
        var zeroCnt = ByteWriter()
        DatagramHeader(frameSeq: 1, dgramIdx: 0, dgramCnt: 0, captureTimestampUS: 0).encode(into: &zeroCnt)
        #expect(parseAll(zeroCnt.bytes).ok == false)

        var idxOutOfRange = ByteWriter()
        DatagramHeader(frameSeq: 1, dgramIdx: 5, dgramCnt: 5, captureTimestampUS: 0).encode(into: &idxOutOfRange)
        #expect(parseAll(idxOutOfRange.bytes).ok == false)
    }

    @Test func headerOnlyDatagramIsValid() {
        var w = ByteWriter()
        DatagramHeader(frameSeq: 1, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        #expect(parseAll(w.bytes).ok)
    }

    @Test func shortBuffersAreRejected() {
        #expect(parseAll([]).ok == false)
        #expect(parseAll([0x10]).ok == false)
        #expect(parseAll([UInt8](repeating: 0, count: DatagramHeader.byteSize - 1)).ok == false)
    }

    @Test func zeroLengthPayloadIsValid() {
        var w = ByteWriter()
        DatagramHeader(frameSeq: 1, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        Datagram.appendRecord(opcode: Opcode.raw, tileIdx: 0, fragIdx: 0, fragCnt: 1,
                              payload: [] as [UInt8], into: &w)
        let (ok, _, records) = parseAll(w.bytes)
        #expect(ok)
        #expect(records == [Rec(opcode: Opcode.raw, tileIdx: 0, fragIdx: 0, fragCnt: 1, payload: [])])
    }

    @Test func invalidRecordFieldsAreRejected() {
        func datagram(op: UInt8, fragIdx: UInt8, fragCnt: UInt8) -> [UInt8] {
            var w = ByteWriter()
            DatagramHeader(frameSeq: 1, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
            w.writeU8(op)
            w.writeU16(0)
            w.writeU8(fragIdx)
            w.writeU8(fragCnt)
            w.writeVarint(0)
            return w.bytes
        }
        #expect(parseAll(datagram(op: 0, fragIdx: 0, fragCnt: 1)).ok == false) // opcode 0x00 invalid
        #expect(parseAll(datagram(op: 1, fragIdx: 0, fragCnt: 0)).ok == false) // frag_cnt must be ≥ 1
        #expect(parseAll(datagram(op: 1, fragIdx: 2, fragCnt: 2)).ok == false) // frag_idx out of range
        #expect(parseAll(datagram(op: 1, fragIdx: 1, fragCnt: 2)).ok)          // boundary is fine
        #expect(parseAll(datagram(op: 8, fragIdx: 0, fragCnt: 1)).ok)          // reserved opcode: structurally accepted
    }

    @Test func truncatedDatagramIsRejectedAtomically() {
        var w = ByteWriter()
        DatagramHeader(frameSeq: 1, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        Datagram.appendRecord(opcode: Opcode.raw, tileIdx: 0, fragIdx: 0, fragCnt: 1,
                              payload: [UInt8](repeating: 0xAB, count: 100), into: &w)
        Datagram.appendRecord(opcode: Opcode.lz4, tileIdx: 1, fragIdx: 0, fragCnt: 1,
                              payload: [UInt8](repeating: 0xCD, count: 100), into: &w)
        let truncated = Array(w.bytes.dropLast(10))
        let (ok, _, records) = parseAll(truncated)
        #expect(!ok)
        #expect(records.isEmpty) // the valid first record must NOT have been delivered
    }

    @Test func randomizedRoundTrip() {
        var rng = SplitMix64(seed: 0x5C10)
        for _ in 0..<300 {
            let cnt = rng.int(1..<10)
            let header = DatagramHeader(
                frameSeq: UInt32(truncatingIfNeeded: rng.next()),
                dgramIdx: UInt16(rng.int(0..<cnt)),
                dgramCnt: UInt16(cnt),
                captureTimestampUS: rng.next())
            var w = ByteWriter()
            header.encode(into: &w)
            var expected: [Rec] = []
            for _ in 0..<rng.int(0..<12) {
                let fragCnt = UInt8(rng.int(1..<5))
                let rec = Rec(
                    opcode: UInt8(rng.int(1..<9)),
                    tileIdx: UInt16(truncatingIfNeeded: rng.next()),
                    fragIdx: UInt8(rng.int(0..<Int(fragCnt))),
                    fragCnt: fragCnt,
                    payload: rng.bytes(rng.int(0..<600)))
                expected.append(rec)
                Datagram.appendRecord(opcode: rec.opcode, tileIdx: rec.tileIdx, fragIdx: rec.fragIdx,
                                      fragCnt: rec.fragCnt, payload: rec.payload, into: &w)
            }
            let (ok, parsedHeader, records) = parseAll(w.bytes)
            #expect(ok)
            if !expected.isEmpty {
                #expect(parsedHeader == header)
            }
            #expect(records == expected)
        }
    }
}
