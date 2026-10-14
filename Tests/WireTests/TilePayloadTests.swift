import Testing
import GlassActWire
import GlassActTestSupport

/// DELTA (0x0B) and CACHE (0x07) payload sub-formats: round trips through
/// the host-side writers, every structural rejection, and INV-6 fuzz.
@Suite struct TilePayloadTests {
    private func withBuffer<R>(_ bytes: [UInt8], _ body: (UnsafeRawBufferPointer) -> R) -> R {
        bytes.withUnsafeBytes(body)
    }

    private func deltaBytes(baseHash: UInt64, subRect: (x: Int, y: Int, width: Int, height: Int)?,
                            inner: UInt8, payload: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: DeltaPayload.subRectHeaderBytes)
        let n = header.withUnsafeMutableBytes {
            DeltaPayload.writeHeader(baseHash: baseHash, subRect: subRect, innerOpcode: inner, into: $0)
        }
        return Array(header.prefix(n)) + payload
    }

    @Test func deltaWholeTileRoundTrips() {
        let bytes = deltaBytes(baseHash: 0x0123_4567_89AB_CDEF, subRect: nil, inner: Opcode.lz4, payload: [9, 8, 7])
        #expect(bytes.count == DeltaPayload.wholeTileHeaderBytes + 3)
        withBuffer(bytes) { buf in
            guard let d = DeltaPayload.parse(buf, tileWidth: 64, tileHeight: 64) else {
                Issue.record("valid DELTA rejected")
                return
            }
            #expect(d.mode == 0 && d.baseHash == 0x0123_4567_89AB_CDEF)
            #expect(d.x == 0 && d.y == 0 && d.width == 64 && d.height == 64)
            #expect(d.innerOpcode == Opcode.lz4 && Array(d.inner) == [9, 8, 7])
        }
    }

    @Test func deltaSubRectRoundTripsOnAnEdgeTile() {
        let bytes = deltaBytes(baseHash: 42, subRect: (x: 3, y: 5, width: 10, height: 7), inner: Opcode.raw,
                               payload: [UInt8](repeating: 1, count: 10 * 7 * 4))
        withBuffer(bytes) { buf in
            guard let d = DeltaPayload.parse(buf, tileWidth: 13, tileHeight: 12) else {
                Issue.record("valid DELTA rejected")
                return
            }
            #expect(d.mode == 1 && d.x == 3 && d.y == 5 && d.width == 10 && d.height == 7)
            #expect(d.inner.count == 280)
            // The same rect doesn't fit a narrower tile.
            #expect(DeltaPayload.parse(buf, tileWidth: 12, tileHeight: 12) == nil)
        }
    }

    @Test func deltaRejectsMalformed() {
        let good = deltaBytes(baseHash: 1, subRect: (x: 0, y: 0, width: 4, height: 4), inner: Opcode.raw, payload: [0])
        var badMode = good; badMode[0] = 2
        var emptyRect = good; emptyRect[11] = 0
        var cacheInner = good; cacheInner[13] = Opcode.cache
        var deltaInner = good; deltaInner[13] = Opcode.delta
        for (name, bytes) in [("mode 2", badMode), ("empty rect", emptyRect), ("CACHE inner", cacheInner),
                              ("DELTA inner", deltaInner), ("truncated", Array(good.prefix(12))), ("empty", [])] {
            withBuffer(bytes) { buf in
                #expect(DeltaPayload.parse(buf, tileWidth: 64, tileHeight: 64) == nil, "\(name) must be rejected")
            }
        }
    }

    @Test func cacheStoreAndRefRoundTrip() {
        var prefix = [UInt8](repeating: 0, count: 16)
        let n = prefix.withUnsafeMutableBytes {
            CachePayload.writeStoreApplyPrefix(slot: 0x0F0E, innerOpcode: Opcode.webpl, into: $0)
        }
        withBuffer(Array(prefix.prefix(n)) + [5, 6]) { buf in
            guard case let .storeApply(slot, inner, payload)? = CachePayload.parse(buf) else {
                Issue.record("valid STORE rejected")
                return
            }
            #expect(slot == 0x0F0E && inner == Opcode.webpl && Array(payload) == [5, 6])
        }
        var ref = [UInt8](repeating: 0, count: 16)
        let m = ref.withUnsafeMutableBytes {
            CachePayload.writeRef(slot: 7, contentHash: 0xFEED_FACE_CAFE_BEEF, into: $0)
        }
        #expect(m == CachePayload.refBytes)
        withBuffer(Array(ref.prefix(m))) { buf in
            guard case let .ref(slot, hash)? = CachePayload.parse(buf) else {
                Issue.record("valid REF rejected")
                return
            }
            #expect(slot == 7 && hash == 0xFEED_FACE_CAFE_BEEF)
        }
    }

    @Test func cacheRejectsMalformed() {
        let cases: [(String, [UInt8])] = [
            ("unknown sub-op", [2, 0, 0]),
            ("STORE of CACHE", [0, 1, 0, Opcode.cache, 1]),
            ("STORE of DELTA", [0, 1, 0, Opcode.delta, 1]),
            ("REF trailing byte", [1, 1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9]),
            ("REF truncated", [1, 1, 0, 1, 2, 3]),
            ("no slot", [0, 1]),
            ("empty", []),
        ]
        for (name, bytes) in cases {
            withBuffer(bytes) { buf in
                #expect(CachePayload.parse(buf) == nil, "\(name) must be rejected")
            }
        }
    }

    /// INV-6: random and mutated payloads never crash or over-read either
    /// parser (run under `just test-asan` for over-read detection), and any
    /// view they return stays inside the input.
    @Test func fuzzRandomAndMutated() {
        var rng = SplitMix64(seed: 0x7A11)
        let seeds: [[UInt8]] = [
            deltaBytes(baseHash: 3, subRect: nil, inner: Opcode.lz4, payload: rng.bytes(40)),
            deltaBytes(baseHash: 4, subRect: (x: 1, y: 2, width: 3, height: 4), inner: Opcode.raw, payload: rng.bytes(48)),
            [0, 5, 0, Opcode.raw] + rng.bytes(64),
            [1, 5, 0] + rng.bytes(8),
        ]
        for i in 0..<40_000 {
            var bytes: [UInt8]
            if i % 2 == 0 {
                bytes = rng.bytes(rng.int(0..<80))
            } else {
                bytes = seeds[rng.int(0..<seeds.count)]
                for _ in 0..<rng.int(1..<6) where !bytes.isEmpty {
                    bytes[rng.int(0..<bytes.count)] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
                }
                if rng.int(0..<4) == 0 { bytes = Array(bytes.prefix(rng.int(0..<bytes.count + 1))) }
            }
            let tw = rng.int(1..<65), th = rng.int(1..<65)
            withBuffer(bytes) { buf in
                let base = UInt(bitPattern: buf.baseAddress)
                let end = base + UInt(buf.count)
                if let d = DeltaPayload.parse(buf, tileWidth: tw, tileHeight: th) {
                    #expect(d.x + d.width <= tw && d.y + d.height <= th)
                    let p = UInt(bitPattern: d.inner.baseAddress)
                    #expect(d.inner.isEmpty || (p >= base && p + UInt(d.inner.count) <= end))
                }
                if case let .storeApply(_, _, inner)? = CachePayload.parse(buf) {
                    let p = UInt(bitPattern: inner.baseAddress)
                    #expect(inner.isEmpty || (p >= base && p + UInt(inner.count) <= end))
                }
            }
        }
    }
}
