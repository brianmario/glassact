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
        /// Whether `blocks` carry chroma decisions too (`decidesLeaves`).
        public var hasChroma: Bool
        public var tiles: av1g_tiles
        /// An inter frame's (`beginPartition(motion:)`): every block's motion, parallel to
        /// `blocks` (an inter block's intra fields are 0); empty otherwise.
        public var inter: [av1g_block_inter] = []
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
    /// The largest shape (in pixels) the thread-per-block kernel takes: av1gpu's 64, and 8x16 / 16x8.
    static let smallMaxPixels = 128
    let dp: any MTLComputePipelineState
    let leaf: any MTLComputePipelineState, leafScan: any MTLComputePipelineState
    /// Inter frames' motion search: k_me, and per block size of 8×8 and up k_inter and its warps.
    let motionSearch: any MTLComputePipelineState
    let inter: [Int: (pipeline: any MTLComputePipelineState, warps: Int)]
    /// Keep each superblock's analysis, partition and leaf decisions from the
    /// previous picture when the source they read hasn't changed (the
    /// superblock itself and the left, above, above-left, above-right and
    /// below-left ones, whose edge pixels it predicts from). Screen content
    /// mostly stands still, so a sequence analyzes only what moved. The
    /// results are the same as analyzing everything.
    public var reusesAnalysis = false
    /// Skip the analysis of 32×32 and larger shapes where the source's
    /// variance is above this many quantizer steps squared, as they rarely win
    /// there (0: analyze them everywhere). On the reference traces 4 costs at
    /// most 0.4 % of bytes (5K), and 1 at most 1.1 %, for ~10–20 % of the
    /// analysis (BENCHMARKS.md).
    public var busyBlockPrune: Float = 0
    /// Try each directional mode's angle deltas (the preset's choice). Off
    /// trades ~0.1–0.9 % of bytes for ~20–30 % of the analysis.
    public var searchesAngleDeltas = true
    /// Superblocks kept from the previous picture in the last one.
    public private(set) var lastKeptSuperblocks = 0
    var cache: AnalysisCache?
    /// Padded source planes of partitions already waited on, for the next picture of the same
    /// geometry: making and clearing 22 MB of shared memory per 5K picture cost milliseconds.
    var sourcePool: [[any MTLBuffer]] = []

    func takeSource(_ lengths: [Int]) throws -> [any MTLBuffer] {
        if let i = sourcePool.firstIndex(where: { $0.map(\.length) == lengths.map { max(16, $0) } }) {
            return sourcePool.remove(at: i)
        }
        return try lengths.map {
            guard let b = device.makeBuffer(length: max(16, $0), options: .storageModeShared)
            else { throw Failure.metal("no buffer of \($0) bytes") }
            return b
        }
    }

    func recycleSource(_ planes: [any MTLBuffer]) {
        if sourcePool.count < 2 { sourcePool.append(planes) }
    }

    /// The padded source of the last partition waited on: the next inter frame's motion search
    /// predicts from it. The one before goes back to the pool (its partitions are done).
    var lastSource: [any MTLBuffer]?
    func keepSource(_ planes: [any MTLBuffer]) {
        if let old = lastSource { recycleSource(old) }
        lastSource = planes
    }

    /// Analyze every superblock of the next picture (keeping nothing from the ones before), as a
    /// stream's first picture must when the cache holds an earlier stream's inter frames.
    public func forgetAnalysis() {
        cache?.previous = nil
    }

    /// The buffers a picture's analysis leaves behind, and the source it read.
    final class AnalysisCache {
        let key: [UInt8]
        let blockResults: any MTLBuffer, leaves: any MTLBuffer, leafCount: any MTLBuffer
        let leafDecisions: any MTLBuffer, sbJ: any MTLBuffer, keep: any MTLBuffer
        /// An inter frame's analysis (GpInterRes, parallel to blockResults).
        let interResults: any MTLBuffer
        /// The SBs to analyze (raster), staleCount of them.
        let stale: any MTLBuffer
        var staleCount = 0
        var previous: [[UInt8]]? = nil
        var keptCount = 0
        /// Each SB's blocks, luma tx types and motion as the last partition read them, for SBs kept since.
        var sbBlocks: [[av1g_block]] = [], sbTypes: [[UInt8]] = [], sbInter: [[av1g_block_inter]] = []

        init(key: [UInt8], device: any MTLDevice, blocks: Int, superblocks nSb: Int) throws {
            self.key = key
            func make(_ n: Int) throws -> any MTLBuffer {
                guard let b = device.makeBuffer(length: max(16, n), options: .storageModeShared)
                else { throw Failure.metal("no buffer of \(n) bytes") }
                memset(b.contents(), 0, b.length)
                return b
            }
            blockResults = try make(blocks * MemoryLayout<GpBlockRes>.stride)
            interResults = try make(blocks * MemoryLayout<GpInterRes>.stride)
            leaves = try make(nSb * Int(GP_MAX_LEAVES) * MemoryLayout<GpLeaf>.stride)
            leafCount = try make(nSb * 2)
            leafDecisions = try make(nSb * Int(GP_MAX_LEAVES) * MemoryLayout<GpLeafDecision>.stride)
            sbJ = try make(nSb * 4)
            keep = try make(nSb)
            stale = try make(nSb * 4)
        }

        /// Sets `keep` from the new source against the previous one, and remembers the new one.
        /// `skip` (per SB, raster): SBs the caller won't use the analysis of (an inter frame's
        /// copies), kept without analysis; one whose source changed keeps the source its analysis
        /// is of, so that a later picture analyzes it.
        func markUnchanged(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
                           width: Int, height: Int, sbCols: Int, sbRows: Int, skip: [UInt8]? = nil) {
            let cw = (width + 1) / 2, ch = (height + 1) / 2
            let planes = [(y, width, height), (u, cw, ch), (v, cw, ch)]
            let k = keep.contents().assumingMemoryBound(to: UInt8.self)
            let list = stale.contents().assumingMemoryBound(to: UInt32.self)
            guard let prev = previous else {
                memset(k, 0, sbCols * sbRows)
                for i in 0..<(sbCols * sbRows) { list[i] = UInt32(i) }
                staleCount = sbCols * sbRows
                keptCount = 0
                previous = planes.map { Array(UnsafeBufferPointer(start: $0.0, count: $0.1 * $0.2)) }
                return
            }
            var changed = [Bool](repeating: false, count: sbCols * sbRows)
            for (p, (pixels, w, h)) in planes.enumerated() {
                let side = p == 0 ? 64 : 32
                prev[p].withUnsafeBufferPointer { old in
                    for sr in 0..<sbRows {
                        for sc in 0..<sbCols where !changed[sr * sbCols + sc] {
                            let x0 = sc * side, y0 = sr * side
                            guard x0 < w, y0 < h else { continue }
                            let n = min(side, w - x0)
                            for row in y0..<min(y0 + side, h) where memcmp(pixels + row * w + x0, old.baseAddress! + row * w + x0, n) != 0 {
                                changed[sr * sbCols + sc] = true
                                break
                            }
                        }
                    }
                }
            }
            func changedAt(_ r: Int, _ c: Int) -> Bool { r >= 0 && c >= 0 && r < sbRows && c < sbCols && changed[r * sbCols + c] }
            keptCount = 0
            staleCount = 0
            for r in 0..<sbRows {
                for c in 0..<sbCols {
                    // with `skip` (an inter frame), every SB not skipped is analyzed: its kept
                    // analysis could hold motion against an older picture
                    let isStale = skip.map { $0[r * sbCols + c] == 0 }
                        ?? (changedAt(r, c) || changedAt(r, c - 1) || changedAt(r - 1, c) || changedAt(r - 1, c - 1)
                            || changedAt(r - 1, c + 1) || changedAt(r + 1, c - 1))
                    k[r * sbCols + c] = isStale ? 0 : 1
                    if isStale {
                        list[staleCount] = UInt32(r * sbCols + c)
                        staleCount += 1
                    } else {
                        keptCount += 1
                    }
                }
            }
            // the rest of the previous source equals this one already
            for (p, (pixels, w, h)) in planes.enumerated() {
                let side = p == 0 ? 64 : 32
                previous![p].withUnsafeMutableBufferPointer { old in
                    for sr in 0..<sbRows {
                        for sc in 0..<sbCols where changed[sr * sbCols + sc] && skip.map({ $0[sr * sbCols + sc] == 0 }) ?? true {
                            let x0 = sc * side, y0 = sr * side
                            guard x0 < w, y0 < h else { continue }
                            let n = min(side, w - x0)
                            for row in y0..<min(y0 + side, h) {
                                (old.baseAddress! + row * w + x0).update(from: pixels + row * w + x0, count: n)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The cache for a picture of this geometry and these settings (made anew
    /// when they change, so its first picture keeps nothing); nil unless
    /// `reusesAnalysis`.
    func analysisCache(width: Int, height: Int, qindex: Int, blocks: Int, superblocks: Int) throws -> AnalysisCache? {
        guard reusesAnalysis else { cache = nil; return nil }
        var p = params
        var key = withUnsafeBytes(of: &p) { Array($0) }
        for v in [width, height, qindex, tiling.columnsLog2, tiling.rowsLog2, decidesLeaves ? 1 : 0,
                  Int(busyBlockPrune.bitPattern), searchesAngleDeltas ? 1 : 0, leafTxSearchPixels,
                  leafChromaAngledModes ? 1 : 0] {
            withUnsafeBytes(of: v) { key += $0 }
        }
        if let cache, cache.key == key { return cache }
        cache = try AnalysisCache(key: key, device: device, blocks: blocks, superblocks: superblocks)
        return cache
    }

    /// k_leaf's threadgroup: LEAF_NW SIMD-groups, one leaf each at a time.
    static let leafThreads = 128
    /// After the partition, also decide every leaf's chroma mode and CfL and
    /// its luma tx type on the GPU, from the source (k_leaf): the partition's
    /// blocks then carry them, for a closed loop that only quantizes.
    public var decidesLeaves = false
    /// The largest block (in pixels) whose luma tx type `decidesLeaves`
    /// searches; larger ones take DCT_DCT. Up to 256 (16×16), where an intra set
    /// stops offering more. 256 is the most exact; 128 saves ~13 % of a moving
    /// picture's GPU time for ~0.1–0.2 % of bytes (BENCHMARKS.md).
    public var leafTxSearchPixels = 256
    /// Whether `decidesLeaves` screens the six angled chroma modes too. Off
    /// saves ~5–8 % of a moving picture's GPU time for 0–0.3 % of bytes.
    public var leafChromaAngledModes = true
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
        /// When profiling: each block shape's analysis (by bsize) and the leaf decisions, in seconds.
        public var shapes: [Int: Double] = [:]
        public var leaves = 0.0
        public init() {}
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
        var inter: [Int: (pipeline: any MTLComputePipelineState, warps: Int)] = [:]
        for (bsize, size) in Self.blockSizes.enumerated() where size.w >= 8 && size.h >= 8 {
            let prefix = "k_inter_\(size.w)x\(size.h)_w"
            guard let name = library.functionNames.first(where: { $0.hasPrefix(prefix) }),
                  let warps = Int(name.dropFirst(prefix.count)),
                  let function = library.makeFunction(name: name)
            else { throw Failure.metal("no \(prefix)…") }
            inter[bsize] = (try Self.pipeline(function, threads: warps * 32, device: device), warps)
        }
        self.inter = inter
        guard let meFunction = library.makeFunction(name: "k_me") else { throw Failure.metal("no k_me") }
        motionSearch = try Self.pipeline(meFunction, threads: 128, device: device)
        var small: [Int: any MTLComputePipelineState] = [:]
        for (bsize, size) in Self.blockSizes.enumerated() where size.w > 0 && size.w * size.h <= Self.smallMaxPixels {
            guard let function = library.makeFunction(name: "k_analysis_small_\(size.w)x\(size.h)")
            else { throw Failure.metal("no k_analysis_small_\(size.w)x\(size.h)") }
            small[bsize] = try Self.pipeline(function, threads: Self.smallThreads, device: device)
        }
        analysisSmall = small
        guard let leafFunction = library.makeFunction(name: "k_leaf"),
              let leafScanFunction = library.makeFunction(name: "k_leaf_scan")
        else { throw Failure.metal("no k_leaf") }
        leafScan = try Self.pipeline(leafScanFunction, threads: 1024, device: device)
        leaf = try Self.pipeline(leafFunction, threads: Self.leafThreads, device: device)
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
        let run = try Run(encoder: self, y: y, u: u, v: v, width: width, height: height, qindex: qindex, closedLoop: false)
        try run.execute(closedLoop: false)
        let (blocks, types, inter) = run.leafBlocks()
        return Partition(blocks: blocks, lumaTxTypes: types, hasChroma: run.decidesLeaves, tiles: run.tiles, inter: inter)
    }

    /// A picture's analysis and partition DP, running on the GPU: the caller
    /// overlaps other work with it, then waits.
    public final class PendingPartition: @unchecked Sendable {
        let run: Run
        /// Superblocks whose analysis the previous picture's stands for.
        public var keptSuperblocks: Int { run.keptSuperblocks }
        let commands: (any MTLCommandBuffer)?

        init(run: Run, commands: (any MTLCommandBuffer)?) {
            self.run = run
            self.commands = commands
        }

        /// The partition, once the GPU is done.
        public func wait() throws -> Partition {
            if let commands {
                commands.waitUntilCompleted()
                if let error = commands.error { throw Failure.metal("\(error)") }
                var stages = StageTimes()
                stages.analysis = commands.gpuEndTime - commands.gpuStartTime
                run.encoder.lastStages = stages
                run.encoder.lastGPUSeconds = stages.analysis
            }
            let (blocks, types, inter) = run.leafBlocks()
            if !run.source.isEmpty {  // the GPU is done with it (or never used it)
                run.encoder.keepSource(run.source)
                run.source = []
            }
            return Partition(blocks: blocks, lumaTxTypes: types, hasChroma: run.decidesLeaves, tiles: run.tiles, inter: inter)
        }
    }

    /// Starts `partition` without waiting for it. (With `profilesStages` on,
    /// the stages run to completion first.)
    /// `skip` (per 64×64, raster; with `reusesAnalysis`): superblocks whose analysis
    /// the caller doesn't need, which keep the previous picture's where it has one.
    /// `motion` (an inter frame's shift candidates, (dx, dy) pairs): search for motion
    /// from the last picture waited on, of the same size (its source); the partition
    /// then mixes inter blocks with intra ones (`Partition.inter`).
    public func beginPartition(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
                               width: Int, height: Int, qindex: Int, skip: [UInt8]? = nil,
                               motion: [Int32]? = nil) throws -> PendingPartition {
        let run = try Run(encoder: self, y: y, u: u, v: v, width: width, height: height, qindex: qindex, closedLoop: false,
                          skip: skip, motion: motion)
        return PendingPartition(run: run, commands: try run.execute(closedLoop: false, wait: false))
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
        /// The padded source planes (the encoder's pool's, returned once a partition is read).
        var source: [any MTLBuffer] = []
        let leaves: any MTLBuffer, leafCount: any MTLBuffer
        let sbOut: any MTLBuffer, oBlocks: any MTLBuffer, oBlockTxb: any MTLBuffer, oTxb: any MTLBuffer
        let oCoeffs: any MTLBuffer
        /// The analysis's result per (shape, position), and each shape's grid.
        let blockResults: any MTLBuffer
        let leafDecisions: any MTLBuffer
        /// An inter frame's: the motion search's result per (shape, position), and k_me's per 16×16.
        let interResults: any MTLBuffer
        let meBest: (any MTLBuffer)?
        var isInter: Bool { meBest != nil }
        /// Superblocks whose analysis the previous picture's stands for (`reusesAnalysis`).
        let keptSuperblocks: Int
        /// With `reusesAnalysis`, the superblocks to analyze (the rest are kept).
        let staleSuperblocks: Int?
        /// k_leaf's list of every SB's leaves, and its indirect dispatch.
        let leafOffsets: any MTLBuffer, leafDispatch: any MTLBuffer
        let decidesLeaves: Bool
        var shapeOffset = [UInt32](repeating: 0, count: Int(GP_NSHAPES)), shapeColumns = [Int32](repeating: 0, count: Int(GP_NSHAPES))
        /// Wavefront steps: superblocks whose left and above-right neighbours are done.
        var steps: [[UInt32]] = []

        /// With `closedLoop` false the closed loop's buffers (reconstruction,
        /// maps, contexts, outputs, scratch) are left out: a partition needs none.
        init(encoder: AV1MetalEncoder, y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
             width: Int, height: Int, qindex: Int, closedLoop: Bool = true, skip: [UInt8]? = nil,
             motion: [Int32]? = nil) throws {
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
            let src = try encoder.takeSource([aw * ah, aw / 2 * (ah / 2), aw / 2 * (ah / 2)])
            made += src
            source = src
            var recPlanes: [any MTLBuffer] = []
            for (p, (pixels, w, h)) in planes.enumerated() {
                let pw = p == 0 ? aw : aw / 2, ph = p == 0 ? ah : ah / 2
                let b = src[p]
                let d = b.contents().assumingMemoryBound(to: UInt8.self)
                for row in 0..<ph {
                    let sr = min(row, h - 1)
                    let line = d + row * pw
                    line.update(from: pixels + sr * w, count: w)
                    (line + w).update(repeating: pixels[sr * w + w - 1], count: pw - w)
                }
                recPlanes.append(try make(closedLoop ? pw * ph : 16))
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
            let maps = try make(closedLoop ? mi * 5 : 16)
            func at(_ b: any MTLBuffer, _ offset: Int) -> UnsafeMutablePointer<UInt8>? {
                UnsafeMutablePointer(bitPattern: UInt(b.gpuAddress) + UInt(offset))
            }
            image.mYMode = at(maps, 0); image.mUVMode = at(maps, mi); image.mSkip = at(maps, 2 * mi)
            image.mMiSize = at(maps, 3 * mi); image.mTx = at(maps, 4 * mi)
            let ctx = try make(closedLoop ? (mi + 2 * mi1) * 2 : 16)
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
            // an inter frame: motion from the last picture's source (padded the same way)
            if let motion, let last = encoder.lastSource, last.map(\.length) == src.map(\.length), last[0] !== src[0] {
                made.append(last[0])
                image.ref = AV1MetalEncoder.address(last[0])
                let n = min(motion.count / 2, Int(GP_ME_CANDS))
                image.nMeCand = Int32(n)
                withUnsafeMutableBytes(of: &image.meCand) { d in
                    for k in 0..<(2 * n) { d.storeBytes(of: Int16(clamping: motion[k]), toByteOffset: 2 * k, as: Int16.self) }
                }
                let me = try make((aw / 16) * (ah / 16) * 2 * Int(GP_ME_KEEP) * 2)
                image.meBest = AV1MetalEncoder.address(me)
                meBest = me
            } else {
                meBest = nil
            }
            shOff.withUnsafeBytes { src in withUnsafeMutableBytes(of: &image.shOff) { $0.copyMemory(from: src) } }
            nbx.withUnsafeBytes { src in withUnsafeMutableBytes(of: &image.shNbx) { $0.copyMemory(from: src) } }
            nby.withUnsafeBytes { src in withUnsafeMutableBytes(of: &image.shNby) { $0.copyMemory(from: src) } }

            let nSb = sbCols * sbRows
            let imageBuffer = try make(MemoryLayout<GpImage>.stride)
            imageBuffer.contents().storeBytes(of: image, as: GpImage.self)
            // the analysis's results: the previous picture's, kept where its source is unchanged
            let cache = try encoder.analysisCache(width: width, height: height, qindex: qindex, blocks: Int(blkTotal),
                                                  superblocks: sbCols * sbRows)
            func keep(_ b: any MTLBuffer) -> any MTLBuffer { made.append(b); return b }
            let blk = try cache.map { keep($0.blockResults) } ?? make(Int(blkTotal) * MemoryLayout<GpBlockRes>.stride)
            blockResults = blk
            shapeOffset = shOff
            shapeColumns = nbx
            let starts = try make(Int(GP_NSHAPES) * 2 * 4)   // per shape: [first block of image 0, total]
            for s in 0..<Int(GP_NSHAPES) {
                starts.contents().storeBytes(of: shTotal[s], toByteOffset: s * 8 + 4, as: UInt32.self)
            }
            let sbImg = try make(nSb * 4)
            leaves = try cache.map { keep($0.leaves) } ?? make(nSb * Int(GP_MAX_LEAVES) * MemoryLayout<GpLeaf>.stride)
            leafCount = try cache.map { keep($0.leafCount) } ?? make(nSb * 2)
            leafDecisions = try cache.map { keep($0.leafDecisions) }
                ?? make(nSb * Int(GP_MAX_LEAVES) * MemoryLayout<GpLeafDecision>.stride)
            interResults = try cache.map { keep($0.interResults) } ?? make(meBest != nil ? Int(blkTotal) * MemoryLayout<GpInterRes>.stride : 16)
            decidesLeaves = encoder.decidesLeaves
            leafOffsets = try make(4 * (nSb + 1))
            leafDispatch = try make(MemoryLayout<MTLDispatchThreadgroupsIndirectArguments>.stride)
            let sbJ = try cache.map { keep($0.sbJ) } ?? make(nSb * 4)
            var sbKeep: (any MTLBuffer)?, sbList: (any MTLBuffer)?
            if let cache {
                cache.markUnchanged(y: y, u: u, v: v, width: width, height: height,
                                    sbCols: (miCols + 15) >> 4, sbRows: (miRows + 15) >> 4,
                                    skip: skip?.count == ((miCols + 15) >> 4) * ((miRows + 15) >> 4) ? skip : nil)
                sbKeep = keep(cache.keep)
                sbList = keep(cache.stale)
            }
            staleSuperblocks = cache?.staleCount
            keptSuperblocks = cache?.keptCount ?? 0
            encoder.lastKeptSuperblocks = keptSuperblocks
            let out = closedLoop ? nSb : 0
            sbOut = try make(out * MemoryLayout<GpSbOut>.stride)
            oBlocks = try make(out * Int(GP_MAX_LEAVES) * MemoryLayout<av1g_block>.stride)
            oBlockTxb = try make(out * Int(GP_MAX_LEAVES) * 2)
            oTxb = try make(out * Int(GP_MAX_TXB) * MemoryLayout<av1g_txb>.stride)
            oCoeffs = try make(out * Int(GP_SB_COEFFS) * 2)
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
            let scratch = try make(closedLoop ? widest * AV1MetalEncoder.reconScratchBytes : 16)

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
            batch.leafDec = AV1MetalEncoder.address(leafDecisions)
            batch.sbKeep = sbKeep.flatMap { AV1MetalEncoder.address($0) }
            batch.sbList = sbList.flatMap { AV1MetalEncoder.address($0) }
            batch.nSbList = UInt32(staleSuperblocks ?? 0)
            batch.inter = meBest != nil ? AV1MetalEncoder.address(interResults) : nil
            tiles = tl
            buffers = made
        }

        /// Encodes the stages. With `wait` false (and no profiling), returns the
        /// committed command buffer instead of waiting for it.
        @discardableResult
        func execute(closedLoop: Bool, wait: Bool = true) throws -> (any MTLCommandBuffer)? {
            let profiling = encoder.profilesStages
            var stages = StageTimes()
            stages.wavefrontSteps = closedLoop ? steps.count : 0
            var commands: (any MTLCommandBuffer)?
            var compute: (any MTLComputeCommandEncoder)?
            var params = encoder.params
            params.leafDecide = decidesLeaves ? 1 : 0
            params.pruneVar = encoder.busyBlockPrune
            if !encoder.searchesAngleDeltas { params.deltas = 0; params.uvDeltas = 0 }
            params.leafTxSearch = Int32(encoder.leafTxSearchPixels)
            params.leafChromaAngled = encoder.leafChromaAngledModes ? 1 : 0
            func open() throws -> any MTLComputeCommandEncoder {
                if let compute { return compute }
                guard let c = encoder.queue.makeCommandBuffer(), let e = c.makeComputeCommandEncoder(dispatchType: .concurrent)
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
            // every SB keeps the previous picture's analysis, and its results are in the cache
            if !closedLoop, !profiling, staleSuperblocks == 0 {
                encoder.lastGPUSeconds = 0
                return nil
            }
            let t0 = CACurrentMediaTime()
            var e = try open()
            let analyzed = staleSuperblocks ?? (sbCols * sbRows)
            if isInter, analyzed > 0 {  // motion per 16x16, alongside the analysis
                var cells = UInt32(analyzed * 16)
                e.setComputePipelineState(encoder.motionSearch)
                e.setBytes(&cells, length: 4, index: 2)
                e.dispatchThreadgroups(MTLSize(width: (Int(cells) + 3) / 4, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }
            for s in 0..<Int(GP_NSHAPES) where shTotal[s] > 0 {
                var n = shTotal[s]
                if let stale = staleSuperblocks {  // only the listed SBs' blocks
                    let size = AV1MetalEncoder.blockSizes[s]
                    n = UInt32(stale * (64 / size.w) * (64 / size.h))
                    if n == 0 { continue }
                }
                if params.smallKernel != 0, let pipeline = encoder.analysisSmall[s] {
                    e.setComputePipelineState(pipeline)
                    e.setBytes(&n, length: 4, index: 2)
                    e.dispatchThreads(MTLSize(width: Int(n), height: 1, depth: 1),
                                      threadsPerThreadgroup: MTLSize(width: AV1MetalEncoder.smallThreads, height: 1, depth: 1))
                    if profiling {
                        let t = try close()
                        stages.shapes[s] = t
                        stages.analysis += t
                        e = try open()
                    }
                    continue
                }
                guard let (pipeline, warps) = encoder.analysis[s] else { continue }
                e.setComputePipelineState(pipeline)
                e.setBytes(&n, length: 4, index: 2)
                e.dispatchThreadgroups(MTLSize(width: (Int(n) + warps - 1) / warps, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: warps * 32, height: 1, depth: 1))
                if profiling {
                    let t = try close()
                    stages.shapes[s] = t
                    stages.analysis += t
                    e = try open()
                }
            }
            if isInter, analyzed > 0 {  // inter candidates against the analysis's intra costs
                e.memoryBarrier(scope: .buffers)
                for s in 0..<Int(GP_NSHAPES) where shTotal[s] > 0 {
                    guard let (pipeline, warps) = encoder.inter[s] else { continue }
                    let size = AV1MetalEncoder.blockSizes[s]
                    var n = staleSuperblocks != nil ? UInt32(analyzed * (64 / size.w) * (64 / size.h)) : shTotal[s]
                    e.setComputePipelineState(pipeline)
                    e.setBytes(&n, length: 4, index: 2)
                    e.dispatchThreadgroups(MTLSize(width: (Int(n) + warps - 1) / warps, height: 1, depth: 1),
                                           threadsPerThreadgroup: MTLSize(width: warps * 32, height: 1, depth: 1))
                }
            }
            if profiling { stages.analysis += try close() }
            e = try open()
            e.memoryBarrier(scope: .buffers)
            let nSb = sbCols * sbRows
            let dpThreads = staleSuperblocks ?? nSb
            if dpThreads > 0 {
                e.setComputePipelineState(encoder.dp)
                e.dispatchThreads(MTLSize(width: dpThreads, height: 1, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: min(64, dpThreads), height: 1, depth: 1))
            }
            if decidesLeaves {
                if profiling { stages.partition = try close(); e = try open() }
                e.memoryBarrier(scope: .buffers)
                e.setComputePipelineState(encoder.leafScan)
                e.setBuffer(leafOffsets, offset: 0, index: 2)
                e.setBuffer(leafDispatch, offset: 0, index: 3)
                e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
                e.memoryBarrier(scope: .buffers)
                e.setComputePipelineState(encoder.leaf)
                e.dispatchThreadgroups(indirectBuffer: leafDispatch, indirectBufferOffset: 0,
                                       threadsPerThreadgroup: MTLSize(width: AV1MetalEncoder.leafThreads, height: 1, depth: 1))
            }
            if profiling {
                let t = try close()
                if decidesLeaves { stages.leaves = t } else { stages.partition = t }
            }
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
                if !wait { return c }
                c.waitUntilCompleted()
                if let error = c.error { throw Failure.metal("\(error)") }
                encoder.lastGPUSeconds = c.gpuEndTime - c.gpuStartTime
            } else {
                encoder.lastGPUSeconds = stages.analysis + stages.partition + stages.leaves + stages.closedLoop
            }
            stages.wall = CACurrentMediaTime() - t0
            encoder.lastStages = stages
            return nil
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

        func leafBlocks() -> ([av1g_block], [UInt8], [av1g_block_inter]) {
            var blocks: [av1g_block] = [], types: [UInt8] = [], inter: [av1g_block_inter] = []
            let interRes = interResults.contents().assumingMemoryBound(to: GpInterRes.self)
            let leafPtr = leaves.contents().assumingMemoryBound(to: GpLeaf.self)
            let results = blockResults.contents().assumingMemoryBound(to: GpBlockRes.self)
            let decisions = leafDecisions.contents().assumingMemoryBound(to: GpLeafDecision.self)
            let counts = leafCount.contents().assumingMemoryBound(to: UInt16.self)
            // SBs whose analysis was kept have last picture's blocks
            let cache = encoder.cache.flatMap { $0.blockResults === blockResults ? $0 : nil }
            let kept = cache?.keep.contents().assumingMemoryBound(to: UInt8.self)
            if let cache, cache.sbBlocks.count != sbCols * sbRows {
                cache.sbBlocks = Array(repeating: [], count: sbCols * sbRows)
                cache.sbTypes = Array(repeating: [], count: sbCols * sbRows)
                cache.sbInter = Array(repeating: [], count: sbCols * sbRows)
            }
            for sb in decodeOrder() {
                if let cache, let kept, kept[sb] != 0, !cache.sbBlocks[sb].isEmpty {
                    blocks += cache.sbBlocks[sb]
                    types += cache.sbTypes[sb]
                    if isInter {
                        let i = cache.sbInter[sb]
                        inter += i.count == cache.sbBlocks[sb].count ? i : Array(repeating: av1g_block_inter(), count: cache.sbBlocks[sb].count)
                    }
                    continue
                }
                let first = blocks.count
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
                    var bi = av1g_block_inter()
                    if isInter, size.w >= 8, size.h >= 8, interRes[Int(shapeOffset[s]) + li].isInter != 0 {
                        let m = interRes[Int(shapeOffset[s]) + li]
                        bi.is_inter = 1
                        bi.mv_row = m.dy * 8
                        bi.mv_col = m.dx * 8
                    } else if res.ncand > 0 {
                        let cand = Int(res.cand.0)
                        b.y_mode = UInt8(cand >> 3)
                        b.angle_delta_y = Int8((cand & 7) - 3)
                    }
                    if decidesLeaves {
                        let d = decisions[sb * Int(GP_MAX_LEAVES) + k]
                        b.uv_mode = d.uvMode
                        b.angle_delta_uv = d.angleUV
                        b.cfl_alpha_u = d.cflU
                        b.cfl_alpha_v = d.cflV
                    }
                    blocks.append(b)
                    types.append(bi.is_inter != 0 ? 0 : decidesLeaves ? decisions[sb * Int(GP_MAX_LEAVES) + k].lumaTx : (res.ncand > 0 ? res.tx : 0))
                    if isInter { inter.append(bi) }
                }
                if let cache {
                    cache.sbBlocks[sb] = Array(blocks[first...])
                    cache.sbTypes[sb] = Array(types[first...])
                    cache.sbInter[sb] = isInter ? Array(inter[first...]) : []
                }
            }
            return (blocks, types, inter)
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
