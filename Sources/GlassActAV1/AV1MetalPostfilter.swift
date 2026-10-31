public import AV1Core
internal import AV1Encoder
internal import Foundation
public import Metal

/// The decoder's post-filters on Metal (research): deblocking and CDEF of an
/// intra picture's reconstruction, exactly as a decoder applies them. av1gpu's
/// GPU post-filter (av1core/src/gpu_postfilter.cu) over av1core's shared
/// av1g/postfilter.h.
///
/// Confined to its caller's queue, like the engines of the pixel path (§8.8).
///
/// ## Deviations
/// - The planes are uploaded and the result read back; av1gpu filters its
///   reconstruction where the closed loop left it. Buffers are made per call.
@available(macOS 27, iOS 27, *)
public final class AV1MetalPostfilter: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case metal(String)

        public var description: String {
            switch self { case let .metal(m): m }
        }
    }

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let mark: any MTLComputePipelineState, deblock: any MTLComputePipelineState
    let cdefDirection: any MTLComputePipelineState, cdef: any MTLComputePipelineState
    /// GPU time of the last picture's command buffer.
    public private(set) var lastGPUSeconds: Double = 0

    public init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.metal("no command queue") }
        self.queue = queue
        let library = try AV1ShaderSource.library(
            AV1ShaderSource.sourceRoot.appending(path: "GlassActAV1/Shaders/postfilter.metal"), device: device)
        func pipeline(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw Failure.metal("no \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        mark = try pipeline("p_mark")
        deblock = try pipeline("p_deblock")
        cdefDirection = try pipeline("p_cdef_dir")
        cdef = try pipeline("p_cdef")
    }

    /// The picture a decoder outputs, from its reconstruction before the
    /// filters: `planes` are MiCols·4 × MiRows·4 (chroma half that each way),
    /// tightly packed, because the filters read past the picture's edge. The
    /// result is cropped: Y width × height, U and V half that, rounded up (Y
    /// only for a monochrome picture).
    public func filter(params fp: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>,
                       planes: [UnsafePointer<UInt8>]) throws -> [[UInt8]] {
        let width = Int(fp.width), height = Int(fp.height)
        let miCols = 2 * ((width + 7) >> 3), miRows = 2 * ((height + 7) >> 3)
        let sbCols = (miCols + 15) >> 4, sbRows = (miRows + 15) >> 4
        let nPlanes = fp.monochrome != 0 ? 1 : 3
        guard planes.count >= nPlanes else { throw Failure.metal("\(nPlanes) planes needed") }
        let pw = [miCols * 4, miCols * 2, miCols * 2], ph = [miRows * 4, miRows * 2, miRows * 2]

        var made: [any MTLBuffer] = []
        func make(_ length: Int) throws -> any MTLBuffer {
            guard let b = device.makeBuffer(length: max(16, length), options: .storageModeShared)
            else { throw Failure.metal("no buffer of \(length) bytes") }
            made.append(b)
            return b
        }
        let source = try (0..<3).map { p -> any MTLBuffer in
            let b = try make(pw[p] * ph[p])
            if p < nPlanes { b.contents().copyMemory(from: planes[p], byteCount: pw[p] * ph[p]) }
            return b
        }
        let output = try (0..<3).map { try make(pw[$0] * ph[$0]) }
        let nmi = miRows * miCols, nuv = (miRows / 2) * (miCols / 2)
        let skip = try make(nmi), txY = try make(nmi), txU = try make(nuv), txV = try make(nuv)
        let cdefIdx = try make(sbCols * sbRows)
        memset(cdefIdx.contents(), 0xFF, sbCols * sbRows)
        let dirVar = try make(4 * nuv)
        let blockBuffer = try make(blocks.count * MemoryLayout<av1g_block>.stride)
        if let base = blocks.baseAddress {
            blockBuffer.contents().copyMemory(from: base, byteCount: blocks.count * MemoryLayout<av1g_block>.stride)
        }

        var addrs = GaPfAddrs()
        addrs.plane = (source[0].gpuAddress, source[1].gpuAddress, source[2].gpuAddress)
        addrs.stride = (Int32(pw[0]), Int32(pw[1]), Int32(pw[2]))
        addrs.skip = skip.gpuAddress
        addrs.lfTx = (txY.gpuAddress, txU.gpuAddress, txV.gpuAddress)
        addrs.cdefIdx = cdefIdx.gpuAddress
        addrs.cdefDirVar = dirVar.gpuAddress
        var params = fp
        var frame = [UInt8](repeating: 0, count: av1enc_pf_frame(nil, nil, nil, 0))
        _ = frame.withUnsafeMutableBytes { av1enc_pf_frame(&params, &addrs, $0.baseAddress, $0.count) }

        guard let commands = queue.makeCommandBuffer(), let compute = commands.makeComputeCommandEncoder()
        else { throw Failure.metal("no command encoder") }
        for b in made { compute.useResource(b, usage: [.read, .write]) }
        frame.withUnsafeBytes { compute.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        func grid(_ w: Int, _ h: Int, _ d: Int, tw: Int, th: Int) {
            compute.dispatchThreads(MTLSize(width: w, height: h, depth: d),
                                    threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }
        var n = UInt32(blocks.count)
        compute.setComputePipelineState(mark)
        compute.setBuffer(blockBuffer, offset: 0, index: 1)
        compute.setBytes(&n, length: 4, index: 2)
        if n > 0 { grid(Int(n), 1, 1, tw: min(128, Int(n)), th: 1) }
        if fp.loop_filter_level.0 != 0 || fp.loop_filter_level.1 != 0 {
            compute.setComputePipelineState(deblock)
            for pass in Int32(0)..<2 {
                var pass = pass
                compute.memoryBarrier(scope: .buffers)
                compute.setBytes(&pass, length: 4, index: 2)
                grid(miCols, miRows, nPlanes, tw: 32, th: 4)
            }
        }
        let cdefOn = fp.enable_cdef != 0
        if cdefOn {
            compute.memoryBarrier(scope: .buffers)
            compute.setComputePipelineState(cdefDirection)
            grid(miCols / 2, miRows / 2, 1, tw: 16, th: 8)
            compute.memoryBarrier(scope: .buffers)
            compute.setComputePipelineState(cdef)
            for p in 0..<3 { compute.setBuffer(output[p], offset: 0, index: 3 + p) }
            grid(miCols * 4, miRows * 4, nPlanes, tw: 32, th: 8)
        }
        compute.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw Failure.metal("\(error)") }
        lastGPUSeconds = commands.gpuEndTime - commands.gpuStartTime

        let result = cdefOn ? output : source
        return (0..<nPlanes).map { p in
            let w = p == 0 ? width : (width + 1) / 2, h = p == 0 ? height : (height + 1) / 2
            let base = result[p].contents().assumingMemoryBound(to: UInt8.self)
            var plane = [UInt8](repeating: 0, count: w * h)
            for row in 0..<h { for col in 0..<w { plane[row * w + col] = base[row * pw[p] + col] } }
            return plane
        }
    }
}
