import AV1Core
import AV1Encoder
import Foundation
import GlassActAV1
import Metal
import Testing

/// The structures the host fills and the kernels read (gp.h) have one layout:
/// Swift's import of the C header and the Metal compiler agree on every size
/// and on the offsets of fields after each change of type.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct EncoderLayoutTests {
    @available(macOS 27, *)
    @Test func hostAndKernelsAgree() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let main = AV1ShaderSource.sourceRootForTests.appending(path: "GlassActAV1/Shaders/encoder.metal")
        let library = try AV1ShaderSource.library(main, device: device)
        let gpu = try MetalTestGPU(device: device, library: library)
        let out = try gpu.buffer(UInt32.self, count: 64)
        try gpu.run("ga_layout", threads: 1, buffers: [out], constants: [])
        let host: [Int] = [
            MemoryLayout<GpParams>.size, MemoryLayout<GpParams>.offset(of: \.satdLambda)!,
            MemoryLayout<GpParams>.offset(of: \.K)!, MemoryLayout<GpParams>.offset(of: \.shapeMask)!,
            MemoryLayout<GpParams>.offset(of: \.uvOverheadBits)!, MemoryLayout<GpParams>.offset(of: \.pruneFlat)!,
            MemoryLayout<GpImage>.size, MemoryLayout<GpImage>.offset(of: \.sbQ)!, MemoryLayout<GpImage>.offset(of: \.usingQm)!,
            MemoryLayout<GpImage>.offset(of: \.ssimLog)!, MemoryLayout<GpImage>.offset(of: \.src)!,
            MemoryLayout<GpImage>.offset(of: \.spitch)!, MemoryLayout<GpImage>.offset(of: \.rec)!,
            MemoryLayout<GpImage>.offset(of: \.aw)!, MemoryLayout<GpImage>.offset(of: \.tileColStart)!,
            MemoryLayout<GpImage>.offset(of: \.shOff)!, MemoryLayout<GpImage>.offset(of: \.sbBase)!,
            MemoryLayout<GpImage>.offset(of: \.mYMode)!, MemoryLayout<GpImage>.offset(of: \.cDc)!,
            MemoryLayout<GpBlockRes>.size, MemoryLayout<GpBlockRes>.offset(of: \.cand)!,
            MemoryLayout<GpBlockRes>.offset(of: \.tx)!,
            MemoryLayout<GpLeaf>.size, MemoryLayout<GpSbOut>.size,
            MemoryLayout<GpBatch>.size, MemoryLayout<GpBatch>.offset(of: \.img)!, MemoryLayout<GpBatch>.offset(of: \.nSb)!,
            MemoryLayout<GpBatch>.offset(of: \.leaves)!, MemoryLayout<GpBatch>.offset(of: \.oCoeffs)!,
            MemoryLayout<GpBatch>.offset(of: \.extCand)!, MemoryLayout<GpBatch>.offset(of: \.extTopK)!,
            MemoryLayout<GpBatch>.offset(of: \.bigScratch)!,
            MemoryLayout<av1g_block>.size, MemoryLayout<av1g_txb>.size,
        ]
        let gpuValues = (0..<host.count).map { Int(out.contents().load(fromByteOffset: $0 * 4, as: UInt32.self)) }
        #expect(out.contents().load(fromByteOffset: host.count * 4, as: UInt32.self) == 0xFFFF_FFFF, "field count")
        #expect(gpuValues == host)
    }
}
