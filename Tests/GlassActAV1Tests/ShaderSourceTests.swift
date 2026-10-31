import Foundation
import GlassActAV1
import Metal
import Testing

/// Every av1core header the kernels share compiles as Metal Shading Language.
@Suite(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (not a VM's paravirtual one)"))
struct ShaderSourceTests {
    @available(macOS 27, *)
    @Test func sharedHeadersCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let main = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Shaders/headers_check.metal")
        do {
            let library = try AV1ShaderSource.library(main, device: device)
            #expect(library.functionNames.contains("headers_check"))
        } catch {
            Issue.record("\(error)")
        }
    }
}
