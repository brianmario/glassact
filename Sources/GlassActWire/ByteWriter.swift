/// Growable little-endian writer for cold-path serialization (control stream,
/// tests, tools). Hot-path datagram packing writes into preallocated arenas
/// instead (`DatagramPacker`, §8.1) — do not use this in per-frame paths.
public struct ByteWriter {
    public private(set) var bytes: [UInt8]

    public init(reserving capacity: Int = 0) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    @inline(__always)
    public mutating func writeU8(_ v: UInt8) {
        bytes.append(v)
    }

    @inline(__always)
    public mutating func writeU16(_ v: UInt16) {
        withUnsafeBytes(of: v.littleEndian) { unsafe bytes.append(contentsOf: $0) }
    }

    @inline(__always)
    public mutating func writeU32(_ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { unsafe bytes.append(contentsOf: $0) }
    }

    @inline(__always)
    public mutating func writeU64(_ v: UInt64) {
        withUnsafeBytes(of: v.littleEndian) { unsafe bytes.append(contentsOf: $0) }
    }

    /// Canonical unsigned LEB128, ≤ 4 bytes. Traps if `v` ≥ 2^28.
    public mutating func writeVarint(_ v: UInt32) {
        precondition(v < (1 << 28), "varint value exceeds 4-byte LEB128 range")
        var x = v
        repeat {
            var b = UInt8(truncatingIfNeeded: x) & 0x7F
            x >>= 7
            if x != 0 { b |= 0x80 }
            bytes.append(b)
        } while x != 0
    }

    @inline(__always)
    public mutating func writeBytes(_ b: some Sequence<UInt8>) {
        bytes.append(contentsOf: b)
    }
}
