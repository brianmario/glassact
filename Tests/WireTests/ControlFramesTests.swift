import Testing
import GlassActWire
import GlassActTestSupport

/// The allocation-free frame writers must be byte-identical to
/// `ControlMessage.encoded()` — the host parses one format.
@Suite struct ControlFramesTests {
    private func frame(_ capacity: Int, _ write: (UnsafeMutableRawBufferPointer) -> Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: capacity)
        let n = buf.withUnsafeMutableBytes(write)
        return Array(buf.prefix(n))
    }

    @Test func matchesControlMessageEncodingExactly() {
        var rng = SplitMix64(seed: 0xC7)
        for _ in 0..<300 {
            let seq = UInt32(truncatingIfNeeded: rng.next())
            let cnt = UInt16(rng.int(1..<2_000))
            let bitmap = rng.bytes((Int(cnt) + 7) / 8)
            #expect(frame(ControlFrames.maxAckBytes) { out in
                bitmap.withUnsafeBytes { ControlFrames.ack(frameSeq: seq, dgramCnt: cnt, bitmap: $0, into: out) }
            } == ControlMessage.ack(frameSeq: seq, dgramCnt: cnt, bitmap: bitmap).encoded())

            let tile = UInt16(truncatingIfNeeded: rng.next())
            #expect(frame(16) { ControlFrames.deltaNack(frameSeq: seq, tile: tile, into: $0) }
                    == ControlMessage.deltaNack(frameSeq: seq, tiles: [tile]).encoded())

            let skipped = (0..<rng.int(0..<300)).map { _ in UInt16(truncatingIfNeeded: rng.next()) }
            let digest = rng.next()
            #expect(frame(ControlFrames.scrollAckBytes(skippedCount: skipped.count)) { out in
                skipped.withUnsafeBufferPointer {
                    ControlFrames.scrollAck(frameSeq: seq, skipped: $0, digest: digest, into: out)
                }
            } == ControlMessage.scrollAck(frameSeq: seq, skipped: skipped, digest: digest).encoded())

            #expect(frame(8) { ControlFrames.keyframeAck(seq: seq, into: $0) }
                    == ControlMessage.keyframeAck(seq: seq).encoded())

            let (x, y) = (UInt16(truncatingIfNeeded: rng.next()), UInt16(truncatingIfNeeded: rng.next()))
            let (w, h) = (UInt16(truncatingIfNeeded: rng.next()), UInt16(truncatingIfNeeded: rng.next()))
            let (dx, dy) = (Int16(truncatingIfNeeded: rng.next()), Int16(truncatingIfNeeded: rng.next()))
            #expect(frame(ControlFrames.scrollBytes) {
                ControlFrames.scroll(frameSeq: seq, x: x, y: y, width: w, height: h, dx: dx, dy: dy, into: $0)
            } == ControlMessage.scroll(frameSeq: seq, x: x, y: y, width: w, height: h, dx: dx, dy: dy).encoded())

            let (a, b, c) = (rng.next(), rng.next(), rng.next())
            #expect(frame(32) { ControlFrames.pong(nonce: a, tUS: b, recvTUS: c, into: $0) }
                    == ControlMessage.pong(nonce: a, tUS: b, recvTUS: c).encoded())
        }
    }

    @Test func largestAckFits() {
        let bitmap = [UInt8](repeating: 0xFF, count: 8192)
        let bytes = frame(ControlFrames.maxAckBytes) { out in
            bitmap.withUnsafeBytes { ControlFrames.ack(frameSeq: 1, dgramCnt: 65_535, bitmap: $0, into: out) }
        }
        #expect(bytes.count == ControlFrames.maxAckBytes)
        #expect(bytes == ControlMessage.ack(frameSeq: 1, dgramCnt: 65_535, bitmap: bitmap).encoded())
    }
}
