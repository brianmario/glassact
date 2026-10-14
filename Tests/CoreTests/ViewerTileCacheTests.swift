import Testing
import GlassActCodec
@testable import GlassActCore
import GlassActTestSupport

/// Viewer tile cache (§4.8), driven on the cache alone. (The cache is
/// noncopyable, so results are taken into locals before `#expect`, whose
/// expansion copies the operands of a call it decomposes.)
@Suite struct ViewerTileCacheTests {
    private static func store(_ cache: inout ViewerTileCache, slot: Int, seq: UInt32, _ tile: [UInt8]) -> Bool {
        tile.withUnsafeBytes { cache.store(slot: slot, seq: seq, tile: $0) }
    }

    private static func lookup(_ cache: borrowing ViewerTileCache, slot: Int, _ tile: [UInt8]) -> [UInt8]? {
        cache.lookup(slot: slot, expectedHash: XXH64.hash(tile)).map { [UInt8]($0) }
    }

    @Test func slotLWWGateRejectsAnOlderStore() {
        var rng = SplitMix64(seed: 0xCAC4E)
        var cache = ViewerTileCache()
        let a = rng.bytes(ViewerTileCache.entryBytes)
        let b = rng.bytes(ViewerTileCache.entryBytes)
        let storedA = Self.store(&cache, slot: 17, seq: 5, a)
        // A late, reordered STORE from before the slot was reused must not
        // poison it; nor may a same-seq one (not newer).
        let storedOlder = Self.store(&cache, slot: 17, seq: 4, b)
        let storedSame = Self.store(&cache, slot: 17, seq: 5, b)
        let slotSeq = cache.storedSeq(17)
        let hitA = Self.lookup(cache, slot: 17, a)
        let hitB = Self.lookup(cache, slot: 17, b)
        #expect(storedA && !storedOlder && !storedSame)
        #expect(slotSeq == 5)
        #expect(hitA == a)
        #expect(hitB == nil)

        // A newer store wins — including across the u32 wrap (serial
        // arithmetic: each step is less than half the space ahead).
        let stored1 = Self.store(&cache, slot: 17, seq: 0x7000_0000, b)
        let stored2 = Self.store(&cache, slot: 17, seq: 0xE000_0000, b)
        let storedPostWrap = Self.store(&cache, slot: 17, seq: 3, a)
        let hitAfterWrap = Self.lookup(cache, slot: 17, a)
        #expect(stored1 && stored2 && storedPostWrap)
        #expect(hitAfterWrap == a)
    }

    @Test func refIsHashGuardedAndSlotsAreIndependent() {
        var rng = SplitMix64(seed: 3)
        var cache = ViewerTileCache()
        let a = rng.bytes(ViewerTileCache.entryBytes)
        let last = ViewerTileCache.slotCount - 1
        let emptyHit = Self.lookup(cache, slot: 0, a)
        let emptyValid = cache.isValid(0)
        let stored = Self.store(&cache, slot: last, seq: 1, a)
        let hit = Self.lookup(cache, slot: last, a)
        let wrongHash = cache.lookup(slot: last, expectedHash: XXH64.hash(a) ^ 1) == nil
        let otherSlot = Self.lookup(cache, slot: 0, a)
        #expect(emptyHit == nil && !emptyValid)
        #expect(stored)
        #expect(hit == a)
        #expect(wrongHash)
        #expect(otherSlot == nil)
    }

    @Test func resetEmptiesEverySlot() {
        var rng = SplitMix64(seed: 4)
        var cache = ViewerTileCache()
        let a = rng.bytes(ViewerTileCache.entryBytes)
        let stored = Self.store(&cache, slot: 9, seq: 100, a)
        cache.reset()
        let validAfterReset = cache.isValid(9)
        let hitAfterReset = Self.lookup(cache, slot: 9, a)
        // The slot seq resets too: a new session's low seqs store again.
        let storedLowSeq = Self.store(&cache, slot: 9, seq: 1, a)
        let hit = Self.lookup(cache, slot: 9, a)
        #expect(stored && !validAfterReset)
        #expect(hitAfterReset == nil)
        #expect(storedLowSeq)
        #expect(hit == a)
    }
}
