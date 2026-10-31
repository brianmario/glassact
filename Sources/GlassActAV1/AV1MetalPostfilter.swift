public import AV1Core
internal import AV1Encoder
internal import Foundation
public import Metal

/// The decoder's post-filters on Metal (research): deblocking and CDEF of an
/// intra picture's reconstruction, exactly as a decoder applies them, and the
/// search that chooses their strengths. av1gpu's GPU post-filter
/// (av1core/src/gpu_postfilter.cu) over av1core's shared av1g/postfilter.h,
/// and its strength search (av1f/src/lfsearch.cu).
///
/// Confined to its caller's queue, like the engines of the pixel path (§8.8).
///
/// ## Deviations
/// - The planes are uploaded and the result read back; av1gpu filters its
///   reconstruction where the closed loop left it. Buffers are made per call.
/// - The search is av1gpu's default, libaom's: the deblocking level from q
///   (LPF_PICK_FROM_Q) and CDEF_FAST_SEARCH_LVL4 with tune=iq's
///   CDEF_ADAPTIVE, by SSE. Not its exhaustive level and strength searches,
///   its damping search or its perceptual distortions.
@available(macOS 27, iOS 27, *)
public final class AV1MetalPostfilter: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case metal(String)

        public var description: String {
            switch self { case let .metal(m): m }
        }
    }

    /// What the search chose, and the picture filtered with it.
    public struct Search {
        /// The input's parameters with the deblocking levels and sharpness,
        /// CDEF damping, bits and presets set.
        public var params: av1g_frame_params
        /// Every 64×64's preset, in raster order (-1: every block skipped).
        /// Each block takes its 64×64's as `cdef_idx`.
        public var superblockCDEF: [Int8]
        /// The filtered picture, cropped like `filter`'s.
        public var planes: [[UInt8]]
        /// Per 64×64 and candidate strength, CDEF's SSE in luma and in both
        /// chroma planes (the search's input; empty when CDEF is off).
        public var lumaSSE: [UInt32], chromaSSE: [UInt32]
        /// Per cdef_bits: the presets (8 luma, then 8 chroma candidate indices)
        /// and their total SSE.
        public var presets: [[Int32]], presetSSE: [UInt64]
    }

    /// libaom's fast CDEF candidates (CDEF_FAST_SEARCH_LVL4): primary {0, 11} × secondary {0, 2}.
    static let candidates: GaCdefCand = {
        var c = GaCdefCand()
        c.npri = 2
        c.nsec = 2
        c.pri.0 = 0
        c.pri.1 = 11
        c.sec.0 = 0
        c.sec.1 = 2
        return c
    }()
    public static let maxCDEFBits = 3
    public static let refinements = 4

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipelines: [String: any MTLComputePipelineState]
    /// GPU time of the last call's command buffers.
    public private(set) var lastGPUSeconds: Double = 0

    public init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.metal("no command queue") }
        self.queue = queue
        let library = try AV1ShaderSource.library(
            AV1ShaderSource.sourceRoot.appending(path: "GlassActAV1/Shaders/postfilter.metal"), device: device)
        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in ["p_mark", "p_deblock", "p_cdef_dir", "p_cdef", "l_cdef_idx_norm", "l_cdef_sse", "l_select_small", "l_assign"] {
            guard let function = library.makeFunction(name: name) else { throw Failure.metal("no \(name)") }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines
    }

    /// The picture a decoder outputs, from its reconstruction before the
    /// filters: `planes` are MiCols·4 × MiRows·4 (chroma half that each way),
    /// tightly packed, because the filters read past the picture's edge. The
    /// result is cropped: Y width × height, U and V half that, rounded up (Y
    /// only for a monochrome picture).
    public func filter(params fp: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>,
                       planes: [UnsafePointer<UInt8>]) throws -> [[UInt8]] {
        let job = try Job(self, params: fp, blocks: blocks, planes: planes)
        lastGPUSeconds = 0
        try run { compute in
            job.mark(compute)
            job.deblock(compute)
            if fp.enable_cdef != 0 {
                job.cdefDirections(compute)
                job.cdef(compute)
            }
        }
        return job.cropped(fp.enable_cdef != 0 ? job.output : job.source)
    }

    /// Chooses the deblocking levels and the CDEF presets for a picture as
    /// libaom tune=iq does, from its reconstruction before the filters
    /// (`planes`, as `filter` takes them) and its source (`source`: the same
    /// sizes, edge-replicated past the picture), and filters it with them.
    /// `params` supplies the size, monochrome and base_q_idx.
    public func search(params: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>,
                       planes: [UnsafePointer<UInt8>], source: [UnsafePointer<UInt8>],
                       sourceStrides: [Int]? = nil) throws -> Search {
        var fp = params
        var tf = GaTuneiqFrame()
        av1enc_tuneiq_frame(Int32(fp.base_q_idx), Int32(fp.monochrome), &tf)
        let level = UInt8(tf.lf_level), mono = fp.monochrome != 0
        fp.loop_filter_level = (level, level, mono ? 0 : level, mono ? 0 : level)
        fp.loop_filter_sharpness = UInt8(tf.lf_sharpness)
        fp.enable_cdef = 1
        fp.cdef_bits = 0
        fp.cdef_damping_minus_3 = UInt8(tf.cdef_damping - 3)
        fp.cdef_y_pri = (0, 0, 0, 0, 0, 0, 0, 0)
        fp.cdef_y_sec = (0, 0, 0, 0, 0, 0, 0, 0)
        fp.cdef_uv_pri = (0, 0, 0, 0, 0, 0, 0, 0)
        fp.cdef_uv_sec = (0, 0, 0, 0, 0, 0, 0, 0)
        let job = try Job(self, params: fp, blocks: blocks, planes: planes)
        let nsb = job.sbCols * job.sbRows
        let nc = Int(Self.candidates.npri * Self.candidates.nsec)
        lastGPUSeconds = 0
        guard tf.cdef_mode != 0 else {
            // libaom CDEF_ADAPTIVE at qindex <= 32: one all-zero preset, signalled but inactive
            try run { compute in
                job.mark(compute)
                job.normalizeCDEF(compute)
                job.deblock(compute)
            }
            return Search(params: fp, superblockCDEF: job.superblockCDEF(), planes: job.cropped(job.source),
                          lumaSSE: [], chromaSSE: [], presets: [], presetSSE: [])
        }

        let target = try (0..<3).map { p -> any MTLBuffer in
            let b = try job.make(job.pw[p] * job.ph[p])
            if p < job.nPlanes { Self.copy(source[p], stride: sourceStrides?[p] ?? job.pw[p], into: b, width: job.pw[p], height: job.ph[p]) }
            return b
        }
        let lumaSSE = try job.make(4 * nsb * nc), chromaSSE = try job.make(4 * nsb * nc)
        memset(chromaSSE.contents(), 0, 4 * nsb * nc)  // stays 0 for a monochrome picture
        let current = try job.make(8 * nsb)
        let bitsCount = Self.maxCDEFBits + 1
        let levels = try job.make(4 * 16 * bitsCount), totals = try job.make(8 * bitsCount)
        var candidates = Self.candidates
        try run { compute in
            job.mark(compute)
            job.normalizeCDEF(compute)
            job.deblock(compute)
            job.cdefDirections(compute)
            compute.memoryBarrier(scope: .buffers)
            compute.setComputePipelineState(pipelines["l_cdef_sse"]!)
            compute.setBytes(&candidates, length: MemoryLayout<GaCdefCand>.stride, index: 1)
            for p in 0..<3 { compute.setBuffer(target[p], offset: 0, index: 3 + p) }
            compute.setBuffer(lumaSSE, offset: 0, index: 6)
            compute.setBuffer(chromaSSE, offset: 0, index: 7)
            compute.dispatchThreadgroups(MTLSize(width: nsb, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            compute.memoryBarrier(scope: .buffers)
            compute.setComputePipelineState(pipelines["l_select_small"]!)
            var args: [Int32] = [Int32(nc), Int32(nsb), mono ? 1 : 0, Int32(Self.maxCDEFBits), Int32(Self.refinements),
                                 mono ? 1 : 0]  // libaom doesn't refine a fast single-plane search
            compute.setBuffer(lumaSSE, offset: 0, index: 0)
            compute.setBuffer(chromaSSE, offset: 0, index: 1)
            compute.setBuffer(current, offset: 0, index: 2)
            compute.setBuffer(levels, offset: 0, index: 3)
            compute.setBuffer(totals, offset: 0, index: 4)
            compute.setBytes(&args, length: 4 * args.count, index: 5)
            compute.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
        }

        let presetSSE = Array(UnsafeBufferPointer(start: totals.contents().assumingMemoryBound(to: UInt64.self), count: bitsCount))
        let lev = levels.contents().assumingMemoryBound(to: Int32.self)
        let presets = (0..<bitsCount).map { Array(UnsafeBufferPointer(start: lev + 16 * $0, count: 16)) }
        let active = job.superblockCDEF().filter { $0 >= 0 }.count
        let bits = Int(presetSSE.withUnsafeBufferPointer {
            av1enc_cdef_bits($0.baseAddress, Int32(Self.maxCDEFBits), Int32(active), mono ? 1 : 0, tf.rdmult)
        })
        av1enc_cdef_presets(presets[bits], Int32(bits), tf.cdef_mode, &candidates, &fp)
        job.setParams(fp)
        try run { compute in
            job.begin(compute, "l_assign")
            var args: [Int32] = [Int32(nc), Int32(nsb), mono ? 1 : 0, Int32(1 << bits)]
            compute.setBuffer(lumaSSE, offset: 0, index: 1)
            compute.setBuffer(chromaSSE, offset: 0, index: 2)
            compute.setBuffer(levels, offset: 16 * 4 * bits, index: 3)
            compute.setBytes(&args, length: 4 * args.count, index: 4)
            compute.dispatchThreads(MTLSize(width: nsb, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(64, nsb), height: 1, depth: 1))
            job.cdef(compute)
        }
        func words(_ b: any MTLBuffer) -> [UInt32] {
            Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: UInt32.self), count: nsb * nc))
        }
        return Search(params: fp, superblockCDEF: job.superblockCDEF(), planes: job.cropped(job.output),
                      lumaSSE: words(lumaSSE), chromaSSE: words(chromaSSE), presets: presets, presetSSE: presetSSE)
    }

    /// A plane of `width` × `height` from rows `stride` apart, tightly into `buffer`.
    static func copy(_ plane: UnsafePointer<UInt8>, stride: Int, into buffer: any MTLBuffer, width: Int, height: Int) {
        let d = buffer.contents().assumingMemoryBound(to: UInt8.self)
        if stride == width {
            d.update(from: plane, count: width * height)
        } else {
            for row in 0..<height { (d + row * width).update(from: plane + row * stride, count: width) }
        }
    }

    private func run(_ body: (any MTLComputeCommandEncoder) -> Void) throws {
        guard let commands = queue.makeCommandBuffer(), let compute = commands.makeComputeCommandEncoder()
        else { throw Failure.metal("no command encoder") }
        body(compute)
        compute.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw Failure.metal("\(error)") }
        lastGPUSeconds += commands.gpuEndTime - commands.gpuStartTime
    }

    /// One picture's planes, maps and frame.
    final class Job {
        let filter: AV1MetalPostfilter
        let width: Int, height: Int, miCols: Int, miRows: Int, sbCols: Int, sbRows: Int, nPlanes: Int
        let pw: [Int], ph: [Int]
        var made: [any MTLBuffer] = []
        var source: [any MTLBuffer] = [], output: [any MTLBuffer] = []
        var cdefIdx: (any MTLBuffer)!, blockBuffer: (any MTLBuffer)!
        var addrs = GaPfAddrs()
        var frame: [UInt8] = []
        var params: av1g_frame_params
        let blockCount: Int

        init(_ filter: AV1MetalPostfilter, params fp: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>,
             planes: [UnsafePointer<UInt8>]) throws {
            self.filter = filter
            params = fp
            width = Int(fp.width)
            height = Int(fp.height)
            miCols = 2 * ((width + 7) >> 3)
            miRows = 2 * ((height + 7) >> 3)
            sbCols = (miCols + 15) >> 4
            sbRows = (miRows + 15) >> 4
            nPlanes = fp.monochrome != 0 ? 1 : 3
            pw = [miCols * 4, miCols * 2, miCols * 2]
            ph = [miRows * 4, miRows * 2, miRows * 2]
            blockCount = blocks.count
            guard planes.count >= nPlanes else { throw Failure.metal("\(nPlanes) planes needed") }
            source = try (0..<3).map { p -> any MTLBuffer in
                let b = try make(pw[p] * ph[p])
                if p < nPlanes { b.contents().copyMemory(from: planes[p], byteCount: pw[p] * ph[p]) }
                return b
            }
            output = try (0..<3).map { try make(pw[$0] * ph[$0]) }
            let nmi = miRows * miCols, nuv = (miRows / 2) * (miCols / 2)
            let skip = try make(nmi), txY = try make(nmi), txU = try make(nuv), txV = try make(nuv)
            cdefIdx = try make(sbCols * sbRows)
            memset(cdefIdx.contents(), 0xFF, sbCols * sbRows)
            let dirVar = try make(4 * nuv)
            blockBuffer = try make(blocks.count * MemoryLayout<av1g_block>.stride)
            if let base = blocks.baseAddress {
                blockBuffer.contents().copyMemory(from: base, byteCount: blocks.count * MemoryLayout<av1g_block>.stride)
            }
            addrs.plane = (source[0].gpuAddress, source[1].gpuAddress, source[2].gpuAddress)
            addrs.stride = (Int32(pw[0]), Int32(pw[1]), Int32(pw[2]))
            addrs.skip = skip.gpuAddress
            addrs.lfTx = (txY.gpuAddress, txU.gpuAddress, txV.gpuAddress)
            addrs.cdefIdx = cdefIdx.gpuAddress
            addrs.cdefDirVar = dirVar.gpuAddress
            setParams(fp)
        }

        func make(_ length: Int) throws -> any MTLBuffer {
            guard let b = filter.device.makeBuffer(length: max(16, length), options: .storageModeShared)
            else { throw Failure.metal("no buffer of \(length) bytes") }
            made.append(b)
            return b
        }

        /// The frame (av1g_pf_frame) for `fp`.
        func setParams(_ fp: av1g_frame_params) {
            params = fp
            var p = fp
            frame = [UInt8](repeating: 0, count: av1enc_pf_frame(nil, nil, nil, 0))
            _ = frame.withUnsafeMutableBytes { av1enc_pf_frame(&p, &addrs, $0.baseAddress, $0.count) }
        }

        func begin(_ compute: any MTLComputeCommandEncoder, _ name: String) {
            compute.memoryBarrier(scope: .buffers)
            for b in made { compute.useResource(b, usage: [.read, .write]) }
            frame.withUnsafeBytes { compute.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            compute.setComputePipelineState(filter.pipelines[name]!)
        }

        private func grid(_ compute: any MTLComputeCommandEncoder, _ w: Int, _ h: Int, _ d: Int, tw: Int, th: Int) {
            compute.dispatchThreads(MTLSize(width: w, height: h, depth: d),
                                    threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }

        func mark(_ compute: any MTLComputeCommandEncoder) {
            guard blockCount > 0 else { return }
            begin(compute, "p_mark")
            var n = UInt32(blockCount)
            compute.setBuffer(blockBuffer, offset: 0, index: 1)
            compute.setBytes(&n, length: 4, index: 2)
            grid(compute, blockCount, 1, 1, tw: min(128, blockCount), th: 1)
        }

        /// Every 64×64 with a non-skipped block takes preset 0, the rest -1.
        func normalizeCDEF(_ compute: any MTLComputeCommandEncoder) {
            begin(compute, "l_cdef_idx_norm")
            grid(compute, sbCols * sbRows, 1, 1, tw: min(64, sbCols * sbRows), th: 1)
        }

        func deblock(_ compute: any MTLComputeCommandEncoder) {
            guard params.loop_filter_level.0 != 0 || params.loop_filter_level.1 != 0 else { return }
            for pass in Int32(0)..<2 {
                var pass = pass
                begin(compute, "p_deblock")
                compute.setBytes(&pass, length: 4, index: 2)
                grid(compute, miCols, miRows, nPlanes, tw: 32, th: 4)
            }
        }

        func cdefDirections(_ compute: any MTLComputeCommandEncoder) {
            begin(compute, "p_cdef_dir")
            grid(compute, miCols / 2, miRows / 2, 1, tw: 16, th: 8)
        }

        func cdef(_ compute: any MTLComputeCommandEncoder) {
            begin(compute, "p_cdef")
            for p in 0..<3 { compute.setBuffer(output[p], offset: 0, index: 3 + p) }
            grid(compute, miCols * 4, miRows * 4, nPlanes, tw: 32, th: 8)
        }

        func superblockCDEF() -> [Int8] {
            Array(UnsafeBufferPointer(start: cdefIdx.contents().assumingMemoryBound(to: Int8.self), count: sbCols * sbRows))
        }

        func cropped(_ planes: [any MTLBuffer]) -> [[UInt8]] {
            (0..<nPlanes).map { p in
                let w = p == 0 ? width : (width + 1) / 2, h = p == 0 ? height : (height + 1) / 2
                let base = planes[p].contents().assumingMemoryBound(to: UInt8.self)
                var plane = [UInt8](repeating: 0, count: w * h)
                for row in 0..<h { for col in 0..<w { plane[row * w + col] = base[row * pw[p] + col] } }
                return plane
            }
        }
    }
}
