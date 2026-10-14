import GlassActWire

/// Packs one batch's tile records into datagrams (§3.3) in a preallocated
/// arena: records never span datagrams, each datagram stays within the
/// budget, and headers are written once `dgram_cnt` is known. Zero
/// allocation per batch (INV-7): the arena and range list are reused.
///
/// Stored inline in `HostEngine` and confined to its encode queue.
/// `~Copyable`: it owns the arena and frees it in `deinit`.
struct DatagramPacker: ~Copyable {
    private let arena: UnsafeMutableRawBufferPointer
    /// Closed datagrams' byte ranges in the arena, in order.
    private var ranges = ContiguousArray<(start: Int, end: Int)>()
    private var cursor = 0
    private var openStart = -1

    init(capacity: Int) {
        arena = .allocate(byteCount: capacity, alignment: 64)
        ranges.reserveCapacity(4096)
    }

    deinit {
        arena.deallocate()
    }

    /// Test hook: the arena never moves.
    var arenaAddress: UInt { UInt(bitPattern: arena.baseAddress) }

    /// Datagrams closed so far (the open one, if any, is not counted).
    var closedCount: Int { ranges.count }

    /// Wire size of a record carrying `length` payload bytes.
    @inline(__always)
    static func recordSize(payloadLength length: Int) -> Int {
        5 + varintSize(UInt32(length)) + length
    }

    mutating func reset() {
        ranges.removeAll(keepingCapacity: true)
        cursor = 0
        openStart = -1
    }

    /// Appends one record whose payload is bytes `[logicalOffset,
    /// logicalOffset + length)` of the logical payload `prefix ++ body`
    /// (CACHE records carry a small header before the tile's bytes). Opens a
    /// new datagram first if the record doesn't fit in `budget`. Returns the
    /// index of the datagram it landed in.
    mutating func append(opcode: UInt8, tileIdx: UInt16, fragIdx: UInt8, fragCnt: UInt8,
                         prefix: UnsafeRawBufferPointer, body: UnsafeRawBufferPointer,
                         logicalOffset: Int, length: Int, budget: Int) -> Int32 {
        let size = Self.recordSize(payloadLength: length)
        if openStart < 0 || (cursor - openStart) + size > budget {
            closeOpen()
            openStart = cursor
            cursor += DatagramHeader.byteSize // header filled in by finish()
        }
        arena[cursor] = opcode
        cursor += 1
        write16(tileIdx)
        arena[cursor] = fragIdx
        cursor += 1
        arena[cursor] = fragCnt
        cursor += 1
        writeVarint(UInt32(length))
        var remaining = length
        var lo = logicalOffset
        if lo < prefix.count {
            let n = min(prefix.count - lo, remaining)
            arena.baseAddress!.advanced(by: cursor)
                .copyMemory(from: prefix.baseAddress!.advanced(by: lo), byteCount: n)
            cursor += n
            lo += n
            remaining -= n
        }
        if remaining > 0 {
            arena.baseAddress!.advanced(by: cursor)
                .copyMemory(from: body.baseAddress!.advanced(by: lo - prefix.count), byteCount: remaining)
            cursor += remaining
        }
        return Int32(ranges.count)
    }

    /// Closes the open datagram and writes every header; returns the count.
    mutating func finish(frameSeq: UInt32, captureTimestampUS: UInt64) -> Int {
        closeOpen()
        let count = ranges.count
        for i in 0..<count {
            var c = ranges[i].start
            arena[c] = DatagramHeader.wireVersion << 4
            c += 1
            cursor = c
            write32(frameSeq)
            write16(UInt16(i))
            write16(UInt16(count))
            write64(captureTimestampUS)
        }
        cursor = ranges.last?.end ?? 0
        return count
    }

    /// Datagram `i`'s bytes (valid until the next `reset`).
    func datagram(_ i: Int) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: arena.baseAddress! + ranges[i].start, count: ranges[i].end - ranges[i].start)
    }

    private mutating func closeOpen() {
        if openStart >= 0 {
            ranges.append((start: openStart, end: cursor))
            openStart = -1
        }
    }

    @inline(__always)
    private mutating func write16(_ v: UInt16) {
        withUnsafeBytes(of: v.littleEndian) {
            arena.baseAddress!.advanced(by: cursor).copyMemory(from: $0.baseAddress!, byteCount: 2)
        }
        cursor += 2
    }

    @inline(__always)
    private mutating func write32(_ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) {
            arena.baseAddress!.advanced(by: cursor).copyMemory(from: $0.baseAddress!, byteCount: 4)
        }
        cursor += 4
    }

    @inline(__always)
    private mutating func write64(_ v: UInt64) {
        withUnsafeBytes(of: v.littleEndian) {
            arena.baseAddress!.advanced(by: cursor).copyMemory(from: $0.baseAddress!, byteCount: 8)
        }
        cursor += 8
    }

    @inline(__always)
    private mutating func writeVarint(_ v: UInt32) {
        var x = v
        repeat {
            var b = UInt8(truncatingIfNeeded: x) & 0x7F
            x >>= 7
            if x != 0 { b |= 0x80 }
            arena[cursor] = b
            cursor += 1
        } while x != 0
    }

    @inline(__always)
    private static func varintSize(_ v: UInt32) -> Int {
        v < 0x80 ? 1 : v < 0x4000 ? 2 : v < 0x20_0000 ? 3 : 4
    }
}
