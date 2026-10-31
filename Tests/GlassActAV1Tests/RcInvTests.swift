import AV1CoreTestSupport
import Foundation
import Metal
import Testing

/// The closed loop's register-resident inverse transforms (av1gpu's
/// rc_inv.cuh, in Metal) give av1core's residual for every conformant tx
/// block of the DSP cases, and flag every non-conformant one. 128 threads per
/// block take rows, then columns, as the closed loop runs them.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct RcInvTests {
    @available(macOS 27, *)
    @Test func matchesAV1Core() throws {
        guard let gpu = try MetalTestGPU.make(shader: "rc_inv_test.metal") else { return }
        let set = try #require(av1t_dsp_set_make(0))
        defer { av1t_dsp_set_free(set) }
        let s = set.pointee
        let count = Int(s.itx_count), per = Int(s.itx_residual_per_case)
        let residual = try gpu.buffer(Int16.self, count: count * per)
        let flags = try gpu.buffer(UInt32.self, count: count)
        try gpu.run("rc_inv_itx", groups: count, groupSize: 128, buffers: [
            gpu.copy(s.itx_cases, bytes: count * Int(s.itx_case_size)),
            gpu.copy(s.itx_coeffs, bytes: count * Int(s.itx_coeffs_per_case) * 2),
            residual, flags,
        ], constants: [])
        var wrong = 0, missedFlag = 0, extraFlag = 0, conformant = 0
        for i in 0..<count {
            let gpuFlag = flags.contents().load(fromByteOffset: i * 4, as: UInt32.self)
            if s.itx_flags[i] != 0 {
                if gpuFlag == 0 { missedFlag += 1 }
                continue
            }
            conformant += 1
            if gpuFlag != 0 { extraFlag += 1; continue }
            for k in 0..<per where Int32(residual.contents().load(fromByteOffset: (i * per + k) * 2, as: Int16.self))
                != s.itx_residual[i * per + k] {
                wrong += 1
                break
            }
        }
        #expect(wrong == 0 && missedFlag == 0 && extraFlag == 0,
                "\(conformant) conformant: \(wrong) residuals differ, \(extraFlag) flagged; \(missedFlag) non-conformant missed")
    }
}
