import AV1Core
import Foundation
import GlassActAV1
import GlassActTestSupport
import Metal
import Testing
import libaom

/// The analysis and partition DP on the GPU decide a legal partition of a
/// screen-like picture: av1core accepts it as a record (every block DC and
/// skipped) and libaom decodes that to av1core's reconstruction. And they
/// decide like an encoder: small blocks on dense text, large ones on flat UI.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil && glassact_aom_available() != 0,
                "needs a Metal device and libaom (arm64)"))
struct PartitionTests {
    struct Picture {
        let width: Int, height: Int
        var y: [UInt8], u: [UInt8], v: [UInt8]

        /// Flat background, a title bar, a block of dense glyph-like text in
        /// the top left, a noisy gradient along the bottom; a coloured bar, and
        /// chroma that follows luma in the gradient.
        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            y = [UInt8](repeating: 236, count: width * height)
            let cw = (width + 1) / 2, ch = (height + 1) / 2
            u = [UInt8](repeating: 128, count: cw * ch)
            v = [UInt8](repeating: 128, count: cw * ch)
            var rng = SplitMix64(seed: 11)
            for row in 0..<min(22, height) { for col in 0..<width { y[row * width + col] = 210 } }
            for row in 32..<min(160, height) {
                for col in 8..<min(260, width) where rng.int(0..<3) == 0 { y[row * width + col] = 30 }
            }
            for row in max(0, height - 60)..<height {
                for col in 0..<width { y[row * width + col] = UInt8(clamping: col / 4 + row / 3 + rng.int(0..<10)) }
            }
            // colour: a bar, and chroma that follows luma in the gradient (what CfL predicts)
            for row in (min(24, ch - 1))..<min(30, ch) { for col in 0..<min(120, cw) { u[row * cw + col] = 80; v[row * cw + col] = 190 } }
            for row in max(0, (height - 60) / 2)..<ch {
                for col in 0..<cw {
                    let l = Int(y[min(height - 1, 2 * row) * width + min(width - 1, 2 * col)])
                    u[row * cw + col] = UInt8(clamping: 128 + (l - 128) / 2)
                    v[row * cw + col] = UInt8(clamping: 128 - (l - 128) / 3)
                }
            }
        }
    }

    @available(macOS 27, *)
    @Test(arguments: [(333, 201), (1280, 720)])
    func partitionIsLegalAndSensible(width: Int, height: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder: AV1MetalEncoder
        do { encoder = try AV1MetalEncoder(device: device) } catch {
            Issue.record("\(error)")
            return
        }
        let picture = Picture(width: width, height: height)
        let partition = try picture.y.withUnsafeBufferPointer { y in
            try picture.u.withUnsafeBufferPointer { u in
                try picture.v.withUnsafeBufferPointer { v in
                    try encoder.partition(y: y.baseAddress!, u: u.baseAddress!, v: v.baseAddress!,
                                          width: width, height: height, qindex: 120)
                }
            }
        }
        var blocks = partition.blocks.map { b -> av1g_block in
            var b = b
            b.skip = 1
            return b
        }
        try #require(!blocks.isEmpty)

        // a legal record: av1core lays it out, encodes it, and libaom agrees
        var record = av1g_decision_record()
        record.fp.version = UInt32(AV1G_DECISIONS_VERSION)
        record.fp.width = UInt32(width)
        record.fp.height = UInt32(height)
        record.fp.base_q_idx = 120
        record.fp.tile_cols_log2 = -1
        record.fp.tile_rows_log2 = -1
        let n = blocks.count
        var blockTxb = [UInt32](repeating: 0, count: n + 1)
        var output = av1g_output()
        defer { av1g_output_free(&output) }
        let rc: Int32 = blocks.withUnsafeMutableBufferPointer { bp in
            blockTxb.withUnsafeMutableBufferPointer { btp in
                record.n_blocks = UInt32(n)
                record.blocks = bp.baseAddress
                record.block_txb = btp.baseAddress
                _ = av1g_layout(&record, 0, 0)
                var txb = [av1g_txb](repeating: av1g_txb(), count: Int(record.n_txb))
                var coeffs = [Int16](repeating: 0, count: Int(record.n_coeffs) + 1)
                return txb.withUnsafeMutableBufferPointer { tp in
                    coeffs.withUnsafeMutableBufferPointer { cp in
                        record.txb = tp.baseAddress
                        record.coeffs = cp.baseAddress
                        guard av1g_layout(&record, record.n_txb, record.n_coeffs) == AV1G_OK else { return -99 }
                        var err = [CChar](repeating: 0, count: 256)
                        let valid = av1g_validate(&record, &err, 256)
                        if valid != AV1G_OK {
                            let message = String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                            Issue.record("invalid record: \(message)")
                            return valid
                        }
                        var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_TD), seq_level_idx: -1)
                        return av1g_encode(&record, &options, &output)
                    }
                }
            }
        }
        try #require(rc == AV1G_OK, "encode \(rc)")
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var frame = glassact_aom_frame()
        try #require(glassact_aom_dec_decode(decoder, output.obu, output.obu_size, &frame) == 0)
        let ours = try #require(output.recon.0), theirs = try #require(frame.planes.0)
        let stride = Int(frame.strides.0)
        let differing = (0..<height).filter { memcmp(ours + $0 * width, theirs + $0 * stride, width) != 0 }.count
        #expect(differing == 0, "\(differing) luma rows differ")

        // sensible: blocks on the text are smaller than on the flat background
        func meanArea(_ inside: (Int, Int) -> Bool) -> Double {
            let sizes = blocks.filter { inside(Int($0.mi_col) * 4, Int($0.mi_row) * 4) }
                .map { b -> Int in
                    let sizes = [(4, 4), (4, 8), (8, 4), (8, 8), (8, 16), (16, 8), (16, 16), (16, 32), (32, 16), (32, 32),
                                 (32, 64), (64, 32), (64, 64), (0, 0), (0, 0), (0, 0), (4, 16), (16, 4), (8, 32), (32, 8),
                                 (16, 64), (64, 16)]
                    return sizes[Int(b.bsize)].0 * sizes[Int(b.bsize)].1
                }
            return sizes.isEmpty ? 0 : Double(sizes.reduce(0, +)) / Double(sizes.count)
        }
        let text = meanArea { x, y in x >= 16 && x < 240 && y >= 40 && y < 150 }
        let flat = meanArea { x, y in x >= 300 && y >= 40 && y < height - 80 }
        #expect(flat == 0 || text < flat, "mean block area: text \(text) px, flat \(flat) px")
    }
}
