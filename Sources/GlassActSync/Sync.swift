// Stand-ins for the Synchronization module's Mutex and Atomic, which need
// macOS 15: the Host runs on macOS 14.4. Same names and call
// shapes, so a file switches by its import; when the floor reaches 15 again,
// delete this module and import Synchronization.
//
// Stored properties can't be gated by #available, so every OS uses these.
// Atomic compiles to the same instructions as Synchronization's (C11
// atomics, static inline); Mutex is os_unfair_lock, as Synchronization's is
// on Darwin.
public import os
// Public so Atomic's operations can be @inlinable: a load is then the
// instruction itself, not a call, as with Synchronization's.
public import GlassActSyncC

/// A value behind an `os_unfair_lock` (`OSAllocatedUnfairLock`, macOS 13+).
public struct Mutex<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ initialValue: sending Value) {
        lock = OSAllocatedUnfairLock(uncheckedState: initialValue)
    }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLockUnchecked(body)
    }
}

/// The orderings Glass Act uses.
public enum AtomicOrdering: Sendable {
    case relaxed
    case sequentiallyConsistent
}

/// A value that fits a 64-bit word.
public protocol AtomicWord {
    var atomicBits: Int64 { get }
    init(atomicBits: Int64)
}

extension Int: AtomicWord {
    @inlinable public var atomicBits: Int64 { Int64(self) }
    @inlinable public init(atomicBits: Int64) { self = Int(atomicBits) }
}
extension UInt: AtomicWord {
    @inlinable public var atomicBits: Int64 { Int64(bitPattern: UInt64(self)) }
    @inlinable public init(atomicBits: Int64) { self = UInt(UInt64(bitPattern: atomicBits)) }
}
extension Int64: AtomicWord {
    @inlinable public var atomicBits: Int64 { self }
    @inlinable public init(atomicBits: Int64) { self = atomicBits }
}
extension UInt64: AtomicWord {
    @inlinable public var atomicBits: Int64 { Int64(bitPattern: self) }
    @inlinable public init(atomicBits: Int64) { self = UInt64(bitPattern: atomicBits) }
}
extension Bool: AtomicWord {
    @inlinable public var atomicBits: Int64 { self ? 1 : 0 }
    @inlinable public init(atomicBits: Int64) { self = atomicBits != 0 }
}

/// A word read and written atomically. Its storage is allocated once, at
/// init; loads, stores and adds allocate nothing.
public final class Atomic<Value: AtomicWord>: @unchecked Sendable {
    @usableFromInline let word: UnsafeMutablePointer<Int64>

    public init(_ initialValue: Value) {
        word = .allocate(capacity: 1)
        word.initialize(to: initialValue.atomicBits)
    }

    deinit { word.deallocate() }

    @inlinable
    public func load(ordering: AtomicOrdering) -> Value {
        switch ordering {
        case .relaxed: Value(atomicBits: ga_atomic_load_relaxed(word))
        case .sequentiallyConsistent: Value(atomicBits: ga_atomic_load_seq_cst(word))
        }
    }

    @inlinable
    public func store(_ desired: Value, ordering: AtomicOrdering) {
        switch ordering {
        case .relaxed: ga_atomic_store_relaxed(word, desired.atomicBits)
        case .sequentiallyConsistent: ga_atomic_store_seq_cst(word, desired.atomicBits)
        }
    }
}

extension Atomic where Value: FixedWidthInteger {
    /// Wrapping add, as Synchronization's: the values before and after.
    @inlinable @discardableResult
    public func add(_ operand: Value, ordering: AtomicOrdering) -> (oldValue: Value, newValue: Value) {
        let bits = operand.atomicBits
        let old = switch ordering {
        case .relaxed: ga_atomic_fetch_add_relaxed(word, bits)
        case .sequentiallyConsistent: ga_atomic_fetch_add_seq_cst(word, bits)
        }
        return (Value(atomicBits: old), Value(atomicBits: old &+ bits))
    }

    /// Wrapping subtract: the values before and after.
    @inlinable @discardableResult
    public func subtract(_ operand: Value, ordering: AtomicOrdering) -> (oldValue: Value, newValue: Value) {
        let bits = 0 &- operand.atomicBits
        let old = switch ordering {
        case .relaxed: ga_atomic_fetch_add_relaxed(word, bits)
        case .sequentiallyConsistent: ga_atomic_fetch_add_seq_cst(word, bits)
        }
        return (Value(atomicBits: old), Value(atomicBits: old &+ bits))
    }
}
