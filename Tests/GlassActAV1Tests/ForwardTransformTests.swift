import AV1CoreTestSupport
import Foundation
import GlassActTestSupport
import Metal
import Testing

/// The encoder's float forward transform on the GPU (av1gpu's dev_tx, with
/// its matrices derived from av1core's exact inverses by AV1Encoder) undoes
/// the decoder's inverse: av1core's inverse of the rounded coefficients gives
/// back the residual within rounding, for every tx size up to 32 points and
/// every intra tx type.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct ForwardTransformTests {
    @available(macOS 27, *)
    @Test func inverseUndoesIt() throws {
        guard let gpu = try MetalTestGPU.make(shader: "fwd_test.metal") else { return }
        var cases: [Int32] = []
        for txSz: Int32 in 0..<19 {
            for txType: Int32 in 0..<16 where av1t_tx_type_allowed(txSz, txType) != 0 {
                cases += [txSz, txType]
            }
        }
        let count = cases.count / 2
        var rng = SplitMix64(seed: 3)
        var residual = [Int16](repeating: 0, count: count * 4096)
        for i in 0..<residual.count { residual[i] = Int16(rng.int(-60..<61)) }
        let coeffs = try gpu.buffer(Float.self, count: count * 1024)
        try gpu.run("fwd_tx", groups: count, groupSize: 32, buffers: [
            gpu.copy(cases, bytes: cases.count * 4),
            gpu.copy(residual, bytes: residual.count * 2),
            coeffs,
        ], constants: [])
        var worst = 0, worstCase = ""
        for c in 0..<count {
            let txSz = cases[2 * c], txType = cases[2 * c + 1]
            let (w, h) = Self.size(txSz)
            if w == 64 || h == 64 { continue }  // 64-point: only the low 32 coefficients are coded
            var dq = [Int32](repeating: 0, count: 1024)
            for p in 0..<(w * h) {
                dq[p] = Int32(coeffs.contents().load(fromByteOffset: (c * 1024 + p) * 4, as: Float.self).rounded())
            }
            var back = [Int32](repeating: 0, count: 4096)
            _ = av1t_inverse_transform(txSz, txType, dq, &back)
            for p in 0..<(w * h) {
                let e = abs(Int(back[p]) - Int(residual[c * 4096 + p]))
                if e > worst { worst = e; worstCase = "tx size \(txSz) type \(txType)" }
            }
        }
        // Rounding the coefficients to integers costs at most a couple of levels.
        #expect(worst <= 2, "worst error \(worst) at \(worstCase)")
    }

    static func size(_ txSz: Int32) -> (Int, Int) {
        let w = [4, 8, 16, 32, 64, 4, 8, 8, 16, 16, 32, 32, 64, 4, 16, 8, 32, 16, 64]
        let h = [4, 8, 16, 32, 64, 8, 4, 16, 8, 32, 16, 64, 32, 16, 4, 32, 8, 64, 16]
        return (w[Int(txSz)], h[Int(txSz)])
    }
}
