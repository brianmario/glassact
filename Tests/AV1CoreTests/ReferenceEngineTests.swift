import AV1Core
import AV1CoreTestSupport
import Foundation
import GlassActTestSupport
import Testing
import libaom

/// av1gpu's CPU reference engine, end to end: a screen-like picture (flat UI,
/// glyph-like text, a photo-like gradient with noise) becomes a stream that
/// libaom decodes to exactly the engine's reconstruction, at a fine and a
/// coarse quantizer, with and without the post-filters and edge filter.
@Suite(.enabled(if: glassact_aom_available() != 0, "libaom is arm64 only"))
struct ReferenceEngineTests {
    /// An odd size, so the padding to 8 and the partial superblocks are coded.
    static let width = 333
    static let height = 201

    struct Picture {
        var y = [UInt8](repeating: 236, count: width * height)
        var u = [UInt8](repeating: 128, count: ((width + 1) / 2) * ((height + 1) / 2))
        var v = [UInt8](repeating: 128, count: ((width + 1) / 2) * ((height + 1) / 2))

        init() {
            var rng = SplitMix64(seed: 7)
            // A title bar, text lines, and a gradient "photo" with noise.
            for row in 0..<22 { for col in 0..<width { y[row * width + col] = 210 } }
            for line in 0..<8 {
                for col in 0..<30 {
                    for gy in 0..<9 { for gx in 0..<6 where rng.int(0..<3) == 0 {
                        let (py, px) = (30 + line * 14 + gy, 8 + col * 7 + gx)
                        if px < width { y[py * width + px] = 30 }
                    } }
                }
            }
            for row in 150..<height { for col in 0..<200 {
                y[row * width + col] = UInt8(clamping: col + row / 2 + rng.int(0..<12))
            } }
            let cw = (width + 1) / 2
            for row in 75..<100 { for col in 10..<100 { u[row * cw + col] = 90; v[row * cw + col] = 200 } }
        }
    }

    @Test(arguments: [(qindex: 40, filters: false), (40, true), (180, false), (180, true)])
    func encodesToADecodableReconstruction(qindex: Int32, filters: Bool) throws {
        let picture = Picture()
        // Blocks up to 32: the engine uses each block's largest transform,
        // and a 64-point one codes only the low 32×32 coefficients, which
        // can't hold text at any quantizer (46 dB → 20 dB on this picture).
        var options = av1t_ref_opts(qindex: qindex, min_block: 4, max_block: 32, lf_level: filters ? 12 : -1,
                                    cdef: filters ? 1 : 0, edge_filter: filters ? 1 : 0)
        var output = av1g_output()
        let rc = av1t_ref_encode(picture.y, picture.u, picture.v, UInt32(Self.width), UInt32(Self.height),
                                 &options, &output)
        defer { av1g_output_free(&output) }
        try #require(rc == AV1G_OK)

        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var frame = glassact_aom_frame()
        try #require(glassact_aom_dec_decode(decoder, output.obu, output.obu_size, &frame) == 0)
        #expect(frame.width == Int32(Self.width) && frame.height == Int32(Self.height))
        let sizes = [(Self.width, Self.height), ((Self.width + 1) / 2, (Self.height + 1) / 2),
                     ((Self.width + 1) / 2, (Self.height + 1) / 2)]
        let ours = [output.recon.0, output.recon.1, output.recon.2]
        for p in 0..<3 {
            let (w, h) = sizes[p]
            let mine = try #require(ours[p]), theirs = try #require(frame.planesTuple(p))
            let stride = Int(frame.stridesTuple(p))
            let rows = (0..<h).filter { memcmp(mine + $0 * w, theirs + $0 * stride, w) != 0 }
            #expect(rows.isEmpty, "q\(qindex) filters \(filters): plane \(p) differs on \(rows.count) rows")
        }
        // Not a quality bar, a sanity one: the fine quantizer reproduces the
        // text, the coarse one is still recognisably the picture.
        // (Measured: about 46 and 29 dB.)
        var sse = 0
        for i in 0..<(Self.width * Self.height) {
            let d = Int(picture.y[i]) - Int(ours[0]![i])
            sse += d * d
        }
        let psnr = 10 * log10(255.0 * 255.0 / max(1e-9, Double(sse) / Double(Self.width * Self.height)))
        #expect(psnr > (qindex < 100 ? 40 : 25), "q\(qindex): \(psnr) dB, \(output.obu_size) B")
    }
}
