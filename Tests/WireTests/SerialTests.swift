import Testing
import GlassActWire
import GlassActTestSupport

@Suite struct SerialTests {
    @Test func basicOrdering() {
        #expect(Serial.newer(1, than: 0))
        #expect(!Serial.newer(0, than: 1))
        #expect(!Serial.newer(7, than: 7))
        #expect(Serial.newer(1000, than: 999))
    }

    @Test func wraparound() {
        #expect(Serial.newer(0, than: UInt32.max))
        #expect(!Serial.newer(UInt32.max, than: 0))
        #expect(Serial.newer(5, than: UInt32.max - 5))
        #expect(!Serial.newer(UInt32.max - 5, than: 5))
    }

    @Test func halfRangeBoundary() {
        #expect(Serial.newer(0x7FFF_FFFF, than: 0))
        // Distance exactly 2^31: undefined ordering, false in both directions.
        #expect(!Serial.newer(0x8000_0000, than: 0))
        #expect(!Serial.newer(0, than: 0x8000_0000))
        // One past the boundary flips direction.
        #expect(!Serial.newer(0x8000_0001, than: 0))
        #expect(Serial.newer(0, than: 0x8000_0001))
    }

    @Test func antisymmetryAcrossRandomPairs() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<10_000 {
            let a = UInt32(truncatingIfNeeded: rng.next())
            let b = UInt32(truncatingIfNeeded: rng.next())
            if a != b && (a &- b) != 0x8000_0000 {
                #expect(Serial.newer(a, than: b) != Serial.newer(b, than: a))
            } else {
                #expect(!Serial.newer(a, than: b) && !Serial.newer(b, than: a))
            }
        }
    }
}
