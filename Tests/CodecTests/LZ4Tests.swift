import Testing
import GlassActCodec
import GlassActTestSupport

@Suite struct LZ4Tests {
    private func encode(_ src: [UInt8]) -> [UInt8]? {
        let lz4 = LZ4Codec()
        var dst = [UInt8](repeating: 0, count: src.count)
        let n = src.withUnsafeBytes { s in
            dst.withUnsafeMutableBytes { d in
                lz4.encode(src: s, dst: d)
            }
        }
        return n > 0 ? Array(dst[0..<n]) : nil
    }

    private func decode(_ src: [UInt8], capacity: Int) -> [UInt8] {
        let lz4 = LZ4Codec()
        var dst = [UInt8](repeating: 0, count: capacity)
        let n = src.withUnsafeBytes { s in
            dst.withUnsafeMutableBytes { d in
                lz4.decode(src: s, dst: d)
            }
        }
        return Array(dst[0..<n])
    }

    @Test func compressibleRoundTrip() {
        // UI-like content: large runs — must compress well below RAW.
        var src = [UInt8](repeating: 0x20, count: 16_384)
        for i in stride(from: 0, to: src.count, by: 97) {
            src[i] = UInt8(truncatingIfNeeded: i)
        }
        guard let compressed = encode(src) else {
            Issue.record("expected compressible data to compress")
            return
        }
        #expect(compressed.count < src.count)
        #expect(decode(compressed, capacity: src.count) == src)
    }

    @Test func randomDataRoundTripsOrFallsBackToRaw() {
        var rng = SplitMix64(seed: 3)
        let src = rng.bytes(16_384)
        // Incompressible input must be rejected (encoder gate: strictly smaller
        // than RAW) — that is the RAW fallback path. If it does compress, it
        // must round-trip.
        if let compressed = encode(src) {
            #expect(compressed.count < src.count)
            #expect(decode(compressed, capacity: src.count) == src)
        }
    }

    @Test func garbageDecodeFailsSafely() {
        var rng = SplitMix64(seed: 13)
        for _ in 0..<200 {
            let garbage = rng.bytes(rng.int(1..<600))
            let out = decode(garbage, capacity: 16_384)
            // No crash is the primary bar; a "successful" decode of garbage is
            // fine as long as callers verify the expected tile size.
            #expect(out.count <= 16_384)
        }
    }

    @Test func truncatedPayloadDoesNotRoundTrip() {
        var src = [UInt8](repeating: 0xAB, count: 16_384)
        for i in stride(from: 0, to: src.count, by: 61) {
            src[i] = UInt8(truncatingIfNeeded: i &* 7)
        }
        guard let compressed = encode(src) else {
            Issue.record("expected compressible data")
            return
        }
        let truncated = Array(compressed.dropLast(compressed.count / 3))
        let out = decode(truncated, capacity: src.count)
        #expect(out != src) // callers reject via size/equality check (INV-6)
    }
}


@Suite struct WebPTileTests {
    /// A lossy VP8 stream decodes "successfully" to approximate pixels; the
    /// lossless entry point (WEBPL tiles, DELTA/STORE inners, lossless
    /// keyframes) must refuse it (INV-1), while the transient-paint decoder
    /// accepts it.
    @Test func losslessDecodeRefusesLossyStreams() {
        var rng = SplitMix64(seed: 72)
        let tile = rng.bytes(64 * 64 * 4)
        var lossy = [UInt8](repeating: 0, count: 64 * 64 * 8)
        let n = tile.withUnsafeBytes { src in
            lossy.withUnsafeMutableBytes { dst in
                WebPTile.encodeLossy(src: src, width: 64, height: 64, quality: 75, dst: dst)
            }
        }
        #expect(n > 0)
        var out = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let strict = lossy.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                WebPTile.decodeLossless(src: UnsafeRawBufferPointer(rebasing: src[0..<n]),
                                        width: 64, height: 64, dst: dst)
            }
        }
        #expect(strict == 0, "a lossy stream must not pass as lossless")
        let lenient = lossy.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                WebPTile.decodeBGRA(src: UnsafeRawBufferPointer(rebasing: src[0..<n]),
                                    width: 64, height: 64, dst: dst)
            }
        }
        #expect(lenient == 64 * 64 * 4)
    }

    @Test func roundTripRandomAndStructured() {
        var rng = SplitMix64(seed: 71)
        // Structured (text-like) and random (photo-like) tiles, plus a
        // cropped edge-tile shape.
        var structured = [UInt8](repeating: 0x20, count: 64 * 64 * 4)
        for i in stride(from: 0, to: structured.count, by: 128 + 4) {
            structured[i] = 0xFF
        }
        for (tw, th, tile) in [(64, 64, structured), (64, 64, rng.bytes(64 * 64 * 4)), (44, 8, rng.bytes(44 * 8 * 4))] {
            var out = [UInt8](repeating: 0, count: 64 * 64 * 4)
            let n = tile.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    WebPTile.encodeLossless(src: src, width: tw, height: th, effort: 4, dst: dst)
                }
            }
            if n > 0 { // random tiles may not beat the strictly-smaller gate
                var decoded = [UInt8](repeating: 0, count: tw * th * 4)
                let m = out[0..<n].withUnsafeBytes { src in
                    decoded.withUnsafeMutableBytes { dst in
                        WebPTile.decodeLossless(src: src, width: tw, height: th, dst: dst)
                    }
                }
                #expect(m == tw * th * 4)
                #expect(decoded == tile, "round trip must be byte-lossless (\(tw)x\(th))")
            }
        }
    }

    @Test func garbageAndDimensionMismatchAreRejected() {
        var rng = SplitMix64(seed: 72)
        var dst = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for _ in 0..<200 {
            let garbage = rng.bytes(rng.int(1..<400))
            let n = garbage.withUnsafeBytes { src in
                dst.withUnsafeMutableBytes { d in
                    WebPTile.decodeLossless(src: src, width: 64, height: 64, dst: d)
                }
            }
            #expect(n == 0 || n == 64 * 64 * 4)
        }
        // A valid 64×64 payload must be rejected when claimed as another size.
        let tile = [UInt8](repeating: 0x40, count: 64 * 64 * 4)
        var out = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let n = tile.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { d in
                WebPTile.encodeLossless(src: src, width: 64, height: 64, effort: 0, dst: d)
            }
        }
        #expect(n > 0)
        let mismatch = out[0..<n].withUnsafeBytes { src in
            dst.withUnsafeMutableBytes { d in
                WebPTile.decodeLossless(src: src, width: 32, height: 32, dst: d)
            }
        }
        #expect(mismatch == 0)
    }
}
