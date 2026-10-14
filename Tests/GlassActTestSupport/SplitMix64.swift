/// Deterministic seeded PRNG shared by every test target — all randomized,
/// fuzz and fault-injection tests use fixed seeds (§6).
public struct SplitMix64: RandomNumberGenerator {
    public var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            var v = next()
            for _ in 0..<8 where out.count < count {
                out.append(UInt8(truncatingIfNeeded: v))
                v >>= 8
            }
        }
        return out
    }

    public mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
