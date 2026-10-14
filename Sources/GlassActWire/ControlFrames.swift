/// Allocation-free encoders for the control messages a viewer sends at
/// batch rate (§3.5 ACK, SCROLL_ACK, KEYFRAME_ACK, DELTA_NACK, PONG): each
/// writes the complete TLV frame into a caller-owned buffer and returns its
/// length. Byte-identical to `ControlMessage.encoded()` (tested); everything
/// else keeps using `ControlMessage`, which allocates and is fine off the
/// per-batch path.
public enum ControlFrames {
    /// Largest ACK frame: `dgram_cnt` ≤ 65 535 → an 8 192-byte bitmap.
    public static let maxAckBytes = 1 + 2 + 4 + 2 + 8192

    /// Frame size for a SCROLL_ACK reporting `skippedCount` tiles.
    public static func scrollAckBytes(skippedCount: Int) -> Int {
        let body = 4 + 2 + 2 * skippedCount + 8
        return 1 + varintSize(body) + body
    }

    public static func ack(frameSeq: UInt32, dgramCnt: UInt16, bitmap: UnsafeRawBufferPointer,
                           into out: UnsafeMutableRawBufferPointer) -> Int {
        precondition(dgramCnt >= 1 && bitmap.count == (Int(dgramCnt) + 7) / 8,
                     "ACK bitmap must be ceil(dgramCnt/8) bytes")
        var w = unsafe Cursor(out, type: 0x03, bodyLength: 6 + bitmap.count)
        unsafe w.u32(frameSeq)
        unsafe w.u16(dgramCnt)
        unsafe w.bytes(bitmap)
        return unsafe w.offset
    }

    /// A DELTA_NACK for one tile (the only shape the viewer sends).
    public static func deltaNack(frameSeq: UInt32, tile: UInt16, into out: UnsafeMutableRawBufferPointer) -> Int {
        var w = unsafe Cursor(out, type: 0x0A, bodyLength: 8)
        unsafe w.u32(frameSeq)
        unsafe w.u16(1)
        unsafe w.u16(tile)
        return unsafe w.offset
    }

    public static func scrollAck(frameSeq: UInt32, skipped: UnsafeBufferPointer<UInt16>, digest: UInt64,
                                 into out: UnsafeMutableRawBufferPointer) -> Int {
        precondition(skipped.count <= 65_535)
        var w = unsafe Cursor(out, type: 0x07, bodyLength: 4 + 2 + 2 * skipped.count + 8)
        unsafe w.u32(frameSeq)
        unsafe w.u16(UInt16(skipped.count))
        for unsafe tile in unsafe skipped { unsafe w.u16(tile) }
        unsafe w.u64(digest)
        return unsafe w.offset
    }

    public static func keyframeAck(seq: UInt32, into out: UnsafeMutableRawBufferPointer) -> Int {
        var w = unsafe Cursor(out, type: 0x09, bodyLength: 4)
        unsafe w.u32(seq)
        return unsafe w.offset
    }

    public static func pong(nonce: UInt64, tUS: UInt64, recvTUS: UInt64,
                            into out: UnsafeMutableRawBufferPointer) -> Int {
        var w = unsafe Cursor(out, type: 0x05, bodyLength: 24)
        unsafe w.u64(nonce)
        unsafe w.u64(tUS)
        unsafe w.u64(recvTUS)
        return unsafe w.offset
    }

    private static func varintSize(_ v: Int) -> Int {
        v < 0x80 ? 1 : v < 0x4000 ? 2 : v < 0x20_0000 ? 3 : 4
    }

    /// Writes `type`, the varint body length, then the body; traps if the
    /// frame would overrun `out` (a caller sizing bug, never wire input).
    @unsafe private struct Cursor {
        let out: UnsafeMutableRawBufferPointer
        var offset = 0

        init(_ out: UnsafeMutableRawBufferPointer, type: UInt8, bodyLength: Int) {
            precondition(bodyLength < 1 << 28)
            unsafe self.out = unsafe out
            precondition(out.count >= 1 + ControlFrames.varintSize(bodyLength) + bodyLength,
                         "control frame buffer too small")
            unsafe u8(type)
            var x = UInt32(bodyLength)
            repeat {
                var b = UInt8(truncatingIfNeeded: x) & 0x7F
                x >>= 7
                if x != 0 { b |= 0x80 }
                unsafe u8(b)
            } while x != 0
        }

        mutating func u8(_ v: UInt8) {
            unsafe out[offset] = v
            unsafe offset += 1
        }

        mutating func u16(_ v: UInt16) {
            unsafe out.storeBytes(of: v.littleEndian, toByteOffset: offset, as: UInt16.self)
            unsafe offset += 2
        }

        mutating func u32(_ v: UInt32) {
            unsafe out.storeBytes(of: v.littleEndian, toByteOffset: offset, as: UInt32.self)
            unsafe offset += 4
        }

        mutating func u64(_ v: UInt64) {
            unsafe out.storeBytes(of: v.littleEndian, toByteOffset: offset, as: UInt64.self)
            unsafe offset += 8
        }

        mutating func bytes(_ b: UnsafeRawBufferPointer) {
            guard b.count > 0 else { return }
            unsafe out.baseAddress!.advanced(by: offset).copyMemory(from: b.baseAddress!, byteCount: b.count)
            unsafe offset += b.count
        }
    }
}
