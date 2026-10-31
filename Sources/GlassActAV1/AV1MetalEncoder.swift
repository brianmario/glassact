public import AV1Core
internal import AV1Encoder
internal import Foundation
public import Metal
internal import QuartzCore

/// av1gpu's AV1 intra encoder, on Metal (research; DESIGN doesn't cover it
/// yet): the open-loop analysis of every block shape, the partition DP, and
/// the closed loop, which decides every block's modes and coefficients and
/// reconstructs it exactly as a decoder will. Its output is a DecisionRecord
/// for av1core's writer.
///
/// Confined to its caller's queue, like the engines of the pixel path (§8.8):
/// one picture at a time, no actors.
///
/// ## Deviations
/// - av1gpu batches many pictures per dispatch for throughput; this encodes
///   one picture per call, the shape of a live frame.
/// - The per-superblock outputs are packed into the record on the CPU, not by
///   k_pack, and no post-filters, delta-q or quantizer matrices yet.
@available(macOS 27, iOS 27, *)
public final class AV1MetalEncoder: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case metal(String)
        case record(String)

        public var description: String {
            switch self { case let .metal(m), let .record(m): m }
        }
    }

    /// A picture's blocks in decode order (tiles, then superblocks, then
    /// decode_partition's pre-order), with their sizes and positions set, and
    /// the analysis's luma mode and angle delta for each.
    public struct Partition {
        public var blocks: [av1g_block]
        /// Each block's luma tx type, from the analysis (for its largest tx size).
        public var lumaTxTypes: [UInt8]
        public var tiles: av1g_tiles
    }

    /// An encoded picture: the decisions, ready for av1core's writer, and the
    /// GPU's reconstruction (cropped planes: Y width × height, U and V half
    /// that, rounded up), which the decoder must reproduce.
    public struct Encoded {
        public var params: av1g_frame_params
        public var blocks: [av1g_block]
        public var blockTxb: [UInt32]
        public var txb: [av1g_txb]
        public var coeffs: [Int16]
        public var reconstruction: [[UInt8]]
        /// The same reconstruction at the post-filters' size, which reaches past
        /// the picture: MiCols·4 × MiRows·4, chroma half that each way.
        public var filterInput: [[UInt8]]

        /// The record, pointing into this value's arrays for the duration of `body`.
        public mutating func withRecord<R>(_ body: (inout av1g_decision_record) throws -> R) rethrows -> R {
            var record = av1g_decision_record()
            record.fp = params
            record.n_blocks = UInt32(blocks.count)
            record.n_txb = UInt32(txb.count)
            record.n_coeffs = UInt64(coeffs.count)
            return try blocks.withUnsafeMutableBufferPointer { b in
                try blockTxb.withUnsafeMutableBufferPointer { bt in
                    try txb.withUnsafeMutableBufferPointer { t in
                        try coeffs.withUnsafeMutableBufferPointer { c in
                            record.blocks = b.baseAddress
                            record.block_txb = bt.baseAddress
                            record.txb = t.baseAddress
                            record.coeffs = c.baseAddress
                            return try body(&record)
                        }
                    }
                }
            }
        }
    }

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    /// Per AV1 block size: the analysis kernel and its warps per threadgroup.
    let analysis: [Int: (pipeline: any MTLComputePipelineState, warps: Int)]
    /// The thread-per-block analysis kernels of the shapes up to 64 pixels.
    let analysisSmall: [Int: any MTLComputePipelineState]
    static let smallThreads = 128
    let dp: any MTLComputePipelineState
    let recon: any MTLComputePipelineState
    var params: GpParams
    /// GPU time of the last picture's command buffer (analysis, DP, closed loop).
    public private(set) var lastGPUSeconds: Double = 0

    /// The last picture's GPU time by stage (when `profilesStages` is on), and
    /// its wall-clock time from the first dispatch to the last completion.
    public struct StageTimes: Sendable {
        public var analysis = 0.0, partition = 0.0, closedLoop = 0.0, wall = 0.0
        /// Closed-loop dispatches that must run one after another.
        public var wavefrontSteps = 0
    }
    /// Runs each stage in its own command buffer so it can be timed, which
    /// adds a little latency between stages. For measurement.
    public var profilesStages = false
    /// Uniform tiles, as log2 of the columns and rows (-1: the fewest legal).
    /// Tiles run the closed loop's wavefronts side by side, and cost the
    /// bits of contexts that don't cross them.
    public var tiling: (columnsLog2: Int, rowsLog2: Int) = (-1, -1)
    public private(set) var lastStages = StageTimes()

    public init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.metal("no command queue") }
        self.queue = queue
        let library = try AV1ShaderSource.library(
            AV1ShaderSource.sourceRoot.appending(path: "GlassActAV1/Shaders/encoder.metal"), device: device)
        var analysis: [Int: (pipeline: any MTLComputePipelineState, warps: Int)] = [:]
        for (bsize, size) in Self.blockSizes.enumerated() where size.w > 0 {
            let prefix = "k_analysis_\(size.w)x\(size.h)_w"
            guard let name = library.functionNames.first(where: { $0.hasPrefix(prefix) }),
                  let warps = Int(name.dropFirst(prefix.count)),
                  let function = library.makeFunction(name: name)
            else { throw Failure.metal("no \(prefix)…") }
            analysis[bsize] = (try Self.pipeline(function, threads: warps * 32, device: device), warps)
        }
        self.analysis = analysis
        var small: [Int: any MTLComputePipelineState] = [:]
        for (bsize, size) in Self.blockSizes.enumerated() where size.w > 0 && size.w * size.h <= 64 {
            guard let function = library.makeFunction(name: "k_analysis_small_\(size.w)x\(size.h)")
            else { throw Failure.metal("no k_analysis_small_\(size.w)x\(size.h)") }
            small[bsize] = try Self.pipeline(function, threads: Self.smallThreads, device: device)
        }
        analysisSmall = small
        guard let dpFunction = library.makeFunction(name: "k_dp"),
              let reconFunction = library.makeFunction(name: "k_recon")
        else { throw Failure.metal("no k_dp / k_recon") }
        dp = try device.makeComputePipelineState(function: dpFunction)
        recon = try Self.pipeline(reconFunction, threads: Self.reconThreads, device: device)
        params = Self.defaultParams()
    }

    /// A pipeline compiled for exactly the threads its threadgroups have: the
    /// compiler then gives each thread more registers than the 1024-thread
    /// default allows.
    static func pipeline(_ function: any MTLFunction, threads: Int, device: any MTLDevice) throws -> any MTLComputePipelineState {
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = function
        descriptor.maxTotalThreadsPerThreadgroup = threads
        return try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
    }

    /// AV1's block sizes in pixels, by `bsize` (128-pixel sizes unused: 0).
    static let blockSizes: [(w: Int, h: Int)] = [
        (4, 4), (4, 8), (8, 4), (8, 8), (8, 16), (16, 8), (16, 16), (16, 32), (32, 16), (32, 32), (32, 64),
        (64, 32), (64, 64), (0, 0), (0, 0), (0, 0), (4, 16), (16, 4), (8, 32), (32, 8), (16, 64), (64, 16),
    ]

    /// Threads per closed-loop threadgroup (k_recon's RC_NT), and the global
    /// scratch each one needs (RC_CTA_BIG_BYTES: 4 × RcBigScr + 8 kept 32×32 levels).
    static let reconThreads = 128
    static let reconScratchBytes = 4 * (64 * 64 * 2 + 32 * 65 * 4 + 32 * 32 * 2) + 8 * 32 * 32 * 2

    /// av1gpu's speed presets (encoder/apps/av1gpu.cpp), each searching less
    /// than the one before. Their tilings are `tiling`'s to choose here, and
    /// `slow`'s exhaustive loop-filter searches aren't ported.
    public enum Preset: String, CaseIterable, Sendable {
        /// Closed-loop tx-size search, every tx type for every re-checked
        /// candidate, K 6, filter intra.
        case slow
        /// Everything at av1gpu's defaults (K 4, tx search in the analysis).
        case base
        /// No 4:1 shapes, K 2, no tx search in the analysis.
        case fast
        /// + flat-region pruning, one closed-loop candidate.
        case faster
        /// + no 32×64 / 64×32, 2× subsampled screening for ≥ 16×16, K 1:
        /// av1gpu's default.
        case turbo
        /// + no 4×4 / 4×8 / 8×4, no closed-loop tx search, one chroma candidate.
        case turbo2
        /// + no angle deltas.
        case turbo3
    }

    /// The search effort; `base` by default.
    public var preset: Preset = .base {
        didSet { params = Self.params(for: preset) }
    }

    static func params(for preset: Preset) -> GpParams {
        var p = defaultParams()
        switch preset {
        case .base:
            break
        case .slow:
            p.txSizeSearch = 1; p.txAllCL = 1; p.K = 6; p.Krecheck = 6; p.filterIntra = 1
        case .fast:
            p.shapeMask = 0x1FFF; p.K = 2; p.Krecheck = 2; p.txSearch = 0
        case .faster:
            p.shapeMask = 0x1FFF; p.K = 2; p.Krecheck = 1; p.txSearch = 0; p.pruneFlat = 1
        case .turbo, .turbo2, .turbo3:
            p.shapeMask = 0x13FF; p.K = 1; p.Krecheck = 1; p.txSearch = 0; p.pruneFlat = 1; p.screenSub = 2
            if preset != .turbo { p.shapeMask = 0x13F8; p.txSearchCL = 0; p.uvK = 1 }
            if preset == .turbo3 { p.deltas = 0; p.uvDeltas = 0 }
        }
        return p
    }

    /// av1gpu's base configuration (GpConfig), without the small-shape kernel.
    static func defaultParams() -> GpParams {
        var p = GpParams()
        p.lambdaMul = 1
        p.satdLambda = 1
        p.rnd = 0.375; p.zbin = 0.656
        p.rndC = 0.375; p.zbinC = 0.656
        p.K = 4
        p.Krecheck = 2
        p.txSearch = 1
        p.txSearchCL = 1
        p.deltas = 1
        p.cfl = 1
        p.uvK = 2
        p.shapeMask = 0x3F_1FFF  // all 19 sizes
        p.partMask8 = 0xF
        p.partMaskN = 0x3FF
        p.maxPart = 64
        p.uvOverheadBits = 1.5
        p.splitBias = 1
        p.lambdaCMul = 1
        p.smallKernel = 1
        p.pruneMinArea = 1024
        p.screenSub = 1
        p.uvDeltas = 1
        return p
    }

    /// The analysis and the partition DP of one 8-bit 4:2:0 picture (planes
    /// tightly packed: Y width × height, U and V half that, rounded up).
    public func partition(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
                          width: Int, height: Int, qindex: Int) throws -> Partition {
        let run = try Run(encoder: self, y: y, u: u, v: v, width: width, height: height, qindex: qindex)
        try run.execute(closedLoop: false)
        let (blocks, types) = run.leafBlocks()
        return Partition(blocks: blocks, lumaTxTypes: types, tiles: run.tiles)
    }

    /// The whole encoder on one picture: decisions and reconstruction.
    public func encode(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
                       width: Int, height: Int, qindex: Int) throws -> Encoded {
        let run = try Run(encoder: self, y: y, u: u, v: v, width: width, height: height, qindex: qindex)
        try run.execute(closedLoop: true)
        return try run.encoded()
    }

    /// One picture's buffers and dispatches.
    final class Run {
        let encoder: AV1MetalEncoder
        let width: Int, height: Int, qindex: Int
        let miCols: Int, miRows: Int, sbCols: Int, sbRows: Int, aw: Int, ah: Int
        var tiles = av1g_tiles()
        var buffers: [any MTLBuffer] = []
        var batch = GpBatch()
        var shTotal = [UInt32](repeating: 0, count: Int(GP_NSHAPES))
        let rec: [any MTLBuffer]
        let leaves: any MTLBuffer, leafCount: any MTLBuffer
        let sbOut: any MTLBuffer, oBlocks: any MTLBuffer, oBlockTxb: any MTLBuffer, oTxb: any MTLBuffer
        let oCoeffs: any MTLBuffer
        /// The analysis's result per (shape, position), and each shape's grid.
        let blockResults: any MTLBuffer
        var shapeOffset = [UInt32](repeating: 0, count: Int(GP_NSHAPES)), shapeColumns = [Int32](repeating: 0, count: Int(GP_NSHAPES))
        /// Wavefront steps: superblocks whose left and above-right neighbours are done.
        var steps: [[UInt32]] = []

        init(encoder: AV1MetalEncoder, y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
             width: Int, height: Int, qindex: Int) throws {
            self.encoder = encoder
            self.width = width
            self.height = height
            self.qindex = qindex
            miCols = 2 * ((width + 7) >> 3)
            miRows = 2 * ((height + 7) >> 3)
            sbCols = (miCols + 15) >> 4
            sbRows = (miRows + 15) >> 4
            aw = sbCols * 64
            ah = sbRows * 64
            let device = encoder.device
            var made: [any MTLBuffer] = []
            func make(_ length: Int) throws -> any MTLBuffer {
                guard let b = device.makeBuffer(length: max(16, length), options: .storageModeShared)
                else { throw Failure.metal("no buffer of \(length) bytes") }
                memset(b.contents(), 0, b.length)
                made.append(b)
                return b
            }
            // source planes, padded to whole superblocks by edge replication
            let planes = [(y, width, height), (u, (width + 1) / 2, (height + 1) / 2), (v, (width + 1) / 2, (height + 1) / 2)]
            var src: [any MTLBuffer] = []
            var recPlanes: [any MTLBuffer] = []
            for (p, (pixels, w, h)) in planes.enumerated() {
                let pw = p == 0 ? aw : aw / 2, ph = p == 0 ? ah : ah / 2
                let b = try make(pw * ph)
                let d = b.contents().assumingMemoryBound(to: UInt8.self)
                for row in 0..<ph {
                    let sr = min(row, h - 1)
                    let line = d + row * pw
                    line.update(from: pixels + sr * w, count: w)
                    (line + w).update(repeating: pixels[sr * w + w - 1], count: pw - w)
                }
                src.append(b)
                recPlanes.append(try make(pw * ph))
            }
            rec = recPlanes
            var tl = av1g_tiles()
            guard av1g_tile_layout(UInt32(width), UInt32(height), Int32(encoder.tiling.columnsLog2),
                                   Int32(encoder.tiling.rowsLog2), &tl) == AV1G_OK
            else { throw Failure.metal("tile layout \(encoder.tiling) for \(width)×\(height)") }

            var image = GpImage()
            image.W = Int32(width); image.H = Int32(height)
            image.MiCols = Int32(miCols); image.MiRows = Int32(miRows)
            image.sbCols = Int32(sbCols); image.sbRows = Int32(sbRows)
            image.baseQ = Int32(qindex)
            image.qctx = qindex <= 20 ? 0 : qindex <= 60 ? 1 : qindex <= 120 ? 2 : 3
            image.qm = (15, 15, 15)
            image.aw = Int32(aw); image.ah = Int32(ah)
            image.src = (AV1MetalEncoder.address(src[0]), AV1MetalEncoder.address(src[1]), AV1MetalEncoder.address(src[2]))
            image.spitch = (Int32(aw), Int32(aw / 2), Int32(aw / 2))
            image.rec = (AV1MetalEncoder.address(rec[0]), AV1MetalEncoder.address(rec[1]), AV1MetalEncoder.address(rec[2]))
            image.rpitch = image.spitch
            image.tileCols = Int32(tl.cols); image.tileRows = Int32(tl.rows)
            let colStarts = withUnsafeBytes(of: tl.mi_col_starts) { Array($0.bindMemory(to: UInt32.self)) }
            let rowStarts = withUnsafeBytes(of: tl.mi_row_starts) { Array($0.bindMemory(to: UInt32.self)) }
            withUnsafeMutableBytes(of: &image.tileColStart) { d in
                for k in 0...Int(tl.cols) { d.storeBytes(of: Int32(colStarts[k]), toByteOffset: k * 4, as: Int32.self) }
            }
            withUnsafeMutableBytes(of: &image.tileRowStart) { d in
                for k in 0...Int(tl.rows) { d.storeBytes(of: Int32(rowStarts[k]), toByteOffset: k * 4, as: Int32.self) }
            }
            // closed-loop context maps: 5 per-4x4 maps, and per plane the coefficient contexts
            let mi = miCols * miRows, mi1 = (miCols >> 1) * (miRows >> 1)
            let maps = try make(mi * 5)
            func at(_ b: any MTLBuffer, _ offset: Int) -> UnsafeMutablePointer<UInt8>? {
                UnsafeMutablePointer(bitPattern: UInt(b.gpuAddress) + UInt(offset))
            }
            image.mYMode = at(maps, 0); image.mUVMode = at(maps, mi); image.mSkip = at(maps, 2 * mi)
            image.mMiSize = at(maps, 3 * mi); image.mTx = at(maps, 4 * mi)
            let ctx = try make((mi + 2 * mi1) * 2)
            let ctxTotal = mi + 2 * mi1
            image.cLvl = (at(ctx, 0), at(ctx, mi), at(ctx, mi + mi1))
            image.cDc = (at(ctx, ctxTotal), at(ctx, ctxTotal + mi), at(ctx, ctxTotal + mi + mi1))

            // analysis grids: every enabled shape over the coded area
            var nbx = [Int32](repeating: 0, count: Int(GP_NSHAPES)), nby = nbx
            var shOff = [UInt32](repeating: 0, count: Int(GP_NSHAPES))
            var blkTotal: UInt32 = 0
            for s in 0..<Int(GP_NSHAPES) {
                shOff[s] = blkTotal
                let size = AV1MetalEncoder.blockSizes[s]
                guard size.w > 0, (encoder.params.shapeMask >> s) & 1 != 0 else { continue }
                nbx[s] = Int32((miCols * 4 + size.w - 1) / size.w)
                nby[s] = Int32((miRows * 4 + size.h - 1) / size.h)
                shTotal[s] = UInt32(nbx[s] * nby[s])
                blkTotal += shTotal[s]
            }
            shOff.withUnsafeBytes { src in withUnsafeMutableBytes(of: &image.shOff) { $0.copyMemory(from: src) } }
            nbx.withUnsafeBytes { src in withUnsafeMutableBytes(of: &image.shNbx) { $0.copyMemory(from: src) } }
            nby.withUnsafeBytes { src in withUnsafeMutableBytes(of: &image.shNby) { $0.copyMemory(from: src) } }

            let nSb = sbCols * sbRows
            let imageBuffer = try make(MemoryLayout<GpImage>.stride)
            imageBuffer.contents().storeBytes(of: image, as: GpImage.self)
            let blk = try make(Int(blkTotal) * MemoryLayout<GpBlockRes>.stride)
            blockResults = blk
            shapeOffset = shOff
            shapeColumns = nbx
            let starts = try make(Int(GP_NSHAPES) * 2 * 4)   // per shape: [first block of image 0, total]
            for s in 0..<Int(GP_NSHAPES) {
                starts.contents().storeBytes(of: shTotal[s], toByteOffset: s * 8 + 4, as: UInt32.self)
            }
            let sbImg = try make(nSb * 4)
            leaves = try make(nSb * Int(GP_MAX_LEAVES) * MemoryLayout<GpLeaf>.stride)
            leafCount = try make(nSb * 2)
            let sbJ = try make(nSb * 4)
            sbOut = try make(nSb * MemoryLayout<GpSbOut>.stride)
            oBlocks = try make(nSb * Int(GP_MAX_LEAVES) * MemoryLayout<av1g_block>.stride)
            oBlockTxb = try make(nSb * Int(GP_MAX_LEAVES) * 2)
            oTxb = try make(nSb * Int(GP_MAX_TXB) * MemoryLayout<av1g_txb>.stride)
            oCoeffs = try make(nSb * Int(GP_SB_COEFFS) * 2)
            let stats = try make(16 * 4)

            // wavefront per tile: step = column + 2 * row from the tile's origin
            for tr in 0..<Int(tl.rows) {
                for tc in 0..<Int(tl.cols) {
                    let r0 = Int(rowStarts[tr]) >> 4, r1 = (Int(rowStarts[tr + 1]) + 15) >> 4
                    let c0 = Int(colStarts[tc]) >> 4, c1 = (Int(colStarts[tc + 1]) + 15) >> 4
                    for r in r0..<r1 {
                        for c in c0..<c1 {
                            let s = (c - c0) + 2 * (r - r0)
                            while steps.count <= s { steps.append([]) }
                            steps[s].append(UInt32(r * sbCols + c))
                        }
                    }
                }
            }
            let widest = steps.map(\.count).max() ?? 1
            let scratch = try make(widest * AV1MetalEncoder.reconScratchBytes)

            batch.nimg = 1
            batch.img = AV1MetalEncoder.address(imageBuffer)
            batch.blk = AV1MetalEncoder.address(blk)
            batch.shImgStart = AV1MetalEncoder.address(starts)
            batch.nSb = UInt32(nSb)
            batch.sbImg = AV1MetalEncoder.address(sbImg)
            batch.leaves = AV1MetalEncoder.address(leaves)
            batch.leafCountW = AV1MetalEncoder.address(leafCount)
            batch.sbJ = AV1MetalEncoder.address(sbJ)
            batch.sbOut = AV1MetalEncoder.address(sbOut)
            batch.oBlocks = AV1MetalEncoder.address(oBlocks)
            batch.oBlockTxb = AV1MetalEncoder.address(oBlockTxb)
            batch.oTxb = AV1MetalEncoder.address(oTxb)
            batch.oCoeffs = AV1MetalEncoder.address(oCoeffs)
            batch.stats = AV1MetalEncoder.address(stats)
            batch.bigScratch = UnsafeMutableRawPointer(bitPattern: UInt(scratch.gpuAddress))
            tiles = tl
            buffers = made
        }

        func execute(closedLoop: Bool) throws {
            let profiling = encoder.profilesStages
            var stages = StageTimes()
            stages.wavefrontSteps = closedLoop ? steps.count : 0
            var commands: (any MTLCommandBuffer)?
            var compute: (any MTLComputeCommandEncoder)?
            var params = encoder.params
            func open() throws -> any MTLComputeCommandEncoder {
                if let compute { return compute }
                guard let c = encoder.queue.makeCommandBuffer(), let e = c.makeComputeCommandEncoder()
                else { throw Failure.metal("no command encoder") }
                for b in buffers { e.useResource(b, usage: [.read, .write]) }
                e.setBytes(&batch, length: MemoryLayout<GpBatch>.stride, index: 0)
                e.setBytes(&params, length: MemoryLayout<GpParams>.stride, index: 1)
                commands = c
                compute = e
                return e
            }
            /// Ends a stage: when profiling, commits it and returns its GPU time.
            func close() throws -> Double {
                guard let c = commands, let e = compute else { return 0 }
                e.endEncoding()
                c.commit()
                c.waitUntilCompleted()
                if let error = c.error { throw Failure.metal("\(error)") }
                commands = nil
                compute = nil
                return c.gpuEndTime - c.gpuStartTime
            }
            let t0 = CACurrentMediaTime()
            var e = try open()
            for s in 0..<Int(GP_NSHAPES) where shTotal[s] > 0 {
                var n = shTotal[s]
                if params.smallKernel != 0, let pipeline = encoder.analysisSmall[s] {
                    e.setComputePipelineState(pipeline)
                    e.setBytes(&n, length: 4, index: 2)
                    e.dispatchThreads(MTLSize(width: Int(n), height: 1, depth: 1),
                                      threadsPerThreadgroup: MTLSize(width: AV1MetalEncoder.smallThreads, height: 1, depth: 1))
                    continue
                }
                guard let (pipeline, warps) = encoder.analysis[s] else { continue }
                e.setComputePipelineState(pipeline)
                e.setBytes(&n, length: 4, index: 2)
                e.dispatchThreadgroups(MTLSize(width: (Int(n) + warps - 1) / warps, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: warps * 32, height: 1, depth: 1))
            }
            stages.analysis = profiling ? try close() : 0
            e = try open()
            e.memoryBarrier(scope: .buffers)
            let nSb = sbCols * sbRows
            e.setComputePipelineState(encoder.dp)
            e.dispatchThreads(MTLSize(width: nSb, height: 1, depth: 1),
                              threadsPerThreadgroup: MTLSize(width: min(64, nSb), height: 1, depth: 1))
            stages.partition = profiling ? try close() : 0
            if closedLoop {
                e = try open()
                e.setComputePipelineState(encoder.recon)
                for step in steps {
                    e.memoryBarrier(scope: .buffers)
                    e.setBytes(step, length: step.count * 4, index: 2)
                    e.dispatchThreadgroups(MTLSize(width: step.count, height: 1, depth: 1),
                                           threadsPerThreadgroup: MTLSize(width: AV1MetalEncoder.reconThreads, height: 1, depth: 1))
                }
                stages.closedLoop = profiling ? try close() : 0
            }
            if let c = commands, let e = compute {
                e.endEncoding()
                c.commit()
                c.waitUntilCompleted()
                if let error = c.error { throw Failure.metal("\(error)") }
                encoder.lastGPUSeconds = c.gpuEndTime - c.gpuStartTime
            } else {
                encoder.lastGPUSeconds = stages.analysis + stages.partition + stages.closedLoop
            }
            stages.wall = CACurrentMediaTime() - t0
            encoder.lastStages = stages
        }

        /// Superblocks in decode order: tiles in raster order, superblocks in raster order inside each.
        func decodeOrder() -> [Int] {
            let colStarts = withUnsafeBytes(of: tiles.mi_col_starts) { Array($0.bindMemory(to: UInt32.self)) }
            let rowStarts = withUnsafeBytes(of: tiles.mi_row_starts) { Array($0.bindMemory(to: UInt32.self)) }
            var order: [Int] = []
            for tr in 0..<Int(tiles.rows) {
                for tc in 0..<Int(tiles.cols) {
                    for r in stride(from: Int(rowStarts[tr]), to: Int(rowStarts[tr + 1]), by: 16) {
                        for c in stride(from: Int(colStarts[tc]), to: Int(colStarts[tc + 1]), by: 16) {
                            order.append((r >> 4) * sbCols + (c >> 4))
                        }
                    }
                }
            }
            return order
        }

        func leafBlocks() -> ([av1g_block], [UInt8]) {
            var blocks: [av1g_block] = [], types: [UInt8] = []
            let leafPtr = leaves.contents().assumingMemoryBound(to: GpLeaf.self)
            let results = blockResults.contents().assumingMemoryBound(to: GpBlockRes.self)
            let counts = leafCount.contents().assumingMemoryBound(to: UInt16.self)
            for sb in decodeOrder() {
                let r = (sb / sbCols) * 16, c = (sb % sbCols) * 16
                for k in 0..<Int(counts[sb]) {
                    let leaf = leafPtr[sb * Int(GP_MAX_LEAVES) + k]
                    var b = av1g_block()
                    b.mi_row = UInt16(r + Int(leaf.y4))
                    b.mi_col = UInt16(c + Int(leaf.x4))
                    b.bsize = leaf.bsize
                    // the analysis's best luma mode for this shape at this position
                    let s = Int(leaf.bsize), size = AV1MetalEncoder.blockSizes[s]
                    let li = (Int(b.mi_row) * 4 / size.h) * Int(shapeColumns[s]) + Int(b.mi_col) * 4 / size.w
                    let res = results[Int(shapeOffset[s]) + li]
                    if res.ncand > 0 {
                        let cand = Int(res.cand.0)
                        b.y_mode = UInt8(cand >> 3)
                        b.angle_delta_y = Int8((cand & 7) - 3)
                    }
                    blocks.append(b)
                    types.append(res.ncand > 0 ? res.tx : 0)
                }
            }
            return (blocks, types)
        }

        /// k_pack's work on the CPU: the per-superblock slots into one record, in decode order.
        func encoded() throws -> Encoded {
            let out = sbOut.contents().assumingMemoryBound(to: GpSbOut.self)
            let gBlocks = oBlocks.contents().assumingMemoryBound(to: av1g_block.self)
            let gBlockTxb = oBlockTxb.contents().assumingMemoryBound(to: UInt16.self)
            let gTxb = oTxb.contents().assumingMemoryBound(to: av1g_txb.self)
            let gCoeffs = oCoeffs.contents().assumingMemoryBound(to: Int16.self)
            var blocks: [av1g_block] = [], blockTxb: [UInt32] = [], txb: [av1g_txb] = [], coeffs: [Int16] = []
            for sb in decodeOrder() {
                let o = out[sb]
                let txb0 = UInt32(txb.count), coef0 = UInt32(coeffs.count)
                for k in 0..<Int(o.nBlocks) {
                    blocks.append(gBlocks[sb * Int(GP_MAX_LEAVES) + k])
                    blockTxb.append(txb0 + UInt32(gBlockTxb[sb * Int(GP_MAX_LEAVES) + k]))
                }
                for k in 0..<Int(o.nTxb) {
                    var t = gTxb[sb * Int(GP_MAX_TXB) + k]
                    t.coeff_off += coef0
                    txb.append(t)
                }
                coeffs.append(contentsOf: UnsafeBufferPointer(start: gCoeffs + sb * Int(GP_SB_COEFFS), count: Int(o.nCoeffs)))
            }
            blockTxb.append(UInt32(txb.count))
            var fp = av1g_frame_params()
            fp.version = UInt32(AV1G_DECISIONS_VERSION)
            fp.width = UInt32(width)
            fp.height = UInt32(height)
            fp.base_q_idx = UInt8(qindex)
            fp.tx_mode_select = encoder.params.txSizeSearch != 0 ? 1 : 0
            fp.tile_cols_log2 = Int8(encoder.tiling.columnsLog2)
            fp.tile_rows_log2 = Int8(encoder.tiling.rowsLog2)
            fp.enable_filter_intra = UInt8(encoder.params.filterIntra)
            func planes(_ size: (Int) -> (Int, Int)) -> [[UInt8]] {
                (0..<3).map { p in
                    let (w, h) = size(p)
                    let pitch = p == 0 ? aw : aw / 2
                    let base = rec[p].contents().assumingMemoryBound(to: UInt8.self)
                    var plane = [UInt8](repeating: 0, count: w * h)
                    plane.withUnsafeMutableBufferPointer { d in
                        for row in 0..<h { (d.baseAddress! + row * w).update(from: base + row * pitch, count: w) }
                    }
                    return plane
                }
            }
            let reconstruction = planes { $0 == 0 ? (width, height) : ((width + 1) / 2, (height + 1) / 2) }
            let filterInput = planes { $0 == 0 ? (miCols * 4, miRows * 4) : (miCols * 2, miRows * 2) }
            return Encoded(params: fp, blocks: blocks, blockTxb: blockTxb, txb: txb, coeffs: coeffs,
                           reconstruction: reconstruction, filterInput: filterInput)
        }
    }

    static func address<T>(_ buffer: any MTLBuffer) -> UnsafeMutablePointer<T>? {
        UnsafeMutablePointer(bitPattern: UInt(buffer.gpuAddress))
    }

    static func address<T>(_ buffer: any MTLBuffer) -> UnsafePointer<T>? {
        UnsafePointer(bitPattern: UInt(buffer.gpuAddress))
    }
}
