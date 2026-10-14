/// §4.2 — what the host knows about each tile of the viewer's canvas, and
/// the tiles owed a send that dirty rects won't volunteer. Flat arrays
/// indexed by tile. Every transition that INV-9 guards goes through a named
/// operation here: a send overwrites the tile's one in-flight slot, and an
/// ACK or timeout for an older send is ignored.
///
/// Stored inline in `HostEngine` and confined to its encode queue.
struct TileLedger {
    struct Tile {
        var ackedHash: UInt64 = 0    // content the viewer is known to have (0 = unknown/cold)
        var inflightHash: UInt64 = 0 // 0 = none
        var inflightSeq: UInt32 = 0
    }

    private(set) var tiles: ContiguousArray<Tile>
    // Tiles owed a send that dirty rects will not volunteer — a dissolved
    // video region's repaint, timed-out tiles on an otherwise-static screen,
    // governor-deferred COLD tiles. Settle work: the settle-drain probe and
    // VP8L gating count these.
    private var pendingRepaint: ContiguousArray<Bool>
    private(set) var pendingRepaintCount = 0
    // Governor-deferred WARM tiles (changed vs ACKed, budget exhausted).
    // Dirty rects only report a tile when it changes again, so a tile that
    // changed once and was deferred would strand stale while captures stay
    // active elsewhere (the quiet-gap full scan never fires). Re-volunteered
    // like pendingRepaint, but deliberately NOT settle work — churn
    // overload is not a settle drain.
    private var carry: ContiguousArray<Bool>
    private var carryCount = 0

    init(count: Int) {
        tiles = ContiguousArray(repeating: Tile(), count: count)
        pendingRepaint = ContiguousArray(repeating: false, count: count)
        carry = ContiguousArray(repeating: false, count: count)
    }

    @inline(__always)
    subscript(_ idx: Int) -> Tile { tiles[idx] }

    // MARK: Queries

    /// §4.3 step 3: send iff the content differs from both what the viewer
    /// has and what is already in flight to it.
    @inline(__always)
    func qualifies(_ idx: Int, hash: UInt64) -> Bool {
        hash != tiles[idx].ackedHash && hash != tiles[idx].inflightHash
    }

    /// ACKed with nothing in flight: the viewer's copy is known exactly
    /// (the only state a DELTA base or a scroll source may rely on — INV-3).
    @inline(__always)
    func isSettled(_ idx: Int) -> Bool {
        tiles[idx].ackedHash != 0 && tiles[idx].inflightSeq == 0
    }

    // MARK: Transitions

    /// INV-9: a send of `hash` in batch `seq` takes the tile's one in-flight
    /// slot, overwriting any older send's.
    @inline(__always)
    mutating func markInflight(_ idx: Int, hash: UInt64, seq: UInt32) {
        tiles[idx].inflightHash = hash
        tiles[idx].inflightSeq = seq
    }

    /// The send in batch `seq` was confirmed. Commits `hash` as ACKed iff
    /// that send still owns the slot (INV-9 — an ACK for an overwritten
    /// send is stale); returns whether it did.
    @discardableResult
    mutating func commit(_ idx: Int, seq: UInt32, hash: UInt64) -> Bool {
        guard tiles[idx].inflightSeq == seq else { return false }
        tiles[idx] = Tile(ackedHash: hash)
        return true
    }

    /// The send in batch `seq` timed out. If it still owns the slot, the
    /// viewer's copy is unknown (it may have applied it without the
    /// confirmation arriving): clear the slot and mark the tile cold.
    /// Returns whether it did.
    @discardableResult
    mutating func invalidate(_ idx: Int, seq: UInt32) -> Bool {
        guard tiles[idx].inflightSeq == seq else { return false }
        tiles[idx].inflightHash = 0
        tiles[idx].inflightSeq = 0
        markCold(idx)
        return true
    }

    /// Drops the in-flight slot (the viewer will LWW-block that send, e.g.
    /// under a SCROLL); `onlyIfSeq` limits it to one batch's send.
    @inline(__always)
    mutating func clearInflight(_ idx: Int, onlyIfSeq seq: UInt32? = nil) {
        if let seq, tiles[idx].inflightSeq != seq { return }
        tiles[idx].inflightHash = 0
        tiles[idx].inflightSeq = 0
    }

    /// Records what the viewer is known to hold (0 = unknown), without
    /// scheduling anything — for callers that repair explicitly.
    @inline(__always)
    mutating func setAcked(_ idx: Int, hash: UInt64) {
        tiles[idx].ackedHash = hash
    }

    /// Everything about the tile is forgotten (a video region now owns it).
    @inline(__always)
    mutating func forget(_ idx: Int) {
        tiles[idx] = Tile()
    }

    /// The one way to declare "the viewer's copy of this tile is unknown":
    /// zero the ACKed hash (the tile re-qualifies as an absolute record and
    /// is scroll-unsafe until re-ACKed) AND schedule it. Zeroing alone is not
    /// enough — dirty rects only report tiles whose pixels change, so on a
    /// static screen (or with captures busy elsewhere) a cold tile nobody
    /// schedules stays stale on the viewer indefinitely.
    @inline(__always)
    mutating func markCold(_ idx: Int) {
        tiles[idx].ackedHash = 0
        scheduleRepaint(idx)
    }

    @inline(__always)
    mutating func scheduleRepaint(_ idx: Int) {
        if !pendingRepaint[idx] {
            pendingRepaint[idx] = true
            pendingRepaintCount += 1
        }
    }

    /// A tile that qualified but won't ship this tick (governor budget,
    /// batch cap): COLD → pendingRepaint (settle work), WARM → carry. Either
    /// way it re-volunteers next tick without needing a dirty rect.
    @inline(__always)
    mutating func deferTile(_ idx: Int) {
        if tiles[idx].ackedHash == 0 {
            scheduleRepaint(idx)
        } else if !carry[idx] {
            carry[idx] = true
            carryCount += 1
        }
    }

    /// Hands every owed tile to `volunteer` (carry first, then repaint) and
    /// clears both queues; returns how many were settle work (repaint).
    /// A carried tile that no longer differs from its ACKed copy simply
    /// fails to qualify and drops out.
    mutating func drainOwed(_ volunteer: (Int) -> Void) -> Int {
        if carryCount > 0 {
            for i in 0..<carry.count where carry[i] {
                carry[i] = false
                volunteer(i)
            }
            carryCount = 0
        }
        let settleWork = pendingRepaintCount
        if settleWork > 0 {
            for i in 0..<pendingRepaint.count where pendingRepaint[i] {
                pendingRepaint[i] = false
                volunteer(i)
            }
            pendingRepaintCount = 0
        }
        return settleWork
    }
}
