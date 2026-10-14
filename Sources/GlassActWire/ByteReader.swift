/// Bounds-checked little-endian reader over a raw buffer. All wire parsing goes
/// through these reads: every access validates `remaining` first, so malformed
/// input can never over-read (INV-6).
///
/// `@safe` under strict memory safety: the unsafe step is constructing one
/// over a buffer (callers mark it, and own the buffer's lifetime); after
/// that every read is bounds-checked against `remaining`.
@safe public struct ByteReader {
    @usableFromInline let buf: UnsafeRawBufferPointer
    @usableFromInline var _offset: Int

    @inline(__always)
    public init(_ buf: UnsafeRawBufferPointer) {
        unsafe self.buf = unsafe buf
        self._offset = 0
    }

    @inline(__always) public var offset: Int { _offset }
    @inline(__always) public var remaining: Int { unsafe buf.count - _offset }

    @inline(__always)
    public mutating func readU8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        let v = unsafe buf[_offset]
        _offset += 1
        return v
    }

    @inline(__always)
    public mutating func readU16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        let v = unsafe buf.loadUnaligned(fromByteOffset: _offset, as: UInt16.self)
        _offset += 2
        return UInt16(littleEndian: v)
    }

    @inline(__always)
    public mutating func readU32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let v = unsafe buf.loadUnaligned(fromByteOffset: _offset, as: UInt32.self)
        _offset += 4
        return UInt32(littleEndian: v)
    }

    @inline(__always)
    public mutating func readU64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        let v = unsafe buf.loadUnaligned(fromByteOffset: _offset, as: UInt64.self)
        _offset += 8
        return UInt64(littleEndian: v)
    }

    /// Unsigned LEB128, at most 4 bytes (max value 2^28 − 1). Returns nil on
    /// truncation or on a 4th byte that still has the continuation bit set.
    /// Overlong-but-in-range encodings are tolerated; the writer always emits
    /// canonical form.
    @inline(__always)
    public mutating func readVarint() -> UInt32? {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        for _ in 0..<4 {
            guard let b = readU8() else { return nil }
            result |= UInt32(b & 0x7F) &<< shift
            if b & 0x80 == 0 { return result }
            shift &+= 7
        }
        return nil
    }

    /// Returns a view into the underlying buffer (no copy). Valid only while the
    /// underlying buffer is.
    @inline(__always)
    public mutating func readBytes(_ count: Int) -> UnsafeRawBufferPointer? {
        guard count >= 0, remaining >= count else { return nil }
        let slice = unsafe UnsafeRawBufferPointer(rebasing: buf[_offset ..< _offset + count])
        _offset += count
        return unsafe slice
    }
}
