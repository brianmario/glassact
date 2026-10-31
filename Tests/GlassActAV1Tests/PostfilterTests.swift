import AV1Core
import AV1CoreTestSupport
import Foundation
import GlassActAV1
import Metal
import Testing

/// The GPU post-filters against av1core's, which the decoder gate holds to
/// libaom: on every random legal record (deblocking levels and sharpness,
/// CDEF presets, skip and tx-size maps, frame edges), deblocking and CDEF of
/// the reconstruction before them give av1core's filtered picture exactly.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct PostfilterTests {
    @available(macOS 27, *)
    @Test(arguments: 0..<4)
    func filtersMatchAV1Core(chunk: UInt64) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let postfilter = try AV1MetalPostfilter(device: device)
        let perChunk: UInt64 = 50
        var filtered = 0
        for seed in (1 + chunk * perChunk)...((chunk + 1) * perChunk) {
            let fuzzCase = try #require(av1t_case_make(seed, 300, 2), "seed \(seed): no record")
            defer { av1t_case_free(fuzzCase) }
            let record = try #require(av1t_case_record(fuzzCase))
            let fp = record.pointee.fp
            // before the filters (this also repairs the coefficients the second encode codes)
            var before = av1g_output(), after = av1g_output()
            defer { av1g_output_free(&before); av1g_output_free(&after) }
            var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_FIX_RANGE) | UInt32(AV1G_ENC_PREFILTER_RECON), seq_level_idx: -1)
            try #require(av1g_encode(record, &options, &before) == AV1G_OK, "seed \(seed)")
            options.flags = UInt32(AV1G_ENC_FIX_RANGE)
            try #require(av1g_encode(record, &options, &after) == AV1G_OK, "seed \(seed)")
            let nPlanes = fp.monochrome != 0 ? 1 : 3
            let source = [before.recon.0, before.recon.1, before.recon.2].prefix(nPlanes).map { UnsafePointer($0!) }
            let gpu = try postfilter.filter(params: fp, blocks: UnsafeBufferPointer(start: record.pointee.blocks,
                                                                                   count: Int(record.pointee.n_blocks)),
                                            planes: source)
            if fp.loop_filter_level.0 != 0 || fp.loop_filter_level.1 != 0 || fp.enable_cdef != 0 { filtered += 1 }
            let cpu = [after.recon.0, after.recon.1, after.recon.2]
            for p in 0..<nPlanes {
                let ours = try #require(cpu[p])
                let n = gpu[p].count
                if let i = (0..<n).first(where: { gpu[p][$0] != ours[$0] }) {
                    Issue.record("seed \(seed) \(fp.width)×\(fp.height): plane \(p) differs first at sample \(i): GPU \(gpu[p][i]), av1core \(ours[i])")
                    break
                }
            }
        }
        #expect(filtered > perChunk / 4, "only \(filtered) of \(perChunk) records were filtered")
    }

    /// The same on random inter sequences (the frames av1core's inter decoder gate checks), with
    /// lf_inter_off's inter blocks at level 0: each frame is coded from the filtered pictures
    /// before it.
    @available(macOS 27, *)
    @Test(arguments: 0..<4)
    func interFiltersMatchAV1Core(chunk: UInt64) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let postfilter = try AV1MetalPostfilter(device: device)
        let perChunk: UInt64 = 12
        var lfOff = 0
        for seed in (1 + chunk * perChunk)...((chunk + 1) * perChunk) {
            let sequence = try #require(av1t_inter_case_make(seed, 240, 6), "seed \(seed): no sequence")
            defer { av1t_inter_case_free(sequence) }
            var outputs: [av1g_output] = []
            defer { for i in outputs.indices { av1g_output_free(&outputs[i]) } }
            var slots = [Int](repeating: -1, count: 8)
            for k in 0..<Int(av1t_inter_case_frames(sequence)) {
                let record = try #require(av1t_inter_case_record(sequence, Int32(k)))
                let fp = record.pointee.fp
                var refs = [av1g_ref_planes](repeating: av1g_ref_planes(), count: 8)
                for (s, f) in slots.enumerated() where f >= 0 {
                    let o = outputs[f]
                    refs[s].plane = (UnsafePointer(o.recon.0), UnsafePointer(o.recon.1), UnsafePointer(o.recon.2))
                    refs[s].stride = (Int32(o.recon_w.0), Int32(o.recon_w.1), Int32(o.recon_w.2))
                    refs[s].cdfs = UnsafeRawPointer(o.cdfs)
                }
                var before = av1g_output(), after = av1g_output()
                defer { av1g_output_free(&before) }
                var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_FIX_RANGE) | UInt32(AV1G_ENC_PREFILTER_RECON), seq_level_idx: -1)
                try #require(av1g_encode_ex(record, &options, refs, &before) == AV1G_OK, "seed \(seed) frame \(k)")
                options.flags = UInt32(AV1G_ENC_FIX_RANGE)
                let rc = av1g_encode_ex(record, &options, refs, &after)
                outputs.append(after)
                try #require(rc == AV1G_OK, "seed \(seed) frame \(k)")
                let n = Int(record.pointee.n_blocks)
                var lfZero: [UInt8]?
                if fp.lf_inter_off != 0, let inter = record.pointee.inter {
                    lfZero = (0..<n).map { inter[$0].is_inter }
                    lfOff += 1
                }
                let nPlanes = fp.monochrome != 0 ? 1 : 3
                let source = [before.recon.0, before.recon.1, before.recon.2].prefix(nPlanes).map { UnsafePointer($0!) }
                let gpu = try postfilter.filter(params: fp, blocks: UnsafeBufferPointer(start: record.pointee.blocks, count: n),
                                                planes: source, lfZero: lfZero)
                let cpu = [after.recon.0, after.recon.1, after.recon.2]
                for p in 0..<nPlanes {
                    let ours = try #require(cpu[p])
                    if let i = (0..<gpu[p].count).first(where: { gpu[p][$0] != ours[$0] }) {
                        Issue.record("seed \(seed) frame \(k) \(fp.width)×\(fp.height): plane \(p) differs first at sample \(i): GPU \(gpu[p][i]), av1core \(ours[i])")
                        return
                    }
                }
                let refresh = fp.frame_type == AV1G_FRAME_KEY ? 0xFF : Int(fp.refresh_frame_flags)
                for s in 0..<8 where refresh >> s & 1 != 0 { slots[s] = k }
            }
        }
        #expect(lfOff > 0, "no frame had lf_inter_off")
    }
}
