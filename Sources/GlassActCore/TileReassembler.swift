import GlassActWire // Serial

/// §5 fragment reassembly: all-or-nothing per (tile, seq). One slot per
/// tile — a partial can only be discarded by a newer seq for the same tile
/// or by expiry, never by pool pressure from *other* tiles (pressure
/// eviction of a tile whose datagrams all arrived and got ACKed would
/// silently diverge from the host's shadow map).
///
/// It only assembles: a completed payload is handed back to the engine,
/// which re-checks LWW and applies it; a rejection is handed back for the
/// engine to NACK. Queue confinement: stored inline in `ViewerEngine` and
/// mutated only on the engine's confining queue (the app's `applyQueue`).
/// Noncopyable because it owns raw buffers (freed in `deinit`).
struct TileReassembler: ~Copyable {
    /// What one fragment did.
    enum Outcome {
        /// Stored; the tile is still waiting for fragments.
        case pending
        /// Duplicate fragment, or one from an older seq than the live
        /// partial: dropped, nothing to report.
        case ignored
        /// Inconsistent or over-size fragmenting (hostile or corrupt): the
        /// partial is discarded. The engine rejects the record.
        case rejected
        /// All fragments arrived. `payload` points into the reassembler's
        /// scratch and is valid until its next mutating call.
        case complete(opcode: UInt8, seq: UInt32, captureTimestampUS: UInt64,
                      payload: UnsafeRawBufferPointer)
    }

    /// A partial older than this is discarded (§5: "entries expire after
    /// 250 ms").
    static let expiryUS: UInt64 = 250_000

    /// Buffer entries: `[fragIdx u8][len u32 LE][payload]`, appended in
    /// arrival order; ordered by fragIdx at completion.
    private struct Slot {
        var active = false
        var frameSeq: UInt32 = 0
        var captureTimestampUS: UInt64 = 0
        var opcode: UInt8 = 0
        var fragCnt = 0
        var receivedCnt = 0
        var mask = SIMD4<UInt64>(0, 0, 0, 0) // 256-bit received mask
        var writeCursor = 0
        var lastRxUS: UInt64 = 0
        /// Pooled buffer (index into `arena`) held only while active.
        var bufferIndex: Int32 = -1
    }

    static let bufferSize = ViewerEngine.maxTilePayload + 16 + 256 * 5

    private var slots: [Slot] = []
    /// Count of active slots, so the 4 ms tick's expiry sweep can skip the
    /// O(grid) scan entirely when nothing is mid-reassembly (the common case
    /// — measured as ~40% of a core on an IDLE 5K session in a debug build:
    /// 3,600 slots × 250 Hz of unspecialized iteration).
    private(set) var activeCount = 0

    // Reassembly buffers are pooled: a tile holds one only while a partial is
    // live (a per-tile 17.7 KB buffer kept forever once the tile had ever
    // fragmented would cost ~64 MB at 5K, allocated on the apply path). The
    // arena starts at arenaInitial buffers and doubles only when concurrent
    // partials exceed its high-water mark (bounded by the tile count);
    // steady state allocates nothing (INV-7).
    static let arenaInitial = 64
    private var arena: UnsafeMutableRawBufferPointer?
    private var arenaCount = 0
    private var free = ContiguousArray<Int32>()

    private var fragOff = [Int32](repeating: -1, count: 256)
    private var fragLen = [Int32](repeating: 0, count: 256)
    private let assembleScratch: UnsafeMutableRawBufferPointer

    init() {
        assembleScratch = .allocate(byteCount: ViewerEngine.maxTilePayload + 16, alignment: 64)
    }

    deinit {
        assembleScratch.deallocate()
        arena?.deallocate()
    }

    /// New canvas geometry: one empty slot per tile, buffer pool released.
    mutating func reset(tileCount: Int) {
        slots = [Slot](repeating: Slot(), count: tileCount)
        arena?.deallocate()
        arena = nil
        arenaCount = 0
        free.removeAll(keepingCapacity: true)
        activeCount = 0
    }

    /// Adds one fragment of a record for `tile` (which the engine has
    /// bounds-checked against the grid). `payload` is only read during the
    /// call.
    mutating func reassemble(tile: Int, opcode: UInt8, fragIdx fragIdxU8: UInt8, fragCnt: UInt8,
                             payload: UnsafeRawBufferPointer, seq: UInt32,
                             captureTimestampUS: UInt64, nowUS: UInt64) -> Outcome {
        if slots[tile].active {
            if Serial.newer(seq, than: slots[tile].frameSeq) {
                begin(tile, opcode: opcode, fragCnt: fragCnt, seq: seq, captureTimestampUS: captureTimestampUS)
            } else if seq != slots[tile].frameSeq {
                return .ignored // older fragment
            }
        } else {
            begin(tile, opcode: opcode, fragCnt: fragCnt, seq: seq, captureTimestampUS: captureTimestampUS)
        }
        guard slots[tile].fragCnt == Int(fragCnt), Int(fragIdxU8) < slots[tile].fragCnt else {
            deactivate(tile) // inconsistent fragmenting: hostile or corrupt
            return .rejected
        }
        let fragIdx = Int(fragIdxU8)
        traceTile(tile, "viewer frag seq=\(seq) idx=\(fragIdx)/\(fragCnt) len=\(payload.count)")
        let word = fragIdx >> 6
        let bit = UInt64(1) << UInt64(fragIdx & 63)
        guard slots[tile].mask[word] & bit == 0 else { return .ignored } // duplicate fragment
        let entrySize = 5 + payload.count
        guard slots[tile].writeCursor + entrySize <= Self.bufferSize else {
            deactivate(tile) // over-size total: hostile
            return .rejected
        }
        let offset = slots[tile].writeCursor
        let payloadCount = payload.count
        let payloadBase = payload.baseAddress
        let buf = buffer(slots[tile].bufferIndex)
        buf[offset] = UInt8(fragIdx)
        withUnsafeBytes(of: UInt32(payloadCount).littleEndian) {
            buf.baseAddress!.advanced(by: offset + 1).copyMemory(from: $0.baseAddress!, byteCount: 4)
        }
        if payloadCount > 0 {
            buf.baseAddress!.advanced(by: offset + 5).copyMemory(from: payloadBase!, byteCount: payloadCount)
        }
        slots[tile].writeCursor = offset + entrySize
        slots[tile].mask[word] |= bit
        slots[tile].receivedCnt += 1
        slots[tile].lastRxUS = nowUS
        if slots[tile].receivedCnt == slots[tile].fragCnt {
            return complete(tile)
        }
        return .pending
    }

    /// Discards every partial idle for longer than `expiryUS`, calling
    /// `onExpired(tile, seq)` for each (in tile order) after it is released.
    mutating func expire(nowUS: UInt64, _ onExpired: (_ tile: Int, _ seq: UInt32) -> Void) {
        guard activeCount > 0 else { return } // idle: skip the O(grid) sweep
        for i in 0..<slots.count where slots[i].active && nowUS &- slots[i].lastRxUS > Self.expiryUS {
            deactivate(i)
            onExpired(i, slots[i].frameSeq)
        }
    }

    private mutating func begin(_ tile: Int, opcode: UInt8, fragCnt: UInt8,
                                seq: UInt32, captureTimestampUS: UInt64) {
        if slots[tile].bufferIndex < 0 {
            slots[tile].bufferIndex = acquireBuffer()
        }
        if !slots[tile].active { activeCount += 1 }
        slots[tile].active = true
        slots[tile].frameSeq = seq
        slots[tile].captureTimestampUS = captureTimestampUS
        slots[tile].opcode = opcode
        slots[tile].fragCnt = Int(fragCnt)
        slots[tile].receivedCnt = 0
        slots[tile].mask = SIMD4<UInt64>(0, 0, 0, 0)
        slots[tile].writeCursor = 0
    }

    private mutating func complete(_ tile: Int) -> Outcome {
        let fragCnt = slots[tile].fragCnt
        let seq = slots[tile].frameSeq
        let captureTS = slots[tile].captureTimestampUS
        let opcode = slots[tile].opcode
        for f in 0..<fragCnt {
            fragOff[f] = -1
        }
        var total = 0
        var valid = true
        gather: do {
            let buf = UnsafeRawBufferPointer(buffer(slots[tile].bufferIndex))
            var c = 0
            while c < slots[tile].writeCursor {
                let fi = Int(buf[c])
                let len = Int(UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: c + 1, as: UInt32.self)))
                fragOff[fi] = Int32(c + 5)
                fragLen[fi] = Int32(len)
                c += 5 + len
            }
            for f in 0..<fragCnt {
                let off = Int(fragOff[f])
                let len = Int(fragLen[f])
                guard off >= 0, total + len <= assembleScratch.count else {
                    valid = false
                    break gather
                }
                if len > 0 {
                    assembleScratch.baseAddress!.advanced(by: total)
                        .copyMemory(from: buf.baseAddress!.advanced(by: off), byteCount: len)
                }
                total += len
            }
        }
        deactivate(tile)
        guard valid else { return .rejected }
        return .complete(opcode: opcode, seq: seq, captureTimestampUS: captureTS,
                         payload: UnsafeRawBufferPointer(rebasing: assembleScratch[0..<total]))
    }

    @inline(__always) private mutating func deactivate(_ tile: Int) {
        if slots[tile].active {
            slots[tile].active = false
            activeCount -= 1
        }
        if slots[tile].bufferIndex >= 0 {
            free.append(slots[tile].bufferIndex)
            slots[tile].bufferIndex = -1
        }
    }

    private mutating func acquireBuffer() -> Int32 {
        if free.isEmpty {
            let grown = max(Self.arenaInitial, arenaCount * 2)
            let next = UnsafeMutableRawBufferPointer.allocate(byteCount: grown * Self.bufferSize,
                                                              alignment: 64)
            if let old = arena {
                next.baseAddress!.copyMemory(from: old.baseAddress!, byteCount: old.count) // live partials keep their index
                old.deallocate()
            }
            free.reserveCapacity(grown)
            for i in stride(from: grown - 1, through: arenaCount, by: -1) { free.append(Int32(i)) }
            arena = next
            arenaCount = grown
        }
        return free.removeLast()
    }

    @inline(__always) private func buffer(_ index: Int32) -> UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(start: arena!.baseAddress!.advanced(by: Int(index) * Self.bufferSize),
                                      count: Self.bufferSize)
    }
}
