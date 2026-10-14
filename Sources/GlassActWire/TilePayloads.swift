/// Payload sub-formats of the reference-carrying opcodes (§3.4):
/// `0x0B DELTA` and `0x07 CACHE`. Their layout is documented on `Opcode`.
/// Parsing is checked like every other wire read (INV-6) and returns views
/// into the record payload; writing fills a caller-owned buffer so the
/// host's per-tile path stays allocation-free (INV-7).

/// Inner-payload opcodes a DELTA or CACHE STORE may wrap: the absolute codecs.
public enum InnerOpcode {
    @inline(__always)
    public static func isValid(_ opcode: UInt8) -> Bool {
        opcode == Opcode.raw || opcode == Opcode.lz4 || opcode == Opcode.lzbitmap || opcode == Opcode.webpl
    }
}

/// `0x0B DELTA` payload: `{mode u8, baseHash u64le, [x u8, y u8, w u8, h u8
/// when mode = 1], inner opcode u8, inner payload}`.
@unsafe public struct DeltaPayload {
    /// 0 = whole-tile XOR against the base; 1 = absolute sub-rect.
    public var mode: UInt8
    public var baseHash: UInt64
    /// Sub-rect in tile coordinates (mode 1); the whole tile for mode 0.
    public var x: Int, y: Int, width: Int, height: Int
    public var innerOpcode: UInt8
    /// View into the record payload — valid only while it is.
    public var inner: UnsafeRawBufferPointer

    public static let wholeTileHeaderBytes = 10
    public static let subRectHeaderBytes = 14

    /// Rejects an unknown mode, a truncated header, an empty or out-of-tile
    /// sub-rect, and an inner opcode that isn't an absolute codec.
    public static func parse(_ payload: UnsafeRawBufferPointer, tileWidth: Int, tileHeight: Int) -> DeltaPayload? {
        var r = unsafe ByteReader(payload)
        guard let mode = r.readU8(), mode <= 1, let baseHash = r.readU64() else { return nil }
        var x = 0, y = 0, w = tileWidth, h = tileHeight
        if mode == 1 {
            guard let bx = r.readU8(), let by = r.readU8(), let bw = r.readU8(), let bh = r.readU8(),
                  bw >= 1, bh >= 1, Int(bx) + Int(bw) <= tileWidth, Int(by) + Int(bh) <= tileHeight
            else { return nil }
            x = Int(bx); y = Int(by); w = Int(bw); h = Int(bh)
        }
        guard let innerOpcode = r.readU8(), InnerOpcode.isValid(innerOpcode),
              let inner = unsafe r.readBytes(r.remaining) else { return nil }
        return unsafe DeltaPayload(mode: mode, baseHash: baseHash, x: x, y: y, width: w, height: h,
                                   innerOpcode: innerOpcode, inner: inner)
    }

    /// Writes the header (everything before the inner payload); returns its
    /// length. `subRect` nil = mode 0. `out` must hold `subRectHeaderBytes`.
    public static func writeHeader(baseHash: UInt64, subRect: (x: Int, y: Int, width: Int, height: Int)?,
                                   innerOpcode: UInt8, into out: UnsafeMutableRawBufferPointer) -> Int {
        precondition(InnerOpcode.isValid(innerOpcode), "DELTA inner must be an absolute codec")
        precondition(unsafe out.count >= subRectHeaderBytes)
        unsafe out[0] = subRect == nil ? 0 : 1
        unsafe out.storeBytes(of: baseHash.littleEndian, toByteOffset: 1, as: UInt64.self)
        guard let rect = subRect else {
            unsafe out[9] = innerOpcode
            return unsafe wholeTileHeaderBytes
        }
        precondition(rect.width >= 1 && rect.height >= 1 && rect.x + rect.width <= 255 && rect.y + rect.height <= 255)
        unsafe out[9] = UInt8(rect.x)
        unsafe out[10] = UInt8(rect.y)
        unsafe out[11] = UInt8(rect.width)
        unsafe out[12] = UInt8(rect.height)
        unsafe out[13] = innerOpcode
        return unsafe subRectHeaderBytes
    }
}

/// `0x07 CACHE` payload: `sub u8 = 0 STORE_APPLY {slot u16, inner opcode u8,
/// inner payload}` or `sub u8 = 1 REF {slot u16, contentHash u64}`.
@unsafe public enum CachePayload {
    case storeApply(slot: UInt16, innerOpcode: UInt8, inner: UnsafeRawBufferPointer)
    case ref(slot: UInt16, contentHash: UInt64)

    public static let storeApplyPrefixBytes = 4
    public static let refBytes = 11

    /// Rejects an unknown sub-op, a truncated prefix, a STORE wrapping a
    /// non-absolute inner codec, and a REF with trailing bytes. Slot range is
    /// the receiver's to check (its cache size).
    public static func parse(_ payload: UnsafeRawBufferPointer) -> CachePayload? {
        var r = unsafe ByteReader(payload)
        guard let sub = r.readU8(), let slot = r.readU16() else { return nil }
        switch sub {
        case 0:
            guard let innerOpcode = r.readU8(), InnerOpcode.isValid(innerOpcode),
                  let inner = unsafe r.readBytes(r.remaining) else { return nil }
            return unsafe .storeApply(slot: slot, innerOpcode: innerOpcode, inner: inner)
        case 1:
            guard let hash = r.readU64(), r.remaining == 0 else { return nil }
            return unsafe .ref(slot: slot, contentHash: hash)
        default:
            return nil
        }
    }

    /// Writes a STORE_APPLY prefix (the inner payload follows); returns 4.
    public static func writeStoreApplyPrefix(slot: UInt16, innerOpcode: UInt8,
                                             into out: UnsafeMutableRawBufferPointer) -> Int {
        precondition(InnerOpcode.isValid(innerOpcode), "STORE inner must be an absolute codec")
        precondition(unsafe out.count >= storeApplyPrefixBytes)
        unsafe out[0] = 0
        unsafe out.storeBytes(of: slot.littleEndian, toByteOffset: 1, as: UInt16.self)
        unsafe out[3] = innerOpcode
        return unsafe storeApplyPrefixBytes
    }

    /// Writes a whole REF payload; returns 11.
    public static func writeRef(slot: UInt16, contentHash: UInt64, into out: UnsafeMutableRawBufferPointer) -> Int {
        precondition(unsafe out.count >= refBytes)
        unsafe out[0] = 1
        unsafe out.storeBytes(of: slot.littleEndian, toByteOffset: 1, as: UInt16.self)
        unsafe out.storeBytes(of: contentHash.littleEndian, toByteOffset: 3, as: UInt64.self)
        return unsafe refBytes
    }
}
