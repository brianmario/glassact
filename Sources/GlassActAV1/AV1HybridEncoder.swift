public import AV1Core
internal import AV1Encoder
internal import Foundation
public import Metal
internal import QuartzCore

/// av1gpu's AV1 intra encoder split between the GPU and the CPU (research):
/// the GPU's analysis and partition DP decide each block's size and luma
/// mode; the CPU decides chroma and runs the closed loop (exact prediction,
/// quantization, reconstruction) through av1core's writer, tiles on
/// parallel threads; the GPU chooses the loop-filter strengths and filters;
/// av1core writes the bitstream.
///
/// The closed loop is a chain of dependent blocks, which a CPU core runs far
/// faster than a GPU threadgroup does (BENCHMARKS.md, "Where the Metal AV1
/// encoder's time goes"); the analysis is wide and parallel, which suits the
/// GPU. A sequence overlaps picture i + 1's analysis with picture i's CPU work.
///
/// Confined to its caller's queue, like the engines of the pixel path (§8.8).
///
/// ## Deviations
/// - The CPU's chroma decisions and quantization hook are av1gpu's CPU
///   reference engine's (AV1Encoder/src/hybrid.cpp), not its GPU closed
///   loop's: about 3–4 % more bytes than AV1MetalEncoder.encode at equal
///   SSIMULACRA2.
/// - Buffers and threads are made per picture; the record and the source
///   keep their capacity.
@available(macOS 27, iOS 27, *)
public final class AV1HybridEncoder: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case encode(String)

        public var description: String {
            switch self { case let .encode(m): m }
        }
    }

    /// One 8-bit 4:2:0 picture, tightly packed: Y width × height, U and V
    /// half that each way, rounded up.
    public struct Picture: Sendable {
        public var y: [UInt8], u: [UInt8], v: [UInt8]
        public var width: Int, height: Int

        public init(y: [UInt8], u: [UInt8], v: [UInt8], width: Int, height: Int) {
            self.y = y
            self.u = u
            self.v = v
            self.width = width
            self.height = height
        }
    }

    /// Where a picture's time went: GPU time for the analysis and wall time
    /// for the rest, in seconds.
    public struct Timing: Sendable {
        public var analysis = 0.0, chroma = 0.0, closedLoop = 0.0, filters = 0.0, writer = 0.0
        /// The share of superblocks whose analysis was kept from the previous picture.
        public var kept = 0.0
        /// The share of tiles whose closed loop (and, mostly, bytes) were kept.
        public var keptTiles = 0.0
        /// The share of 64×64s filtered anew.
        public var filtered = 1.0
        /// The filters' GPU time (their command buffers').
        public var filtersGPU = 0.0
        /// Inter frames: the share of 64×64s copied from the GOLDEN_FRAME picture (`goldenFrames`).
        public var copiedGolden = 0.0
        /// Inter frames: GOLDEN_FRAME's long-term picture by use, as it was chosen (0: the most
        /// recently used or kept; `longTermReferences`), -1 with none.
        public var goldenRank = -1
        /// Inter frames: GOLDEN_FRAME's AV1 slot (0…7), -1 with none.
        public var goldenSlot = -1
        /// Inter frames: the share of 64×64s copied from the previous picture (unchanged or
        /// shifted), and of those at a shift; the time deciding them.
        public var copied = 0.0, shifted = 0.0, motion = 0.0
        /// Inter frames: the share of the picture in blocks the motion search predicts (with a residual).
        public var searched = 0.0
        /// Inter frames: whether the coded 64×64s were searched for motion (`searchesMotion`, and
        /// not skipped by `motionSkip`).
        public var searchedMotion = false
        /// Inter frames searched for motion: the share of the coded (not copied) 64×64s' area in
        /// blocks the analysis predicts by motion (`motionSkip`'s signal); -1 otherwise, or with
        /// nothing coded.
        public var motionFound = -1.0
        /// Key frames with `intraBlockCopy`: the share of the picture in blocks that copy the frame itself.
        public var intraCopied = 0.0
        /// From the picture's partition being ready to its bitstream.
        public var wall = 0.0
    }

    /// An encoded picture.
    public struct Frame: Sendable {
        /// A temporal delimiter, the sequence header and the frame.
        public var obu: [UInt8]
        /// What a decoder outputs for it (cropped like `Picture`).
        public var planes: [[UInt8]]
        /// The frame's parameters, with the loop-filter levels and CDEF presets chosen.
        public var params: av1g_frame_params
        public var timing: Timing
    }

    let metal: AV1MetalEncoder
    let postfilter: AV1MetalPostfilter
    let cpu: OpaquePointer
    let motion: OpaquePointer
    /// The partition readers' (`read(_:of:after:)`, one at a time): their inter frames' motion applied.
    private let readerMotion: OpaquePointer
    private let copyFinder: CopyFinder

    /// The analysis's search effort; `turbo` by default.
    public var preset: AV1MetalEncoder.Preset {
        get { metal.preset }
        set { metal.preset = newValue }
    }

    /// Uniform tiles, as log2 of the columns and rows (-1: the fewest legal).
    /// The CPU codes tiles on parallel threads, so pictures want many.
    public var tiling: (columnsLog2: Int, rowsLog2: Int) {
        get { metal.tiling }
        set { metal.tiling = newValue }
    }

    /// Decide chroma and the luma tx types on the GPU, up front and in parallel
    /// (`AV1MetalEncoder.decidesLeaves`), so the CPU's closed loop only
    /// quantizes and reconstructs; otherwise the CPU decides chroma and searches
    /// the tx types in the closed loop. On by default.
    public var gpuDecides: Bool {
        get { metal.decidesLeaves }
        set { metal.decidesLeaves = newValue }
    }

    /// Keep each superblock's analysis from the previous picture when the
    /// source it reads is unchanged (`AV1MetalEncoder.reusesAnalysis`): the
    /// same bytes, for a fraction of the GPU's work on screen content. On by
    /// default.
    public var reusesAnalysis: Bool {
        get { metal.reusesAnalysis }
        set {
            metal.reusesAnalysis = newValue
            av1enc_hybrid_set_reuse(cpu, newValue ? 1 : 0)
        }
    }

    /// Try the angle deltas of directional modes (on). Off is faster on
    /// moving content for a little more bytes.
    public var searchesAngleDeltas: Bool {
        get { metal.searchesAngleDeltas }
        set { metal.searchesAngleDeltas = newValue }
    }
    /// The learned pruning the encoder starts with: the shipped level, mode and
    /// chroma models (AV1PrunerWeights), eps 0.02 each, in pictures coding more
    /// than half their superblocks.
    public static let defaultLearnedPrune = AV1MetalEncoder.LearnedPrune(
        levelWeights: AV1PrunerWeights.cellV1, eps: 0.02, modeWeights: AV1PrunerWeights.modeV1, modeEps: 0.02,
        chromaWeights: AV1PrunerWeights.chromaV1, chromaEps: 0.02, overShare: 0.5)
    /// The closed loop searches luma tx types: intra blocks' and inter blocks'
    /// (on). Off: DCT_DCT, or the analysis's types where it searches them
    /// (`leafTxSearchPixels`).
    public var searchesTxTypes = true {
        didSet { av1enc_hybrid_set_tx_search(cpu, searchesTxTypes ? 1 : 0, searchesTxTypes ? 1 : 0) }
    }

    /// The closed loop's levels optimized by rate and distortion after the
    /// dead-zone quantizer (rust/av1 hybrid::rdoq; on), in tx blocks whose
    /// source spans at least `rdoqMinRange` values (BENCHMARKS "RDOQ").
    public var usesRDOQ = true {
        didSet { applyRDOQ() }
    }
    /// With `usesRDOQ`: the luma tx type search compares each type after RDOQ.
    public var rdoqInTrials = false {
        didSet { applyRDOQ() }
    }
    /// With `usesRDOQ`: the smallest span of source values (max - min) a tx
    /// block's RDOQ needs (0: every block). Flat gradients below it keep the
    /// quantizer's levels, which RDOQ would drop into bands.
    public var rdoqMinRange = 40 {
        didSet { applyRDOQ() }
    }

    private func applyRDOQ() {
        av1enc_hybrid_set_rdoq(cpu, usesRDOQ ? 1 : 0, rdoqInTrials ? 1 : 0, Int32(rdoqMinRange))
    }

    /// The learned tx type pruning's eps (rust/av1 hybrid::tx_model): the closed
    /// loop's luma tx search tries only the types it keeps. Nil: every type.
    public var txModelEps: Float? {
        didSet { av1enc_hybrid_set_tx_model(cpu, txModelEps ?? -1) }
    }

    /// The closed loop's luma tx type search measures each type's distortion in the transform
    /// domain and stops at DCT_DCT when that codes nothing (rust/av1 hybrid::quant; on: BD-neutral,
    /// BENCHMARKS). Off: the exact reconstruction's SSE, every type.
    public var quickTxTrials = true {
        didSet { av1enc_hybrid_set_quick_tx_trials(cpu, quickTxTrials ? 1 : 0) }
    }

    /// The tx types the closed loop's luma search tries (bit t: AV1 tx type t; DCT_DCT always).
    /// By default `screenTxTypes`: DCT_DCT, IDTX, V_DCT and H_DCT, +0.1–0.5 % of new pictures'
    /// bytes for a cheaper closed loop (BENCHMARKS "the closed loop's tx types"; the owner's
    /// choice, 2026-11-03). `.max`: every type.
    public var txTypes: UInt32 = AV1HybridEncoder.screenTxTypes {
        didSet { av1enc_hybrid_set_tx_types(cpu, txTypes) }
    }
    public static let screenTxTypes: UInt32 = 0xE01

    /// See `AV1MetalEncoder.learnedPrune` (on: `defaultLearnedPrune`).
    public var learnedPrune: AV1MetalEncoder.LearnedPrune? {
        get { metal.learnedPrune }
        set { metal.learnedPrune = newValue }
    }
    /// See `AV1MetalEncoder.interGate` (2: BENCHMARKS "the inter gate").
    public var interGate: Float {
        get { metal.interGate }
        set { metal.interGate = newValue }
    }
    /// See `AV1MetalEncoder.learnedPruneMinSuperblocks`.
    public var learnedPruneMinSuperblocks: Int {
        get { metal.learnedPruneMinSuperblocks }
        set { metal.learnedPruneMinSuperblocks = newValue }
    }
    /// See `AV1MetalEncoder.angleDeltasUpToShare`.
    public var angleDeltasUpToShare: Double {
        get { metal.angleDeltasUpToShare }
        set { metal.angleDeltasUpToShare = newValue }
    }

    /// Skip 32×32-and-up analysis where the source is busy
    /// (`AV1MetalEncoder.busyBlockPrune`; 4 by default, 0 off, 1 faster).
    public var busyBlockPrune: Float {
        get { metal.busyBlockPrune }
        set { metal.busyBlockPrune = newValue }
    }

    /// The largest block whose luma tx type the GPU searches
    /// (`AV1MetalEncoder.leafTxSearchPixels`; 256 for every one). 0 by default: the
    /// closed loop searches every luma tx type itself and keeps none of these, so the
    /// search was only GPU time (4–8 ms a 5K key frame; BENCHMARKS.md).
    public var leafTxSearchPixels: Int {
        get { metal.leafTxSearchPixels }
        set { metal.leafTxSearchPixels = newValue }
    }

    /// Screen the angled chroma modes too (`AV1MetalEncoder.leafChromaAngledModes`; off).
    public var leafChromaAngledModes: Bool {
        get { metal.leafChromaAngledModes }
        set { metal.leafChromaAngledModes = newValue }
    }

    /// Code every picture after the first as an inter frame of one stream
    /// (off: each picture is a still key frame). A 64×64 whose source equals
    /// the previous picture's, unchanged or at a whole-sample shift (scrolling,
    /// a dragged window), becomes skip inter blocks that copy the previous
    /// decoded picture, which the deblocking leaves alone; the rest is coded as
    /// before, as intra blocks. Each inter frame references the one before it.
    public var interFrames = false

    /// Each picture's qindex per 64×64 superblock (raster, 1…255; given the
    /// picture and the frame's qindex), coded with delta-q: the GPU analysis
    /// weighs and the closed loop quantizes each superblock by its own. Nil, or
    /// a map of another size: the frame's qindex everywhere. Called once a
    /// picture, on the thread that sets its analysis up. Not with 128×128
    /// superblocks.
    public var sbQindex: (@Sendable (Picture, Int) -> [UInt8]?)?

    /// With `interFrames`: the stream's size, when its pictures are coded
    /// smaller (decisions.h "Reduced frames"). A decoder shows each frame scaled
    /// up to this size. Every picture of the stream must then be the same size:
    /// nothing here codes prediction from a reference of another size.
    public var streamSize: (width: Int, height: Int)?

    /// With `interFrames`: search the coded 64×64s for motion too (on). A block
    /// predicted from the previous picture at a vector, with a residual, takes the
    /// place of an intra one where it costs less. Off: copies only.
    public var searchesMotion = true

    /// With `searchesMotion`, in `encode(count:)`: an inter frame skips the motion search (codes
    /// as with `searchesMotion` off: copies only, whole samples) when the last
    /// `motionSkipLookback` frames that searched each found motion in less than `threshold` of
    /// what they coded (`Timing.motionFound`); after `recheckEvery - 1` skipped in a row, one
    /// searches again, so motion returning is seen. A frame's search is set up while the one
    /// before it is analyzed, so frame i decides from frames up to i - 2. After a key frame (or
    /// a size change) the first frames search. It saves the search's GPU time (the motion search
    /// and the inter candidates) on frames that would find nothing; on by default at 0.2,
    /// re-checking every 8th frame, which lost no bytes on any content measured (BENCHMARKS "no
    /// motion search after frames whose search found nothing"). Nil: every inter frame searches.
    public var motionSkip: (threshold: Double, recheckEvery: Int)? = (threshold: 0.2, recheckEvery: 8)
    /// With `motionSkip`: how many frames that searched must all have found less than its
    /// threshold (2).
    public var motionSkipLookback = 2

    /// With `interFrames`: an inter frame starts from the CDFs its reference frame
    /// saved instead of the defaults (on), so a picture that hardly changed costs
    /// few bits. Loss-safe as long as the reference is a frame the decoder has.
    public var carriesCDFs = true

    /// With `interFrames`: 128×128 superblocks (on), so that four copied 64×64s at one
    /// shift are one block. The GPU's analysis stays 64×64; the stream's sequence header
    /// says 128, for every frame.
    public var largeSuperblocks = true

    /// With `interFrames`: inter frames carry no sequence header (on); the key frame's
    /// applies.
    public var omitsSequenceHeaders = true

    /// Whether a frame comes with its decoded picture (`Frame.planes`; on). Off saves copying
    /// it out of the GPU's buffers every picture (22 MB at 5K): an encoder for a decoder
    /// elsewhere doesn't need it, and its inter frames reference the GPU's copy.
    public var returnsPlanes = true

    /// Inter frames search no intra modes for a block whose motion-compensated residual
    /// quantizes to nothing (on): libaom realtime's rule, a third more speed on moving content.
    public var interSkipsIntra: Bool {
        get { metal.interSkipsIntra }
        set { metal.interSkipsIntra = newValue }
    }

    /// Inter frames' analysis effort (nil: `preset`'s).
    public var interPreset: AV1MetalEncoder.Preset? {
        get { metal.interPreset }
        set { metal.interPreset = newValue }
    }
    /// Squares only (GpParams.shapeMask bits 4x4, 8x8, 16x16, 32x32, 64x64) where most of an inter
    /// frame is new: +1.6 % of such a picture's bytes for ~17 ms less GPU at 5K (BENCHMARKS "what
    /// buys speed on a picture of new content"; the owner's choice, 2026-11-03).
    public static let defaultNewPictureShapeMask: Int32 = 0x1249
    /// See `AV1MetalEncoder.newPictureShapeMask` (nil: off; default `defaultNewPictureShapeMask`).
    public var newPictureShapeMask: Int32? {
        get { metal.newPictureShapeMask }
        set { metal.newPictureShapeMask = newValue }
    }

    /// The previous picture's decoded planes are the post-filter's buffers (not `previous.planes`).
    private var previousOnGPU = false

    /// Inter frames also copy from an older picture, GOLDEN_FRAME's: one of the long-term
    /// pictures (`longTermReferences`), each the last picture of a scene that a mostly new picture
    /// (most of whose 64×64s didn't copy the picture before it) left. Switching back to what was
    /// on the screen before (another app, a Space, a tab) copies it (on).
    public var goldenFrames = true

    /// With `goldenFrames`: how many long-term pictures inter frames keep, each in an AV1 slot of
    /// its own (1…7: the 8 slots less LAST_FRAME's). A mostly new picture keeps the one before
    /// it, the end of the scene it leaves, where it is (LAST_FRAME's slot), and goes itself into
    /// the slot of the long-term picture it returns to, if it does (it copied at least half of
    /// what it didn't copy from LAST_FRAME from GOLDEN_FRAME): an older state of its own scene,
    /// which it supersedes; else into a free slot, or the least recently used one's. So a scene
    /// left keeps only its newest state. Each inter frame's GOLDEN_FRAME is the long-term picture
    /// the most of its 64×64s not copying LAST_FRAME look like (a sample of their rows, at no
    /// shift; ties to the most recently used). With more than one, the key frame is the first
    /// (its scene's end replaces it). 1: GOLDEN_FRAME is the end of the last scene left, none
    /// before the first (the rule before there were more). Each costs a picture's source and
    /// decoded planes (3 bytes a pixel: 44 MB at 5K, 14 MB at 2900 × 1630). 4 by default: on four
    /// screens in turn, 2 saves 18 % of the bytes at equal RGB PSNR, 4 and 6 49 % (2900 px).
    public var longTermReferences = 4 {
        didSet { longTermReferences = min(7, max(1, longTermReferences)) }
    }
    /// With `interFrames`: the stream's key frames' qindex against the one `encode` is given
    /// (-16, the default; 0: the same; negative: finer). Everything a frame derives
    /// from its qindex follows its own: the analysis's lambda and learned pruning, the closed
    /// loop's quantizer and RDOQ, deblocking and CDEF. Clamped to 1…255 (a qindex of 0,
    /// lossless, stays 0). A key frame coded finer than the inter frames that copy from it for
    /// long passes its quality on to them (BENCHMARKS "libaom's lead at low rates"); the first
    /// inter frame after it analyzes all its 64×64s (the analysis kept is a picture's at one qindex).
    /// -16 keeps the key frame at 1.1–1.4× (its size is latency on a session's start or a repair)
    /// for 5–10 % fewer bytes over streams that return to it (BENCHMARKS "key frames at a finer
    /// qindex"). Pictures coded alone (no `interFrames`) take the qindex given: nothing copies them.
    public var keyFrameQindexDelta = -16

    /// A key frame's qindex, for frames at `qindex` (`keyFrameQindexDelta`).
    public func keyFrameQindex(_ qindex: Int) -> Int {
        qindex <= 0 || keyFrameQindexDelta == 0 || !interFrames ? qindex : min(255, max(1, qindex + keyFrameQindexDelta))
    }

    /// The long-term pictures' decoded planes (tight) by AV1 slot ([] where there's none), for the
    /// inter frames whose copies choose them.
    private var slotPlanes: [[[UInt8]]] = Array(repeating: [], count: 8)

    /// The current stream's superblock size (set when it starts).
    private var streamSB128 = false

    /// The post-filters' output is the last picture's (false after a picture with intra block
    /// copies, which has none: the next one is filtered whole).
    private var filteredLast = true
    /// Pictures whose filters are done (or that have none), over the encoder's life: the
    /// analyses' gate (`AV1MetalEncoder.gate`) is raised to it as each one's are.
    private var filtersDone: UInt64 = 0
    /// A picture's filters are done (or it has none): analyses ordered behind them may start.
    private func filtered() {
        filtersDone += 1
        metal.openGate(filtersDone)
    }

    /// With `searchesMotion`: refine motion vectors to quarter samples (on). Scaled
    /// or animated content moves by fractions of a sample; captured scrolling and
    /// dragging at full size don't, and cost nothing more. Off: whole samples.
    public var searchesSubpelMotion: Bool {
        get { metal.searchesSubpelMotion }
        set { metal.searchesSubpelMotion = newValue }
    }

    /// The last picture, for the next inter frame: its source, decoded
    /// output and per-64×64 decisions (copy, dx, dy).
    private var previous: (source: Picture, planes: [[UInt8]], motion: [Int32])?

    /// Key frames copy what repeats inside them (AV1 intra block copy; on): a block whose source
    /// appears where the decoder has it already (spec is_mv_valid: at least 256 samples back, in
    /// the tile) copies it, exactly or nearly (the residual coded). A frame with copies has no
    /// deblocking or CDEF, which the format turns off for it, so a key frame copies only where
    /// its exact copies cover enough of it (text at full size: at 5K, typing -20 %, cursor-drag
    /// -17 %, scroll -8 % BD-rate; photos and downscaled text don't copy).
    public var intraBlockCopy = true {
        didSet { av1enc_hybrid_set_intrabc(cpu, intraBlockCopy ? 1 : 0) }
    }

    /// Deblocking and CDEF (on). Off, the picture is the closed loop's
    /// reconstruction as is, and a tile decodes to the same samples alone
    /// as in its frame (the filters cross tile edges).
    public var postfilters = true

    /// Time the GPU's stages one by one (`AV1MetalEncoder.profilesStages`):
    /// for measurement, as it serializes them.
    public var profilesStages: Bool {
        get { metal.profilesStages }
        set { metal.profilesStages = newValue }
    }
    /// The analysis's 32x32 forward DCT runs on the matrix units (`AV1MetalEncoder.analysisUsesMatrixUnits`).
    public var analysisUsesMatrixUnits: Bool { metal.analysisUsesMatrixUnits }
    /// The last picture's GPU stages (with `profilesStages`).
    public var lastStages: AV1MetalEncoder.StageTimes { metal.lastStages }

    public init(device: any MTLDevice) throws {
        metal = try AV1MetalEncoder(device: device)
        metal.preset = .turbo
        metal.decidesLeaves = true
        metal.reusesAnalysis = true
        metal.busyBlockPrune = 4
        metal.learnedPrune = Self.defaultLearnedPrune
        metal.leafTxSearchPixels = 0
        metal.leafChromaAngledModes = false
        metal.searchesSubpelMotion = true
        metal.interGate = 2
        metal.newPictureShapeMask = Self.defaultNewPictureShapeMask
        postfilter = try AV1MetalPostfilter(device: device)
        guard let cpu = av1enc_hybrid_create(), let motion = av1enc_motion_create(), let readerMotion = av1enc_motion_create()
        else { throw Failure.encode("no CPU state") }
        self.cpu = cpu
        self.motion = motion
        self.readerMotion = readerMotion
        av1enc_hybrid_set_intrabc(cpu, 1)
        copyFinder = try CopyFinder()
        applyRDOQ()
        av1enc_hybrid_set_quick_tx_trials(cpu, quickTxTrials ? 1 : 0)
        av1enc_hybrid_set_tx_types(cpu, txTypes)
    }

    deinit {
        av1enc_hybrid_destroy(cpu)
        av1enc_motion_destroy(motion)
        av1enc_motion_destroy(readerMotion)
    }

    /// `motionSkip`'s state in a stream: what the searched frames found, newest last, and the
    /// frames skipped in a row.
    private struct MotionRule {
        var found: [Double] = []
        var skipped = 0
        /// The last key frame decided (frames before it don't count).
        var key = 0

        /// Picture `index`'s copies, before its analysis begins: its search dropped when the rule
        /// says so.
        mutating func decide(_ index: Int, _ copies: inout Copies, rule: (threshold: Double, recheckEvery: Int)?, lookback: Int) {
            guard copies.motion != nil else {  // a key frame
                (found, skipped, key) = ([], 0, index)
                return
            }
            guard let rule, copies.candidates != nil else { return }
            let quiet = lookback > 0 && found.count >= lookback && found.suffix(lookback).allSatisfy { $0 < rule.threshold }
            if quiet && skipped + 1 < rule.recheckEvery {
                copies.candidates = nil
                skipped += 1
            } else {
                skipped = 0
            }
        }

        /// What picture `index`, searched, found (`Timing.motionFound`; < 0: nothing coded).
        mutating func record(_ index: Int, _ share: Double) {
            guard index > key, share >= 0 else { return }
            found.append(share)
            if found.count > 8 { found.removeFirst() }
        }
    }

    /// A searched inter frame's `Timing.motionFound`: the area in blocks the analysis predicts by
    /// motion, of the coded 64×64s' (-1: not searched, or nothing coded).
    private static func motionFound(_ partition: AV1MetalEncoder.Partition, motion: [Int32]?) -> Double {
        guard let motion, !partition.inter.isEmpty, partition.inter.count == partition.blocks.count else { return -1 }
        var coded = 0
        for k in stride(from: 0, to: motion.count, by: 3) where motion[k] == 0 { coded += 1 }
        guard coded > 0 else { return -1 }
        var area = 0
        for (b, i) in zip(partition.blocks, partition.inter) where i.is_inter != 0 {
            let size = AV1MetalEncoder.blockSizes[Int(b.bsize)]
            area += size.w * size.h
        }
        return min(1, Double(area) / Double(coded * 64 * 64))
    }

    /// One picture.
    public func encode(_ picture: Picture, qindex: Int) throws -> Frame {
        var frame: Frame?
        try encode(count: 1, qindex: qindex, picture: { _ in picture }, output: { _, f in frame = f })
        guard let frame else { throw Failure.encode("no frame") }
        return frame
    }

    /// Pictures 0..<count: picture i + 1's analysis runs on the GPU while
    /// picture i is finished on the CPU. `output` gets them in order. With
    /// `interFrames`, they're one stream: the first a key frame and the rest
    /// inter frames. Picture i's bitstream is written, and picture i + 1's
    /// analysis set up and committed (while picture i - 1 is finished), on other
    /// threads; `output` gets picture i before picture i + 1's closed loop.
    public func encode(count: Int, qindex: Int, picture: (Int) throws -> Picture,
                       written: (@Sendable (Int, Frame) -> Void)? = nil, output: (Int, Frame) throws -> Void) throws {
        guard count > 0 else { return }
        previous = nil
        slotPlanes = Array(repeating: [], count: 8)
        copyFinder.golden = interFrames && goldenFrames
        copyFinder.limit = longTermReferences
        copyFinder.reset()
        streamSB128 = interFrames && largeSuperblocks
        metal.largeSuperblocks = streamSB128
        if interFrames { metal.forgetAnalysis() }  // the cache may hold an earlier stream's inter frames
        // picture i - 1's bitstream, being written while picture i + 1's analysis starts, which
        // is also on a thread of its own (`starting`), as is picture i + 2's after it (`following`)
        var writing: Writing?
        var starting: Later<Pending>?, following: Later<Pending>?
        // Picture k's analysis waits on the GPU for picture k - 2's filters (`gate(k)`), besides
        // picture k - 1's analysis being read: the filters, which picture k - 1's closed loop
        // waits for, then have the GPU as soon as their own closed loop ends, and picture k's
        // analysis runs beside picture k - 1's closed loop.
        let gateBase = filtersDone
        func gate(_ k: Int) -> UInt64 { k >= 2 ? gateBase + UInt64(k - 1) : 0 }
        // picture i's partition, read on a thread of its own as soon as its analysis ends
        var reading: Later<Read>?
        defer {
            // (no analysis waits for filters that won't come)
            filtersDone = max(filtersDone, gateBase + UInt64(count) + 1)
            metal.openGate(filtersDone)
            copyFinder.drain()
            _ = try? writing?.end()
            _ = try? reading?.wait()
            for later in [starting, following] {
                if let p = try? later?.wait() { _ = try? p.read?.wait() }
            }
        }
        // `motionSkip`: picture i + 2's search is decided once picture i's analysis is read
        var rule = MotionRule()
        // picture i's qindex: a key frame's for the first, or every one without inter frames
        let keyQindex = keyFrameQindex(qindex)
        func qindexOf(_ i: Int) -> Int { interFrames && i > 0 ? qindex : keyQindex }
        var current = try picture(0)
        var pending = try begin(current, Copies(), qindex: keyQindex)
        read(&pending, of: current, after: nil)
        reading = pending.read
        // picture i + 1's analysis is set up while picture i - 1 is finished, and committed: its
        // command buffer waits on the GPU until picture i's results are read
        // (AV1MetalEncoder.readEvent; on the reader's thread, as soon as its analysis ends) and
        // picture i - 1's filters are done (`gate`), so its GPU work starts as soon as both are.
        // Its copies are decided (on the CPU, from the two sources alone) before that.
        var next = count > 1 ? try picture(1) : nil
        if let next {
            if interFrames { copyFinder.start(next, after: current, searchesMotion: searchesMotion) }
            var copies = interFrames ? copyFinder.wait() : Copies()
            if interFrames { rule.decide(1, &copies, rule: motionSkip, lookback: motionSkipLookback) }
            let q = qindexOf(1)
            let first = pending.read
            starting = Later { [copies] in
                var p = try self.begin(next, copies, qindex: q)
                self.read(&p, of: next, after: first)
                return p
            }
        }
        var upcoming = count > 2 ? try picture(2) : nil
        if interFrames, let upcoming, let next { copyFinder.start(upcoming, after: next, searchesMotion: searchesMotion) }
        for i in 0..<count {
            // (each picture's autoreleased objects, its Metal command buffers and what they hold,
            // go with it, not when the stream ends: a caller's thread may never drain them)
            try autoreleasepool {
                let got = try pending.read?.wait() ?? Read(partition: pending.partition.wait())
                let partition = got.partition
                // the picture before's source back to the pool: its closed loop and filters, and
                // this picture's analysis (whose motion search read it), are done
                if pending.read != nil { metal.keepSource(partition.source) }
                Self.trace("partition \(i)")
                let found = Self.motionFound(partition, motion: pending.motion)
                rule.record(i, found)
                // picture i + 2's analysis, set up after picture i + 1's (two at most are set up and not
                // yet read: their kept-analysis buffers alternate)
                let afterNext = upcoming
                if let up = upcoming {
                    var copies = interFrames ? copyFinder.wait() : Copies()
                    if interFrames { rule.decide(i + 2, &copies, rule: motionSkip, lookback: motionSkipLookback) }
                    let before = starting
                    let q = qindexOf(i + 2), g = gate(i + 2)
                    following = Later { [copies] in
                        let previous = try before?.wait()
                        var p = try self.begin(up, copies, qindex: q, after: g)
                        self.read(&p, of: up, after: previous?.read)
                        return p
                    }
                    upcoming = i + 3 < count ? try picture(i + 3) : nil
                    if interFrames, let upcoming { copyFinder.start(upcoming, after: up, searchesMotion: searchesMotion) }
                }
                let t0 = CACurrentMediaTime()
                var timing = Timing()
                timing.analysis = partition.gpuSeconds
                let sbs = ((2 * ((current.width + 7) >> 3) + 15) >> 4) * ((2 * ((current.height + 7) >> 3) + 15) >> 4)
                timing.kept = Double(pending.partition.keptSuperblocks) / Double(max(1, sbs))
                timing.motion = pending.motionSeconds
                timing.motionFound = found
                let motion = pending.motion
                // picture i - 1's write runs beside this closed loop; finish takes it back before
                // picture i's write begins (until then `writing` holds it, for the defer)
                var onWritten: (@Sendable (Frame) -> Void)?
                if let written {
                    let index = i
                    onWritten = { frame in written(index, frame) }
                }
                let (w, ended) = try finish(current, partition: partition, applied: got.applied, motion: motion,
                                            searchesMotion: pending.searchesMotion,
                                            refs: pending.refs, qindex: qindexOf(i),
                                            qmap: pending.qmap, hashes: pending.hashes, timing: timing, started: t0, writingBefore: writing,
                                            written: onWritten)
                writing = w
                if let ended {
                    try output(i - 1, ended)
                    Self.trace("written \(i - 1)")
                }
                if let s = starting {
                    starting = following
                    following = nil
                    pending = try s.wait()
                    reading = pending.read
                }
                if let n = next {
                    current = n
                    next = afterNext
                }
            }
        }
        if let w = writing {
            writing = nil
            try output(count - 1, try w.end())
        }
    }

    /// A measurement (BENCHMARKS "a picture in two steps"), not a mode anything ships: one stream
    /// that codes each picture twice, first at `coarseQindex` as `encode(count:)` would, then at
    /// `qindex` as an inter frame that copies in place what the first copied and codes the rest,
    /// its motion search from no shift against the first step's decoded picture (the analysis's reference too, so
    /// one picture is finished before the next begins: nothing overlaps). `output` gets the
    /// picture's index, the step (0 or 1) and the frame. Needs `interFrames`.
    public func encodeTwoSteps(count: Int, coarseQindex: Int, qindex: Int, picture: (Int) throws -> Picture,
                               output: (Int, Int, Frame) throws -> Void) throws {
        guard count > 0, interFrames else { return }
        previous = nil
        slotPlanes = Array(repeating: [], count: 8)
        copyFinder.golden = goldenFrames
        copyFinder.limit = longTermReferences
        copyFinder.reset()
        streamSB128 = largeSuperblocks
        metal.largeSuperblocks = streamSB128
        func code(_ p: Picture, _ copies: Copies, _ q: Int) throws -> Frame {
            metal.forgetAnalysis()  // (the same source at another q, or against another reference)
            let pending = try begin(p, copies, qindex: q)
            let partition = try pending.partition.wait()
            var timing = Timing()
            timing.analysis = metal.lastGPUSeconds
            timing.motion = pending.motionSeconds
            timing.motionFound = Self.motionFound(partition, motion: pending.motion)
            let (writing, _) = try finish(p, partition: partition, motion: pending.motion, searchesMotion: pending.searchesMotion,
                                          refs: pending.refs, qindex: q,
                                          qmap: pending.qmap, hashes: pending.hashes, timing: timing, started: CACurrentMediaTime(),
                                          writingBefore: nil, written: nil)
            return try writing.end()
        }
        var last: Picture?
        for i in 0..<count {
            let p = try picture(i)
            var copies = Copies()
            if let last {
                copyFinder.start(p, after: last, searchesMotion: searchesMotion)
                copies = copyFinder.wait()
            }
            try output(i, 0, try code(p, copies, i == 0 ? keyFrameQindex(coarseQindex) : coarseQindex))
            let decoded = previousDecoded(width: p.width, height: p.height)
            guard decoded.count == 3 else { throw Failure.encode("two steps: no decoded picture") }
            try decoded[0].withUnsafeBufferPointer { try metal.setReference(y: $0.baseAddress!, width: p.width, height: p.height) }
            // (the second step's vectors are its motion search's, at its precision: `again` searches)
            try output(i, 1, try code(p, copyFinder.again(p, after: copies), qindex))
            last = p
        }
    }

    /// GA_TIMELINE (diagnostics): each picture's stages as they start and end, and the GPU's
    /// command buffers, on stderr as `tl <ms> <what>` (BENCHMARKS "where a new picture's period goes").
    static let traces = ProcessInfo.processInfo.environment["GA_TIMELINE"] != nil
    static func trace(_ what: @autoclosure () -> String) {
        guard traces else { return }
        FileHandle.standardError.write("tl \(String(format: "%.3f", CACurrentMediaTime() * 1000)) \(what())\n".data(using: .utf8)!)
    }

    /// Work on a thread of its own, and its result.
    private final class Later<T>: @unchecked Sendable {
        private var result: Result<T, any Error>?
        private let done = DispatchSemaphore(value: 0)

        init(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () throws -> T) {
            DispatchQueue.global(qos: qos).async {
                self.result = Result { try work() }
                self.done.signal()
            }
        }

        func wait() throws -> T {
            done.wait()
            done.signal()  // for a later wait (an encode that threw)
            return try result!.get()
        }
    }

    /// A picture's bitstream, written on a thread of its own while the next picture's closed loop
    /// runs (av1enc_hybrid_write_begin, av1enc_write_job_run): begun once its filters are chosen,
    /// taken back (`end`) on the encoder's thread before the next picture's write begins, which
    /// needs the writer's state again. `written` gets the frame on the writer's thread as soon as
    /// its bitstream exists.
    private final class Writing: @unchecked Sendable {
        private let cpu: OpaquePointer?
        private var job: OpaquePointer?
        private let frameParams: av1g_frame_params
        private let planes: [[UInt8]]
        private var timing: Timing
        private let t0: Double, t2: Double
        private var result: Result<Frame, any Error>?
        private let done = DispatchSemaphore(value: 0)

        /// Starts writing the last closed loop's picture with the filters' choices.
        init(cpu: OpaquePointer, search: AV1MetalPostfilter.Search, sbCols: Int, flags: UInt32, timing: Timing,
             t0: Double, t2: Double, written: (@Sendable (Frame) -> Void)?) throws {
            self.cpu = cpu
            frameParams = search.params
            planes = search.planes
            self.timing = timing
            self.t0 = t0
            self.t2 = t2
            var params = search.params
            var message = [CChar](repeating: 0, count: 256)
            var job: OpaquePointer?
            let rc = search.superblockCDEF.withUnsafeBufferPointer { cdef in
                av1enc_hybrid_write_begin(cpu, &params, cdef.baseAddress, Int32(sbCols), flags, &job, &message, 256)
            }
            guard rc == AV1G_OK, let job else { throw Failure.encode("writer (\(rc)): \(Self.text(message))") }
            self.job = job
            DispatchQueue.global(qos: .userInitiated).async {
                self.result = Result { try self.write() }
                if let written, case let .success(frame) = self.result { written(frame) }
                self.done.signal()
            }
        }

        /// A picture already written.
        init(_ frame: Frame) {
            (cpu, job, frameParams, planes, timing, t0, t2) = (nil, nil, frame.params, frame.planes, frame.timing, 0, 0)
            result = .success(frame)
            done.signal()
        }

        /// The picture's frame, once written; the job taken back. On the encoder's thread; again
        /// after the first, the same result.
        func end() throws -> Frame {
            done.wait()
            done.signal()  // for a later end (an encode that threw)
            if let job, let cpu {
                self.job = nil
                var message = [CChar](repeating: 0, count: 256)
                let rc = av1enc_hybrid_write_end(cpu, job, &message, 256)
                if rc != AV1G_OK, case .success = result {
                    result = .failure(Failure.encode("writer (\(rc)): \(Self.text(message))"))
                }
            }
            return try result!.get()
        }

        private func write() throws -> Frame {
            guard let job else { throw Failure.encode("writer: no job") }
            var message = [CChar](repeating: 0, count: 256)
            AV1HybridEncoder.trace("writer start")
            let wrc = av1enc_write_job_run(job, &message, 256)
            guard wrc == AV1G_OK else { throw Failure.encode("writer (\(wrc)): \(Self.text(message))") }
            var bytes: UnsafePointer<UInt8>?
            var size = 0
            av1enc_write_job_bitstream(job, &bytes, &size)
            guard let bytes else { throw Failure.encode("writer: no bitstream") }
            let obu = Array(UnsafeBufferPointer(start: bytes, count: size))
            let t3 = CACurrentMediaTime()
            AV1HybridEncoder.trace("writer end")
            timing.writer = t3 - t2
            timing.wall = t3 - t0
            return Frame(obu: obu, planes: planes, params: frameParams, timing: timing)
        }

        static func text(_ message: [CChar]) -> String {
            String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// A picture's analysis under way, and its copies (an inter frame's).
    /// A picture's intra block copy hashes, taken while its analysis runs (`begin`), for its
    /// closed loop (av1enc_ibc_hashes): from `hashPool`, and back to it once given.
    private final class IbcHashes: @unchecked Sendable {
        let handle: OpaquePointer
        init() throws {
            guard let h = av1enc_ibc_hashes_create() else { throw Failure.encode("no hashes") }
            handle = h
        }
        deinit { av1enc_ibc_hashes_destroy(handle) }
    }
    private var hashPool: [IbcHashes] = []
    private let hashPoolLock = NSLock()
    private func takeHashes() throws -> IbcHashes {
        hashPoolLock.lock()
        defer { hashPoolLock.unlock() }
        return try hashPool.popLast() ?? IbcHashes()
    }
    private func give(_ hashes: IbcHashes) {
        hashPoolLock.lock()
        defer { hashPoolLock.unlock() }
        hashPool.append(hashes)
    }

    private struct Pending {
        var partition: AV1MetalEncoder.PendingPartition
        /// The partition, read on a thread of its own (`read(_:after:)`), or nil: read on the caller's.
        var read: Later<Read>? = nil
        /// Per 64×64: copy, dx, dy (nil: a key frame or a still picture).
        var motion: [Int32]?
        /// An inter frame's coded 64×64s are searched for motion (its copies had candidates): the
        /// header's mv_precision follows.
        var searchesMotion = false
        var motionSeconds = 0.0
        /// The picture's qindex per 64×64 (`sbQindex`'s), or nil.
        var qmap: [UInt8]? = nil
        /// A key frame's intra block copy hashes, or nil.
        var hashes: IbcHashes? = nil
        /// An inter frame's reference slots (nil: a key frame or a still picture).
        var refs: Refs? = nil
    }

    /// An inter frame's reference slots: LAST_FRAME's, GOLDEN_FRAME's + 1 (0: none), the slots it
    /// refreshes, and whether it swaps (it was mostly new: the previous picture, in LAST_FRAME's
    /// slot, is kept there as a long-term picture, and this one goes into `refresh`'s slot, which
    /// becomes LAST_FRAME's: the long-term picture it held is replaced or evicted).
    struct Refs {
        var last = 0, golden = 0, refresh = 1
        var swaps = false
        /// A stream's first inter frame, with more than one long-term picture: the key frame (its
        /// reference) is the first, in this slot (-1: none).
        var keepsKey = -1
        /// GOLDEN_FRAME's long-term picture's rank by use (`Timing.goldenRank`).
        var goldenRank = -1
    }

    /// Decides inter frames' copies on a thread of its own, with a motion handle of its own (the
    /// encoder's applies them, which doesn't read what classifying left in it).
    private final class CopyFinder: @unchecked Sendable {
        private let motion: OpaquePointer
        private var result: Copies?
        private var running = false
        private let done = DispatchSemaphore(value: 0)
        /// `goldenFrames`, and `longTermReferences`: the long-term pictures and the slots, as of the
        /// next picture (the pictures are classified in order)
        var golden = false
        var limit = 1
        private struct LongTerm {
            var slot: Int
            var source: Picture
        }
        /// Most recently used (copied from, or kept) first.
        private var longTerm: [LongTerm] = []
        private var lastSlot = 0
        /// The slot of a long-term picture that holds the current scene's older state, which the
        /// scene's end replaces when it's left: the key frame's, in the first scene. (A scene
        /// entered from a long-term picture replaces it with its first picture, as LAST_FRAME's.)
        private var sceneSlot: Int?
        /// The next picture classified is the stream's first inter frame, and its reference, the
        /// key frame, becomes the first long-term picture (with `limit` > 1).
        private var keyPending = false

        /// A stream starts (after its key frame every slot holds it; no GOLDEN_FRAME yet).
        func reset() {
            longTerm = []
            lastSlot = 0
            sceneSlot = nil
            keyPending = golden && limit > 1
        }

        init() throws {
            guard let motion = av1enc_motion_create() else { throw Failure.encode("no CPU state") }
            self.motion = motion
        }

        deinit { av1enc_motion_destroy(motion) }

        /// Starts deciding picture `p`'s 64×64s that copy `prev` (none unless they're the same size).
        func start(_ p: Picture, after prev: Picture, searchesMotion: Bool) {
            running = true
            DispatchQueue.global(qos: .userInitiated).async {
                self.result = self.copies(of: p, after: prev, searchesMotion: searchesMotion)
                self.done.signal()
            }
        }

        /// The started picture's copies.
        func wait() -> Copies {
            guard running else { return Copies() }
            done.wait()
            running = false
            defer { result = nil }
            return result ?? Copies()
        }

        /// Waits for any started picture (an encode that threw).
        func drain() { _ = wait() }

        /// A frame that codes the last picture again (`encodeTwoSteps`): what `first` copied is
        /// copied from it in place (it was already as good as what it copied) and the rest is
        /// coded, with no shift as the motion search's one candidate. LAST_FRAME's slot is refreshed.
        func again(_ p: Picture, after first: Copies) -> Copies {
            let nsb = ((p.width + 63) / 64) * ((p.height + 63) / 64)
            let g = longTerm.first.flatMap { $0.source.width == p.width && $0.source.height == p.height ? $0 : nil }
            let copied = (0..<nsb).map { i in UInt8(first.skip.map { $0[i] != 0 ? 1 : 0 } ?? 0) }
            var m = [Int32](repeating: 0, count: 3 * nsb)
            for i in 0..<nsb { m[3 * i] = Int32(copied[i]) }
            return Copies(motion: m, skip: copied, candidates: [0, 0],
                          refs: Refs(last: lastSlot, golden: g.map { $0.slot + 1 } ?? 0, refresh: 1 << lastSlot))
        }

        private func copies(of p: Picture, after prev: Picture, searchesMotion: Bool) -> Copies {
            guard prev.width == p.width, prev.height == p.height else {
                reset()  // (a key frame, which every slot then holds)
                return Copies()
            }
            let tm = CACurrentMediaTime()
            var keepsKey = -1
            if keyPending {
                keyPending = false
                (longTerm, sceneSlot, keepsKey) = ([LongTerm(slot: 1, source: prev)], 1, 1)
            }
            let nsb = ((p.width + 63) / 64) * ((p.height + 63) / 64)
            var m = [Int32](repeating: 0, count: 3 * nsb)
            let strides: [Int32] = [Int32(p.width), Int32((p.width + 1) / 2), Int32((p.width + 1) / 2)]
            var chosen: Int32 = -1
            AV1HybridEncoder.planes(p) { cur in
                AV1HybridEncoder.planes(prev) { before in
                    AV1HybridEncoder.planes(longTerm.map(\.source)[...]) { olds in
                        let oldStrides = [[Int32]](repeating: strides, count: longTerm.count).flatMap { $0 }
                        _ = av1enc_motion_classify_multi(motion, cur, strides, before, strides, olds, oldStrides,
                                                         Int32(longTerm.count), Int32(p.width), Int32(p.height), 3, 8,
                                                         &m, &chosen)
                    }
                }
            }
            // the reference slots, and the long-term pictures for the next picture
            let fromLast = (0..<nsb).filter { m[3 * $0] == 1 }.count
            let fromGolden = (0..<nsb).filter { m[3 * $0] == 2 }.count
            let k = Int(chosen)
            var refs = Refs(last: lastSlot, golden: k >= 0 ? longTerm[k].slot + 1 : 0, refresh: 1 << lastSlot,
                            keepsKey: keepsKey, goldenRank: k)
            if k > 0, fromGolden > 0 { longTerm.insert(longTerm.remove(at: k), at: 0) }
            if golden && 2 * fromLast < nsb {
                // the previous picture, the end of the scene this one leaves, is kept where it is.
                // This one goes into the slot of the long-term picture it returns to (an earlier
                // state of its scene: GOLDEN_FRAME's, if that gave it at least half of what
                // LAST_FRAME didn't), which it supersedes; else the slot of the older state of the
                // scene it leaves, a free one, or the least recently used one's.
                let entered = k >= 0 && 2 * fromGolden >= nsb - fromLast ? refs.golden - 1 : -1
                let target: Int
                if let i = longTerm.firstIndex(where: { $0.slot == entered }) {
                    target = longTerm.remove(at: i).slot
                } else if let s = sceneSlot, let i = longTerm.firstIndex(where: { $0.slot == s }) {
                    target = longTerm.remove(at: i).slot
                } else if longTerm.count < limit {
                    target = (0..<8).first { t in t != lastSlot && !longTerm.contains { $0.slot == t } } ?? 0
                } else {
                    target = longTerm.removeLast().slot
                }
                sceneSlot = nil
                longTerm.insert(LongTerm(slot: lastSlot, source: prev), at: 0)
                (refs.refresh, refs.swaps) = (1 << target, true)
                lastSlot = target
            }
            var candidates: [Int32]?
            if searchesMotion {
                var c = [Int32](repeating: 0, count: 2 * Int(GP_ME_CANDS))
                c.removeLast(c.count - 2 * Int(av1enc_motion_candidates(motion, &c, GP_ME_CANDS)))
                candidates = c
            }
            return Copies(motion: m, skip: (0..<nsb).map { UInt8(m[3 * $0]) }, candidates: candidates,
                          seconds: CACurrentMediaTime() - tm, refs: refs)
        }
    }

    /// An inter frame's copies, decided before its analysis (none: a key frame).
    private struct Copies {
        /// Per 64×64: copy, dx, dy.
        var motion: [Int32]?
        /// Per 64×64: nonzero where it's a copy (not analyzed).
        var skip: [UInt8]?
        /// The frame's shift candidates for the motion search (nil: no motion search).
        var candidates: [Int32]?
        var seconds = 0.0
        /// The frame's reference slots.
        var refs: Refs?
    }

    /// A partition as its reader leaves it: with an inter frame's motion applied (the blocks in
    /// decode order with the copies' and the searched blocks' motion), or nil: `finish` applies it.
    private struct Read {
        var partition: AV1MetalEncoder.Partition
        var applied: Applied? = nil
    }

    /// An inter frame's blocks with its motion applied (`av1enc_motion_apply_ex`), and the area of
    /// its coded inter blocks in samples.
    private struct Applied {
        var blocks: [av1g_block], inter: [av1g_block_inter], lumaTx: [UInt8]
        var searchedArea = 0
    }

    /// Picture `p`'s motion (`sbMotion`: per 64×64 copy, dx, dy) applied to its partition with
    /// `handle`'s scratch.
    private func apply(_ handle: OpaquePointer, _ sbMotion: [Int32], to partition: AV1MetalEncoder.Partition,
                       width: Int, height: Int) throws -> Applied {
        var outBlocks: UnsafePointer<av1g_block>?, outInter: UnsafePointer<av1g_block_inter>?, outTx: UnsafePointer<UInt8>?
        let n = partition.blocks.withUnsafeBufferPointer { b in
            partition.lumaTxTypes.withUnsafeBufferPointer { t in
                partition.inter.withUnsafeBufferPointer { searched in
                    av1enc_motion_apply_ex(handle, sbMotion, b.baseAddress, UInt32(b.count), gpuDecides ? t.baseAddress : nil,
                                           searched.count == b.count ? searched.baseAddress : nil,
                                           Int32(width), Int32(height), streamSB128 ? 1 : 0,
                                           Int32(tiling.columnsLog2), Int32(tiling.rowsLog2), &outBlocks, &outInter, &outTx)
                }
            }
        }
        guard n > 0, let outBlocks, let outInter, let outTx else { throw Failure.encode("motion: no blocks") }
        var applied = Applied(blocks: Array(UnsafeBufferPointer(start: outBlocks, count: Int(n))),
                              inter: Array(UnsafeBufferPointer(start: outInter, count: Int(n))),
                              lumaTx: Array(UnsafeBufferPointer(start: outTx, count: Int(n))))
        for (b, i) in zip(applied.blocks, applied.inter) where i.is_inter != 0 && b.skip == 0 {
            let size = AV1MetalEncoder.blockSizes[Int(b.bsize)]
            applied.searchedArea += size.w * size.h
        }
        return applied
    }

    /// Reads `p`'s partition (of `picture`) on a thread of its own as soon as its analysis ends,
    /// after the picture before's (`previous`: their kept analysis is read in order, and they
    /// share `readerMotion`), and applies an inter frame's motion to it. Its source isn't handed
    /// back: the caller does that (`AV1MetalEncoder.keepSource`) when the picture before's closed
    /// loop and filters are done with theirs.
    private func read(_ p: inout Pending, of picture: Picture, after previous: Later<Read>?) {
        let partition = p.partition, motion = interFrames ? p.motion : nil
        let (width, height) = (picture.width, picture.height)
        // (above the closed loop's threads, which take every core: it's short, and the next
        // analysis and closed loop wait for it)
        p.read = Later(qos: .userInteractive) {
            _ = try previous?.wait()
            var read = Read(partition: try partition.wait(keepsSource: false))
            AV1HybridEncoder.trace("read")
            if let motion {
                read.applied = try self.apply(self.readerMotion, motion, to: read.partition, width: width, height: height)
                AV1HybridEncoder.trace("applied")
            }
            return read
        }
    }

    /// Starts picture `p`'s analysis, without its copies; its GPU work waits for `gate` to reach
    /// `after` (`AV1MetalEncoder.beginPartition(after:)`).
    private func begin(_ p: Picture, _ copies: Copies, qindex: Int, after gateValue: UInt64 = 0) throws -> Pending {
        let sbs = ((p.width + 63) / 64) * ((p.height + 63) / 64)
        let qmap = sbQindex?(p, qindex).flatMap { $0.count == sbs ? $0 : nil }
        let partition = try p.y.withUnsafeBufferPointer { y in
            try p.u.withUnsafeBufferPointer { u in
                try p.v.withUnsafeBufferPointer { v in
                    try metal.beginPartition(y: y.baseAddress!, u: u.baseAddress!, v: v.baseAddress!,
                                             width: p.width, height: p.height, qindex: qindex, skip: copies.skip,
                                             motion: copies.candidates, sbQindex: qmap, after: gateValue)
                }
            }
        }
        // a key frame's intra block copy hashes, while its analysis runs on the GPU
        var hashes: IbcHashes?
        if intraBlockCopy && copies.motion == nil {
            let h = try takeHashes()
            p.y.withUnsafeBufferPointer { av1enc_ibc_hashes_compute(h.handle, $0.baseAddress, UInt32(p.width), UInt32(p.height)) }
            hashes = h
        }
        return Pending(partition: partition, motion: copies.motion, searchesMotion: copies.candidates != nil,
                       motionSeconds: copies.seconds, qmap: qmap, hashes: hashes, refs: copies.refs)
    }

    private func finish(_ p: Picture, partition: AV1MetalEncoder.Partition, applied pre: Applied? = nil, motion sbMotionIn: [Int32]?,
                        searchesMotion: Bool,
                        refs: Refs?, qindex: Int,
                        qmap: [UInt8]?, hashes: IbcHashes?, timing: Timing, started t0: Double, writingBefore: Writing?,
                        written: (@Sendable (Frame) -> Void)?) throws -> (Writing, Frame?) {
        var timing = timing
        if let hashes {  // (its closed loop's search takes them)
            av1enc_hybrid_use_ibc_hashes(cpu, hashes.handle)
            give(hashes)
        }
        (qmap ?? []).withUnsafeBufferPointer { av1enc_hybrid_set_sb_qindex(cpu, $0.baseAddress, $0.count) }
        var message = [CChar](repeating: 0, count: 256)
        let sbCols0 = (2 * ((p.width + 7) >> 3) + 15) >> 4, sbRows0 = (2 * ((p.height + 7) >> 3) + 15) >> 4
        // an inter frame: the copies, and the blocks with them
        var video = av1g_frame_params()
        var blocks = partition.blocks, lumaTx = partition.lumaTxTypes, inter: [av1g_block_inter] = []
        var sbMotion: [Int32] = []
        let reference = sbMotionIn != nil ? previous : nil
        if interFrames, reference == nil {
            slotPlanes = Array(repeating: [], count: 8)  // (a key frame: every slot holds it)
        }
        if interFrames {
            video.video = 1
            video.sb128 = streamSB128 ? 1 : 0
            if let streamSize {
                (video.stream_width, video.stream_height) = (UInt16(streamSize.width), UInt16(streamSize.height))
            }
            if streamSB128, sbMotionIn == nil || reference == nil {
                // a key frame: its blocks in the 128×128 superblocks' decode order
                var outBlocks: UnsafePointer<av1g_block>?, outInter: UnsafePointer<av1g_block_inter>?, outTx: UnsafePointer<UInt8>?
                let n = partition.blocks.withUnsafeBufferPointer { b in
                    partition.lumaTxTypes.withUnsafeBufferPointer { t in
                        av1enc_motion_apply_ex(motion, nil, b.baseAddress, UInt32(b.count), gpuDecides ? t.baseAddress : nil, nil,
                                               Int32(p.width), Int32(p.height), 1, Int32(tiling.columnsLog2), Int32(tiling.rowsLog2),
                                               &outBlocks, &outInter, &outTx)
                    }
                }
                guard n > 0, let outBlocks, let outTx else { throw Failure.encode("128×128 order: no blocks") }
                blocks = Array(UnsafeBufferPointer(start: outBlocks, count: Int(n)))
                lumaTx = Array(UnsafeBufferPointer(start: outTx, count: Int(n)))
            }
            if reference != nil, let sbMotionIn {
                video.frame_type = UInt8(AV1G_FRAME_INTER)
                let refs = refs ?? Refs()
                if refs.keepsKey >= 0 {
                    slotPlanes[refs.keepsKey] = previousDecoded(width: p.width, height: p.height)
                }
                video.ref_slot = UInt8(refs.last)
                video.golden_slot = refs.golden > 0 && slotPlanes[refs.golden - 1].count == 3 ? UInt8(refs.golden) : 0
                timing.goldenRank = video.golden_slot != 0 ? refs.goldenRank : -1
                timing.goldenSlot = Int(video.golden_slot) - 1
                video.refresh_frame_flags = UInt8(refs.refresh)
                video.lf_inter_off = 1
                video.allow_screen_content_tools = 1
                video.cdf_from_ref = carriesCDFs ? 1 : 0
                // (the frame's: `motionSkip` decides it frame by frame)
                video.mv_precision = searchesMotion && searchesSubpelMotion ? 1 : 0
                timing.searchedMotion = searchesMotion
                sbMotion = sbMotionIn
                let copies = (0..<(sbCols0 * sbRows0)).filter { sbMotion[3 * $0] != 0 }.count
                // (applied by the partition's reader, or here)
                let applied = try pre ?? apply(motion, sbMotion, to: partition, width: p.width, height: p.height)
                (blocks, inter, lumaTx) = (applied.blocks, applied.inter, applied.lumaTx)
                timing.searched = Double(applied.searchedArea) / Double(p.width * p.height)
                let nsb = sbCols0 * sbRows0
                timing.copied = Double(copies) / Double(nsb)
                timing.copiedGolden = Double((0..<nsb).filter { sbMotion[3 * $0] == 2 }.count) / Double(nsb)
                timing.shifted = Double((0..<nsb).filter { sbMotion[3 * $0] != 0 && (sbMotion[3 * $0 + 1] != 0 || sbMotion[3 * $0 + 2] != 0) }.count) / Double(nsb)
            }
        }
        let refPlanes = reference?.planes ?? []
        let gpuRef = reference != nil && previousOnGPU ? (postfilter.outputPlanes, postfilter.outputStrides) : nil
        // the filters read the analysis's padded source, and so does an inter frame's closed loop
        // (a key frame's pads its own, which the next picture's compares tiles with)
        let analysisSource: [UnsafePointer<UInt8>?] = partition.source.count == 3
            ? partition.source.map { UnsafePointer($0.contents().assumingMemoryBound(to: UInt8.self)) } : []
        let padded = reference != nil && sbMotionIn != nil ? analysisSource : []
        // a stream's reconstruction goes into the filters' buffers, which deblock it in place (an
        // inter frame's straight there, a key frame's copied)
        var geometry = av1g_frame_params()
        (geometry.width, geometry.height) = (UInt32(p.width), UInt32(p.height))
        let store = interFrames && postfilters ? try postfilter.reconstructionBuffers(params: geometry) : []
        let into: [UnsafeMutablePointer<UInt8>?] = store.map { $0.contents().assumingMemoryBound(to: UInt8.self) }
        // a frame that swaps the slots keeps the previous picture as a long-term one (below): its
        // decoded planes, copied out of the filters' buffers beside the closed loop, which only
        // reads them (unless it reconstructs into them: with CDEF off they're the same buffers)
        let swapsOut = refs.map { $0.swaps } == true && reference != nil
        let keeping: Later<[[UInt8]]>? = swapsOut && previousOnGPU && postfilter.outputPlanes.first.map { out in
            !into.contains { $0.map { UnsafePointer($0) == out } == true }
        } == true ? Later { [width = p.width, height = p.height] in self.previousDecoded(width: width, height: height) } : nil
        Self.trace("closed loop start")
        let rc = p.y.withUnsafeBufferPointer { y in
            p.u.withUnsafeBufferPointer { u in
                p.v.withUnsafeBufferPointer { v in
                    blocks.withUnsafeBufferPointer { blocks in
                        lumaTx.withUnsafeBufferPointer { types in
                            inter.withUnsafeBufferPointer { inter in
                                Self.reference(refPlanes, gpu: gpuRef, golden: video.golden_slot != 0 ? slotPlanes[Int(video.golden_slot) - 1] : [],
                                               width: p.width) { ref in
                                    withUnsafePointer(to: video) { vp in
                                    av1enc_hybrid_closed_loop_ex(cpu, y.baseAddress, u.baseAddress, v.baseAddress, UInt32(p.width),
                                                                 UInt32(p.height), blocks.baseAddress, UInt32(blocks.count),
                                                                 gpuDecides ? types.baseAddress : nil,
                                                                 gpuDecides && partition.hasChroma ? Int32(AV1ENC_HYBRID_GIVEN_CHROMA) : 0,
                                                                 Int32(qindex), Int32(tiling.columnsLog2), Int32(tiling.rowsLog2),
                                                                 interFrames ? vp : nil, inter.isEmpty ? nil : inter.baseAddress,
                                                                 ref, padded.isEmpty ? nil : padded, into.isEmpty ? nil : into,
                                                                 &message, 256)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard rc == AV1G_OK, let record = av1enc_hybrid_record(cpu) else {
            throw Failure.encode("closed loop (\(rc)): \(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))")
        }
        Self.trace("closed loop end")
        timing.chroma = av1enc_hybrid_seconds(cpu, 0)
        timing.closedLoop = av1enc_hybrid_seconds(cpu, 1)
        // a frame that swaps the slots keeps the previous picture as a long-term one: its decoded
        // planes, before this one's filters overwrite them (and the slot this one goes into drops its)
        if let refs, swapsOut {
            slotPlanes[refs.last] = try keeping?.wait() ?? previousDecoded(width: p.width, height: p.height)
            slotPlanes[refs.refresh.trailingZeroBitCount] = []
        }
        let tileCount = (1 << max(0, tiling.columnsLog2)) * (1 << max(0, tiling.rowsLog2))
        timing.keptTiles = Double(av1enc_hybrid_reused_tiles(cpu)) / Double(tileCount)

        let t1 = CACurrentMediaTime()
        // a key frame with intra block copies has no post-filters (its reconstruction is its own, not
        // the filters' buffers)
        let copies = record.pointee.fp.allow_intrabc != 0
        if copies, let inter = record.pointee.inter {
            var area = 0
            for k in 0..<Int(record.pointee.n_blocks) where inter[k].is_inter != 0 {
                let size = AV1MetalEncoder.blockSizes[Int(record.pointee.blocks[k].bsize)]
                area += size.w * size.h
            }
            timing.intraCopied = Double(area) / Double(p.width * p.height)
        }
        var recon: [UnsafePointer<UInt8>] = [], source: [UnsafePointer<UInt8>] = [], strides: [Int] = []
        for plane in 0..<3 {
            var stride: Int32 = 0
            guard let r = store.isEmpty || copies ? av1enc_hybrid_recon(cpu, Int32(plane)) : UnsafePointer(into[plane]),
                  let s = analysisSource.isEmpty ? av1enc_hybrid_source(cpu, Int32(plane), &stride) : analysisSource[plane]
            else { throw Failure.encode("no reconstruction") }
            recon.append(r)
            source.append(s)
            strides.append(analysisSource.isEmpty ? Int(stride) : partition.sourceStrides[plane])
        }
        let n = Int(record.pointee.n_blocks)
        guard postfilters, !copies else {
            // (a stream with post-filters keeps CDEF on in its sequence header, for its inter frames)
            filtered()  // (none)
            let ended = try writingBefore?.end()  // (the writer's state, back for this write)
            let frame = try write(p, record: record, recon: recon, sequenceCDEF: postfilters && interFrames, timing: timing,
                                  t0: t0, t1: t1)
            filteredLast = false
            remember(p, frame.planes, sbMotion)
            written?(frame)
            return (Writing(frame), ended)
        }
        var changed = [UInt8](repeating: 1, count: sbCols0 * sbRows0)
        var direct: [UInt8]?
        let known: Bool
        if reference != nil {
            var d = [UInt8](repeating: 0, count: sbCols0 * sbRows0)
            known = reusesAnalysis && Self.filterRegions(now: sbMotion, before: previous?.motion ?? [], sbCols: sbCols0,
                                                         sbRows: sbRows0, changed: &changed, direct: &d)
            direct = d
        } else {
            known = reusesAnalysis && filteredLast
                && av1enc_hybrid_changed_superblocks(cpu, &changed, Int32(sbCols0), Int32(sbRows0)) != 0
        }
        filteredLast = true
        Self.trace("filters start")
        let search = try postfilter.search(params: record.pointee.fp,
                                           blocks: UnsafeBufferPointer(start: record.pointee.blocks, count: n),
                                           planes: recon, source: source, sourceStrides: strides,
                                           sourceBuffers: analysisSource.isEmpty ? nil : partition.source,
                                           changed: known ? changed : nil, direct: known ? direct : nil,
                                           lfZero: inter.isEmpty ? nil : (0..<n).map { record.pointee.inter[$0].is_inter != 0 ? 3 : 0 },
                                           cropsOutput: returnsPlanes)
        let sbCols = sbCols0
        let t2 = CACurrentMediaTime()
        Self.trace("filters end")
        filtered()
        timing.filters = t2 - t1
        timing.filtered = postfilter.lastFilteredShare
        timing.filtersGPU = postfilter.lastGPUSeconds

        remember(p, search.planes, sbMotion)
        // the previous picture's write ran beside this closed loop and these filters: taken back
        // now, before this one's begins
        let ended = try writingBefore?.end()
        let writing = try Writing(cpu: cpu, search: search, sbCols: sbCols, flags: headerFlags(search.params), timing: timing,
                                  t0: t0, t2: t2, written: written)
        return (writing, ended)
    }

    /// The writer's flags for a frame: an inter frame of a stream without its sequence header.
    private func headerFlags(_ fp: av1g_frame_params) -> UInt32 {
        omitsSequenceHeaders && fp.frame_type == UInt8(AV1G_FRAME_INTER) ? UInt32(AV1G_ENC_NO_SEQ_HEADER) : 0
    }

    /// The picture the next inter frame references.
    private func remember(_ p: Picture, _ planes: [[UInt8]], _ sbMotion: [Int32]) {
        previous = interFrames ? (p, planes, sbMotion) : nil
        previousOnGPU = interFrames && planes.isEmpty
    }

    /// Per 64×64 of an inter frame, how the post-filters treat it. `changed`: the coded ones
    /// (intra blocks). `direct`: copies that differ from the previous picture's output, whose
    /// filtered samples are their reconstruction unless an intra block is next to them (a coded
    /// 64×64 around them, which `changed` covers). The rest are the previous picture's: copies at
    /// no motion now that were copies in the previous picture (an inter frame's decisions in
    /// `before`) with no coded 64×64 around them then (deblocking an edge with an intra block
    /// changes both sides, and the copy now holds that). False when the previous picture wasn't
    /// an inter frame.
    static func filterRegions(now: [Int32], before: [Int32], sbCols: Int, sbRows: Int,
                              changed: inout [UInt8], direct: inout [UInt8]) -> Bool {
        let nsb = sbCols * sbRows
        guard now.count == 3 * nsb, before.count == 3 * nsb else { return false }
        for r in 0..<sbRows {
            for c in 0..<sbCols {
                let s = r * sbCols + c
                guard now[3 * s] != 0 else {
                    (changed[s], direct[s]) = (1, 0)
                    continue
                }
                var same = now[3 * s] == 1 && now[3 * s + 1] == 0 && now[3 * s + 2] == 0
                for dr in -1...1 where same {
                    for dc in -1...1 where r + dr >= 0 && r + dr < sbRows && c + dc >= 0 && c + dc < sbCols {
                        if before[3 * ((r + dr) * sbCols + c + dc)] == 0 { same = false }
                    }
                }
                (changed[s], direct[s]) = (0, same ? 0 : 1)
            }
        }
        return true
    }

    /// A picture's planes as C pointers.
    static func planes<R>(_ p: Picture, _ body: ([UnsafePointer<UInt8>?]) throws -> R) rethrows -> R {
        try p.y.withUnsafeBufferPointer { y in
            try p.u.withUnsafeBufferPointer { u in
                try p.v.withUnsafeBufferPointer { v in try body([y.baseAddress, u.baseAddress, v.baseAddress]) }
            }
        }
    }

    /// Pictures' planes as C pointers, three each, in order.
    static func planes<R>(_ ps: ArraySlice<Picture>, _ before: [UnsafePointer<UInt8>?] = [],
                          _ body: ([UnsafePointer<UInt8>?]) throws -> R) rethrows -> R {
        guard let first = ps.first else { return try body(before) }
        return try planes(first) { try planes(ps.dropFirst(), before + $0, body) }
    }

    /// The reference picture (cropped planes, tight) as av1g_ref_planes; nil when there's none.
    /// With `golden` (tight planes), two: the reference's, then GOLDEN_FRAME's.
    static func reference<R>(_ planes: [[UInt8]], gpu: ([UnsafePointer<UInt8>], [Int])?, golden: [[UInt8]] = [],
                             width: Int, _ body: (UnsafePointer<av1g_ref_planes>?) -> R) -> R {
        let cw = Int32((width + 1) / 2)
        func tight(_ q: [[UInt8]], _ body: (av1g_ref_planes) -> R) -> R {
            q[0].withUnsafeBufferPointer { y in
                q[1].withUnsafeBufferPointer { u in
                    q[2].withUnsafeBufferPointer { v in
                        var r = av1g_ref_planes()
                        r.plane = (y.baseAddress, u.baseAddress, v.baseAddress)
                        r.stride = (Int32(width), cw, cw)
                        return body(r)
                    }
                }
            }
        }
        func with(_ last: av1g_ref_planes) -> R {
            guard golden.count == 3 else { return withUnsafePointer(to: last) { body($0) } }
            return tight(golden) { g in [last, g].withUnsafeBufferPointer { body($0.baseAddress) } }
        }
        if let (p, s) = gpu, p.count == 3, s.count == 3 {
            var r = av1g_ref_planes()
            r.plane = (p[0], p[1], p[2])
            r.stride = (Int32(s[0]), Int32(s[1]), Int32(s[2]))
            return with(r)
        }
        guard planes.count == 3 else { return body(nil) }
        return tight(planes) { with($0) }
    }

    /// The previous picture's decoded planes, tight (a copy of the filters' buffers when they
    /// hold them).
    private func previousDecoded(width: Int, height: Int) -> [[UInt8]] {
        guard previousOnGPU else { return previous?.planes ?? [] }
        let p = postfilter.outputPlanes, s = postfilter.outputStrides
        guard p.count == 3, s.count == 3 else { return [] }
        return (0..<3).map { k in
            let (w, h) = k == 0 ? (width, height) : ((width + 1) / 2, (height + 1) / 2)
            var out = [UInt8](repeating: 0, count: w * h)
            out.withUnsafeMutableBufferPointer { o in
                for row in 0..<h { (o.baseAddress! + row * w).update(from: p[k] + row * s[k], count: w) }
            }
            return out
        }
    }

    /// The picture without post-filters: the record's parameters (no deblocking, no CDEF) and the
    /// reconstruction, cropped. `sequenceCDEF`: the sequence header enables CDEF all the same (a
    /// frame with intra block copies, which codes none, of a stream whose other frames filter).
    private func write(_ p: Picture, record: UnsafeMutablePointer<av1g_decision_record>, recon: [UnsafePointer<UInt8>],
                       sequenceCDEF: Bool, timing: Timing, t0: Double, t1: Double) throws -> Frame {
        var timing = timing
        var params = record.pointee.fp
        params.loop_filter_level = (0, 0, 0, 0)
        params.enable_cdef = sequenceCDEF && params.allow_intrabc != 0 ? 1 : 0
        params.cdef_bits = 0
        var message = [CChar](repeating: 0, count: 256)
        var bytes: UnsafeMutablePointer<UInt8>?
        var size = 0
        let wrc = av1enc_hybrid_write_ex(cpu, &params, nil, 0, headerFlags(params), &bytes, &size, &message, 256)
        guard wrc == AV1G_OK, let bytes else {
            throw Failure.encode("writer (\(wrc)): \(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))")
        }
        defer { free(bytes) }
        let obu = Array(UnsafeBufferPointer(start: bytes, count: size))
        let paddedWidth = 2 * ((p.width + 7) >> 3) * 4
        let planes = (0..<3).map { plane -> [UInt8] in
            let w = plane == 0 ? p.width : (p.width + 1) / 2, h = plane == 0 ? p.height : (p.height + 1) / 2
            let stride = plane == 0 ? paddedWidth : paddedWidth / 2
            return [UInt8](unsafeUninitializedCapacity: w * h) { d, count in
                for row in 0..<h { (d.baseAddress! + row * w).update(from: recon[plane] + row * stride, count: w) }
                count = w * h
            }
        }
        let t3 = CACurrentMediaTime()
        timing.filters = 0
        timing.writer = t3 - t1
        timing.wall = t3 - t0
        return Frame(obu: obu, planes: planes, params: params, timing: timing)
    }
}
