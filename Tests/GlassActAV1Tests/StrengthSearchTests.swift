import AV1Core
import AV1Encoder
import Foundation
import GlassActAV1
import Metal
import Testing
import libaom

/// The deblocking-level and CDEF-strength search on the Metal encoder's
/// pictures, at a q where tune=iq turns CDEF off, halves its strengths, and
/// keeps them whole:
/// - its per-64×64 SSE of every candidate strength is what av1core's own CDEF
///   gives (relative to no CDEF, which leaves the inactive blocks alike);
/// - its preset search chooses what the sequential reference chooses;
/// - the picture coded with its choices decodes in libaom to exactly the
///   picture it filtered.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil && glassact_aom_available() != 0,
                "needs a Metal device and libaom (arm64)"))
struct StrengthSearchTests {
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(333, 201, 24), (333, 201, 120), (1280, 720, 120), (333, 201, 240)])
    func searchIsLibaomsAndDecodes(width: Int, height: Int, qindex: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1MetalEncoder(device: device)
        let postfilter = try AV1MetalPostfilter(device: device)
        let picture = PartitionTests.Picture(width: width, height: height)
        var encoded = try picture.y.withUnsafeBufferPointer { y in
            try picture.u.withUnsafeBufferPointer { u in
                try picture.v.withUnsafeBufferPointer { v in
                    try encoder.encode(y: y.baseAddress!, u: u.baseAddress!, v: v.baseAddress!,
                                       width: width, height: height, qindex: qindex)
                }
            }
        }
        let label = "\(width)×\(height) q\(qindex)"
        let miCols = 2 * ((width + 7) >> 3), miRows = 2 * ((height + 7) >> 3), sbCols = (miCols + 15) >> 4
        let pw = [miCols * 4, miCols * 2, miCols * 2], ph = [miRows * 4, miRows * 2, miRows * 2]

        // the reconstruction before the filters, and the source, at the filters' sizes
        var before = av1g_output()
        defer { av1g_output_free(&before) }
        try encoded.withRecord { record in
            var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_PREFILTER_RECON), seq_level_idx: -1)
            try #require(av1g_encode(&record, &options, &before) == AV1G_OK, "\(label)")
        }
        let unfiltered = (0..<3).map { p in
            Array(UnsafeBufferPointer(start: [before.recon.0, before.recon.1, before.recon.2][p]!, count: pw[p] * ph[p]))
        }
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        let src = [(picture.y, width, height), (picture.u, cw, ch), (picture.v, cw, ch)]
        let source = (0..<3).map { p -> [UInt8] in
            let (plane, w, h) = src[p]
            var out = [UInt8](repeating: 0, count: pw[p] * ph[p])
            for y in 0..<ph[p] { for x in 0..<pw[p] { out[y * pw[p] + x] = plane[min(y, h - 1) * w + min(x, w - 1)] } }
            return out
        }

        let search = try encoded.withRecord { record in
            try withPlanes(unfiltered) { planes in
                try withPlanes(source) { sources in
                    try postfilter.search(params: record.fp, blocks: UnsafeBufferPointer(start: record.blocks, count: Int(record.n_blocks)),
                                          planes: planes, source: sources)
                }
            }
        }
        let fp = search.params

        if !search.lumaSSE.isEmpty {
            // 1. the SSE tables are av1core's CDEF
            let nsb = search.superblockCDEF.count, nc = search.lumaSSE.count / nsb
            let pri = [0, 11], sec = [0, 2]
            func cpuSSE(_ c: Int) throws -> (luma: [Int], chroma: [Int]) {
                var p = fp
                p.cdef_bits = 0
                p.cdef_y_pri.0 = UInt8(pri[c / 2]); p.cdef_y_sec.0 = UInt8(sec[c % 2])
                p.cdef_uv_pri.0 = UInt8(pri[c / 2]); p.cdef_uv_sec.0 = UInt8(sec[c % 2])
                var py = unfiltered[0], pu = unfiltered[1], pv = unfiltered[2]
                var record = av1g_decision_record()
                var blocks = encoded.blocks.map { b -> av1g_block in var b = b; b.cdef_idx = 0; return b }
                record.fp = p
                record.n_blocks = UInt32(blocks.count)
                let rc = blocks.withUnsafeMutableBufferPointer { bp -> Int32 in
                    record.blocks = bp.baseAddress
                    return py.withUnsafeMutableBufferPointer { y in
                        pu.withUnsafeMutableBufferPointer { u in
                            pv.withUnsafeMutableBufferPointer { v in
                                let ptrs: [UnsafeMutablePointer<UInt8>?] = [y.baseAddress, u.baseAddress, v.baseAddress]
                                let strides = pw.map { Int32($0) }
                                return ptrs.withUnsafeBufferPointer { av1g_postfilter(&record, $0.baseAddress, strides) }
                            }
                        }
                    }
                }
                let planes = [py, pu, pv]
                try #require(rc == AV1G_OK)
                var luma = [Int](repeating: 0, count: nsb), chroma = [Int](repeating: 0, count: nsb)
                for p in 0..<3 {
                    let sub = p == 0 ? 0 : 1
                    for y in 0..<ph[p] {
                        for x in 0..<pw[p] {
                            let d = Int(planes[p][y * pw[p] + x]) - Int(source[p][y * pw[p] + x])
                            let sb = ((y << sub) >> 6) * sbCols + ((x << sub) >> 6)
                            if p == 0 { luma[sb] += d * d } else { chroma[sb] += d * d }
                        }
                    }
                }
                return (luma, chroma)
            }
            let base = try cpuSSE(0)
            for c in 1..<nc {
                let cpu = try cpuSSE(c)
                for sb in 0..<nsb where search.superblockCDEF[sb] >= 0 {
                    let gpuY = Int(search.lumaSSE[sb * nc + c]) - Int(search.lumaSSE[sb * nc])
                    let gpuUV = Int(search.chromaSSE[sb * nc + c]) - Int(search.chromaSSE[sb * nc])
                    #expect(gpuY == cpu.luma[sb] - base.luma[sb] && gpuUV == cpu.chroma[sb] - base.chroma[sb],
                            "\(label): SB \(sb) candidate \(c): GPU ΔSSE \(gpuY)/\(gpuUV), av1core \(cpu.luma[sb] - base.luma[sb])/\(cpu.chroma[sb] - base.chroma[sb])")
                }
            }

            // 2. the preset search is the reference's
            let bits = search.presets.count
            var lev = [Int32](repeating: 0, count: 16 * bits), tot = [UInt64](repeating: 0, count: bits)
            av1enc_cdef_select_cpu(search.lumaSSE, search.chromaSSE, Int32(nc), Int32(nsb), 0, Int32(bits - 1), 4, 0, &lev, &tot)
            #expect(tot == search.presetSSE, "\(label): preset SSE GPU \(search.presetSSE), CPU \(tot)")
            #expect(lev == search.presets.flatMap { $0 }, "\(label): presets differ")
        }

        // 3. coded with the choices, the stream decodes to the filtered picture
        for i in encoded.blocks.indices {
            let b = encoded.blocks[i]
            encoded.blocks[i].cdef_idx = max(0, search.superblockCDEF[(Int(b.mi_row) >> 4) * sbCols + (Int(b.mi_col) >> 4)])
        }
        encoded.params = fp
        var output = av1g_output()
        defer { av1g_output_free(&output) }
        try encoded.withRecord { record in
            var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_TD), seq_level_idx: -1)
            try #require(av1g_encode(&record, &options, &output) == AV1G_OK, "\(label)")
        }
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var frame = glassact_aom_frame()
        try #require(glassact_aom_dec_decode(decoder, output.obu, output.obu_size, &frame) == 0, "\(label): libaom")
        let sizes = [(width, height), (cw, ch), (cw, ch)]
        for p in 0..<3 {
            let (w, h) = sizes[p]
            let theirs = try #require(frame.planesTuple(p))
            let stride = Int(frame.stridesTuple(p))
            let rows = (0..<h).filter { r in (0..<w).contains { search.planes[p][r * w + $0] != theirs[r * stride + $0] } }
            #expect(rows.isEmpty, "\(label): plane \(p) differs from libaom on \(rows.count) rows")
        }
        let before0 = psnr(encoded.reconstruction[0], picture.y), after0 = psnr(search.planes[0], picture.y)
        // and filtering helps, or at least doesn't hurt (libaom's level from q isn't an SSE optimum)
        #expect(after0 > before0 - 0.1, "\(label): \(before0) dB before the filters, \(after0) after")
    }

    func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let sse = zip(a, b).reduce(0) { $0 + (Int($1.0) - Int($1.1)) * (Int($1.0) - Int($1.1)) }
        return 10 * log10(255.0 * 255.0 * Double(a.count) / max(1, Double(sse)))
    }

    func withPlanes<R>(_ planes: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) throws -> R) rethrows -> R {
        try planes[0].withUnsafeBufferPointer { y in
            try planes[1].withUnsafeBufferPointer { u in
                try planes[2].withUnsafeBufferPointer { v in try body([y.baseAddress!, u.baseAddress!, v.baseAddress!]) }
            }
        }
    }
}
