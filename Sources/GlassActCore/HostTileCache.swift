import Foundation

/// Session tile cache (§4.8), host mirror. Slot-addressed; the host owns
/// allocation, so no eviction synchronization is needed: reuse travels as an
/// explicit STORE. A slot is only overwritten when quiescent (stored, no
/// in-flight refs), and only REF'd when its store is ACKed and no overwrite
/// is in flight. Hits are memcmp-verified (hash quality is not load-bearing).
/// Full 64×64 tiles only.
///
/// Stored inline in `HostEngine` and confined to its encode queue.
/// `~Copyable`: it owns the pixel mirror and frees it in `deinit`.
struct HostTileCache: ~Copyable {
    static let slotCount = 4096
    static let tileBytes = TileGrid.tileSize * TileGrid.tileSize * 4

    enum SlotState: UInt8 {
        case free = 0
        case storing = 1 // STORE sent, unresolved
        case stored = 2  // STORE ACKed: the viewer has it
    }

    struct Slot {
        var state = SlotState.free
        var hash: UInt64 = 0
        var refInflight: UInt16 = 0
        var storedOrder: UInt32 = 0
    }

    private(set) var slots = ContiguousArray(repeating: Slot(), count: HostTileCache.slotCount)
    private var index: [UInt64: UInt16] = [:] // hash → stored slot
    private let pixels: UnsafeMutableRawBufferPointer
    private var clock: UInt32 = 0
    private var evictScan = 0
    private var storing: Set<UInt64> = [] // dedupe STOREs in flight

    init() {
        pixels = .allocate(byteCount: Self.slotCount * Self.tileBytes, alignment: 16_384)
        index.reserveCapacity(Self.slotCount)
    }

    deinit {
        pixels.deallocate()
    }

    // MARK: Encode path

    /// A stored slot whose pixels byte-match `tight` (hash lookup + memcmp
    /// verification), usable for a REF right now.
    func lookup(hash: UInt64, tight: UnsafeRawBufferPointer) -> Int? {
        guard let slotU16 = index[hash] else { return nil }
        let slot = Int(slotU16)
        guard slots[slot].state == .stored, slots[slot].hash == hash else { return nil }
        let entry = pixels.baseAddress!.advanced(by: slot * Self.tileBytes)
        guard memcmp(entry, tight.baseAddress!, tight.count) == 0 else { return nil }
        return slot
    }

    /// A REF to `slot` is going out: pin it against reuse until resolved.
    mutating func pinRef(_ slot: Int) {
        slots[slot].refInflight += 1
    }

    /// Starts a STORE of `hash`: nil if identical content is already being
    /// stored (many identical background tiles in one batch store once) or
    /// no slot is reusable; else the slot, now `.storing`.
    mutating func beginStore(hash: UInt64) -> Int? {
        guard !storing.contains(hash), let slot = allocate() else { return nil }
        slots[slot] = Slot(state: .storing, hash: hash)
        storing.insert(hash)
        return slot
    }

    /// A free slot, else the oldest quiescent stored slot (clock scan).
    private mutating func allocate() -> Int? {
        var scanned = 0
        var best = -1
        var bestOrder = UInt32.max
        while scanned < Self.slotCount {
            let slot = evictScan
            evictScan = (evictScan + 1) % Self.slotCount
            scanned += 1
            if slots[slot].state == .free {
                return slot
            }
            if slots[slot].state == .stored && slots[slot].refInflight == 0
                && slots[slot].storedOrder < bestOrder {
                best = slot
                bestOrder = slots[slot].storedOrder
            }
        }
        guard best >= 0 else { return nil }
        index.removeValue(forKey: slots[best].hash)
        return best
    }

    // MARK: Resolution (ACK, timeout, NACK)

    /// A STORE of `hash` into `slot` resolved. `committed`: the viewer
    /// provably stored it — the slot becomes REF-able with `tight` as its
    /// mirror. Otherwise (timed out, or superseded mid-flight so reassembly
    /// may have discarded it) the viewer's slot state is unknown: free it.
    /// No-op if the slot was already reused for something else.
    mutating func resolveStore(slot: Int, hash: UInt64, committed: Bool, tight: UnsafeRawBufferPointer) {
        guard slots[slot].state == .storing, slots[slot].hash == hash else { return }
        storing.remove(hash)
        guard committed else {
            slots[slot] = Slot()
            return
        }
        slots[slot].state = .stored
        clock &+= 1
        slots[slot].storedOrder = clock
        index[hash] = UInt16(slot)
        pixels.baseAddress!.advanced(by: slot * Self.tileBytes)
            .copyMemory(from: tight.baseAddress!, byteCount: tight.count)
    }

    /// A REF to `slot` resolved (delivered or not): release its pin.
    mutating func releaseRef(_ slot: Int) {
        if slots[slot].refInflight > 0 {
            slots[slot].refInflight -= 1
        }
    }

    /// The viewer reported a REF to `slot` (expected `hash`) as a miss: the
    /// slot is unusable. Unindex it and zero its hash so it never matches
    /// again; the clock scan may reuse it. Returns true if it was poisoned.
    mutating func poison(slot: Int, hash: UInt64) -> Bool {
        guard slots[slot].state == .stored, slots[slot].hash == hash else { return false }
        if index[hash] == UInt16(slot) {
            index.removeValue(forKey: hash)
        }
        slots[slot].hash = 0
        return true
    }
}
