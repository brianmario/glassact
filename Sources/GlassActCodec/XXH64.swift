/// xxHash64 (public spec, seed 0 by default) — §4.5. Used to hash cropped,
/// tightly-packed tile bytes. A collision costs a missed visual update
/// (~2⁻⁶⁴ per changed tile), never divergence or a crash.
public enum XXH64 {
    @usableFromInline static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    @usableFromInline static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    @usableFromInline static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    @usableFromInline static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    @usableFromInline static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    @inline(__always)
    static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x &<< r) | (x &>> (64 &- r))
    }

    @inline(__always)
    static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always)
    static func mergeRound(_ h: UInt64, _ acc: UInt64) -> UInt64 {
        (h ^ round(0, acc)) &* p1 &+ p4
    }

    public static func hash(_ buf: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let len = buf.count
        var off = 0
        var h: UInt64
        if len >= 32 {
            var a1 = seed &+ p1 &+ p2
            var a2 = seed &+ p2
            var a3 = seed
            var a4 = seed &- p1
            let limit = len - 32
            while off <= limit {
                a1 = round(a1, UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: off, as: UInt64.self)))
                a2 = round(a2, UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: off + 8, as: UInt64.self)))
                a3 = round(a3, UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: off + 16, as: UInt64.self)))
                a4 = round(a4, UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: off + 24, as: UInt64.self)))
                off += 32
            }
            h = rotl(a1, 1) &+ rotl(a2, 7) &+ rotl(a3, 12) &+ rotl(a4, 18)
            h = mergeRound(h, a1)
            h = mergeRound(h, a2)
            h = mergeRound(h, a3)
            h = mergeRound(h, a4)
        } else {
            h = seed &+ p5
        }
        h &+= UInt64(len)
        while off + 8 <= len {
            h ^= round(0, UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: off, as: UInt64.self)))
            h = rotl(h, 27) &* p1 &+ p4
            off += 8
        }
        if off + 4 <= len {
            h ^= UInt64(UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: off, as: UInt32.self))) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            off += 4
        }
        while off < len {
            h ^= UInt64(buf[off]) &* p5
            h = rotl(h, 11) &* p1
            off += 1
        }
        h ^= h >> 33
        h &*= p2
        h ^= h >> 29
        h &*= p3
        h ^= h >> 32
        return h
    }

    public static func hash(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        bytes.withUnsafeBytes { hash($0, seed: seed) }
    }

    /// Hashes a tile's rows directly from a strided frame — byte-identical to
    /// hashing the tightly-packed extraction (§4.5's canonical byte order)
    /// without the 16 KB copy. This is the diff pass's fast path.
    public static func hashRows(
        frame: UnsafeRawBufferPointer, bytesPerRow: Int,
        x: Int, y: Int, tw: Int, th: Int, seed: UInt64 = 0
    ) -> UInt64 {
        let rowBytes = tw * 4
        let base = frame.baseAddress!
        // Fast path — every full-width tile (256-byte rows): when a row is a
        // whole number of 32-byte stripes, stripes never straddle rows, so
        // walking the rows with the accumulators in registers IS the
        // one-shot hash of the tight bytes (no buffering, no tail). Sending
        // every tile through the streaming path below would make it the top
        // self-owned hotspot in profiles (one non-inlined update call per
        // row, state through memory).
        if rowBytes >= 32 && rowBytes & 31 == 0 && th > 0 {
            var a1 = seed &+ p1 &+ p2
            var a2 = seed &+ p2
            var a3 = seed
            var a4 = seed &- p1
            for row in 0..<th {
                var p = UnsafeRawPointer(base.advanced(by: (y + row) * bytesPerRow + x * 4))
                let end = p.advanced(by: rowBytes)
                while p < end {
                    a1 = round(a1, UInt64(littleEndian: p.loadUnaligned(as: UInt64.self)))
                    a2 = round(a2, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
                    a3 = round(a3, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
                    a4 = round(a4, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 24, as: UInt64.self)))
                    p = p.advanced(by: 32)
                }
            }
            var h = rotl(a1, 1) &+ rotl(a2, 7) &+ rotl(a3, 12) &+ rotl(a4, 18)
            h = mergeRound(h, a1)
            h = mergeRound(h, a2)
            h = mergeRound(h, a3)
            h = mergeRound(h, a4)
            h &+= UInt64(rowBytes * th)
            h ^= h >> 33
            h &*= p2
            h ^= h >> 29
            h &*= p3
            h ^= h >> 32
            return h
        }
        var state = Streaming(seed: seed)
        for row in 0..<th {
            state.update(UnsafeRawBufferPointer(
                start: base.advanced(by: (y + row) * bytesPerRow + x * 4), count: rowBytes))
        }
        return state.finalize()
    }

    /// Incremental xxHash64 — same output as the one-shot `hash` for the
    /// concatenation of all `update` inputs.
    public struct Streaming {
        var acc1: UInt64
        var acc2: UInt64
        var acc3: UInt64
        var acc4: UInt64
        var buffer = SIMD32<UInt8>()
        var bufferCount = 0
        var totalLength = 0
        let seed: UInt64

        public init(seed: UInt64 = 0) {
            self.seed = seed
            acc1 = seed &+ XXH64.p1 &+ XXH64.p2
            acc2 = seed &+ XXH64.p2
            acc3 = seed
            acc4 = seed &- XXH64.p1
        }

        @inline(__always)
        mutating func consumeStripe(_ p: UnsafeRawPointer) {
            acc1 = XXH64.round(acc1, UInt64(littleEndian: p.loadUnaligned(as: UInt64.self)))
            acc2 = XXH64.round(acc2, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
            acc3 = XXH64.round(acc3, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
            acc4 = XXH64.round(acc4, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 24, as: UInt64.self)))
        }

        public mutating func update(_ input: UnsafeRawBufferPointer) {
            guard input.count > 0, let base = input.baseAddress else { return }
            totalLength += input.count
            var offset = 0
            if bufferCount > 0 {
                let need = 32 - bufferCount
                let take = min(need, input.count)
                withUnsafeMutableBytes(of: &buffer) { buf in
                    buf.baseAddress!.advanced(by: bufferCount)
                        .copyMemory(from: base, byteCount: take)
                }
                bufferCount += take
                offset += take
                if bufferCount == 32 {
                    withUnsafeBytes(of: buffer) { consumeStripe($0.baseAddress!) }
                    bufferCount = 0
                }
            }
            while offset + 32 <= input.count {
                consumeStripe(base.advanced(by: offset))
                offset += 32
            }
            if offset < input.count {
                let tail = input.count - offset
                withUnsafeMutableBytes(of: &buffer) { buf in
                    buf.baseAddress!.copyMemory(from: base.advanced(by: offset), byteCount: tail)
                }
                bufferCount = tail
            }
        }

        public mutating func finalize() -> UInt64 {
            var h: UInt64
            if totalLength >= 32 {
                h = XXH64.rotl(acc1, 1) &+ XXH64.rotl(acc2, 7) &+ XXH64.rotl(acc3, 12) &+ XXH64.rotl(acc4, 18)
                h = XXH64.mergeRound(h, acc1)
                h = XXH64.mergeRound(h, acc2)
                h = XXH64.mergeRound(h, acc3)
                h = XXH64.mergeRound(h, acc4)
            } else {
                h = seed &+ XXH64.p5
            }
            h &+= UInt64(totalLength)
            withUnsafeBytes(of: buffer) { buf in
                let base = buf.baseAddress!
                var offset = 0
                while offset + 8 <= bufferCount {
                    h ^= XXH64.round(0, UInt64(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
                    h = XXH64.rotl(h, 27) &* XXH64.p1 &+ XXH64.p4
                    offset += 8
                }
                if offset + 4 <= bufferCount {
                    h ^= UInt64(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) &* XXH64.p1
                    h = XXH64.rotl(h, 23) &* XXH64.p2 &+ XXH64.p3
                    offset += 4
                }
                while offset < bufferCount {
                    h ^= UInt64(buf[offset]) &* XXH64.p5
                    h = XXH64.rotl(h, 11) &* XXH64.p1
                    offset += 1
                }
            }
            h ^= h >> 33
            h &*= XXH64.p2
            h ^= h >> 29
            h &*= XXH64.p3
            h ^= h >> 32
            return h
        }
    }
}
