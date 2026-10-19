// Heap-allocation counter for `replay --mode encode --count-allocs` (INV-7
// evidence): libmalloc's `malloc_logger` hook, the one MallocStackLogging
// and Instruments use, sees every malloc, calloc and realloc in the
// process. Counting is armed only around `encodeTick`, so the bench's own
// bookkeeping (ACK synthesis, trace reads) stays out of the numbers.
import Foundation
import Synchronization

enum AllocCounter {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    // libmalloc's MALLOC_LOG_TYPE_ALLOCATE bit.
    private static let typeAllocate: UInt32 = 2

    private static let armed = Atomic<Bool>(false)
    private static let armedThread = Atomic<UInt>(0)
    private static let allThreads = Atomic<Int>(0)
    private static let onArmedThread = Atomic<Int>(0)

    /// A snapshot of the running totals.
    struct Counts {
        var allThreads = 0   // every thread while armed (encode workers included)
        var armedThread = 0  // the thread that armed the counter (the encode queue)

        static func - (a: Counts, b: Counts) -> Counts {
            Counts(allThreads: a.allThreads - b.allThreads,
                   armedThread: a.armedThread - b.armedThread)
        }
    }

    private static let hook: Logger = { type, _, _, _, _, _ in
        // malloc, calloc and realloc (ALLOCATE | DEALLOCATE) all set ALLOCATE.
        guard type & AllocCounter.typeAllocate != 0,
              AllocCounter.armed.load(ordering: .relaxed) else { return }
        AllocCounter.allThreads.add(1, ordering: .relaxed)
        if UInt(bitPattern: pthread_self()) == AllocCounter.armedThread.load(ordering: .relaxed) {
            AllocCounter.onArmedThread.add(1, ordering: .relaxed)
        }
    }

    /// Installs the hook. False when libmalloc doesn't export `malloc_logger`
    /// or something else (MallocStackLogging, Instruments) already owns it.
    static func install() -> Bool {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return false }
        let slot = symbol.assumingMemoryBound(to: Optional<Logger>.self)
        guard slot.pointee == nil else { return false }
        // Touch every static first: a lazy initializer must not run inside
        // the hook, re-entering malloc.
        disarm()
        armedThread.store(0, ordering: .relaxed)
        _ = counts
        slot.pointee = hook
        return true
    }

    static func arm() {
        armedThread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed)
        armed.store(true, ordering: .sequentiallyConsistent)
    }

    static func disarm() {
        armed.store(false, ordering: .sequentiallyConsistent)
    }

    static var counts: Counts {
        Counts(allThreads: allThreads.load(ordering: .relaxed),
               armedThread: onArmedThread.load(ordering: .relaxed))
    }
}
