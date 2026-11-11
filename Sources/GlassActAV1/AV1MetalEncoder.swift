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
        /// With `dumpsTrainingData`: per SB (raster) GP_DP_DEBUG floats, as k_dp writes them.
        public var nodeCosts: [Float] = []
        /// With `dumpsTrainingData`: per analyzed shape (bsize), its grid and each block's best
        /// luma candidate (GpBlockRes.cand[0]: mode << 3 | delta + 3; 255: none).
        public var blockModes: [(shape: Int, columns: Int, rows: Int, modes: [UInt8])] = []
        /// The source the analysis read (`beginPartition`'s): Y, U and V padded to whole 64×64s
        /// by edge replication, rows `sourceStrides` apart. It's the encoder's until the next
        /// picture's partition is read, and then goes back to its pool (the picture after next
        /// reuses it), so the caller may read it until then.
        public var source: [any MTLBuffer] = []
        public var sourceStrides: [Int] = []
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
    let analysis: [Int: (pipeline: any MTLComputePipelineState, warps: Int, threads: Int)]
    /// The thread-per-block analysis kernels of the shapes up to 64 pixels.
    let analysisSmall: [Int: any MTLComputePipelineState]
    static let smallThreads = 128
    /// The largest shape (in pixels) the thread-per-block kernel takes: av1gpu's 64, and 8x16 / 16x8.
    static let smallMaxPixels = 128
    let dp: any MTLComputePipelineState
    let leaf: any MTLComputePipelineState, leafScan: any MTLComputePipelineState
    let leafSmall: any MTLComputePipelineState
    /// Inter frames' motion search: k_me, and per block size of 8×8 and up k_inter and its warps.
    let motionSearch: any MTLComputePipelineState, projectionSearch: any MTLComputePipelineState
    /// k_inter_sad: an SB's distinct inter candidates and its 8x8s' SAD at each, which k_inter sums.
    let candidateSAD: any MTLComputePipelineState
    /// k_inter_sad's tables (GpMeU and the SADs, per SB of the picture), kept across pictures: the
    /// kernel writes every entry k_inter reads, so they're neither cleared nor reallocated.
    private var interTables: (candidates: any MTLBuffer, sad: any MTLBuffer)?
    func interTables(superblocks n: Int) throws -> (candidates: any MTLBuffer, sad: any MTLBuffer) {
        let bytes = n * MemoryLayout<GpMeU>.stride, sadBytes = n * (1 + 16 * Int(GP_ME_KEEP)) * 64 * 2  // GP_ME_U per SB
        if let t = interTables, t.candidates.length >= bytes, t.sad.length >= sadBytes { return t }
        guard let c = device.makeBuffer(length: bytes, options: .storageModeShared),
              let s = device.makeBuffer(length: sadBytes, options: .storageModeShared)
        else { throw Failure.metal("no inter tables for \(n) SBs") }
        interTables = (c, s)
        return (c, s)
    }
    let inter: [Int: (pipeline: any MTLComputePipelineState, warps: Int, threads: Int)]
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
    /// With `searchesAngleDeltas`: search them only in an inter frame that
    /// codes (doesn't copy) at most this share of its superblocks; key frames
    /// and still pictures count as all coded. A picture that changes all over
    /// (a key frame, a full-screen change) then codes ~30 % faster at 5K for
    /// 0.3–1.7 % more of its bytes, and one that changes in places keeps them:
    /// whole streams +0.3 % at most (BENCHMARKS.md). 1: always. Superblocks kept
    /// from earlier pictures keep the analysis they had, either way.
    public var angleDeltasUpToShare = 0.5
    /// Superblocks kept from the previous picture in the last one.
    public private(set) var lastKeptSuperblocks = 0
    var cache: AnalysisCache?
    /// Padded source planes of partitions already waited on, for the next picture of the same
    /// geometry: making and clearing 22 MB of shared memory per 5K picture cost milliseconds.
    var sourcePool: [[any MTLBuffer]] = []
    /// Guards the source pool and `readEvent`: a picture's analysis is set up on one thread while
    /// the last one's is read on another.
    private let poolLock = NSLock()

    func takeSource(_ lengths: [Int]) throws -> [any MTLBuffer] {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let i = sourcePool.firstIndex(where: { $0.map(\.length) == lengths.map { max(16, $0) } }) {
            return sourcePool.remove(at: i)
        }
        // Untracked: the CPU writes a source before the analysis that reads it is committed, and
        // every GPU use only reads it (the next picture's motion search, the hybrid's filters),
        // so Metal needn't order those command buffers behind one another.
        return try lengths.map {
            guard let b = device.makeBuffer(length: max(16, $0), options: [.storageModeShared, .hazardTrackingModeUntracked])
            else { throw Failure.metal("no buffer of \($0) bytes") }
            return b
        }
    }

    /// Learned pruning's buffers (`Run.kept`), from picture to picture: the ML kernels write every
    /// entry they read, so they're neither made nor cleared again (29 MB a 5K picture, ~2 ms).
    private var mlScratch: [Int: any MTLBuffer] = [:]
    func mlBuffer(_ slot: Int, length: Int) throws -> any MTLBuffer {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let b = mlScratch[slot], b.length >= length { return b }
        guard let b = device.makeBuffer(length: max(16, length), options: .storageModeShared)
        else { throw Failure.metal("no buffer of \(length) bytes") }
        mlScratch[slot] = b
        return b
    }

    /// The padded source of the last partition waited on. The one before goes back to the pool:
    /// the analyses that read it (its own, and the next picture's motion search) are done.
    var lastSource: [any MTLBuffer]?
    func keepSource(_ planes: [any MTLBuffer]) {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let old = lastSource, sourcePool.count < 2 { sourcePool.append(old) }
        lastSource = planes
    }

    /// The padded source of the last analysis set up: the next inter frame's motion search
    /// predicts from it.
    var referenceSource: [any MTLBuffer]?

    /// The next inter frame's motion search predicts from this luma plane instead (padded as a
    /// source is): a decoded picture, for a frame that codes the same source again
    /// (`AV1HybridEncoder.encodeTwoSteps`). Only luma is read from a reference.
    func setReference(y: UnsafePointer<UInt8>, width: Int, height: Int) throws {
        let aw = ((2 * ((width + 7) >> 3) + 15) >> 4) * 64, ah = ((2 * ((height + 7) >> 3) + 15) >> 4) * 64
        let planes = try takeSource([aw * ah, aw / 2 * (ah / 2), aw / 2 * (ah / 2)])
        let d = planes[0].contents().assumingMemoryBound(to: UInt8.self)
        for row in 0..<ah {
            let line = d + row * aw, from = y + min(row, height - 1) * width
            line.update(from: from, count: width)
            (line + width).update(repeating: from[width - 1], count: aw - width)
        }
        referenceSource = planes
    }

    /// Orders pictures' analyses on the GPU behind the CPU's reading of the one before, which
    /// they overwrite (the cache's results): a picture's analysis is committed while the last one
    /// still runs, and its command buffer waits until the event reaches the last one's `seq`.
    let readEvent: any MTLSharedEvent
    /// Analyses set up so far (each Run's `seq`).
    var runCount: UInt64 = 0
    /// Run `seq`'s results are read (or never will be).
    func markRead(_ seq: UInt64) {
        poolLock.lock()
        defer { poolLock.unlock() }
        if readEvent.signaledValue < seq { readEvent.signaledValue = seq }
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
        let leafDecisions: any MTLBuffer, sbJ: any MTLBuffer
        /// An inter frame's analysis (GpInterRes, parallel to blockResults).
        let interResults: any MTLBuffer
        /// Per SB, whether its analysis is kept (`keep`), and the SBs to analyze (raster,
        /// staleCount of them: `stale`): two of each, alternating, as the last picture's analysis
        /// may still be reading its own while the next picture's are set.
        private let keeps: [any MTLBuffer], stales: [any MTLBuffer]
        private var flip = 0
        var keep: any MTLBuffer { keeps[flip] }
        var stale: any MTLBuffer { stales[flip] }
        var staleCount = 0
        var previous: [[UInt8]]? = nil
        /// The last picture's qindex per 64x64 (delta-q), or nil.
        var previousQ: [UInt8]? = nil
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
            keeps = [try make(nSb), try make(nSb)]
            stales = [try make(nSb * 4), try make(nSb * 4)]
        }

        /// Sets `keep` from the new source against the previous one, and remembers the new one.
        /// `skip` (per SB, raster): SBs the caller won't use the analysis of (an inter frame's
        /// copies), kept without analysis; one whose source changed keeps the source its analysis
        /// is of, so that a later picture analyzes it.
        func markUnchanged(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
                           width: Int, height: Int, sbCols: Int, sbRows: Int, skip: [UInt8]? = nil, sbQindex: [UInt8]? = nil) {
            // a 64x64 whose qindex changed is analyzed again, as one whose source did
            let qmap = sbQindex?.count == sbCols * sbRows ? sbQindex : nil
            defer { previousQ = qmap }
            let qChanged: (Int) -> Bool = { [previousQ] i in (qmap?[i] ?? 0) != (previousQ?[i] ?? 0) }
            flip ^= 1
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
            if let skip {
                // the mask decides: every SB not skipped is analyzed (and its source remembered, which
                // for an unchanged one changes nothing), with no comparison
                for i in changed.indices { changed[i] = skip[i] == 0 }
            }
            for (p, (pixels, w, h)) in planes.enumerated() where skip == nil {
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
            for i in changed.indices where qChanged(i) { changed[i] = true }
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
    func analysisCache(width: Int, height: Int, qindex: Int, shapeMask: Int32, blocks: Int, superblocks: Int) throws -> AnalysisCache? {
        guard reusesAnalysis else { cache = nil; return nil }
        var p = params
        var key = withUnsafeBytes(of: &p) { Array($0) }
        for v in [width, height, qindex, tiling.columnsLog2, tiling.rowsLog2, decidesLeaves ? 1 : 0,
                  Int(busyBlockPrune.bitPattern), searchesAngleDeltas ? 1 : 0, leafTxSearchPixels,
                  leafChromaAngledModes ? 1 : 0, Int(shapeMask)] {
            withUnsafeBytes(of: v) { key += $0 }
        }
        if let cache, cache.key == key { return cache }
        cache = try AnalysisCache(key: key, device: device, blocks: blocks, superblocks: superblocks)
        return cache
    }

    /// k_leaf's threadgroup: LEAF_NW (1) SIMD-groups, one leaf each at a time.
    static let leafThreads = 32
    /// k_leaf_small's threadgroup: a leaf a thread (k_leaf.h LEAF_SMALL_TG).
    static let leafSmallThreads = 32
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
    /// Inter frames' motion search refines vectors to quarter samples (off: whole
    /// samples). The frame must then allow them (av1g_frame_params.mv_precision 1).
    public var searchesSubpelMotion = false
    /// Tiles in 128×128-superblock units (the stream's are), so that the analysis's tiles are
    /// the bitstream's; the analysis itself stays 64×64.
    public var largeSuperblocks = false
    /// Inter frames search no intra modes for a block whose motion-compensated residual
    /// quantizes to nothing (libaom realtime's rule; on).
    public var interSkipsIntra = true
    /// > 0: inter frames cost no inter RD for a block whose best candidate's SAD passes this many
    /// times its SAD to its own mean (GpParams.interGate); 0: off.
    public var interGate: Float = 0
    /// The inter gate only in pictures coding more than this share of their superblocks.
    public var interGateOverShare = 0.5
    /// Inter frames' analysis effort (nil: `preset`'s): their intra blocks matter less, as
    /// most of the picture is copied or predicted from the previous one.
    public var interPreset: Preset?
    /// Inter frames coding more than `interGateOverShare` of their superblocks analyze only these
    /// shapes (GpParams.shapeMask bits; nil: their preset's). Fewer shapes cost a little more of
    /// such a picture's bytes for less analysis (BENCHMARKS "fewer shapes in mostly new pictures").
    public var newPictureShapeMask: Int32?
    let recon: any MTLComputePipelineState
    let mlStats: any MTLComputePipelineState, mlCell: any MTLComputePipelineState
    let mlTree: any MTLComputePipelineState, mlList: any MTLComputePipelineState, mlMode: any MTLComputePipelineState
    var params: GpParams

    /// Learned pruning of the analysis (k_ml.h). A small network per 8×8
    /// cell, trained offline on the full search's choices
    /// (rust/av1/examples/prune_train.rs), says which tree level the search
    /// will choose; the cell keeps its likeliest levels until all but `eps` of
    /// the probability is kept, and the analysis skips the shapes of levels no
    /// cell of a node keeps (repaired so each cell's levels stay reachable).
    /// The variance rule then stands aside. A second network per node (with
    /// its gradients' orientations) picks the luma modes the node's blocks
    /// screen, of the 13. Only in pictures of at least
    /// `learnedPruneMinSuperblocks` that code more than `overShare` of their
    /// superblocks (key frames count as all). Retrain with scripts/train-pruner
    /// (BENCHMARKS.md has what each model buys). nil: off (the hybrid encoder
    /// turns it on).
    public var learnedPrune: LearnedPrune? {
        didSet {
            func buffer(_ w: [Float]) -> (any MTLBuffer)? {
                w.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            }
            mlWeights = learnedPrune.flatMap { buffer($0.levelWeights) }
            mlModeWeights = learnedPrune?.modeWeights.flatMap { buffer($0) }
            mlChromaWeights = learnedPrune?.chromaWeights.flatMap { buffer($0) }
        }
    }
    /// The learned pruning's models and settings (k_ml.h; AV1PrunerWeights has the shipped ones).
    public struct LearnedPrune: Sendable {
        /// The level model (ML_FLOATS): which tree levels each 8×8 cell keeps.
        public var levelWeights: [Float]
        /// A cell keeps its likeliest levels until all but this much probability is kept.
        public var eps: Float
        /// The mode model (ML_MODE_FLOATS), or nil: every node's blocks screen all 13 modes.
        public var modeWeights: [Float]?
        /// A node keeps its likeliest modes until all but this much probability is kept.
        public var modeEps: Float
        /// The chroma model (ML_CHROMA_FLOATS), or nil: every leaf screens all its chroma modes, and CfL.
        public var chromaWeights: [Float]?
        /// A leaf keeps its likeliest chroma modes (and CfL) until all but this much is kept.
        public var chromaEps: Float
        /// Only in pictures coding more than this share of their superblocks, or (with
        /// `minCoded`) at least that many of them.
        public var overShare: Double
        public var minCoded: Int?
        public init(levelWeights: [Float], eps: Float, modeWeights: [Float]?, modeEps: Float,
                    chromaWeights: [Float]? = nil, chromaEps: Float = 0.02, overShare: Double, minCoded: Int? = nil) {
            (self.levelWeights, self.eps, self.modeWeights, self.modeEps) = (levelWeights, eps, modeWeights, modeEps)
            (self.chromaWeights, self.chromaEps, self.overShare, self.minCoded) = (chromaWeights, chromaEps, overShare, minCoded)
        }
    }
    var mlWeights: (any MTLBuffer)?, mlModeWeights: (any MTLBuffer)?, mlChromaWeights: (any MTLBuffer)?
    /// Learned pruning's least picture: 1440p (920 superblocks) and up, where
    /// it takes 8–22 % off the GPU's analysis at the same bytes (±0.3 %). At
    /// 1080p it costs up to 0.7 % of bytes for less (BENCHMARKS "learned
    /// pruning's statistics in one pass").
    public var learnedPruneMinSuperblocks = 900
    /// Training data for the learned pruning (`glassact-bench av1seq --dump-partition`):
    /// `partition` also returns the DP's per-node costs and every analyzed block's best mode.
    public var dumpsTrainingData = false
    /// GPU time of the last picture's command buffer (analysis, DP, closed loop).
    public private(set) var lastGPUSeconds: Double = 0

    /// The last picture's GPU time by stage (when `profilesStages` is on), and
    /// its wall-clock time from the first dispatch to the last completion.
    public struct StageTimes: Sendable {
        public var analysis = 0.0, partition = 0.0, closedLoop = 0.0, wall = 0.0
        /// When profiling an inter frame: the motion search (k_proj and k_me) and the inter
        /// candidates (k_inter, every shape), in seconds; not in `analysis`.
        public var motionSearch = 0.0, interSearch = 0.0
        /// Closed-loop dispatches that must run one after another.
        public var wavefrontSteps = 0
        /// When profiling: each block shape's analysis (by bsize) and the leaf decisions, in seconds.
        public var shapes: [Int: Double] = [:]
        public var leaves = 0.0
        /// When profiling a picture with learned pruning: its network and fix-up, in seconds.
        public var mlPrune = 0.0
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
        guard let readEvent = device.makeSharedEvent() else { throw Failure.metal("no shared event") }
        self.readEvent = readEvent
        let library = try AV1ShaderSource.library(
            AV1ShaderSource.sourceRoot.appending(path: "GlassActAV1/Shaders/encoder.metal"), device: device)
        var analysis: [Int: (pipeline: any MTLComputePipelineState, warps: Int, threads: Int)] = [:]
        for (bsize, size) in Self.blockSizes.enumerated() where size.w > 0 {
            // k_analysis_<W>x<H>_w<NW>: NW blocks a threadgroup, a SIMD-group each; or _w1t<NT>: a
            // block a threadgroup, on NT threads
            let prefix = "k_analysis_\(size.w)x\(size.h)_w"
            guard let name = library.functionNames.first(where: { $0.hasPrefix(prefix) }) else { throw Failure.metal("no \(prefix)…") }
            let parts = name.dropFirst(prefix.count).split(separator: "t").compactMap { Int($0) }
            guard let warps = parts.first, let function = library.makeFunction(name: name) else { throw Failure.metal("no \(prefix)…") }
            let perBlock = parts.count > 1 ? parts[1] : 32
            analysis[bsize] = (try Self.pipeline(function, threads: warps * perBlock, device: device), warps, warps * perBlock)
        }
        self.analysis = analysis
        var inter: [Int: (pipeline: any MTLComputePipelineState, warps: Int, threads: Int)] = [:]
        for (bsize, size) in Self.blockSizes.enumerated() where size.w >= 8 && size.h >= 8 {
            let prefix = "k_inter_\(size.w)x\(size.h)_w"  // as k_analysis's names
            guard let name = library.functionNames.first(where: { $0.hasPrefix(prefix) }) else { throw Failure.metal("no \(prefix)…") }
            let parts = name.dropFirst(prefix.count).split(separator: "t").compactMap { Int($0) }
            guard let warps = parts.first, let function = library.makeFunction(name: name) else { throw Failure.metal("no \(prefix)…") }
            let perBlock = parts.count > 1 ? parts[1] : 32
            inter[bsize] = (try Self.pipeline(function, threads: warps * perBlock, device: device), warps, warps * perBlock)
        }
        self.inter = inter
        guard let meFunction = library.makeFunction(name: "k_me"), let projFunction = library.makeFunction(name: "k_proj")
        else { throw Failure.metal("no k_me / k_proj") }
        motionSearch = try Self.pipeline(meFunction, threads: 128, device: device)
        guard let sadFunction = library.makeFunction(name: "k_inter_sad") else { throw Failure.metal("no k_inter_sad") }
        candidateSAD = try Self.pipeline(sadFunction, threads: 128, device: device)
        projectionSearch = try Self.pipeline(projFunction, threads: 256, device: device)
        var small: [Int: any MTLComputePipelineState] = [:]
        for (bsize, size) in Self.blockSizes.enumerated() where size.w > 0 && size.w * size.h <= Self.smallMaxPixels {
            guard let function = library.makeFunction(name: "k_analysis_small_\(size.w)x\(size.h)")
            else { throw Failure.metal("no k_analysis_small_\(size.w)x\(size.h)") }
            small[bsize] = try Self.pipeline(function, threads: Self.smallThreads, device: device)
        }
        analysisSmall = small
        guard let leafFunction = library.makeFunction(name: "k_leaf"),
              let leafSmallFunction = library.makeFunction(name: "k_leaf_small"),
              let leafScanFunction = library.makeFunction(name: "k_leaf_scan")
        else { throw Failure.metal("no k_leaf") }
        leafScan = try Self.pipeline(leafScanFunction, threads: 1024, device: device)
        leafSmall = try Self.pipeline(leafSmallFunction, threads: Self.leafSmallThreads, device: device)
        leaf = try Self.pipeline(leafFunction, threads: Self.leafThreads, device: device)
        let ml = try ["k_ml_stats", "k_ml_cell", "k_ml_tree", "k_ml_list", "k_ml_mode"].map { name in
            guard let f = library.makeFunction(name: name) else { throw Failure.metal("no \(name)") }
            return try Self.pipeline(f, threads: 64, device: device)
        }
        (mlStats, mlCell, mlTree, mlList, mlMode) = (ml[0], ml[1], ml[2], ml[3], ml[4])
        guard let dpFunction = library.makeFunction(name: "k_dp"),
              let reconFunction = library.makeFunction(name: "k_recon")
        else { throw Failure.metal("no k_dp / k_recon") }
        dp = try Self.pipeline(dpFunction, threads: 128, device: device)
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
        var part = Partition(blocks: blocks, lumaTxTypes: types, hasChroma: run.decidesLeaves, tiles: run.tiles, inter: inter)
        if let b = run.nodeCostBuffer {
            part.nodeCosts = Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: Float.self), count: b.length / 4))
            let results = run.blockResults.contents().assumingMemoryBound(to: GpBlockRes.self)
            for s in 0..<Int(GP_NSHAPES) where run.shapeColumns[s] > 0 {
                let columns = Int(run.shapeColumns[s]), count = Int(run.shTotal[s])
                let modes = (0..<count).map { k -> UInt8 in
                    let r = results[Int(run.shapeOffset[s]) + k]
                    return r.ncand > 0 ? r.cand.0 : 255
                }
                part.blockModes.append((s, columns, count / columns, modes))
            }
        }
        return part
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
                AV1HybridEncoder.trace("analysis gpu \(String(format: "%.3f %.3f", commands.gpuStartTime * 1000, commands.gpuEndTime * 1000))")
                run.encoder.lastStages = stages
                run.encoder.lastGPUSeconds = stages.analysis
            } else if !run.encoder.profilesStages {
                run.encoder.lastGPUSeconds = 0  // every SB kept: no GPU work
            }
            let (blocks, types, inter) = run.leafBlocks()
            let source = run.source
            if !run.source.isEmpty {  // the GPU is done with it (or never used it)
                run.encoder.keepSource(run.source)
                run.source = []
            }
            return Partition(blocks: blocks, lumaTxTypes: types, hasChroma: run.decidesLeaves, tiles: run.tiles, inter: inter,
                             source: source, sourceStrides: [run.aw, run.aw / 2, run.aw / 2])
        }
    }

    /// Starts `partition` without waiting for it. (With `profilesStages` on,
    /// the stages run to completion first.)
    /// `skip` (per 64×64, raster; with `reusesAnalysis`): superblocks the caller replaces,
    /// which aren't analyzed and come back as one 64×64 block each.
    /// `motion` (an inter frame's shift candidates, (dx, dy) pairs): search for motion
    /// from the last picture waited on, of the same size (its source); the partition
    /// then mixes inter blocks with intra ones (`Partition.inter`).
    public func beginPartition(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
                               width: Int, height: Int, qindex: Int, skip: [UInt8]? = nil,
                               motion: [Int32]? = nil, sbQindex: [UInt8]? = nil) throws -> PendingPartition {
        let run = try Run(encoder: self, y: y, u: u, v: v, width: width, height: height, qindex: qindex, closedLoop: false,
                          skip: skip, motion: motion, sbQindex: sbQindex)
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
        /// The list of every SB's leaves and the leaf kernels' indirect dispatches (k_leaf_small's,
        /// then k_leaf's), and the leaves k_leaf_small leaves to k_leaf.
        let leafOffsets: any MTLBuffer, leafDispatch: any MTLBuffer, leafRest: any MTLBuffer
        let decidesLeaves: Bool
        /// SBs the caller replaces (`beginPartition(skip:)`): the partition gives each one block.
        let skipped: [UInt8]?
        /// Learned pruning's buffers, when this picture uses it: per-8x8 skip flags (4 levels),
        /// node statistics (per level from `mlBases`), the cells' kept levels, the small shapes'
        /// lists and their counts.
        var mlMask: (any MTLBuffer)?
        var mlStatsBuffer: (any MTLBuffer)?, mlKeep: (any MTLBuffer)?, mlListBuffer: (any MTLBuffer)?, mlCounts: (any MTLBuffer)?
        var mlBases: [UInt32] = []
        /// The mode model's per-node masks (from `mlModeBases` per level), when it runs.
        var mlModes: (any MTLBuffer)?
        var mlModeBases: [UInt32] = []
        /// `dumpsTrainingData`: the DP's per-node costs (GP_DP_DEBUG floats per SB).
        var nodeCostBuffer: (any MTLBuffer)?
        var shapeOffset = [UInt32](repeating: 0, count: Int(GP_NSHAPES)), shapeColumns = [Int32](repeating: 0, count: Int(GP_NSHAPES))
        /// Wavefront steps: superblocks whose left and above-right neighbours are done.
        var steps: [[UInt32]] = []
        /// This analysis's place in the encoder's order (`readEvent`).
        let seq: UInt64
        /// The cache it keeps results in, and its SBs' kept flags (the cache's `keep` then).
        let cacheRef: AnalysisCache?
        let keptFlags: (any MTLBuffer)?

        /// With `closedLoop` false the closed loop's buffers (reconstruction,
        /// maps, contexts, outputs, scratch) are left out: a partition needs none.
        init(encoder: AV1MetalEncoder, y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
             width: Int, height: Int, qindex: Int, closedLoop: Bool = true, skip: [UInt8]? = nil,
             motion: [Int32]? = nil, sbQindex: [UInt8]? = nil) throws {
            self.encoder = encoder
            encoder.runCount += 1
            seq = encoder.runCount
            self.width = width
            self.height = height
            self.qindex = qindex
            skipped = skip
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
            // one of learned pruning's buffers, kept by the encoder (its next picture's analysis waits
            // on the GPU until this one's is read: readEvent)
            func kept(_ slot: Int, _ length: Int) throws -> any MTLBuffer {
                let b = try encoder.mlBuffer(slot, length: length)
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
            guard av1g_tile_layout_ex(UInt32(width), UInt32(height), Int32(encoder.tiling.columnsLog2),
                                      Int32(encoder.tiling.rowsLog2), encoder.largeSuperblocks ? 1 : 0, &tl) == AV1G_OK
            else { throw Failure.metal("tile layout \(encoder.tiling) for \(width)×\(height)") }

            var image = GpImage()
            image.W = Int32(width); image.H = Int32(height)
            image.MiCols = Int32(miCols); image.MiRows = Int32(miRows)
            image.sbCols = Int32(sbCols); image.sbRows = Int32(sbRows)
            image.baseQ = Int32(qindex)
            // delta-q: the analysis's λ per 64x64 from the picture's map (`sbQindex`)
            if let map = sbQindex, map.count == sbCols * sbRows {
                let q = try make(map.count)
                map.withUnsafeBytes { q.contents().copyMemory(from: $0.baseAddress!, byteCount: map.count) }
                image.sbQ = AV1MetalEncoder.address(q)
            }
            image.qctx = qindex <= 20 ? 0 : qindex <= 60 ? 1 : qindex <= 120 ? 2 : 3
            image.qm = (15, 15, 15)
            image.aw = Int32(aw); image.ah = Int32(ah)
            image.src = (AV1MetalEncoder.address(src[0]), AV1MetalEncoder.address(src[1]), AV1MetalEncoder.address(src[2]))
            image.spitch = (Int32(aw), Int32(aw / 2), Int32(aw / 2))
            image.rec = (AV1MetalEncoder.address(rec[0]), AV1MetalEncoder.address(rec[1]), AV1MetalEncoder.address(rec[2]))
            image.rpitch = image.spitch
            // learned pruning: in a picture that codes enough of itself (key frames: all)
            let codedSBs = skip.map { m in m.count(where: { $0 == 0 }) } ?? sbCols * sbRows
            let coded = Double(codedSBs) / Double(max(1, skip?.count ?? sbCols * sbRows))
            if let lp = encoder.learnedPrune, encoder.mlWeights != nil,
               coded > lp.overShare || lp.minCoded.map({ codedSBs >= $0 }) == true,
               sbCols * sbRows >= encoder.learnedPruneMinSuperblocks {
                let mask = try kept(0, aw / 8 * (ah / 8) * 4)
                mlMask = mask
                image.mlSkip = AV1MetalEncoder.address(mask)
                image.cols8 = Int32(aw / 8)
                var base: UInt32 = 0, nodes: UInt32 = 0
                for level in 0..<4 {
                    let n = 8 << level
                    mlBases.append(base)
                    mlModeBases.append(nodes)
                    base += UInt32((width / n) * (height / n) * 16)  // ML_STRIDE floats a node
                    nodes += UInt32((width / n) * (height / n))
                }
                mlStatsBuffer = try kept(1, Int(max(base, 1)) * 4)
                if let chroma = encoder.mlChromaWeights {
                    made.append(chroma)
                    image.mlChroma = AV1MetalEncoder.address(chroma)
                    image.mlChromaEps = lp.chromaEps
                }
                if encoder.mlModeWeights != nil {
                    let modes = try kept(2, Int(max(nodes, 1)) * 2)
                    mlModes = modes
                    image.mlModes = AV1MetalEncoder.address(modes)
                    image.mlModeBase = (mlModeBases[0], mlModeBases[1], mlModeBases[2], mlModeBases[3])
                }
                mlKeep = try kept(3, aw / 8 * (ah / 8))
                mlCounts = try make(Int(GP_NSHAPES) * 4)
            }
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

            // an inter frame: motion from the last picture's source (padded the same way)
            let last = motion == nil ? nil : encoder.referenceSource.flatMap { last in
                last.map(\.length) == src.map(\.length) && last[0] !== src[0] ? last : nil
            }
            // analysis grids: every enabled shape over the coded area (inter frames': interPreset's)
            let newPicture = skipped != nil && encoder.newPictureShapeMask != nil
                && Double(skipped?.count(where: { $0 == 0 }) ?? 1) > encoder.interGateOverShare * Double(max(1, skipped?.count ?? 1))
            let shapeMask = newPicture ? encoder.newPictureShapeMask!
                : last != nil ? encoder.interPreset.map { AV1MetalEncoder.params(for: $0).shapeMask } ?? encoder.params.shapeMask
                : encoder.params.shapeMask
            var nbx = [Int32](repeating: 0, count: Int(GP_NSHAPES)), nby = nbx
            var shOff = [UInt32](repeating: 0, count: Int(GP_NSHAPES))
            var blkTotal: UInt32 = 0
            for s in 0..<Int(GP_NSHAPES) {
                shOff[s] = blkTotal
                let size = AV1MetalEncoder.blockSizes[s]
                guard size.w > 0, (shapeMask >> s) & 1 != 0 else { continue }
                nbx[s] = Int32((miCols * 4 + size.w - 1) / size.w)
                nby[s] = Int32((miRows * 4 + size.h - 1) / size.h)
                shTotal[s] = UInt32(nbx[s] * nby[s])
                blkTotal += shTotal[s]
            }
            if let motion, let last {
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
                image.meSb = AV1MetalEncoder.address(try make(sbCols * sbRows * 4))
                let tables = try encoder.interTables(superblocks: sbCols * sbRows)
                made += [tables.candidates, tables.sad]
                image.meU = AV1MetalEncoder.address(tables.candidates)
                image.meSad = AV1MetalEncoder.address(tables.sad)
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
            let cache = try encoder.analysisCache(width: width, height: height, qindex: qindex, shapeMask: shapeMask, blocks: Int(blkTotal),
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
            leafDispatch = try make(2 * MemoryLayout<MTLDispatchThreadgroupsIndirectArguments>.stride)
            leafRest = try make(4 * nSb * Int(GP_MAX_LEAVES))
            let sbJ = try cache.map { keep($0.sbJ) } ?? make(nSb * 4)
            var sbKeep: (any MTLBuffer)?, sbList: (any MTLBuffer)?
            if let cache {
                cache.markUnchanged(y: y, u: u, v: v, width: width, height: height,
                                    sbCols: (miCols + 15) >> 4, sbRows: (miRows + 15) >> 4,
                                    skip: skip?.count == ((miCols + 15) >> 4) * ((miRows + 15) >> 4) ? skip : nil,
                                    sbQindex: sbQindex)
                sbKeep = keep(cache.keep)
                sbList = keep(cache.stale)
            }
            staleSuperblocks = cache?.staleCount
            keptSuperblocks = cache?.keptCount ?? 0
            cacheRef = cache
            keptFlags = sbKeep
            encoder.referenceSource = src
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
            if let counts = mlCounts {
                let list = try kept(4, Int(max(blkTotal, 1)) * 4)
                mlListBuffer = list
                batch.mlList = AV1MetalEncoder.address(list)
                batch.mlCount = AV1MetalEncoder.address(counts)
            }
            if encoder.dumpsTrainingData {
                let debug = try make(sbCols * sbRows * Int(GP_DP_DEBUG) * 4)
                nodeCostBuffer = debug
                batch.dpDebug = AV1MetalEncoder.address(debug)
            }
            tiles = tl
            buffers = made
        }

        // (a run whose results are never read mustn't hold up the next picture's)
        deinit { encoder.markRead(seq) }

        /// Encodes the stages. With `wait` false (and no profiling), returns the
        /// committed command buffer instead of waiting for it.
        @discardableResult
        func execute(closedLoop: Bool, wait: Bool = true) throws -> (any MTLCommandBuffer)? {
            let profiling = encoder.profilesStages
            var stages = StageTimes()
            stages.wavefrontSteps = closedLoop ? steps.count : 0
            var commands: (any MTLCommandBuffer)?
            var compute: (any MTLComputeCommandEncoder)?
            var params = isInter && encoder.interPreset != nil ? AV1MetalEncoder.params(for: encoder.interPreset!) : encoder.params
            params.leafDecide = decidesLeaves ? 1 : 0
            params.pruneVar = mlMask != nil ? 0 : encoder.busyBlockPrune
            // the share of the picture coded (not copied): the same with kept analysis as without
            let codedShare = skipped.map { m in Double(m.count(where: { $0 == 0 })) / Double(max(1, m.count)) } ?? 1
            if !encoder.searchesAngleDeltas || codedShare > encoder.angleDeltasUpToShare { params.deltas = 0; params.uvDeltas = 0 }
            // (an inter frame has copies decided, with or without a motion search)
            if skipped != nil, codedShare > encoder.interGateOverShare, let m = encoder.newPictureShapeMask { params.shapeMask = m }
            // the inter gate where most of the picture is new (a switch of Spaces, apps or windows)
            params.interGate = codedShare > encoder.interGateOverShare ? encoder.interGate : 0
            params.leafTxSearch = Int32(encoder.leafTxSearchPixels)
            params.leafChromaAngled = encoder.leafChromaAngledModes ? 1 : 0
            params.meSubpel = encoder.searchesSubpelMotion ? 1 : 0
            params.interSkipsIntra = encoder.interSkipsIntra ? 1 : 0
            func open() throws -> any MTLComputeCommandEncoder {
                if let compute { return compute }
                guard let c = encoder.queue.makeCommandBuffer() else { throw Failure.metal("no command buffer") }
                // the last picture's results, which this one's overwrite, are read
                if seq > 1 { c.encodeWaitForEvent(encoder.readEvent, value: seq - 1) }
                guard let e = c.makeComputeCommandEncoder(dispatchType: .concurrent) else { throw Failure.metal("no command encoder") }
                c.label = "AV1 analysis"  // for Instruments
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
                if wait { encoder.lastGPUSeconds = 0 }
                return nil
            }
            let t0 = CACurrentMediaTime()
            var e = try open()
            // the shapes the thread-per-block kernel takes (the analysis loop below decides the same):
            // in an inter frame, not those of 64 samples and up (below), but those up to 128 (8x8, 8x16,
            // 16x8) where most of the picture is new, which few blocks skip the intra search of (5K:
            // 8x8 3.2 -> 2.0 ms; photos' 8x16 and 16x8 5.3 -> 3.6)
            let newPicture = isInter && codedShare > encoder.interGateOverShare
            func takesSIMDGroup(_ size: (w: Int, h: Int), _ n: Int) -> Bool {
                isInter && (n < 4096 || (size.w * size.h >= 64 && !(newPicture && size.w * size.h <= 128)))
            }
            func smallKernel(_ s: Int) -> Bool {
                guard shTotal[s] > 0, params.smallKernel != 0, encoder.analysisSmall[s] != nil else { return false }
                let size = AV1MetalEncoder.blockSizes[s]
                let n = staleSuperblocks.map { $0 * (64 / size.w) * (64 / size.h) } ?? Int(shTotal[s])
                return n > 0 && !takesSIMDGroup(size, n)
            }
            let analyzed = staleSuperblocks ?? (sbCols * sbRows)
            if isInter, analyzed > 0 {  // long-range motion per SB, then per 16x16, alongside the analysis
                var sbs = UInt32(analyzed)
                e.setComputePipelineState(encoder.projectionSearch)
                e.setBytes(&sbs, length: 4, index: 2)
                e.dispatchThreadgroups(MTLSize(width: analyzed, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                e.memoryBarrier(scope: .buffers)
                var cells = UInt32(analyzed * 16)
                e.setComputePipelineState(encoder.motionSearch)
                e.setBytes(&cells, length: 4, index: 2)
                e.dispatchThreadgroups(MTLSize(width: (Int(cells) + 3) / 4, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
                e.memoryBarrier(scope: .buffers)
                e.setComputePipelineState(encoder.candidateSAD)  // the SB's candidates, its 8x8s' SADs
                e.dispatchThreadgroups(MTLSize(width: analyzed, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
                if profiling {
                    stages.motionSearch = try close()
                    e = try open()
                }
            }
            if isInter, analyzed > 0 {  // the inter candidates, which the intra analysis then weighs
                e.memoryBarrier(scope: .buffers)
                for s in 0..<Int(GP_NSHAPES) where shTotal[s] > 0 {
                    guard let (pipeline, warps, threads) = encoder.inter[s] else { continue }
                    let size = AV1MetalEncoder.blockSizes[s]
                    var n = staleSuperblocks != nil ? UInt32(analyzed * (64 / size.w) * (64 / size.h)) : shTotal[s]
                    e.setComputePipelineState(pipeline)
                    e.setBytes(&n, length: 4, index: 2)
                    e.dispatchThreadgroups(MTLSize(width: (Int(n) + warps - 1) / warps, height: 1, depth: 1),
                                           threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
                }
                if profiling {
                    stages.interSearch = try close()
                    e = try open()
                }
            }
            if isInter, analyzed > 0 { e.memoryBarrier(scope: .buffers) }
            if let mask = mlMask, let weights = encoder.mlWeights, let lp = encoder.learnedPrune,
               let stats = mlStatsBuffer, let keepBuffer = mlKeep, let counts = mlCounts {
                // learned pruning: node statistics, the cells' network, each SB's skip flags (repaired),
                // then the small shapes' lists (k_ml.h); after an inter frame's motion search and inter
                // candidates, whose results the lists read
                func threads(_ n: Int) -> (MTLSize, MTLSize) { (MTLSize(width: max(n, 1), height: 1, depth: 1), MTLSize(width: 64, height: 1, depth: 1)) }
                // with kept analysis, the passes cover the stale list's SBs only (B.sbList): `per`
                // items an SB, or the whole picture's `all`
                let stale = staleSuperblocks
                func items(_ per: Int, all: Int) -> Int { stale.map { $0 * per } ?? all }
                e.setComputePipelineState(encoder.mlStats)
                e.setBuffer(stats, offset: 0, index: 3)
                e.setBytes(mlBases, length: 16, index: 4)
                e.dispatchThreadgroups(MTLSize(width: max(1, items(1, all: sbCols * sbRows)), height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                e.memoryBarrier(scope: .buffers)
                if let modes = mlModes, let modeWeights = encoder.mlModeWeights {
                    // each whole node's modes, beside the cells' network
                    var modeEps = lp.modeEps
                    e.setComputePipelineState(encoder.mlMode)
                    e.setBuffer(stats, offset: 0, index: 3)
                    e.setBuffer(modeWeights, offset: 0, index: 5)
                    e.setBytes(&modeEps, length: 4, index: 7)
                    e.setBuffer(modes, offset: 0, index: 10)
                    for level in 0..<4 {
                        var lv = UInt32(level), base = mlBases[level]
                        let n = 8 << level
                        e.setBytes(&lv, length: 4, index: 2)
                        e.setBytes(&base, length: 4, index: 4)
                        let (g, t) = threads(items((8 >> level) * (8 >> level), all: (width / n) * (height / n)))
                        e.dispatchThreads(g, threadsPerThreadgroup: t)
                    }
                }
                var eps = lp.eps
                e.setComputePipelineState(encoder.mlCell)
                e.setBytes(mlBases, length: 16, index: 4)
                e.setBuffer(weights, offset: 0, index: 5)
                e.setBuffer(keepBuffer, offset: 0, index: 6)
                e.setBytes(&eps, length: 4, index: 7)
                e.setBuffer(counts, offset: 0, index: 8)
                let (gc, tc) = threads(max(items(64, all: aw / 8 * (ah / 8)), Int(GP_NSHAPES)))
                e.dispatchThreads(gc, threadsPerThreadgroup: tc)
                e.memoryBarrier(scope: .buffers)
                e.setComputePipelineState(encoder.mlTree)
                e.setBuffer(mask, offset: 0, index: 9)
                let (gt, tt) = threads(items(1, all: sbCols * sbRows))
                e.dispatchThreads(gt, threadsPerThreadgroup: tt)
                e.memoryBarrier(scope: .buffers)
                e.setComputePipelineState(encoder.mlList)
                for s in 0..<Int(GP_NSHAPES) where mlListBuffer != nil && smallKernel(s) {
                    var bs = UInt32(s)
                    e.setBytes(&bs, length: 4, index: 2)
                    let size = AV1MetalEncoder.blockSizes[s]
                    let (g, t) = threads(items((64 / size.w) * (64 / size.h), all: Int(shTotal[s])))
                    e.dispatchThreads(g, threadsPerThreadgroup: t)
                }
                e.memoryBarrier(scope: .buffers)
                if profiling { stages.mlPrune = try close(); e = try open() }
            }
            for s in 0..<Int(GP_NSHAPES) where shTotal[s] > 0 {
                var n = shTotal[s]
                if let stale = staleSuperblocks {  // only the listed SBs' blocks
                    let size = AV1MetalEncoder.blockSizes[s]
                    n = UInt32(stale * (64 / size.w) * (64 / size.h))
                    if n == 0 { continue }
                }
                // the thread-per-block kernel has the throughput, but one block's chain of work on
                // one thread takes ~1.5 ms: an inter frame analyzing little takes the SIMD-group one
                // (whose float sums may order differently: kept analysis of a key frame stays the
                // thread kernel, and so the same as fresh analysis). An inter frame's blocks of 64
                // samples and up take it too: where inter prediction leaves nothing to code, a block
                // skips the intra search, and a thread-per-block SIMD-group then waits on its
                // slowest block (8x8 to 16x8 3-6x slower there; BENCHMARKS)
                let size = AV1MetalEncoder.blockSizes[s]
                let fewBlocks = takesSIMDGroup(size, Int(n))
                if params.smallKernel != 0, !fewBlocks, let pipeline = encoder.analysisSmall[s] {
                    if mlListBuffer != nil { n = shTotal[s] }  // the list's count bounds it
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
                guard let (pipeline, warps, threads) = encoder.analysis[s] else { continue }
                e.setComputePipelineState(pipeline)
                e.setBytes(&n, length: 4, index: 2)
                e.dispatchThreadgroups(MTLSize(width: (Int(n) + warps - 1) / warps, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
                if profiling {
                    let t = try close()
                    stages.shapes[s] = t
                    stages.analysis += t
                    e = try open()
                }
            }
            if profiling { stages.analysis += try close() }
            e = try open()
            e.memoryBarrier(scope: .buffers)
            let nSb = sbCols * sbRows
            let dpThreads = staleSuperblocks ?? nSb
            if dpThreads > 0 {
                e.setComputePipelineState(encoder.dp)  // a SIMD-group per SB, 4 to a threadgroup
                e.dispatchThreadgroups(MTLSize(width: (dpThreads + 3) / 4, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
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
                e.setComputePipelineState(encoder.leafSmall)  // a leaf a thread; it lists the rest
                e.setBuffer(leafRest, offset: 0, index: 4)
                e.dispatchThreadgroups(indirectBuffer: leafDispatch, indirectBufferOffset: 0,
                                       threadsPerThreadgroup: MTLSize(width: AV1MetalEncoder.leafSmallThreads, height: 1, depth: 1))
                e.memoryBarrier(scope: .buffers)
                e.setComputePipelineState(encoder.leaf)  // a SIMD-group per leaf of the rest
                e.dispatchThreadgroups(indirectBuffer: leafDispatch,
                                       indirectBufferOffset: MemoryLayout<MTLDispatchThreadgroupsIndirectArguments>.stride,
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
            let cache = cacheRef
            let kept = keptFlags?.contents().assumingMemoryBound(to: UInt8.self)
            defer { encoder.markRead(seq) }
            if let cache, cache.sbBlocks.count != sbCols * sbRows {
                cache.sbBlocks = Array(repeating: [], count: sbCols * sbRows)
                cache.sbTypes = Array(repeating: [], count: sbCols * sbRows)
                cache.sbInter = Array(repeating: [], count: sbCols * sbRows)
            }
            for sb in decodeOrder() {
                if let skipped, skipped.count == sbCols * sbRows, skipped[sb] != 0 {
                    // the caller replaces it: one block at its origin stands for it
                    var b = av1g_block()
                    (b.mi_row, b.mi_col, b.bsize) = (UInt16((sb / sbCols) * 16), UInt16((sb % sbCols) * 16), UInt8(AV1G_BLOCK_64X64))
                    blocks.append(b)
                    types.append(0)
                    if isInter { inter.append(av1g_block_inter()) }
                    continue
                }
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
                        bi.mv_row = m.dy
                        bi.mv_col = m.dx
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
            defer { encoder.markRead(seq) }
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
