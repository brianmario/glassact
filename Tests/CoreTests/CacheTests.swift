import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Session tile cache (opcode 0x07, §4.8).
@Suite struct CacheTests {
    private func cacheStore(seq: UInt32, tile: UInt16, slot: UInt16, raw: [UInt8]) -> Data {
        var w = ByteWriter()
        DatagramHeader(frameSeq: seq, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        var payload: [UInt8] = [0, UInt8(truncatingIfNeeded: slot), UInt8(truncatingIfNeeded: slot >> 8), Opcode.raw]
        payload.append(contentsOf: raw)
        Datagram.appendRecord(opcode: Opcode.cache, tileIdx: tile, fragIdx: 0, fragCnt: 1,
                              payload: payload, into: &w)
        return Data(w.bytes)
    }

    private func cacheRef(seq: UInt32, tile: UInt16, slot: UInt16, hash: UInt64) -> Data {
        var w = ByteWriter()
        DatagramHeader(frameSeq: seq, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        var payload: [UInt8] = [1, UInt8(truncatingIfNeeded: slot), UInt8(truncatingIfNeeded: slot >> 8)]
        withUnsafeBytes(of: hash.littleEndian) { payload.append(contentsOf: $0) }
        Datagram.appendRecord(opcode: Opcode.cache, tileIdx: tile, fragIdx: 0, fragCnt: 1,
                              payload: payload, into: &w)
        return Data(w.bytes)
    }

    @Test func storeThenRefAppliesCachedContent() {
        var rng = SplitMix64(seed: 91)
        let (viewer, _) = makeRunningViewer(width: 128, height: 64) // 2 tiles
        let content = rng.bytes(64 * 64 * 4)
        let hash = XXH64.hash(content)
        viewer.handleDatagram(cacheStore(seq: 1, tile: 0, slot: 7, raw: content), nowUS: 0)
        #expect(viewer.stats.cacheStores == 1)
        #expect(canvasTile(viewer, 0) == content) // STORE also applies
        // REF materializes the same content at another tile from the cache.
        viewer.handleDatagram(cacheRef(seq: 2, tile: 1, slot: 7, hash: hash), nowUS: 0)
        #expect(viewer.stats.cacheRefsApplied == 1)
        #expect(canvasTile(viewer, 1) == content)
    }

    @Test func refWithWrongHashIsDroppedCleanly() {
        var rng = SplitMix64(seed: 92)
        let (viewer, _) = makeRunningViewer(width: 128, height: 64)
        let content = rng.bytes(64 * 64 * 4)
        viewer.handleDatagram(cacheStore(seq: 1, tile: 0, slot: 3, raw: content), nowUS: 0)
        // Slot was since (conceptually) overwritten: hash mismatch → drop.
        viewer.handleDatagram(cacheRef(seq: 2, tile: 1, slot: 3, hash: 0xDEAD_BEEF), nowUS: 0)
        #expect(viewer.stats.cacheRefMisses == 1)
        #expect(canvasTile(viewer, 1) == [UInt8](repeating: 0, count: 64 * 64 * 4))
        // Unstored slot and out-of-range slot: also clean drops.
        viewer.handleDatagram(cacheRef(seq: 3, tile: 1, slot: 99, hash: 1), nowUS: 0)
        viewer.handleDatagram(cacheRef(seq: 4, tile: 1, slot: 60_000, hash: 1), nowUS: 0)
        #expect(viewer.stats.recordsApplied == 1) // only the STORE applied
    }

    /// The race the design closes: a STORE that is canvas-stale (an LWW-newer
    /// record already landed) must STILL seed the cache — receipt ⇒ stored.
    @Test func canvasStaleStoreStillStores() {
        var rng = SplitMix64(seed: 93)
        let (viewer, _) = makeRunningViewer(width: 128, height: 64)
        let newer = rng.bytes(64 * 64 * 4)
        let older = rng.bytes(64 * 64 * 4)
        viewer.handleDatagram(makeDatagram(seq: 10, records: [(0, newer)]), nowUS: 0)
        // Straggler STORE with an older seq: canvas must keep `newer`, cache
        // must gain `older`.
        viewer.handleDatagram(cacheStore(seq: 5, tile: 0, slot: 2, raw: older), nowUS: 0)
        #expect(canvasTile(viewer, 0) == newer)
        #expect(viewer.stats.cacheStores == 1)
        #expect(viewer.stats.recordsStale >= 1)
        // And the cached content is fully usable afterwards.
        viewer.handleDatagram(cacheRef(seq: 11, tile: 1, slot: 2, hash: XXH64.hash(older)), nowUS: 0)
        #expect(canvasTile(viewer, 1) == older)
    }

    /// Host end-to-end: repeated content becomes REFs (blink/revert pattern),
    /// and the loop stays byte-exact under faults with the cache active.
    @Test func hostEmitsRefsForRepeatedContent() {
        var rng = SplitMix64(seed: 94)
        let (host, capture) = makeRunningHost(width: 128, height: 128) // 4 tiles
        var frameA = TestFrame(width: 128, height: 128)
        frameA.fillRandom(&rng)
        var frameB = frameA
        frameB.fillRect(x: 0, y: 0, w: 128, h: 128, &rng)

        func ackAll(_ nowUS: UInt64) {
            for ack in fullAcks(for: capture.sentDatagrams) {
                host.handleControl(ack, nowUS: nowUS)
            }
        }
        frameA.encode(host: host, nowUS: 10_000)
        ackAll(20_000)
        frameB.encode(host: host, nowUS: 30_000)
        ackAll(40_000)
        #expect(host.stats.cacheStoresSent >= 8) // both frames' tiles seeded
        #expect(host.stats.cacheRefsSent == 0)
        // Revert to frame A: all four tiles should ship as 11-byte REFs.
        let bytesBefore = host.stats.bytesOut
        frameA.encode(host: host, nowUS: 50_000)
        #expect(host.stats.cacheRefsSent == 4)
        let revertBytes = host.stats.bytesOut - bytesBefore
        #expect(revertBytes < 300, "revert shipped \(revertBytes) B — expected ~4 refs + headers")
        ackAll(60_000)
    }

    /// Full-loop golden with blink/revert content — cache refs under faults
    /// must stay byte-exact.
    /// Same revert with DELTA records on (as in every real session): every reverted
    /// tile has an ACKed base, so a DELTA is always available — but an
    /// 11-byte REF beats any DELTA. The cache lookup used to be skipped for
    /// DELTA-coded tiles (a STORE can't wrap a DELTA; the REF was collateral).
    @Test func refBeatsDeltaForRevertedContent() {
        var rng = SplitMix64(seed: 95)
        let (host, capture) = makeRunningHost(width: 128, height: 128, deltas: true)
        var frameA = TestFrame(width: 128, height: 128)
        frameA.fillRandom(&rng)
        var frameB = frameA
        frameB.fillRect(x: 10, y: 10, w: 20, h: 20, &rng) // small edits: DELTA territory
        frameB.fillRect(x: 74, y: 74, w: 20, h: 20, &rng)
        frameB.fillRect(x: 10, y: 74, w: 20, h: 20, &rng)
        frameB.fillRect(x: 74, y: 10, w: 20, h: 20, &rng)
        func ackAll(_ nowUS: UInt64) {
            for ack in fullAcks(for: capture.sentDatagrams) {
                host.handleControl(ack, nowUS: nowUS)
            }
        }
        frameA.encode(host: host, nowUS: 10_000)
        ackAll(20_000)
        frameB.encode(host: host, nowUS: 30_000)
        ackAll(40_000)
        let deltasToB = host.stats.deltasSent
        #expect(deltasToB > 0, "the A → B edits should ship as DELTAs")
        let bytesBefore = host.stats.bytesOut
        frameA.encode(host: host, nowUS: 50_000) // revert: A is cached and ACKed
        #expect(host.stats.cacheRefsSent == 4)
        #expect(host.stats.deltasSent == deltasToB, "no DELTA may ship where a REF hits")
        #expect(host.stats.bytesOut - bytesBefore < 4 * 64, "four REFs are ~11 B each")
    }

    @Test(arguments: [UInt64(21), 22])
    func blinkingGoldenUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = seed
        let harness = Harness(width: 320, height: 320, faults: faults)
        var rng = SplitMix64(seed: seed &* 131)
        harness.frame.fillRandom(&rng)
        harness.encodeFrame()
        harness.run(untilUS: harness.now + 500_000)
        let stateA = harness.frame.bytes
        var stateB = harness.frame
        stateB.fillRect(x: 64, y: 64, w: 192, h: 192, &rng)
        let stateBBytes = stateB.bytes
        for i in 0..<24 { // blink A ↔ B — cache heaven after the first cycle
            harness.frame.bytes = (i % 2 == 0) ? stateBBytes : stateA
            harness.encodeFrame()
            harness.run(untilUS: harness.now + 50_000)
        }
        #expect(harness.settle())
        #expect(harness.canvasMatchesFrame(), "blinking golden diverged (seed \(seed))")
        #expect(harness.host.stats.cacheRefsSent > 0, "cache never engaged")
        #expect(harness.viewer.stats.cacheRefsApplied > 0)
    }
}
