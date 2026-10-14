import Foundation
import GlassActCodec
import GlassActTransport
import GlassActWire

/// ACK / timeout resolution (§4.4), NACK repairs, send stamps, SRTT.
/// HostEngine extension: encodeQueue-confined like the engine itself.
extension HostEngine {
    // MARK: - ACK / timeout resolution (§4.4)

    func applyAck(frameSeq: UInt32, dgramCnt: UInt16, bitmap: [UInt8]) {
        stats.acksReceived += 1
        var batchIdx = -1
        for i in 0..<batches.count where batches[i].frameSeq == frameSeq
            && batches[i].dgramCnt == Int(dgramCnt) && batches[i].sendTimeUS != 0 {
            batchIdx = i
            break
        }
        guard batchIdx >= 0 else { return }
        // A batch already resolved by timeout (its slot not yet reused): its
        // tiles were invalidated and re-encode — nothing to commit (INV-9) —
        // but the ACK still MEASURES the path. Once a deep queue holds more
        // than a timeout's worth, every ACK is late; ignoring them left the
        // governor with only the few datagrams that skipped the queue (it
        // read no queue at all) while the link sat 2 s deep.
        guard batches[batchIdx].active else {
            measureLateAck(batchIndex: batchIdx, bitmap: bitmap)
            return
        }

        // Datagram-path delay (send → ACK), the congestion signal for the
        // governor and the timeout floor. PING SRTT rides the CONTROL tunnel
        // — a separate QUIC connection that stays snappy while the datagram
        // path drowns; measured live: a 13 s standing queue with SRTT
        // reading a healthy 15–25 ms, so the rate boost never backed off and
        // healthy-SRTT timeouts re-encoded batches that were merely queued
        // (resend amplification). ACK delay includes the real queue.
        //
        // Sampled only from ACKs that confirm something new. The viewer
        // re-ACKs incomplete batches every 100 ms as keepalive; those carry
        // no new information, and their age is the ACK cadence, not the
        // path. Sampling them made loss inflate the EWMA, which raised the
        // timeout floor (2 × ackDelay), which let more re-ACKs arrive before
        // timeout — a feedback loop (120 ms RTT at 5 % loss read 275 ms).
        var confirmedNew = false
        var newlyConfirmed = 0
        for d in 0..<batches[batchIdx].dgramCnt {
            let received = (bitmap[d >> 3] >> UInt8(d & 7)) & 1 == 1
            guard received && !batches[batchIdx].confirmed[d] else { continue }
            if !confirmedNew {
                confirmedNew = true
                samplePathDelay(batchIndex: batchIdx, datagram: d)
            }
            batches[batchIdx].confirmed[d] = true
            batches[batchIdx].confirmedCnt += 1
            newlyConfirmed += 1
            var t = Int(batches[batchIdx].dgramFirstTile[d])
            guard t >= 0 else { continue } // header-only datagram (none today)
            let tileCount = batches[batchIdx].tiles.count
            while t < tileCount && batches[batchIdx].tiles[t].firstDgram <= Int32(d) {
                if Int32(d) <= batches[batchIdx].tiles[t].lastDgram {
                    batches[batchIdx].tiles[t].remaining -= 1
                    if batches[batchIdx].tiles[t].remaining == 0 {
                        commitAck(batchIndex: batchIdx, entry: t)
                    }
                }
                t += 1
            }
        }
        if newlyConfirmed > 0 {
            governor.noteDelivered(newlyConfirmed * batches[batchIdx].byteSize / batches[batchIdx].dgramCnt,
                                   nowUS: lastControlNowUS)
        }
        if batches[batchIdx].confirmedCnt == batches[batchIdx].dgramCnt {
            batches[batchIdx].active = false
            observePace(batchIndex: batchIdx, lost: 0)
        }
    }

    /// One delay sample from the first datagram an ACK newly confirms.
    func samplePathDelay(batchIndex batchIdx: Int, datagram d: Int) {
        let delaySample = lastControlNowUS &- batches[batchIdx].sendTimeUS
        if delaySample < 60_000_000 { // sanity: ignore pathological samples
            ackDelayUS = ackDelayUS == 0 ? delaySample : (ackDelayUS &* 7 &+ delaySample) / 8
            ackDelaySampleUS = lastControlNowUS
        }
        // Path delay for the auto rate: this datagram's ACK time
        // minus its estimated departure from the pacer (what was
        // queued ahead, then its share of the batch's own bytes).
        // (A transport that doesn't pace releases everything at once.)
        let departUS = batches[batchIdx].paceRate == 0 ? batches[batchIdx].sendTimeUS
            : batches[batchIdx].sendTimeUS &+ batches[batchIdx].aheadUS
                &+ UInt64(d + 1) &* batches[batchIdx].ownUS / UInt64(batches[batchIdx].dgramCnt)
        let pathSample = Self.elapsedUS(lastControlNowUS, since: departUS)
        if pathSample < 60_000_000 {
            governor.notePathDelay(pathSample, nowUS: lastControlNowUS)
        }
    }

    /// An ACK for a batch already resolved by timeout: delay and delivered
    /// bytes only (same rules as a live ACK — one sample per ACK that
    /// confirms something new, never the keepalive re-ACKs).
    func measureLateAck(batchIndex batchIdx: Int, bitmap: [UInt8]) {
        var newlyConfirmed = 0
        for d in 0..<batches[batchIdx].dgramCnt {
            guard (bitmap[d >> 3] >> UInt8(d & 7)) & 1 == 1, !batches[batchIdx].confirmed[d] else { continue }
            if newlyConfirmed == 0 { samplePathDelay(batchIndex: batchIdx, datagram: d) }
            batches[batchIdx].confirmed[d] = true
            batches[batchIdx].confirmedCnt += 1
            newlyConfirmed += 1
        }
        if newlyConfirmed > 0 {
            governor.noteDelivered(newlyConfirmed * batches[batchIdx].byteSize / batches[batchIdx].dgramCnt,
                                   nowUS: lastControlNowUS)
        }
    }

    @inline(__always)
    func sendStampUS(_ nowUS: UInt64) -> UInt64 {
        guard let clock else { return nowUS }
        return max(clock(), nowUS)
    }

    /// Send stamps can be later than a caller's `nowUS` (captured before the
    /// tick that sent): not yet elapsed, never a wrapped huge age.
    @inline(__always)
    public static func elapsedUS(_ nowUS: UInt64, since: UInt64) -> UInt64 {
        nowUS > since ? nowUS - since : 0
    }

    func resolveTimeouts(nowUS: UInt64) {
        resolveKeyframeTimeout(nowUS: nowUS)
        for i in 0..<batches.count where batches[i].active {
            guard Self.elapsedUS(nowUS, since: batches[i].sendTimeUS)
                    >= timeoutUS(serializationUS: batches[i].serializationUS) else { continue }
            observePace(batchIndex: i, lost: batches[i].dgramCnt - batches[i].confirmedCnt)
            governor.noteTimeout(datagrams: batches[i].dgramCnt,
                                 lost: batches[i].dgramCnt - batches[i].confirmedCnt,
                                 sentUS: batches[i].sendTimeUS, nowUS: nowUS)
            // INV-5: lost pixels are never retransmitted; affected tiles are
            // re-encoded from the current capture.
            //
            // Cold on timeout (§4.4), required by the §7 golden bar: a
            // timed-out send may have been APPLIED by the viewer even though
            // its confirmation never arrived (the batch's other datagrams were
            // lost, or the ACKs that would have covered this tile were).
            // Keeping ackedHash would then misdescribe the viewer — and if the
            // tile's content REVERTS to that ackedHash (blinking cursor,
            // clock), `h == ackedHash` suppresses the re-send forever:
            // permanent divergence, caught by the real-trace golden replay.
            // Timeout therefore drops the tile to cold state (ackedHash = 0),
            // forcing one re-send whose newer frame_seq wins on the viewer
            // whatever its actual state is.
            for tile in batches[i].tiles where tile.remaining > 0 {
                invalidateAfterTimeout(tile: Int(tile.tileIdx), seq: batches[i].frameSeq)
                // Tile cache: undelivered STORE → viewer state unknown → free the
                // slot; undelivered REF → release the pin.
                switch tile.cacheKind {
                case 1:
                    cache.resolveStore(slot: Int(tile.cacheSlot), hash: tile.hash, committed: false,
                                       tight: UnsafeRawBufferPointer(start: nil, count: 0))
                case 2:
                    cache.releaseRef(Int(tile.cacheSlot))
                default:
                    break
                }
            }
            batches[i].active = false
        }
    }

    public var timeoutUS: UInt64 {
        max(3 &* srttUS, 50_000)
    }

    /// Batch timeout (§4.4): `max(3·SRTT, 50 ms)` plus a serialization
    /// allowance. Large batches (a 5K cold start is ~15 MB) take longer to
    /// *serialize onto the wire* than the bare RTT timeout — timing them out
    /// mid-transmission re-encodes and re-floods the full frame in a
    /// permanent thrash loop (found by the sustained-session QUIC test at
    /// live-demo scale). The allowance covers the batch plus what was queued
    /// ahead of it, at the pace in effect when it was sent.
    public func timeoutUS(serializationUS: UInt64) -> UInt64 {
        // Floor at 2× the observed datagram-path delay: under a standing
        // queue, control-tunnel-SRTT timeouts fired while datagrams were
        // still queued, re-encoding tiles whose first copies were in flight
        // (live resend-amplification spiral). Bounded so a dead path still
        // times out.
        max(timeoutUS &+ serializationUS, min(2 &* ackDelayUS, 3_000_000))
    }

    /// Adaptive pacing (`PaceController`): a resolved batch's loss steers
    /// the transport's datagram pace. Batches sent before the last change
    /// are ignored by the controller (they describe the old rate).
    func observePace(batchIndex i: Int, lost: Int) {
        guard batches[i].paceRate > 0,
              pace.observe(sentAtRate: batches[i].paceRate, datagrams: batches[i].dgramCnt,
                           bytes: batches[i].byteSize, lost: lost) else { return }
        transport.setDatagramPaceRate(bytesPerSecond: pace.rate)
        stats.datagramPaceRate = pace.rate
        stats.paceDecreases = pace.decreases
        stats.paceIncreases = pace.increases
    }

    func commitAck(batchIndex: Int, entry: Int) {
        let tileEntry = batches[batchIndex].tiles[entry]
        let idx = Int(tileEntry.tileIdx)
        // Tile-cache resolution. Store-slot commitment needs MORE than
        // datagram receipt: a fragmented STORE superseded mid-flight by a
        // newer same-tile send gets discarded by the viewer's all-or-nothing
        // reassembly while every datagram still ACKs (found by the windowed-
        // scroll faulted golden). But that newer send necessarily overwrote
        // this tile's inflight slot — so the INV-9 seq guard is exactly the
        // "no discard was possible" test. Guard passes ⇒ the viewer stored
        // (even if canvas-stale); guard fails ⇒ viewer state unknown ⇒ free
        // the slot.
        switch tileEntry.cacheKind {
        case 1:
            let (_, _, ttw, tth) = grid.rect(of: idx)
            cache.resolveStore(
                slot: Int(tileEntry.cacheSlot), hash: tileEntry.hash,
                committed: ledger[idx].inflightSeq == batches[batchIndex].frameSeq,
                tight: UnsafeRawBufferPointer(start: retention[batchIndex].baseAddress!.advanced(by: entry * Self.tileBytes),
                                              count: ttw * tth * 4))
        case 2:
            cache.releaseRef(Int(tileEntry.cacheSlot))
        default:
            break
        }
        // INV-9 seq guard. It also carries the scroll semantics (§4.8): when a
        // SCROLL is emitted, in-flight slots for tiles inside its rect are
        // cleared (the viewer will LWW-block those records), so their late
        // ACKs land here and are correctly ignored.
        guard ledger.commit(idx, seq: batches[batchIndex].frameSeq, hash: tileEntry.hash) else { return }
        noteExactCopyConfirmed(idx, seq: batches[batchIndex].frameSeq)
        traceTile(idx, "host commitAck seq=\(batches[batchIndex].frameSeq) hash=\(String(tileEntry.hash, radix: 16))")
        // The viewer verifiably applied these pixels — promote them into
        // the ACKed shadow canvas.
        let (x, y, tw, th) = grid.rect(of: idx)
        let retained = UnsafeRawBufferPointer(
            start: retention[batchIndex].baseAddress!.advanced(by: entry * Self.tileBytes),
            count: tw * th * 4)
        TileOps.apply(tight: retained, into: shadow, canvasWidth: grid.width, x: x, y: y, tw: tw, th: th)
    }

    @inline(__always)
    func invalidateAfterTimeout(tile: Int, seq: UInt32) {
        // INV-9 guard: newer sends govern. Viewer state unknown → cold
        // (§4.4 cold-on-timeout; see resolveTimeouts).
        if ledger.invalidate(tile, seq: seq) {
            traceTile(tile, "host timeout-invalidate seq=\(seq)")
        }
    }

    func updateSRTT(sample: UInt64) {
        srttUS = srttUS == 0 ? sample : (srttUS &* 7 &+ sample) / 8 // EWMA α = 0.125
    }


    /// DELTA_NACK repair: the viewer received these delta records but their
    /// pinned base hash did not match the canvas — received ≠ applied. The
    /// host's belief about these tiles is wrong (or about to be made wrong by
    /// the bitmap ACK, which promotes on receipt): zero the acked hash so the
    /// tile re-qualifies as an absolute record, and clear the in-flight slot
    /// under the INV-9 seq guard so the bitmap ACK for the same send is
    /// treated as stale instead of promoting the never-applied hash.
    func repairAfterDeltaNack(frameSeq: UInt32, tiles: [UInt16]) {
        for t in tiles {
            let idx = Int(t)
            guard idx < grid.count else { continue } // INV-6: hostile index
            ledger.markCold(idx)
            unindexCacheRef(frameSeq: frameSeq, tile: idx)
            ledger.clearInflight(idx, onlyIfSeq: frameSeq)
            stats.deltaNacksRepaired += 1
            traceTile(idx, "host deltaNack-repair seq=\(frameSeq)")
        }
    }

    /// A NACKed send that was a cache REF means the viewer's copy of that
    /// slot is unusable (a REF miss). Stop REF-ing it — otherwise the
    /// repair re-send would look up the same hash, REF the same slot, miss
    /// again, and NACK forever. The slot drops out of the index and its
    /// hash is cleared (so a later eviction can't unindex a re-store of the
    /// same content elsewhere); in-flight refs drain as usual, after which
    /// cacheAllocate may reuse it. A NACKed STORE needs nothing here: the
    /// NACK clears the tile's in-flight slot first, so commitAck's INV-9
    /// guard frees the store slot when the batch ACK lands.
    func unindexCacheRef(frameSeq: UInt32, tile: Int) {
        for b in 0..<batches.count where batches[b].frameSeq == frameSeq {
            for e in batches[b].tiles where Int(e.tileIdx) == tile && e.cacheKind == 2 {
                if cache.poison(slot: Int(e.cacheSlot), hash: e.hash) {
                    stats.cacheSlotsPoisoned += 1
                }
            }
        }
    }
}
