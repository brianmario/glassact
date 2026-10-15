import GlassActCodec // XXH64
import GlassActWire  // Serial

/// Session tile cache (§4.8), viewer side: slot-addressed, host-allocated,
/// full 64×64 tiles only. Stores happen on receipt (decoupled from the LWW
/// canvas gate); refs are hash-guarded.
///
/// Queue confinement: stored inline in `ViewerEngine` and mutated only on
/// the engine's confining queue (the app's `applyQueue`). Noncopyable
/// because it owns the pixel store (freed in `deinit`).
struct ViewerTileCache: ~Copyable {
    static let slotCount = 4096
    /// One full tightly-packed BGRA tile.
    static let entryBytes = ViewerEngine.maxTilePayload

    /// 64 MB, allocated on the first store rather than for every session.
    private var pixels: UnsafeMutableRawBufferPointer?
    private var hash: ContiguousArray<UInt64>
    private var valid: ContiguousArray<Bool>
    /// Slots are LWW registers keyed by the STORE's frame_seq (the keyframe
    /// golden covers this). A host-side STORE timeout frees and
    /// reuses the slot, but the timed-out STORE's datagrams may arrive late
    /// and REORDERED after the reused slot's new STORE — without this gate
    /// the stale content poisons the slot, a later hash-guarded REF cleanly
    /// drops, yet its datagram is ACKed and the host commits: permanent
    /// divergence. Zero wire cost — the seq already rides the header.
    private var slotSeq: ContiguousArray<UInt32>

    init() {
        hash = ContiguousArray(repeating: 0, count: Self.slotCount)
        valid = ContiguousArray(repeating: false, count: Self.slotCount)
        slotSeq = ContiguousArray(repeating: 0, count: Self.slotCount)
    }

    deinit {
        pixels?.deallocate()
    }

    /// Empties every slot and releases the pixel store (new canvas geometry).
    mutating func reset() {
        pixels?.deallocate()
        pixels = nil
        hash = ContiguousArray(repeating: 0, count: Self.slotCount)
        valid = ContiguousArray(repeating: false, count: Self.slotCount)
        slotSeq = ContiguousArray(repeating: 0, count: Self.slotCount)
    }

    /// Stores a decoded tile (`entryBytes` long) in `slot` iff this STORE is
    /// newer than the slot's last one (slot LWW, see `slotSeq`). Returns
    /// whether it stored. `slot` must be `< slotCount`.
    mutating func store(slot: Int, seq: UInt32, tile: UnsafeRawBufferPointer) -> Bool {
        precondition(tile.count == Self.entryBytes)
        guard Serial.newer(seq, than: slotSeq[slot]) else { return false }
        if pixels == nil {
            pixels = .allocate(byteCount: Self.slotCount * Self.entryBytes, alignment: 16_384)
        }
        pixels!.baseAddress!.advanced(by: slot * Self.entryBytes)
            .copyMemory(from: tile.baseAddress!, byteCount: Self.entryBytes)
        hash[slot] = XXH64.hash(tile)
        valid[slot] = true
        slotSeq[slot] = seq
        return true
    }

    /// The slot's tile iff it holds content hashing to `expectedHash`; nil
    /// is a miss. Valid until the next mutating call.
    func lookup(slot: Int, expectedHash: UInt64) -> UnsafeRawBufferPointer? {
        guard valid[slot], hash[slot] == expectedHash, let pixels else { return nil }
        return UnsafeRawBufferPointer(start: pixels.baseAddress!.advanced(by: slot * Self.entryBytes),
                                      count: Self.entryBytes)
    }

    // Forensics (GLASSACT_TRACE_TILE).
    func isValid(_ slot: Int) -> Bool { valid[slot] }
    func storedSeq(_ slot: Int) -> UInt32 { slotSeq[slot] }
}
