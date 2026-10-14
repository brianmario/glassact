import Testing
import GlassActWire

@Suite struct VarintTests {
    private func decode(_ bytes: [UInt8]) -> (value: UInt32, consumed: Int)? {
        bytes.withUnsafeBytes { raw -> (value: UInt32, consumed: Int)? in
            var r = ByteReader(raw)
            guard let v = r.readVarint() else { return nil }
            return (v, r.offset)
        }
    }

    @Test(arguments: [0, 1, 127, 128, 129, 300, 16_383, 16_384, 2_097_151, 2_097_152, 268_435_455] as [UInt32])
    func roundTrip(value: UInt32) {
        var w = ByteWriter()
        w.writeVarint(value)
        #expect(w.bytes.count <= 4)
        let decoded = decode(w.bytes)
        #expect(decoded?.value == value)
        #expect(decoded?.consumed == w.bytes.count)
    }

    @Test func encodedLengthsAreCanonical() {
        let cases: [(UInt32, Int)] = [
            (0, 1), (127, 1),
            (128, 2), (16_383, 2),
            (16_384, 3), (2_097_151, 3),
            (2_097_152, 4), (268_435_455, 4),
        ]
        for (value, expected) in cases {
            var w = ByteWriter()
            w.writeVarint(value)
            #expect(w.bytes.count == expected, "value \(value)")
        }
    }

    @Test func truncatedIsRejected() {
        #expect(decode([]) == nil)
        #expect(decode([0x80]) == nil)
        #expect(decode([0xFF, 0xFF]) == nil)
        #expect(decode([0x80, 0x80, 0x80]) == nil)
    }

    @Test func fourContinuationBytesIsRejected() {
        #expect(decode([0x80, 0x80, 0x80, 0x80]) == nil)
        #expect(decode([0xFF, 0xFF, 0xFF, 0xFF, 0x00]) == nil)
    }

    @Test func overlongEncodingIsAcceptedWithinFourBytes() {
        // Non-canonical but ≤ 4 bytes: tolerated on read; the writer always emits canonical form.
        #expect(decode([0x80, 0x00])?.value == 0)
        #expect(decode([0xFF, 0x00])?.value == 127)
        #expect(decode([0x80, 0x80, 0x80, 0x00])?.value == 0)
    }
}
