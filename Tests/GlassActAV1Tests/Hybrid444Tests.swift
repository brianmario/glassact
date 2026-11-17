import AV1Core
import Foundation
import GlassActAV1
import GlassActTestSupport
import Metal
import Testing
import libaom

/// The hybrid encoder's 4:4:4 key frames (`Picture.chroma444`, the High profile): every one
/// decodes in libaom to exactly the picture the encoder reports, at sizes down to a few samples,
/// with intra block copy on (and copying) and off; a stream with inter frames refuses them; and a
/// 4:4:4 picture leaves nothing behind that changes the 4:2:0 pictures coded after it.
@Suite(.enabled(if: AV1ShaderSource.hasCapableGPU && glassact_aom_available() != 0,
                "needs an Apple-silicon GPU (not a VM's paravirtual one) and libaom (arm64)"))
struct Hybrid444Tests {
    /// Screen-like 4:4:4 content whose chroma has detail 4:2:0 can't hold: a title bar, coloured
    /// glyphs (each its own colour, sample by sample), one-sample colour stripes, and a gradient
    /// whose chroma follows luma; with `repeats`, the block of glyphs repeated down the picture
    /// (what intra block copy copies).
    @available(macOS 27, *)
    static func picture(width: Int, height: Int, seed: UInt64, repeats: Bool = false) -> AV1HybridEncoder.Picture {
        var rng = SplitMix64(seed: seed)
        let n = width * height
        var y = [UInt8](repeating: 236, count: n), u = [UInt8](repeating: 128, count: n), v = u
        for r in 0..<min(12, height) { for c in 0..<width { (y[r * width + c], u[r * width + c], v[r * width + c]) = (210, 120, 134) } }
        let (bw, bh) = (min(width, 200), min(height, 48))
        let (gy, gx) = (min(12, height - 1), 0)
        for r in gy..<min(height, gy + bh) {
            for c in gx..<min(width, gx + bw) where rng.int(0..<3) == 0 {
                let k = r * width + c
                (y[k], u[k], v[k]) = (UInt8(rng.int(20..<90)), UInt8(rng.int(40..<216)), UInt8(rng.int(40..<216)))
            }
        }
        if repeats {
            for k in 0..<8 {
                let (dx, dy) = (8 + (k % 2) * 300 + k % 3, 80 + k * 76 + k % 2)
                guard dx + bw <= width, dy + bh <= height else { continue }
                for r in 0..<bh {
                    for c in 0..<bw {
                        let (to, from) = ((dy + r) * width + dx + c, (gy + r) * width + gx + c)
                        (y[to], u[to], v[to]) = (y[from], u[from], v[from])
                    }
                }
            }
        }
        // one-sample colour stripes on the right
        for r in 0..<height { for c in (width * 3 / 4)..<width { u[r * width + c] = c % 2 == 0 ? 70 : 190; v[r * width + c] = r % 2 == 0 ? 60 : 200 } }
        // a noisy gradient along the bottom, chroma following luma (what CfL predicts)
        for r in (height - min(40, height / 3))..<height {
            for c in 0..<width {
                let k = r * width + c, l = c / 4 + r / 3 + rng.int(0..<10)
                y[k] = UInt8(clamping: l)
                u[k] = UInt8(clamping: 128 + (l - 128) / 2)
                v[k] = UInt8(clamping: 128 - (l - 128) / 3)
            }
        }
        return AV1HybridEncoder.Picture(y: y, u: u, v: v, width: width, height: height, chroma444: true)
    }

    /// libaom's decode of a still picture, planes cropped (a 4:4:4 stream's chroma is full size).
    @available(macOS 27, *)
    static func decoded(_ frame: AV1HybridEncoder.Frame, width: Int, height: Int) throws -> [[UInt8]] {
        var parsed: UnsafeMutablePointer<av1g_parsed>?
        try #require(av1g_parse(frame.obu, frame.obu.count, &parsed) == AV1G_OK)
        let p = try #require(parsed)
        let format = p.pointee.rec.fp.chroma_format
        av1g_parsed_free(p)
        let full = format == UInt8(AV1G_CHROMA_444)
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var f = glassact_aom_frame()
        try #require(glassact_aom_dec_decode(decoder, frame.obu, frame.obu.count, &f) == 0, "libaom rejected the frame")
        try #require(Int(f.width) == width && Int(f.height) == height)
        return try (0..<3).map { k in
            let (w, h) = k == 0 || full ? (width, height) : ((width + 1) / 2, (height + 1) / 2)
            let src = try #require(f.planesTuple(k))
            let stride = Int(f.stridesTuple(k))
            try #require(stride >= w)
            return (0..<h).flatMap { r in (0..<w).map { src[r * stride + $0] } }
        }
    }

    @available(macOS 27, *)
    @Test(.serialized, arguments: [(1280, 720, true, 80, 1), (1280, 720, false, 80, 1), (333, 201, true, 40, -1), (333, 201, false, 120, -1),
                                   (64, 64, true, 32, 0), (64, 64, false, 8, 0), (33, 17, true, 80, 0), (33, 17, false, 20, 0),
                                   (7, 5, false, 60, 0)])
    func keyFramesDecodeToTheirPictures(width: Int, height: Int, intraBlockCopy: Bool, qindex: Int, tilesLog2: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (tilesLog2, tilesLog2 > 0 ? 0 : tilesLog2)
        encoder.intraBlockCopy = intraBlockCopy
        let label = "\(width)×\(height) q\(qindex) intra block copy \(intraBlockCopy)"
        let pictures = (0..<2).map { i in Self.picture(width: width, height: height, seed: 0x444 + UInt64(i), repeats: width >= 1280) }
        var copied = 0
        for (i, picture) in pictures.enumerated() {
            let frame = try encoder.encode(picture, qindex: qindex)
            #expect(frame.params.chroma_format == UInt8(AV1G_CHROMA_444), "\(label): picture \(i) isn't 4:4:4")
            #expect(frame.params.loop_filter_level == (0, 0, 0, 0) && frame.params.enable_cdef == 0, "\(label): picture \(i) filters")
            #expect(frame.planes.map(\.count) == [Int](repeating: width * height, count: 3), "\(label): picture \(i)'s planes")
            if frame.timing.intraCopied > 0 {
                copied += 1
                #expect(frame.params.allow_intrabc == 1, "\(label): picture \(i)")
            }
            let theirs = try Self.decoded(frame, width: width, height: height)
            for p in 0..<3 {
                let rows = (0..<height).filter { r in (0..<width).contains { frame.planes[p][r * width + $0] != theirs[p][r * width + $0] } }
                #expect(rows.isEmpty, "\(label): picture \(i) plane \(p) differs from libaom on \(rows.count) rows")
            }
            // (lossy, but near: the chroma's detail kept)
            var sse = 0
            for k in 0..<(width * height) { let d = Int(frame.planes[1][k]) - Int(picture.u[k]); sse += d * d }
            #expect(Double(sse) / Double(width * height) < 400, "\(label): picture \(i)'s U is far from its source")
        }
        if intraBlockCopy && width >= 1280 { #expect(copied == pictures.count, "\(label): \(copied) pictures copied") }
        if !intraBlockCopy { #expect(copied == 0, "\(label)") }
        // (4:4:4 pictures code palettes, luma and chroma, by default: these decoded with them)
        let stats = encoder.paletteStats
        if width >= 333 { #expect(stats.count > 11 && stats[3] > 0 && stats[11] > 0, "\(label): palettes \(stats)") }
    }

    /// A stream with inter frames refuses a 4:4:4 picture (its inter frames would be 4:2:0's), with
    /// an error rather than a 4:2:0 frame, and the encoder codes the next stream as a fresh one would.
    @available(macOS 27, *)
    @Test func interFramesRefuse444() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (width, height) = (640, 384)
        func make() throws -> AV1HybridEncoder {
            let e = try AV1HybridEncoder(device: device)
            e.tiling = (1, 0)
            e.interFrames = true
            return e
        }
        let encoder = try make()
        #expect(throws: AV1HybridEncoder.Failure.self) {
            _ = try encoder.encode(Self.picture(width: width, height: height, seed: 1), qindex: 80)
        }
        let base = PartitionTests.Picture(width: width, height: height)
        let pictures = (0..<3).map { i -> AV1HybridEncoder.Picture in
            var y = base.y
            for k in stride(from: i * 5, to: y.count, by: 641) { y[k] = UInt8(truncatingIfNeeded: k) }
            return AV1HybridEncoder.Picture(y: y, u: base.u, v: base.v, width: width, height: height)
        }
        var after: [[UInt8]] = [], fresh: [[UInt8]] = []
        try encoder.encode(count: pictures.count, qindex: 80, picture: { pictures[$0] }, output: { _, f in after.append(f.obu) })
        try make().encode(count: pictures.count, qindex: 80, picture: { pictures[$0] }, output: { _, f in fresh.append(f.obu) })
        #expect(after.count == 3 && after == fresh, "a stream after the refused picture codes differently")
    }

    /// 4:2:0, then 4:4:4, then 4:2:0 again on one encoder (analysis and tiles kept, the filters'
    /// state): the 4:2:0 pictures code as on a fresh encoder, byte for byte, and as alone.
    @available(macOS 27, *)
    @Test(arguments: [true, false])
    func a444PictureLeaves420Unchanged(intraBlockCopy: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (width, height) = (1280, 720)
        func make() throws -> AV1HybridEncoder {
            let e = try AV1HybridEncoder(device: device)
            e.tiling = (1, 1)
            e.intraBlockCopy = intraBlockCopy
            return e
        }
        let base = PartitionTests.Picture(width: width, height: height)
        let p420 = AV1HybridEncoder.Picture(y: base.y, u: base.u, v: base.v, width: width, height: height)
        let p444 = Self.picture(width: width, height: height, seed: 9)
        let encoder = try make()
        let first = try encoder.encode(p420, qindex: 100)
        let mid = try encoder.encode(p444, qindex: 100)
        #expect(mid.params.chroma_format == UInt8(AV1G_CHROMA_444))
        let again = try encoder.encode(p420, qindex: 100)
        let fresh = try make().encode(p420, qindex: 100)
        #expect(first.obu == fresh.obu && again.obu == fresh.obu, "a 4:4:4 picture changed the 4:2:0 picture after it")
        #expect(again.planes == fresh.planes && again.params.chroma_format == UInt8(AV1G_CHROMA_420))
        // and the 4:4:4 picture codes as on a fresh encoder
        #expect(try make().encode(p444, qindex: 100).obu == mid.obu, "the 4:4:4 picture codes differently after a 4:2:0 one")
    }
}
