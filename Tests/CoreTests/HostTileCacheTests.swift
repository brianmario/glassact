import Testing
@testable import GlassActCore
import GlassActTestSupport

/// HostTileCache (the host's tile-cache mirror) in isolation: the slot lifecycle rules the
/// engine's REF/STORE decisions depend on. (`#expect` can't evaluate calls
/// on a ~Copyable value, so results go through locals.)
@Suite struct HostTileCacheTests {
    private func tile(_ rng: inout SplitMix64) -> [UInt8] { rng.bytes(HostTileCache.tileBytes) }

    private func commit(_ cache: inout HostTileCache, _ pixels: [UInt8], hash: UInt64) -> Int? {
        guard let slot = cache.beginStore(hash: hash) else { return nil }
        pixels.withUnsafeBytes { cache.resolveStore(slot: slot, hash: hash, committed: true, tight: $0) }
        return slot
    }

    private func lookup(_ cache: borrowing HostTileCache, _ pixels: [UInt8], hash: UInt64) -> Int? {
        pixels.withUnsafeBytes { cache.lookup(hash: hash, tight: $0) }
    }

    @Test func storeDedupesInFlightAndBecomesRefableOnlyWhenCommitted() {
        var rng = SplitMix64(seed: 1)
        var cache = HostTileCache()
        let a = tile(&rng)
        guard let slot = cache.beginStore(hash: 7) else {
            Issue.record("empty cache refused a store")
            return
        }
        let again = cache.beginStore(hash: 7)
        #expect(again == nil, "identical content already storing")
        let early = lookup(cache, a, hash: 7)
        #expect(early == nil, "not REF-able before its ACK")
        a.withUnsafeBytes { cache.resolveStore(slot: slot, hash: 7, committed: true, tight: $0) }
        let hit = lookup(cache, a, hash: 7)
        #expect(hit == slot)
        let collision = lookup(cache, tile(&rng), hash: 7) // same hash, other bytes
        #expect(collision == nil, "memcmp must reject a hash collision")
    }

    @Test func abandonedStoreFreesTheSlot() {
        var cache = HostTileCache()
        guard let slot = cache.beginStore(hash: 9) else { return }
        cache.resolveStore(slot: slot, hash: 9, committed: false, tight: UnsafeRawBufferPointer(start: nil, count: 0))
        let state = cache.slots[slot].state
        #expect(state == .free)
        let restore = cache.beginStore(hash: 9)
        #expect(restore != nil, "the hash may be stored again")
    }

    @Test func evictionTakesTheOldestQuiescentSlotAndNeverAPinnedOne() {
        var rng = SplitMix64(seed: 2)
        var cache = HostTileCache()
        // Only the first two entries' bytes are looked up; the rest share one.
        let pixels = [tile(&rng), tile(&rng)]
        let filler = tile(&rng)
        for h in 1...UInt64(HostTileCache.slotCount) {
            let slot = commit(&cache, h <= 2 ? pixels[Int(h) - 1] : filler, hash: h)
            #expect(slot != nil)
        }
        // Full. Pin the oldest (hash 1): the next store must evict hash 2.
        guard let oldest = lookup(cache, pixels[0], hash: 1) else {
            Issue.record("oldest entry missing")
            return
        }
        cache.pinRef(oldest)
        let evicted = cache.beginStore(hash: 99_999)
        #expect(evicted != nil && evicted != oldest)
        let victim = lookup(cache, pixels[1], hash: 2)
        #expect(victim == nil, "hash 2 was the victim")
        let survivor = lookup(cache, pixels[0], hash: 1)
        #expect(survivor == oldest, "the pinned slot survives")
    }

    @Test func poisonedSlotNeverMatchesAgain() {
        var rng = SplitMix64(seed: 3)
        var cache = HostTileCache()
        let a = tile(&rng)
        guard let slot = commit(&cache, a, hash: 5) else { return }
        let first = cache.poison(slot: slot, hash: 5)
        let second = cache.poison(slot: slot, hash: 5)
        #expect(first && !second)
        let after = lookup(cache, a, hash: 5)
        #expect(after == nil)
    }
}
