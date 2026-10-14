import GlassActWire
import GlassActTestSupport

/// Builds a structurally valid datagram with random header and records.
func randomValidDatagram(_ rng: inout SplitMix64) -> [UInt8] {
    let cnt = rng.int(1..<10)
    let header = DatagramHeader(
        frameSeq: UInt32(truncatingIfNeeded: rng.next()),
        dgramIdx: UInt16(rng.int(0..<cnt)),
        dgramCnt: UInt16(cnt),
        captureTimestampUS: rng.next())
    var w = ByteWriter()
    header.encode(into: &w)
    for _ in 0..<rng.int(0..<12) {
        let fragCnt = UInt8(rng.int(1..<5))
        Datagram.appendRecord(
            opcode: UInt8(rng.int(1..<9)),
            tileIdx: UInt16(truncatingIfNeeded: rng.next()),
            fragIdx: UInt8(rng.int(0..<Int(fragCnt))),
            fragCnt: fragCnt,
            payload: rng.bytes(rng.int(0..<600)),
            into: &w)
    }
    return w.bytes
}
