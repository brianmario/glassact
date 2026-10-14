import GlassActWire

/// §3.5 ACK generation for the viewer: per-batch received bitmaps and the
/// ACK cadence. A small fixed set of slots, one per tracked batch.
///
/// Queue confinement: a value stored inline in `ViewerEngine` and mutated
/// only on the engine's confining queue (the app's `applyQueue`). It sends
/// nothing itself: every ACK goes out through the caller's `send` closure
/// (non-escaping) as `(frameSeq, dgramCnt, bitmap bytes)`, which the engine
/// encodes without allocating (ControlFrames) and counts in its stats.
///
/// Zero allocation per batch (§8.1): each slot's bitmap, and the straggler
/// bitmap, keep a full 8 KB capacity (dgram_cnt ≤ 65 535) and are reused.
struct AckTracker {
    typealias Send = (_ frameSeq: UInt32, _ dgramCnt: UInt16, _ bitmap: UnsafeRawBufferPointer) -> Void
    private static let maxBitmapBytes = 8192
    static let slotCount = 4
    /// Incomplete ACK slots older than this are abandoned: the host has
    /// long since timed the batch out (its timeout is capped at a few s).
    static let slotExpiryUS: UInt64 = 5_000_000
    /// First partial ACK of an incomplete batch, and the minimum gap between
    /// partial re-ACKs (§3.5: "8 ms after first datagram").
    static let partialDelayUS: UInt64 = 8_000
    /// Keepalive re-ACK interval (§3.5: "every 100 ms").
    static let keepaliveUS: UInt64 = 100_000

    private struct Slot {
        var active = false
        var frameSeq: UInt32 = 0
        var dgramCnt = 0
        var bitmap = ContiguousArray<UInt8>()
        var receivedCnt = 0
        var firstRxUS: UInt64 = 0
        var complete = false
        var lastSentUS: UInt64 = 0 // 0 = never ACKed
        var newSinceSent = false   // bits arrived since the last ACK of this slot
    }

    private var slots: ContiguousArray<Slot>
    private var stragglerBitmap = ContiguousArray<UInt8>()
    /// Newest batch seen (serial order); it keeps its keepalive even once
    /// complete.
    private(set) var latestSeq: UInt32?

    init() {
        slots = ContiguousArray(repeating: Slot(), count: Self.slotCount)
        for i in 0..<Self.slotCount {
            slots[i].bitmap.reserveCapacity(Self.maxBitmapBytes)
        }
        stragglerBitmap.reserveCapacity(Self.maxBitmapBytes)
    }

    /// Forget every batch (in-session geometry change); storage is kept.
    mutating func reset() {
        for i in 0..<slots.count { claim(i, frameSeq: 0, dgramCnt: 0, nowUS: 0, active: false) }
        latestSeq = nil
    }

    /// Re-initializes slot `i` in place, keeping its bitmap's capacity.
    private mutating func claim(_ i: Int, frameSeq: UInt32, dgramCnt: Int, nowUS: UInt64, active: Bool) {
        slots[i].active = active
        slots[i].frameSeq = frameSeq
        slots[i].dgramCnt = dgramCnt
        slots[i].bitmap.removeAll(keepingCapacity: true)
        slots[i].bitmap.append(contentsOf: repeatElement(0, count: (dgramCnt + 7) / 8))
        slots[i].receivedCnt = 0
        slots[i].firstRxUS = nowUS
        slots[i].complete = false
        slots[i].lastSentUS = 0
        slots[i].newSinceSent = false
    }

    /// Records one received datagram (called after its records were
    /// processed, so any NACKs precede the batch ACK on the ordered control
    /// stream). Sends the completion ACK when the batch just completed.
    mutating func note(_ header: DatagramHeader, nowUS: UInt64,
                       send: Send) {
        let cnt = Int(header.dgramCnt)
        let idx = Int(header.dgramIdx)
        var slot = -1
        for i in 0..<slots.count where slots[i].active && slots[i].frameSeq == header.frameSeq {
            slot = i
            break
        }
        if slot < 0 {
            var chosen = -1
            for i in 0..<slots.count where !slots[i].active {
                chosen = i
                break
            }
            if chosen < 0 {
                // Evict a COMPLETE, non-latest slot first (oldest such): its
                // ACK already rode the reliable control stream, so nothing
                // is lost. Evicting the serially-oldest slot instead threw
                // away incomplete batches — exactly the ones whose late
                // datagrams still need reporting — as soon as four newer
                // batches had completed around them.
                for i in 0..<slots.count
                where slots[i].complete && slots[i].frameSeq != latestSeq
                    && (chosen < 0 || Serial.newer(slots[chosen].frameSeq, than: slots[i].frameSeq)) {
                    chosen = i
                }
            }
            if chosen < 0 {
                chosen = 0 // all incomplete: serially-oldest
                for i in 1..<slots.count
                where Serial.newer(slots[chosen].frameSeq, than: slots[i].frameSeq) {
                    chosen = i
                }
                // A straggler older than every tracked batch must not evict
                // one of them (possibly incomplete, possibly before its first
                // ACK — its received bits would be lost). Report it alone.
                if Serial.newer(slots[chosen].frameSeq, than: header.frameSeq) {
                    guard idx < cnt else { return }
                    stragglerBitmap.removeAll(keepingCapacity: true)
                    stragglerBitmap.append(contentsOf: repeatElement(0, count: (cnt + 7) / 8))
                    stragglerBitmap[idx >> 3] |= UInt8(1) << UInt8(idx & 7)
                    stragglerBitmap.withUnsafeBytes { send(header.frameSeq, UInt16(cnt), $0) }
                    return
                }
            }
            slot = chosen
            claim(slot, frameSeq: header.frameSeq, dgramCnt: cnt, nowUS: nowUS, active: true)
            if latestSeq == nil || Serial.newer(header.frameSeq, than: latestSeq!) {
                latestSeq = header.frameSeq
            }
        }
        guard slots[slot].dgramCnt == cnt, idx < cnt else { return }
        let bit = UInt8(1) << UInt8(idx & 7)
        if slots[slot].bitmap[idx >> 3] & bit == 0 {
            slots[slot].bitmap[idx >> 3] |= bit
            slots[slot].receivedCnt += 1
            slots[slot].newSinceSent = true
        }
        if slots[slot].receivedCnt == cnt && !slots[slot].complete {
            slots[slot].complete = true
            sendAck(slot, nowUS: nowUS, send: send) // batch completion
        }
    }

    /// Per-slot cadence (§3.5):
    ///  - partial: 8 ms after the batch's first datagram, then again ≥ 8 ms
    ///    after the previous ACK whenever NEW datagrams arrived — late or
    ///    reordered datagrams are reported promptly, coalesced;
    ///  - keepalive: the latest batch and every incomplete one, 100 ms
    ///    after THAT slot's last ACK. (Incomplete older batches too:
    ///    latest-only left their late datagrams unconfirmed, forcing
    ///    timeout → cold invalidation → redundant re-sends. And per slot:
    ///    a single global timestamp, reset by every completion ACK, meant
    ///    incomplete slots were never re-ACKed under steady traffic.)
    ///  - incomplete slots expire after `slotExpiryUS` (the host timed
    ///    them out long ago; re-ACKing forever is noise).
    mutating func tick(nowUS: UInt64, send: Send) {
        for i in 0..<slots.count where slots[i].active {
            if !slots[i].complete && nowUS &- slots[i].firstRxUS > Self.slotExpiryUS {
                slots[i].active = false
                continue
            }
            let sinceSent = nowUS &- slots[i].lastSentUS
            if !slots[i].complete && slots[i].newSinceSent
                && nowUS &- slots[i].firstRxUS >= Self.partialDelayUS
                && (slots[i].lastSentUS == 0 || sinceSent >= Self.partialDelayUS) {
                sendAck(i, nowUS: nowUS, send: send)
            } else if slots[i].lastSentUS != 0 && sinceSent >= Self.keepaliveUS
                        && (slots[i].frameSeq == latestSeq || !slots[i].complete) {
                sendAck(i, nowUS: nowUS, send: send)
            }
        }
    }

    private mutating func sendAck(_ slot: Int, nowUS: UInt64, send: Send) {
        let frameSeq = slots[slot].frameSeq
        let dgramCnt = UInt16(slots[slot].dgramCnt)
        slots[slot].bitmap.withUnsafeBytes { send(frameSeq, dgramCnt, $0) }
        slots[slot].lastSentUS = max(nowUS, 1)
        slots[slot].newSinceSent = false
    }
}
