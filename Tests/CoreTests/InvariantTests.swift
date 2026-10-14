import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// §1 — every invariant gets a named test. A failing INV_* test blocks merge (§12).
@Suite struct InvariantTests {
    /// INV-1: no tile payload ever encodes a delta against unspecified prior
    /// content. Every record (reassembled if fragmented) must decode standalone
    /// to exactly the source tile bytes.
    @Test func INV_1_absolutePayloads() {
        var rng = SplitMix64(seed: 11)
        let (host, capture) = makeRunningHost(width: 128, height: 128)
        var frame = TestFrame(width: 128, height: 128)
        frame.fillRandom(&rng) // noise → RAW, fragmented
        frame.encode(host: host, nowUS: 10_000)
        #expect(!capture.sentDatagrams.isEmpty)
        let decoded = decodeTilePayloads(capture.sentDatagrams)
        #expect(decoded.count == 4) // cold start: all tiles
        for (tileIdx, payload) in decoded {
            #expect(payload == frame.tightTile(Int(tileIdx)), "tile \(tileIdx)")
        }
    }

    /// INV-1 at parallel-hash scale: ≥ 128 candidates routes the diff through
    /// the concurrent hash path — payloads must decode identically, and a
    /// second unchanged frame must still qualify zero tiles (hash equivalence
    /// between the in-place row hash and the tight-extraction hash).
    @Test func INV_1_absolutePayloads_parallelHashPath() {
        var rng = SplitMix64(seed: 12)
        let (host, capture) = makeRunningHost(width: 1024, height: 1024) // 256 tiles
        var frame = TestFrame(width: 1024, height: 1024)
        frame.fillRandom(&rng)
        // A 256-tile noise flood exceeds the send governor's burst bucket — pace it with
        // ACKed ticks until every tile has shipped (the invariant is about
        // payload absoluteness, not single-tick delivery).
        var now: UInt64 = 10_000
        for _ in 0..<20 {
            let mark = capture.sentDatagrams.count
            frame.encode(host: host, nowUS: now)
            for ack in fullAcks(for: Array(capture.sentDatagrams[mark...])) {
                host.handleControl(ack, nowUS: now + 1_000)
            }
            now += 100_000
            if decodeTilePayloads(capture.sentDatagrams).count == 256 { break }
        }
        let decoded = decodeTilePayloads(capture.sentDatagrams)
        #expect(decoded.count == 256)
        for (tileIdx, payload) in decoded {
            #expect(payload == frame.tightTile(Int(tileIdx)), "tile \(tileIdx)")
        }
        frame.encode(host: host, nowUS: now) // unchanged: zero qualifiers
        #expect(host.stats.lastTickQualifiedTiles == 0)
    }

    /// INV-2: per-tile LWW. A batch is never dropped wholesale as stale —
    /// stale records are skipped per tile, fresh records in the same datagram
    /// still apply.
    @Test func INV_2_perTileLWW() {
        let (viewer, _) = makeRunningViewer(width: 128, height: 64) // 2 tiles
        let tileBytes = 64 * 64 * 4
        let a = [UInt8](repeating: 0xAA, count: tileBytes)
        let b = [UInt8](repeating: 0xBB, count: tileBytes)
        let c = [UInt8](repeating: 0xCC, count: tileBytes)
        viewer.handleDatagram(makeDatagram(seq: 5, records: [(0, a)]), nowUS: 0)
        // Older batch: tile 0 must NOT regress, tile 1 must still apply.
        viewer.handleDatagram(makeDatagram(seq: 3, records: [(0, b), (1, c)]), nowUS: 0)
        #expect(canvasTile(viewer, 0) == a)
        #expect(canvasTile(viewer, 1) == c)
        #expect(viewer.stats.recordsStale == 1)
    }

    /// INV-3: the encoder's shadow map (ackedHash) only advances on ACK —
    /// never on send.
    @Test func INV_3_ackGatedReferences() {
        var rng = SplitMix64(seed: 23)
        let (host, capture) = makeRunningHost(width: 64, height: 64) // 1 tile
        var frame = TestFrame(width: 64, height: 64)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        let sentAfterFirst = capture.sentDatagrams.count
        #expect(sentAfterFirst > 0)
        #expect(host.ackedHash(forTile: 0) == 0) // sent ≠ acked
        #expect(host.inflight(forTile: 0).hash != 0)

        // Identical content while in flight: skip-if-identical-in-flight.
        frame.encode(host: host, nowUS: 20_000)
        #expect(capture.sentDatagrams.count == sentAfterFirst)
        #expect(host.stats.lastTickQualifiedTiles == 0)

        for ack in fullAcks(for: capture.sentDatagrams) {
            host.handleControl(ack, nowUS: 30_000)
        }
        #expect(host.ackedHash(forTile: 0) != 0)
        #expect(host.inflight(forTile: 0).hash == 0)
        #expect(host.openBatchCount == 0)

        // Now identical to the ACKed map: nothing qualifies.
        frame.encode(host: host, nowUS: 40_000)
        #expect(capture.sentDatagrams.count == sentAfterFirst)
    }

    /// INV-4: with ≥ 2 open batches the capture is skipped entirely; the
    /// changed pixels re-qualify once a batch resolves.
    @Test func INV_4_newestWinsNeverQueue() {
        var rng = SplitMix64(seed: 31)
        let (host, capture) = makeRunningHost(width: 64, height: 64)
        var frame = TestFrame(width: 64, height: 64)

        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000) // batch 1
        let afterFirst = capture.sentDatagrams.count
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 20_000) // batch 2
        let afterSecond = capture.sentDatagrams.count
        #expect(afterSecond > afterFirst)
        #expect(host.openBatchCount == 2)

        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 25_000) // must be dropped
        #expect(capture.sentDatagrams.count == afterSecond)
        #expect(host.stats.batchesDropped == 1)

        // Resolve batch 1; the change is still pending vs the ACKed map and
        // re-qualifies — nothing was lost.
        let batch1Acks = fullAcks(for: Array(capture.sentDatagrams[0..<afterFirst]))
        for ack in batch1Acks {
            host.handleControl(ack, nowUS: 30_000)
        }
        #expect(host.openBatchCount == 1)
        frame.encode(host: host, nowUS: 35_000)
        #expect(capture.sentDatagrams.count > afterSecond)
        #expect(host.stats.lastTickQualifiedTiles == 1)
    }

    /// INV-4 with dirty rects: a dropped capture's changes still re-qualify.
    /// Rects are deltas against the previous capture, so the tick after a
    /// drop does not report what changed in the dropped one — without
    /// carrying that damage forward, the tile was never hashed again and
    /// stayed stale on the viewer (live, 2026-09-30). The settle harness
    /// hid it: its ticks pass `dirtyRects: nil`, a full scan.
    @Test func INV_4_droppedCaptureDamageStillRequalifies() {
        var rng = SplitMix64(seed: 33)
        let (host, capture) = makeRunningHost(width: 128, height: 64)
        var frame = TestFrame(width: 128, height: 64)
        let tile0 = DirtyRect(x: 0, y: 0, width: 64, height: 64)
        let tile1 = DirtyRect(x: 64, y: 0, width: 64, height: 64)

        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000) // cold start: full scan
        for ack in fullAcks(for: capture.sentDatagrams) { host.handleControl(ack, nowUS: 12_000) }
        #expect(host.openBatchCount == 0)

        // Two batches open on tile 0 …
        var sent = capture.sentDatagrams.count
        frame.fillRect(x: 0, y: 0, w: 64, h: 64, &rng)
        frame.encode(host: host, dirtyRects: [tile0], nowUS: 20_000)
        let batch2 = Array(capture.sentDatagrams[sent...])
        sent = capture.sentDatagrams.count
        frame.fillRect(x: 0, y: 0, w: 64, h: 64, &rng)
        frame.encode(host: host, dirtyRects: [tile0], nowUS: 25_000)
        let batch3 = Array(capture.sentDatagrams[sent...])
        #expect(host.openBatchCount == 2)

        // … so the capture that changes tile 1 is dropped (INV-4).
        frame.fillRect(x: 64, y: 0, w: 64, h: 64, &rng)
        frame.encode(host: host, dirtyRects: [tile1], nowUS: 30_000)
        #expect(host.stats.batchesDropped == 1)

        for ack in fullAcks(for: batch2 + batch3) { host.handleControl(ack, nowUS: 35_000) }
        #expect(host.openBatchCount == 0)
        // The next capture's rects don't mention tile 1 (it didn't change
        // again) — it must still be sent.
        frame.encode(host: host, dirtyRects: [tile0], nowUS: 40_000)
        #expect(host.stats.lastTickQualifiedTiles == 1)
        #expect(host.inflight(forTile: 1).hash == XXH64.hash(frame.tightTile(1)))
    }

    /// INV-5: pixels are never retransmitted. After a timeout, the tile is
    /// re-encoded from the *current* capture under a new frame_seq.
    @Test func INV_5_reliabilityForStateNotPixels() {
        var rng = SplitMix64(seed: 41)
        let (host, capture) = makeRunningHost(width: 64, height: 64)
        var frame = TestFrame(width: 64, height: 64)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        let firstBatchDatagrams = capture.sentDatagrams
        let firstSeq = header(of: firstBatchDatagrams[0])!.frameSeq
        #expect(host.openBatchCount == 1)

        // No ACK ever arrives; the batch times out (timeout = max(3·SRTT, 50 ms)).
        host.tick(nowUS: 10_000 + host.timeoutUS + 1_000)
        #expect(host.openBatchCount == 0)
        #expect(host.inflight(forTile: 0).hash == 0)

        // Content changed since the loss: the re-send must carry the *new*
        // pixels, not the old batch's bytes.
        frame.fillRandom(&rng)
        let before = capture.sentDatagrams.count
        frame.encode(host: host, nowUS: 10_000 + host.timeoutUS + 5_000)
        let resent = Array(capture.sentDatagrams[before...])
        #expect(!resent.isEmpty)
        let newSeq = header(of: resent[0])!.frameSeq
        #expect(Serial.newer(newSeq, than: firstSeq))
        let decoded = decodeTilePayloads(resent)
        #expect(decoded[0] == frame.tightTile(0))
    }

    /// INV-9: one in-flight slot per tile. A re-send overwrites the slot and
    /// stale ACKs for the older send are ignored.
    @Test func INV_9_oneInflightSlotPerTile() {
        var rng = SplitMix64(seed: 53)
        let (host, capture) = makeRunningHost(width: 64, height: 64)
        var frame = TestFrame(width: 64, height: 64)

        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        let batch1 = capture.sentDatagrams
        let inflight1 = host.inflight(forTile: 0)

        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 20_000)
        let batch2 = Array(capture.sentDatagrams[batch1.count...])
        let inflight2 = host.inflight(forTile: 0)
        #expect(inflight2.seq != inflight1.seq && inflight2.hash != inflight1.hash) // slot overwritten

        // Stale ACK for the overwritten send: must not touch ackedHash or the slot.
        for ack in fullAcks(for: batch1) {
            host.handleControl(ack, nowUS: 30_000)
        }
        #expect(host.ackedHash(forTile: 0) == 0)
        #expect(host.inflight(forTile: 0) == inflight2)

        // ACK for the current send commits.
        for ack in fullAcks(for: batch2) {
            host.handleControl(ack, nowUS: 40_000)
        }
        #expect(host.ackedHash(forTile: 0) == inflight2.hash)
        #expect(host.inflight(forTile: 0).hash == 0)
    }

    /// INV-10: no changes → no datagrams (keepalive ACK/PING ride control and
    /// are exempt). Counted on the WIRE, not by the engine's stats: the old
    /// 10 s keepalive datagram bypassed `datagramsSent`, so this test never
    /// saw it.
    @Test func INV_10_idleZeroBytes() {
        var rng = SplitMix64(seed: 61)
        let harness = Harness(width: 256, height: 192)
        harness.frame.fillRandom(&rng)
        harness.encodeFrame()
        #expect(harness.settle())
        let settled = harness.host.stats.datagramsSent
        let onWire = harness.link.deliveredDatagrams + harness.link.pendingDatagramCount
        // 60 s of idle at ~60 Hz.
        for _ in 0..<120 {
            harness.encodeFrame()
            harness.run(untilUS: harness.now + 500_000)
        }
        #expect(harness.link.deliveredDatagrams + harness.link.pendingDatagramCount == onWire,
                "idle must put zero datagrams on the wire")
        #expect(harness.host.stats.datagramsSent == settled)
        #expect(harness.host.stats.batchesDropped == 0)
    }

    /// INV-6 at engine level: malformed datagrams and control garbage must
    /// never crash the engines (wire-level fuzz lives in WireTests; payload
    /// decoders are reached by `EngineFuzzTests`, since random bytes almost
    /// never survive whole-datagram validation).
    @Test func INV_6_parserSafetyEngineLevel() {
        var rng = SplitMix64(seed: 71)
        let (viewer, _) = makeRunningViewer(width: 256, height: 192)
        for _ in 0..<2_000 {
            var bytes = rng.bytes(rng.int(0..<600))
            if !bytes.isEmpty && rng.int(0..<2) == 0 {
                bytes[0] = WireVersion.current << 4 // was 0x10 (v1): every one died at the header
            }
            viewer.handleDatagram(Data(bytes), nowUS: 0)
        }
        #expect(viewer.stats.recordsApplied == 0 || viewer.state == .running) // no crash is the bar

        let (host, _) = makeRunningHost(width: 64, height: 64)
        host.handleControl(Data(rng.bytes(300)), nowUS: 0) // may latch failed; must not crash
        viewer.handleControl(Data(rng.bytes(300)), nowUS: 0)
    }

    /// INV-7 smoke: per-frame paths run out of preallocated storage — the
    /// encode arena must never reallocate across a sustained session. Full
    /// allocation validation is a bench/Instruments job.
    @Test func INV_7_noPerFrameArenaGrowth() {
        var rng = SplitMix64(seed: 83)
        let harness = Harness(width: 256, height: 192)
        harness.frame.fillRandom(&rng)
        harness.encodeFrame()
        harness.settle()
        let arenaBase = harness.host.debugArenaBase
        for _ in 0..<100 {
            _ = harness.mutateRandomRects(&rng, count: 2)
            harness.encodeFrame()
            harness.run(untilUS: harness.now + 16_000)
        }
        harness.settle()
        #expect(harness.host.debugArenaBase == arenaBase)
        #expect(harness.canvasMatchesFrame())
    }

    /// Regression (§4.4 cold-on-timeout, found by golden replay of a real capture):
    /// a timed-out send may have been applied by the viewer even though its
    /// confirmation was lost. If ackedHash survived the timeout and the tile's
    /// content then REVERTED to it (clock/cursor blink), `h == ackedHash`
    /// suppressed the re-send forever — permanent divergence. Timeout must
    /// drop the tile to cold state so it re-sends unconditionally.
    @Test func timeoutInvalidatesShadowMap_revertRegression() {
        var rng = SplitMix64(seed: 67)
        let (host, capture) = makeRunningHost(width: 64, height: 64) // 1 tile
        var frameA = TestFrame(width: 64, height: 64)
        frameA.fillRandom(&rng)

        // Content A: sent, fully ACKed — viewer has A, ackedHash = H(A).
        frameA.encode(host: host, nowUS: 10_000)
        for ack in fullAcks(for: capture.sentDatagrams) {
            host.handleControl(ack, nowUS: 20_000)
        }
        let ackedA = host.ackedHash(forTile: 0)
        #expect(ackedA != 0)

        // Content B: sent, never confirmed (the viewer may still have applied
        // it — the host cannot know), batch times out.
        var frameB = frameA
        frameB.fillRandom(&rng)
        frameB.encode(host: host, nowUS: 30_000)
        host.tick(nowUS: 30_000 + host.timeoutUS + 1_000)
        #expect(host.openBatchCount == 0)
        #expect(host.ackedHash(forTile: 0) == 0, "timeout must invalidate the shadow map")

        // Content reverts to A. Pre-fix: h == stale ackedHash -> never sent,
        // leaving a viewer that applied B diverged forever. Now: must re-send.
        let before = capture.sentDatagrams.count
        frameA.encode(host: host, nowUS: 30_000 + host.timeoutUS + 10_000)
        #expect(capture.sentDatagrams.count > before, "reverted content must re-send after timeout")
        #expect(host.stats.lastTickQualifiedTiles == 1)
    }

    /// INV-8: the canvas holds exactly the decoded bytes — no filtering, no
    /// smoothing, and untouched tiles stay untouched.
    @Test func INV_8_canvasExactlyAsCoded() {
        let (viewer, _) = makeRunningViewer(width: 128, height: 64)
        var rng = SplitMix64(seed: 97)
        let payload = rng.bytes(64 * 64 * 4)
        viewer.handleDatagram(makeDatagram(seq: 1, records: [(0, payload)]), nowUS: 0)
        #expect(canvasTile(viewer, 0) == payload)
        #expect(canvasTile(viewer, 1) == [UInt8](repeating: 0, count: 64 * 64 * 4))
    }
}
