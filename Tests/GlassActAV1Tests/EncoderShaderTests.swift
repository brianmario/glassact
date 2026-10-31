import Foundation
import GlassActAV1
import Metal
import Testing

/// The encoder's kernels (Sources/GlassActAV1/Shaders/encoder.metal) compile,
/// and each fits Metal's threadgroup memory.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct EncoderShaderTests {
    @available(macOS 27, *)
    @Test func kernelsCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let main = AV1ShaderSource.sourceRootForTests.appending(path: "GlassActAV1/Shaders/encoder.metal")
        do {
            let library = try AV1ShaderSource.library(main, device: device)
            let analysis = library.functionNames.filter { $0.hasPrefix("k_analysis_") }
            let small = analysis.filter { $0.hasPrefix("k_analysis_small_") }
            #expect(analysis.count == 19 + 6 && small.count == 6, "\(analysis.sorted())")
            #expect(library.functionNames.contains("k_recon") && library.functionNames.contains("k_dp"))
            for name in analysis + ["k_recon", "k_dp"] {
                let pipeline = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: name)))
                #expect(pipeline.staticThreadgroupMemoryLength <= device.maxThreadgroupMemoryLength, "\(name)")
            }
        } catch {
            Issue.record("\(error)")
        }
    }
}
