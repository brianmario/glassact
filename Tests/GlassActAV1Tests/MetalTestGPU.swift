import Foundation
import GlassActAV1
import Metal
import Testing

/// Just enough Metal for the equivalence tests: compile a test shader, copy
/// arrays in, run one kernel and wait for it.
struct MetalTestGPU {
    let device: any MTLDevice
    let library: any MTLLibrary
    let queue: any MTLCommandQueue

    /// Where the tests' shaders find av1core's headers, the encoder's ported
    /// headers, and the test cases.
    static let includes = AV1ShaderSource.defaultIncludeDirectories + [
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/AV1CoreTestSupport/include"),
    ]

    /// Compiles `Shaders/<shader>`; nil (with the compiler's message
    /// recorded) if it doesn't.
    @available(macOS 27, *)
    static func make(shader: String) throws -> MetalTestGPU? {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let main = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Shaders/\(shader)")
        do {
            let library = try AV1ShaderSource.library(main, device: device, includeDirectories: includes)
            return try MetalTestGPU(device: device, library: library)
        } catch {
            Issue.record("\(error)")
            return nil
        }
    }

    init(device: any MTLDevice, library: any MTLLibrary) throws {
        self.device = device
        self.library = library
        queue = try #require(device.makeCommandQueue())
    }

    func buffer<T>(_: T.Type, count: Int) throws -> any MTLBuffer {
        try #require(device.makeBuffer(length: max(1, count * MemoryLayout<T>.stride), options: .storageModeShared))
    }

    func copy(_ pointer: UnsafeRawPointer?, bytes: Int) throws -> any MTLBuffer {
        let p = try #require(pointer)
        return try #require(device.makeBuffer(bytes: p, length: max(1, bytes), options: .storageModeShared))
    }

    /// `buffers` at indices 0…, then each constant at the next index. One
    /// thread per item (`threads`), or `groups` threadgroups of `groupSize`.
    func run(_ name: String, threads: Int? = nil, groups: Int? = nil, groupSize: Int = 64,
             buffers: [any MTLBuffer], constants: [UInt32]) throws {
        let function = try #require(library.makeFunction(name: name))
        let pipeline = try device.makeComputePipelineState(function: function)
        let commands = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        for (i, b) in buffers.enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        for (i, var c) in constants.enumerated() {
            encoder.setBytes(&c, length: 4, index: buffers.count + i)
        }
        if let groups {
            encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
        } else {
            let width = min(groupSize, pipeline.maxTotalThreadsPerThreadgroup)
            encoder.dispatchThreads(MTLSize(width: threads ?? 1, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let failure = commands.error.map { "\($0)" } ?? "status \(commands.status.rawValue)"
        #expect(commands.status == .completed, "\(name): \(failure)")
    }
}
