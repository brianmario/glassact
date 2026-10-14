import Foundation
import Testing
import GlassActCodec
import GlassActTestSupport

@Suite struct XXH64Tests {
    @Test func knownVectorEmptyInput() {
        // §4.5 required vector.
        #expect(XXH64.hash([] as [UInt8]) == 0xEF46_DB37_51D8_E999)
    }

    @Test func determinism() {
        var rng = SplitMix64(seed: 42)
        for size in [0, 1, 3, 4, 7, 8, 31, 32, 33, 100, 4096, 16_384] {
            let buf = rng.bytes(size)
            #expect(XXH64.hash(buf) == XXH64.hash(buf), "size \(size)")
            #expect(XXH64.hash(buf, seed: 1) != XXH64.hash(buf, seed: 2), "seeds must differ, size \(size)")
        }
    }

    @Test func alignmentInvariance() {
        // Tile hashing may read from arbitrarily-offset row copies; the hash
        // must not depend on buffer alignment.
        var rng = SplitMix64(seed: 9)
        let payload = rng.bytes(1000)
        let aligned = XXH64.hash(payload)
        var shifted = [UInt8](repeating: 0, count: 1003)
        for offset in 1...3 {
            for i in 0..<payload.count {
                shifted[offset + i] = payload[i]
            }
            let h = shifted.withUnsafeBytes { raw in
                XXH64.hash(UnsafeRawBufferPointer(rebasing: raw[offset ..< offset + payload.count]))
            }
            #expect(h == aligned, "offset \(offset)")
        }
    }

    @Test func avalancheSanity() {
        var rng = SplitMix64(seed: 7)
        let trials = 200
        var totalFlipped = 0
        for _ in 0..<trials {
            var buf = rng.bytes(512)
            let h0 = XXH64.hash(buf)
            let bit = rng.int(0..<(512 * 8))
            buf[bit >> 3] ^= 1 << UInt8(bit & 7)
            let h1 = XXH64.hash(buf)
            let flipped = (h0 ^ h1).nonzeroBitCount
            #expect(flipped > 0)
            totalFlipped += flipped
        }
        let avg = Double(totalFlipped) / Double(trials)
        #expect(avg > 24 && avg < 40, "average flipped bits \(avg) — expected ≈ 32")
    }

    @Test func streamingMatchesOneShot() {
        var rng = SplitMix64(seed: 55)
        for size in [0, 1, 5, 31, 32, 33, 63, 64, 100, 255, 256, 1000, 16_384] {
            let payload = rng.bytes(size)
            let expected = XXH64.hash(payload)
            // Many random chunkings, including 1-byte feeds.
            for trial in 0..<8 {
                var state = XXH64.Streaming()
                var offset = 0
                while offset < size {
                    let chunk = trial == 0 ? 1 : min(size - offset, rng.int(1..<300))
                    payload.withUnsafeBytes { raw in
                        state.update(UnsafeRawBufferPointer(rebasing: raw[offset ..< offset + chunk]))
                    }
                    offset += chunk
                }
                #expect(state.finalize() == expected, "size \(size) trial \(trial)")
            }
        }
    }

    @Test func hashRowsMatchesTightExtraction() {
        var rng = SplitMix64(seed: 56)
        let width = 300, height = 200
        let bytesPerRow = width * 4 + 48 // padded stride, as capture buffers are
        let frame = rng.bytes(bytesPerRow * height)
        // Full and cropped tiles, including edges.
        for (x, y, tw, th) in [(0, 0, 64, 64), (64, 64, 64, 64), (256, 0, 44, 64), (0, 192, 64, 8), (256, 192, 44, 8)] {
            var tight = [UInt8](repeating: 0, count: tw * th * 4)
            frame.withUnsafeBytes { src in
                tight.withUnsafeMutableBytes { dst in
                    _ = TileOps.extract(src: src, bytesPerRow: bytesPerRow, x: x, y: y, tw: tw, th: th, into: dst)
                }
            }
            let rows = frame.withUnsafeBytes { raw in
                XXH64.hashRows(frame: raw, bytesPerRow: bytesPerRow, x: x, y: y, tw: tw, th: th)
            }
            #expect(rows == XXH64.hash(tight), "tile (\(x),\(y),\(tw),\(th))")
        }
    }

    /// hashRows has a register fast path for stripe-aligned rows (widths
    /// that are multiples of 8 px) and a streaming path otherwise; both must
    /// equal the one-shot hash of the tight bytes for every tile shape.
    @Test func hashRowsMatchesTightExtractionForEveryWidth() {
        var rng = SplitMix64(seed: 57)
        let bytesPerRow = 80 * 4 + 20 // padded, unaligned stride
        let frame = rng.bytes(bytesPerRow * 70)
        for tw in 1...64 {
            for th in [1, 2, 7, 64] {
                for seed: UInt64 in [0, 0x9E37_79B9_7F4A_7C15] {
                    let (x, y) = (3, 5)
                    var tight = [UInt8](repeating: 0, count: tw * th * 4)
                    frame.withUnsafeBytes { src in
                        tight.withUnsafeMutableBytes { dst in
                            _ = TileOps.extract(src: src, bytesPerRow: bytesPerRow, x: x, y: y, tw: tw, th: th, into: dst)
                        }
                    }
                    let rows = frame.withUnsafeBytes { raw in
                        XXH64.hashRows(frame: raw, bytesPerRow: bytesPerRow, x: x, y: y, tw: tw, th: th, seed: seed)
                    }
                    #expect(rows == XXH64.hash(tight, seed: seed), "tile \(tw)×\(th) seed \(seed)")
                }
            }
        }
    }

    /// Published xxHash64 vectors beyond the empty string — the one-shot and
    /// streaming paths share round/mergeRound, so a shared bug would pass
    /// every self-consistency test.
    @Test func knownVectors() {
        #expect(XXH64.hash(Array("a".utf8)) == 0xD24E_C4F1_A98C_6E5B)
        #expect(XXH64.hash(Array("abc".utf8)) == 0x44BC_2CF5_AD77_0999)
        #expect(XXH64.hash(Array("Nobody inspects the spammish repetition".utf8)) == 0xFBCE_A83C_8A37_8BF1)
    }

    @Test func zeroCollisionsAcrossRandomBuffers() {
        // §4.5 requires 10^6 × 16 KB buffers; that sweep runs via
        // `just test-exhaustive` (release mode). The default keeps the same
        // shape at 10^4 buffers so every test run still exercises it.
        let exhaustive = ProcessInfo.processInfo.environment["GLASSACT_EXHAUSTIVE"] == "1"
        let n = exhaustive ? 1_000_000 : 10_000
        var rng = SplitMix64(seed: 0x5EED)
        var seen = Set<UInt64>(minimumCapacity: n)
        var buf = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<n {
            buf.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt64.self)
                for i in 0..<words.count {
                    words[i] = rng.next()
                }
            }
            seen.insert(XXH64.hash(buf))
        }
        #expect(seen.count == n, "hash collision detected across \(n) random 16 KB buffers")
    }
}
