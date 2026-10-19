import Foundation
import Testing
import GlassActCodec
import GlassActTestSupport

/// INV-6 inside the tile decoder. The datagram parser only frames a WEBPL
/// payload; its bytes go straight to the vendored libwebp VP8L decoder (the
/// one CVE-2023-4863 hit). This corpus is real `WebPTile` output for
/// screen-like tiles at the sizes the Viewer decodes, mutated with
/// structure-aware edits (`WebPMutator`). The bar: never crash, never
/// over-read the payload (ASan, `just test-asan`), never write outside the
/// destination (canaries), and either fail (0) or fill exactly the
/// expected tile, every byte of it, independent of what was there before.
@Suite struct WebPDecodeFuzzTests {
    struct Entry {
        var width: Int
        var height: Int
        var image: FuzzImage
        var pixels: [UInt8]
        var payload: [UInt8]
    }

    /// `GLASSACT_EXHAUSTIVE=1` (`just test-exhaustive`, release) runs 100×
    /// the iterations.
    static let scale = ProcessInfo.processInfo.environment["GLASSACT_EXHAUSTIVE"] == "1" ? 100 : 1

    /// Full tiles, the cropped edge tiles of odd-sized displays, and
    /// DELTA-sized sub-rects.
    static let sizes = [(64, 64), (64, 14), (17, 64), (36, 6), (1, 64), (64, 1), (8, 8)]

    static func corpus(lossless: Bool) -> [Entry] {
        var rng = SplitMix64(seed: lossless ? 0x5EB1 : 0x5EB2)
        let efforts: [Int32] = [0, 1, 4, 6] // the host uses 1 and 4; 0 and 6 vary the transforms
        var out: [Entry] = []
        var dst = [UInt8](repeating: 0, count: 64 * 64 * 4 * 2 + 1024)
        for (si, (w, h)) in sizes.enumerated() {
            for (ii, image) in FuzzImage.allCases.enumerated() {
                let px = image.pixels(width: w, height: h, &rng)
                let n = px.withUnsafeBytes { src in
                    dst.withUnsafeMutableBytes { d in
                        lossless
                            ? WebPTile.encodeLossless(src: src, width: w, height: h,
                                                      effort: efforts[(si + ii) % efforts.count], dst: d)
                            : WebPTile.encodeLossy(src: src, width: w, height: h, quality: 90, dst: d)
                    }
                }
                guard n > 0 else { continue } // not smaller than RAW: the host would send RAW
                out.append(Entry(width: w, height: h, image: image, pixels: px, payload: Array(dst.prefix(n))))
            }
        }
        return out
    }

    @Test func corpusRoundTripsAndLossyIsRefused() {
        let lossless = Self.corpus(lossless: true)
        #expect(lossless.count >= 40, "corpus too small: \(lossless.count)")
        #expect(Set(lossless.map(\.image)) == Set(FuzzImage.allCases))
        #expect(Set(lossless.map { "\($0.width)×\($0.height)" }).count == Self.sizes.count)
        for e in lossless {
            for fill: UInt8 in [0x00, 0xFF] {
                let r = GuardedDecode.run(e.payload, dstBytes: e.width * e.height * 4, fill: fill) {
                    WebPTile.decodeLossless(src: $0, width: e.width, height: e.height, dst: $1)
                }
                #expect(r.count == e.width * e.height * 4 && r.output == e.pixels && r.canariesIntact,
                        "\(e.image) \(e.width)×\(e.height)")
            }
        }
        // A lossy (VP8) payload would decode "successfully" to approximate
        // pixels; the lossless decode must refuse it (INV-1).
        for e in Self.corpus(lossless: false) {
            let r = GuardedDecode.run(e.payload, dstBytes: e.width * e.height * 4, fill: 0) {
                WebPTile.decodeLossless(src: $0, width: e.width, height: e.height, dst: $1)
            }
            #expect(r.count == 0 && r.canariesIntact)
        }
    }

    @Test func INV_6_mutatedLosslessTilesFailCleanlyOrDecodeWholeTiles() {
        let corpus = Self.corpus(lossless: true)
        let (decoded, rejected) = Self.fuzz(corpus, iterations: 10_000 * Self.scale, seed: 0xD1CE) {
            WebPTile.decodeLossless(src: $0, width: $1, height: $2, dst: $3)
        }
        // Both outcomes must be common, or the mutations aren't reaching
        // the entropy-coded body (all rejected) or aren't biting (all decoded).
        #expect(decoded > 500 * Self.scale && rejected > 5_000 * Self.scale, "decoded \(decoded), rejected \(rejected)")
    }

    /// `decodeBGRA` (the striped lossy first paint) takes VP8 as well as
    /// VP8L, so its corpus has both.
    @Test func INV_6_mutatedLossyTilesFailCleanlyOrDecodeWholeTiles() {
        let corpus = Self.corpus(lossless: false) + Self.corpus(lossless: true)
        let (decoded, rejected) = Self.fuzz(corpus, iterations: 5_000 * Self.scale, seed: 0x10557) {
            WebPTile.decodeBGRA(src: $0, width: $1, height: $2, dst: $3)
        }
        #expect(decoded > 250 * Self.scale && rejected > 2_500 * Self.scale, "decoded \(decoded), rejected \(rejected)")
    }

    /// Mutates, decodes under guard, and checks the contract; records an
    /// issue per violation. Returns (decoded, rejected) counts.
    static func fuzz(_ corpus: [Entry], iterations: Int, seed: UInt64,
                     _ decode: (UnsafeRawBufferPointer, Int, Int, UnsafeMutableRawBufferPointer) -> Int)
        -> (decoded: Int, rejected: Int) {
        var rng = SplitMix64(seed: seed)
        var decoded = 0, rejected = 0, violations = 0
        for iteration in 0..<iterations {
            let e = corpus[rng.int(0..<corpus.count)]
            let donor = corpus[rng.int(0..<corpus.count)].payload
            var kind = rng.int(0..<WebPMutator.kinds)
            var p = WebPMutator.mutate(e.payload, donor: donor, width: e.width, height: e.height, kind: kind, &rng)
            if rng.int(0..<4) == 0 { // stacked
                kind = kind * 100 + rng.int(0..<WebPMutator.kinds)
                p = WebPMutator.mutate(p, donor: donor, width: e.width, height: e.height, kind: kind % 100, &rng)
            }
            // The size the caller expects: usually the tile's own; sometimes
            // another tile size, or whatever the header now declares, so a
            // dimension lie gets past the size check. Huge declared sizes
            // keep a tile-sized destination: the decode must refuse it.
            var (w, h) = (e.width, e.height)
            var dstBytes = w * h * 4
            switch rng.int(0..<16) {
            case 0:
                (w, h) = sizes[rng.int(0..<sizes.count)]
                dstBytes = w * h * 4
            case 1, 2:
                if let d = WebPMutator.declaredDims(p), d.width >= 1, d.height >= 1 {
                    (w, h) = d
                    dstBytes = w * h <= 256 * 256 ? w * h * 4 : 64 * 64 * 4
                }
            case 3: // undersized destination
                dstBytes = rng.int(0..<dstBytes)
            default:
                break
            }
            let first = GuardedDecode.run(p, dstBytes: dstBytes, fill: 0xA5) { decode($0, w, h, $1) }
            var ok = first.canariesIntact && (first.count == 0 || (first.count == w * h * 4 && dstBytes >= first.count))
            if ok && first.count > 0 {
                // Every byte written, deterministically: a decode that
                // "succeeds" but leaves bytes alone would leak stale scratch
                // into the canvas.
                let second = GuardedDecode.run(p, dstBytes: dstBytes, fill: 0x5A) { decode($0, w, h, $1) }
                ok = second.canariesIntact && second.count == first.count && second.output == first.output
                decoded += 1
            } else if ok {
                rejected += 1
            }
            if !ok {
                violations += 1
                if violations <= 5 {
                    Issue.record("""
                        iteration \(iteration) mutation \(kind): \(e.image) \(e.width)×\(e.height) \
                        decoded as \(w)×\(h) into \(dstBytes) B → \(first.count) \
                        (canaries \(first.canariesIntact ? "intact" : "SMASHED"))
                        """)
                }
            }
        }
        #expect(violations == 0)
        return (decoded, rejected)
    }
}
