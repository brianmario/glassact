import Foundation
import GlassActAV1
import Metal
import Testing

/// The encoder's kernels (Sources/GlassActAV1/Shaders/encoder.metal) compile,
/// and each fits Metal's threadgroup memory.
@Suite(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (not a VM's paravirtual one)"))
struct EncoderShaderTests {
    @available(macOS 27, *)
    @Test func kernelsCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let main = AV1ShaderSource.sourceRootForTests.appending(path: "GlassActAV1/Shaders/encoder.metal")
        do {
            let library = try AV1ShaderSource.library(main, device: device)
            let analysis = library.functionNames.filter { $0.hasPrefix("k_analysis_") }
            let small = analysis.filter { $0.hasPrefix("k_analysis_small_") }
            #expect(analysis.count == 19 + 8 && small.count == 8, "\(analysis.sorted())")
            #expect(library.functionNames.contains("k_recon") && library.functionNames.contains("k_dp"))
            for name in ["k_recon", "k_dp"] {
                let pipeline = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: name)))
                #expect(pipeline.staticThreadgroupMemoryLength <= device.maxThreadgroupMemoryLength, "\(name)")
            }
            // the analysis kernels, general and at the fixed settings (k_analysis.h's function constant)
            for name in analysis {
                for var fixed in [false, true] {
                    let values = MTLFunctionConstantValues()
                    values.setConstantValue(&fixed, type: .bool, index: 0)
                    let function = try library.makeFunction(name: name, constantValues: values)
                    let pipeline = try device.makeComputePipelineState(function: function)
                    #expect(pipeline.staticThreadgroupMemoryLength <= device.maxThreadgroupMemoryLength, "\(name) fixed \(fixed)")
                }
            }
        } catch {
            Issue.record("\(error)")
        }
    }
}
