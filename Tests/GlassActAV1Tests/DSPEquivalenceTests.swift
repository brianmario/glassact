import AV1CoreTestSupport
import Foundation
import GlassActAV1
import Metal
import Testing

/// av1core's shared DSP gives the same results on the GPU as on the CPU, from
/// the same source (av1gpu's gpu_dsp_test, ported): random cases of the
/// dequantizer and every inverse transform (19 sizes × 16 types, with the
/// conformance flags), intra prediction (every mode, angle delta, edge filter,
/// upsampling, filter intra), CfL, and the range coder with CDF adaptation.
/// The CPU side is what DecoderGateTests checks against libaom, so equal here
/// means the GPU computes what a decoder does.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct DSPEquivalenceTests {
    @available(macOS 27, *)
    @Test func gpuMatchesCPU() throws {
        guard let gpu = try MetalTestGPU.make(shader: "dsp_test.metal") else { return }
        let set = try #require(av1t_dsp_set_make(0))
        defer { av1t_dsp_set_free(set) }
        let s = set.pointee

        // 1. dequant + inverse transforms
        let itxCount = Int(s.itx_count)
        let residual = try gpu.buffer(Int32.self, count: itxCount * Int(s.itx_residual_per_case))
        let flags = try gpu.buffer(UInt32.self, count: itxCount)
        try gpu.run("dsp_itx", threads: itxCount, buffers: [
            gpu.copy(s.itx_cases, bytes: itxCount * Int(s.itx_case_size)),
            gpu.copy(s.itx_coeffs, bytes: itxCount * Int(s.itx_coeffs_per_case) * 2),
            residual, flags,
            gpu.buffer(Int32.self, count: itxCount * Int(s.itx_coeffs_per_case)),
        ], constants: [UInt32(itxCount)])
        var itxBad = 0
        for i in 0..<itxCount {
            let n = Int(s.itx_residual_per_case)
            if flags.contents().load(fromByteOffset: i * 4, as: UInt32.self) != s.itx_flags[i]
                || memcmp(residual.contents() + i * n * 4, s.itx_residual + i * n, n * 4) != 0 { itxBad += 1 }
        }
        let flagged = s.itx_flagged_count
        #expect(itxBad == 0, "inverse transforms: \(itxBad) of \(itxCount) cases differ (\(flagged) non-conformant)")

        // 2./3. prediction + CfL
        let predCount = Int(s.pred_count), side = Int(s.pred_side) * Int(s.pred_side)
        let predicted = try gpu.buffer(UInt8.self, count: predCount * side)
        try gpu.run("dsp_pred", threads: predCount, buffers: [
            gpu.copy(s.pred_cases, bytes: predCount * Int(s.pred_case_size)),
            gpu.copy(s.pred_planes, bytes: predCount * side),
            gpu.copy(s.pred_luma, bytes: Int(s.pred_luma_size)),
            predicted,
        ], constants: [UInt32(predCount)])
        let predBad = (0..<predCount).count {
            memcmp(predicted.contents() + $0 * side, s.pred_out + $0 * side, side) != 0
        }
        #expect(predBad == 0, "prediction: \(predBad) of \(predCount) cases differ (\(s.pred_cfl_count) CfL)")

        // 4. range coder
        let ecCount = Int(s.ec_count), capacity = Int(s.ec_capacity)
        let coded = try gpu.buffer(UInt8.self, count: ecCount * capacity)
        let sizes = try gpu.buffer(Int32.self, count: ecCount)
        try gpu.run("dsp_ec", threads: ecCount, buffers: [
            gpu.copy(s.ec_symbols, bytes: Int(s.ec_symbol_count) * Int(s.ec_symbol_size)),
            gpu.copy(s.ec_offsets, bytes: ecCount * 4),
            gpu.copy(s.ec_counts, bytes: ecCount * 4),
            gpu.buffer(UInt8.self, count: ecCount * Int(s.ec_cdfs_size)),
            gpu.buffer(UInt16.self, count: ecCount * capacity),
            coded, sizes,
        ], constants: [UInt32(capacity), UInt32(ecCount), UInt32(bitPattern: s.ec_qindex)])
        let ecBad = (0..<ecCount).count { i in
            let n = Int(sizes.contents().load(fromByteOffset: i * 4, as: Int32.self))
            return n != Int(s.ec_sizes[i]) || memcmp(coded.contents() + i * capacity, s.ec_bytes + i * capacity, n) != 0
        }
        #expect(ecBad == 0, "range coder: \(ecBad) of \(ecCount) streams differ")
    }
}
