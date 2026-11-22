import Testing
import GlassActSync

/// GlassActSync's stand-ins for Synchronization's Mutex and Atomic (the Host's
/// macOS 14.4 floor): the same results, including wrapping arithmetic.
@Suite struct SyncTests {
    @Test func atomicLoadsStoresAndAdds() {
        let n = Atomic<Int>(5)
        #expect(n.load(ordering: .relaxed) == 5)
        n.store(-3, ordering: .relaxed)
        #expect(n.load(ordering: .sequentiallyConsistent) == -3)
        let added = n.add(10, ordering: .relaxed)
        #expect(added.oldValue == -3 && added.newValue == 7)
        let subtracted = n.subtract(9, ordering: .relaxed)
        #expect(subtracted.oldValue == 7 && subtracted.newValue == -2)
    }

    @Test func atomicWordsKeepTheirBits() {
        let big = Atomic<UInt64>(.max)
        #expect(big.load(ordering: .relaxed) == .max)
        #expect(big.add(1, ordering: .relaxed).newValue == 0) // wraps, as Synchronization's does
        let unsigned = Atomic<UInt>(.max - 1)
        #expect(unsigned.add(1, ordering: .relaxed).newValue == .max)
        let flag = Atomic<Bool>(false)
        flag.store(true, ordering: .sequentiallyConsistent)
        #expect(flag.load(ordering: .relaxed))
        let low = Atomic<Int>(.min)
        #expect(low.subtract(1, ordering: .relaxed).newValue == .max)
    }

    @Test func atomicAddsFromManyThreadsAreAllCounted() async {
        let n = Atomic<Int>(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { for _ in 0..<10_000 { n.add(1, ordering: .relaxed) } }
            }
        }
        #expect(n.load(ordering: .relaxed) == 80_000)
    }

    @Test func mutexSerializesUpdates() async {
        let m = Mutex<[Int]>([])
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask { for i in 0..<1_000 { m.withLock { $0.append(t * 1_000 + i) } } }
            }
        }
        let all = m.withLock { $0 }
        #expect(all.count == 8_000)
        #expect(Set(all).count == 8_000)
    }

    @Test func mutexRethrows() {
        struct Boom: Error {}
        let m = Mutex(1)
        #expect(throws: Boom.self) { try m.withLock { _ in throw Boom() } }
        #expect(m.withLock { $0 } == 1)
    }
}
