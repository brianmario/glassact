import AV1Encoder
import GlassActTestSupport
import GlassActAV1
import Metal
import Testing

/// The GPU's CDEF preset search (l_select) is the sequential reference's
/// (av1enc_cdef_select_cpu) on random SSE tables: every size of picture from
/// one 64×64 to more than a thread each, monochrome, ties, and the largest
/// SSE a 64×64 can have.
@Suite(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (not a VM's paravirtual one)"))
struct PresetSearchTests {
    @available(macOS 27, *)
    @Test(arguments: [(1, 1), (3, 2), (20, 12), (31, 1), (33, 17), (80, 45), (96, 54)])
    func gpuSearchIsTheReferences(sbCols: Int, sbRows: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let postfilter = try AV1MetalPostfilter(device: device)
        var rng = SplitMix64(seed: UInt64(sbCols * 1000 + sbRows))
        let nsb = sbCols * sbRows
        for trial in 0..<6 {
            let mono = trial == 5
            // trial 0: few distinct values (ties everywhere); 4: the largest a 64×64 has
            let top: UInt32 = trial == 0 ? 3 : trial == 4 ? 4096 * 255 * 255 : 1 << UInt32(8 + 4 * trial)
            let luma = (0..<4 * nsb).map { _ in UInt32.random(in: 0...top, using: &rng) }
            let chroma = mono ? [UInt32](repeating: 0, count: 4 * nsb)
                : (0..<4 * nsb).map { _ in UInt32.random(in: 0...top / 2, using: &rng) }
            let gpu = try postfilter.presetSearch(lumaSSE: luma, chromaSSE: chroma, sbCols: sbCols, mono: mono)
            let bits = AV1MetalPostfilter.maxCDEFBits + 1
            var lev = [Int32](repeating: 0, count: 16 * bits), tot = [UInt64](repeating: 0, count: bits)
            av1enc_cdef_select_cpu(luma, chroma, 4, Int32(nsb), mono ? 1 : 0, Int32(bits - 1),
                                   Int32(AV1MetalPostfilter.refinements), mono ? 1 : 0, &lev, &tot)
            let label = "\(sbCols)×\(sbRows) trial \(trial)"
            #expect(gpu.totals == tot, "\(label): totals GPU \(gpu.totals), CPU \(tot)")
            #expect(gpu.presets.flatMap { $0 } == lev, "\(label): presets differ")
        }
    }
}
