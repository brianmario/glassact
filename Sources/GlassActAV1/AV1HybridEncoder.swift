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
        /// Inter frames: the share of 64×64s copied from the previous picture (unchanged or
        /// shifted), and of those at a shift; the time deciding them.
        public var copied = 0.0, shifted = 0.0, motion = 0.0
        /// Inter frames: the share of the picture in blocks the motion search predicts (with a residual).
        public var searched = 0.0
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

    /// See `AV1MetalEncoder.learnedPrune` (on: `defaultLearnedPrune`).
    public var learnedPrune: AV1MetalEncoder.LearnedPrune? {
        get { metal.learnedPrune }
        set { metal.learnedPrune = newValue }
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

    /// The previous picture's decoded planes are the post-filter's buffers (not `previous.planes`).
    private var previousOnGPU = false

    /// The current stream's superblock size (set when it starts).
    private var streamSB128 = false

    /// The post-filters' output is the last picture's (false after a picture with intra block
    /// copies, which has none: the next one is filtered whole).
    private var filteredLast = true

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
        postfilter = try AV1MetalPostfilter(device: device)
        guard let cpu = av1enc_hybrid_create(), let motion = av1enc_motion_create() else { throw Failure.encode("no CPU state") }
        self.cpu = cpu
        self.motion = motion
        av1enc_hybrid_set_intrabc(cpu, 1)
        copyFinder = try CopyFinder()
        applyRDOQ()
    }

    deinit {
        av1enc_hybrid_destroy(cpu)
        av1enc_motion_destroy(motion)
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
                       output: (Int, Frame) throws -> Void) throws {
        guard count > 0 else { return }
        previous = nil
        streamSB128 = interFrames && largeSuperblocks
        metal.largeSuperblocks = streamSB128
        if interFrames { metal.forgetAnalysis() }  // the cache may hold an earlier stream's inter frames
        // picture i - 1's bitstream, being written while picture i + 1's analysis starts, which
        // is also on a thread of its own (`starting`), as is picture i + 2's after it (`following`)
        var writing: Writing?
        var starting: Later<Pending>?, following: Later<Pending>?
        defer {
            copyFinder.drain()
            _ = try? writing?.wait()
            _ = try? starting?.wait()
            _ = try? following?.wait()
        }
        var current = try picture(0)
        var pending = try begin(current, Copies(), qindex: qindex)
        // picture i + 1's analysis is set up while picture i - 1 is finished, and committed: its
        // command buffer waits on the GPU until picture i's results are read
        // (AV1MetalEncoder.readEvent), so its GPU work starts as soon as they are. Its copies are
        // decided (on the CPU, from the two sources alone) before that.
        var next = count > 1 ? try picture(1) : nil
        if let next {
            if interFrames { copyFinder.start(next, after: current, searchesMotion: searchesMotion) }
            let copies = interFrames ? copyFinder.wait() : Copies()
            starting = Later { try self.begin(next, copies, qindex: qindex) }
        }
        var upcoming = count > 2 ? try picture(2) : nil
        if interFrames, let upcoming, let next { copyFinder.start(upcoming, after: next, searchesMotion: searchesMotion) }
        for i in 0..<count {
            let partition = try pending.partition.wait()
            // picture i + 2's analysis, set up after picture i + 1's (two at most are set up and not
            // yet read: their kept-analysis buffers alternate)
            let afterNext = upcoming
            if let up = upcoming {
                let copies = interFrames ? copyFinder.wait() : Copies()
                let before = starting
                following = Later {
                    _ = try before?.wait()
                    return try self.begin(up, copies, qindex: qindex)
                }
                upcoming = i + 3 < count ? try picture(i + 3) : nil
                if interFrames, let upcoming { copyFinder.start(upcoming, after: up, searchesMotion: searchesMotion) }
            }
            let t0 = CACurrentMediaTime()
            var timing = Timing()
            timing.analysis = metal.lastGPUSeconds
            let sbs = ((2 * ((current.width + 7) >> 3) + 15) >> 4) * ((2 * ((current.height + 7) >> 3) + 15) >> 4)
            timing.kept = Double(pending.partition.keptSuperblocks) / Double(max(1, sbs))
            timing.motion = pending.motionSeconds
            let motion = pending.motion
            if let w = writing {
                writing = nil
                try output(i - 1, try w.wait())
            }
            writing = try finish(current, partition: partition, motion: motion, qindex: qindex, qmap: pending.qmap,
                                 hashes: pending.hashes, timing: timing, started: t0)
            if let s = starting {
                starting = following
                following = nil
                pending = try s.wait()
            }
            if let n = next {
                current = n
                next = afterNext
            }
        }
        if let w = writing {
            writing = nil
            try output(count - 1, try w.wait())
        }
    }

    /// Work on a thread of its own, and its result.
    private final class Later<T>: @unchecked Sendable {
        private var result: Result<T, any Error>?
        private let done = DispatchSemaphore(value: 0)

        init(_ work: @escaping @Sendable () throws -> T) {
            DispatchQueue.global(qos: .userInitiated).async {
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

    /// A picture's bitstream, written on a thread of its own (`av1enc_hybrid_write_ex`) while
    /// the main thread starts the next picture's analysis. It's waited for before the next
    /// closed loop, which uses the same CPU state.
    private final class Writing: @unchecked Sendable {
        private let cpu: OpaquePointer?
        private var params: av1g_frame_params
        private let frameParams: av1g_frame_params
        private let cdef: [Int8]
        private let sbCols: Int, flags: UInt32
        private let planes: [[UInt8]]
        private var timing: Timing
        private let t0: Double, t2: Double
        private var result: Result<Frame, any Error>?
        private let done = DispatchSemaphore(value: 0)

        /// Starts writing the last closed loop's picture with the filters' choices.
        init(cpu: OpaquePointer, search: AV1MetalPostfilter.Search, sbCols: Int, flags: UInt32, timing: Timing,
             t0: Double, t2: Double) {
            self.cpu = cpu
            params = search.params
            frameParams = search.params
            cdef = search.superblockCDEF
            self.sbCols = sbCols
            self.flags = flags
            planes = search.planes
            self.timing = timing
            self.t0 = t0
            self.t2 = t2
            DispatchQueue.global(qos: .userInitiated).async {
                self.result = Result { try self.write() }
                self.done.signal()
            }
        }

        /// A picture already written.
        init(_ frame: Frame) {
            (cpu, params, frameParams, cdef, sbCols, flags) = (nil, frame.params, frame.params, [], 0, 0)
            (planes, timing, t0, t2) = (frame.planes, frame.timing, 0, 0)
            result = .success(frame)
            done.signal()
        }

        /// The picture's frame, once written.
        func wait() throws -> Frame {
            done.wait()
            done.signal()  // for a later wait (an encode that threw)
            return try result!.get()
        }

        private func write() throws -> Frame {
            var message = [CChar](repeating: 0, count: 256)
            var bytes: UnsafeMutablePointer<UInt8>?
            var size = 0
            let wrc = cdef.withUnsafeBufferPointer { cdef in
                av1enc_hybrid_write_ex(cpu, &params, cdef.baseAddress, Int32(sbCols), flags, &bytes, &size, &message, 256)
            }
            guard wrc == AV1G_OK, let bytes else {
                throw Failure.encode("writer (\(wrc)): \(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))")
            }
            defer { free(bytes) }
            let obu = Array(UnsafeBufferPointer(start: bytes, count: size))
            let t3 = CACurrentMediaTime()
            timing.writer = t3 - t2
            timing.wall = t3 - t0
            return Frame(obu: obu, planes: planes, params: frameParams, timing: timing)
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
        /// Per 64×64: copy, dx, dy (nil: a key frame or a still picture).
        var motion: [Int32]?
        var motionSeconds = 0.0
        /// The picture's qindex per 64×64 (`sbQindex`'s), or nil.
        var qmap: [UInt8]? = nil
        /// A key frame's intra block copy hashes, or nil.
        var hashes: IbcHashes? = nil
    }

    /// Decides inter frames' copies on a thread of its own, with a motion handle of its own (the
    /// encoder's applies them, which doesn't read what classifying left in it).
    private final class CopyFinder: @unchecked Sendable {
        private let motion: OpaquePointer
        private var result: Copies?
        private var running = false
        private let done = DispatchSemaphore(value: 0)

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

        private func copies(of p: Picture, after prev: Picture, searchesMotion: Bool) -> Copies {
            guard prev.width == p.width, prev.height == p.height else { return Copies() }
            let tm = CACurrentMediaTime()
            let nsb = ((p.width + 63) / 64) * ((p.height + 63) / 64)
            var m = [Int32](repeating: 0, count: 3 * nsb)
            AV1HybridEncoder.planes(p) { cur in
                AV1HybridEncoder.planes(prev) { before in
                    let strides: [Int32] = [Int32(p.width), Int32((p.width + 1) / 2), Int32((p.width + 1) / 2)]
                    _ = av1enc_motion_classify(motion, cur, strides, before, strides, Int32(p.width), Int32(p.height), 3, 8, &m)
                }
            }
            var candidates: [Int32]?
            if searchesMotion {
                var c = [Int32](repeating: 0, count: 2 * Int(GP_ME_CANDS))
                c.removeLast(c.count - 2 * Int(av1enc_motion_candidates(motion, &c, GP_ME_CANDS)))
                candidates = c
            }
            return Copies(motion: m, skip: (0..<nsb).map { UInt8(m[3 * $0]) }, candidates: candidates,
                          seconds: CACurrentMediaTime() - tm)
        }
    }

    /// An inter frame's copies, decided before its analysis (none: a key frame).
    private struct Copies {
        /// Per 64×64: copy, dx, dy.
        var motion: [Int32]?
        /// Per 64×64: nonzero where it's a copy (not analyzed).
        var skip: [UInt8]?
        /// The frame's shift candidates for the motion search.
        var candidates: [Int32]?
        var seconds = 0.0
    }

    /// Starts picture `p`'s analysis, without its copies.
    private func begin(_ p: Picture, _ copies: Copies, qindex: Int) throws -> Pending {
        let sbs = ((p.width + 63) / 64) * ((p.height + 63) / 64)
        let qmap = sbQindex?(p, qindex).flatMap { $0.count == sbs ? $0 : nil }
        let partition = try p.y.withUnsafeBufferPointer { y in
            try p.u.withUnsafeBufferPointer { u in
                try p.v.withUnsafeBufferPointer { v in
                    try metal.beginPartition(y: y.baseAddress!, u: u.baseAddress!, v: v.baseAddress!,
                                             width: p.width, height: p.height, qindex: qindex, skip: copies.skip,
                                             motion: copies.candidates, sbQindex: qmap)
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
        return Pending(partition: partition, motion: copies.motion, motionSeconds: copies.seconds, qmap: qmap, hashes: hashes)
    }

    private func finish(_ p: Picture, partition: AV1MetalEncoder.Partition, motion sbMotionIn: [Int32]?, qindex: Int,
                        qmap: [UInt8]?, hashes: IbcHashes?, timing: Timing, started t0: Double) throws -> Writing {
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
                video.refresh_frame_flags = 1  // slot 0: always the previous picture
                video.lf_inter_off = 1
                video.allow_screen_content_tools = 1
                video.cdf_from_ref = carriesCDFs ? 1 : 0
                video.mv_precision = searchesMotion && searchesSubpelMotion ? 1 : 0
                sbMotion = sbMotionIn
                let copies = (0..<(sbCols0 * sbRows0)).filter { sbMotion[3 * $0] != 0 }.count
                var outBlocks: UnsafePointer<av1g_block>?, outInter: UnsafePointer<av1g_block_inter>?, outTx: UnsafePointer<UInt8>?
                let n = partition.blocks.withUnsafeBufferPointer { b in
                    partition.lumaTxTypes.withUnsafeBufferPointer { t in
                        partition.inter.withUnsafeBufferPointer { searched in
                            av1enc_motion_apply_ex(motion, sbMotion, b.baseAddress, UInt32(b.count), gpuDecides ? t.baseAddress : nil,
                                                   searched.count == b.count ? searched.baseAddress : nil,
                                                   Int32(p.width), Int32(p.height), streamSB128 ? 1 : 0,
                                                   Int32(tiling.columnsLog2), Int32(tiling.rowsLog2), &outBlocks, &outInter, &outTx)
                        }
                    }
                }
                guard n > 0, let outBlocks, let outInter, let outTx else { throw Failure.encode("motion: no blocks") }
                blocks = Array(UnsafeBufferPointer(start: outBlocks, count: Int(n)))
                inter = Array(UnsafeBufferPointer(start: outInter, count: Int(n)))
                var area = 0
                for (b, i) in zip(blocks, inter) where i.is_inter != 0 && b.skip == 0 {
                    let size = AV1MetalEncoder.blockSizes[Int(b.bsize)]
                    area += size.w * size.h
                }
                timing.searched = Double(area) / Double(p.width * p.height)
                lumaTx = Array(UnsafeBufferPointer(start: outTx, count: Int(n)))
                let nsb = sbCols0 * sbRows0
                timing.copied = Double(copies) / Double(nsb)
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
        let rc = p.y.withUnsafeBufferPointer { y in
            p.u.withUnsafeBufferPointer { u in
                p.v.withUnsafeBufferPointer { v in
                    blocks.withUnsafeBufferPointer { blocks in
                        lumaTx.withUnsafeBufferPointer { types in
                            inter.withUnsafeBufferPointer { inter in
                                Self.reference(refPlanes, gpu: gpuRef, width: p.width) { ref in
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
        timing.chroma = av1enc_hybrid_seconds(cpu, 0)
        timing.closedLoop = av1enc_hybrid_seconds(cpu, 1)
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
            let frame = try write(p, record: record, recon: recon, sequenceCDEF: postfilters && interFrames, timing: timing,
                                  t0: t0, t1: t1)
            filteredLast = false
            remember(p, frame.planes, sbMotion)
            return Writing(frame)
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
        let search = try postfilter.search(params: record.pointee.fp,
                                           blocks: UnsafeBufferPointer(start: record.pointee.blocks, count: n),
                                           planes: recon, source: source, sourceStrides: strides,
                                           sourceBuffers: analysisSource.isEmpty ? nil : partition.source,
                                           changed: known ? changed : nil, direct: known ? direct : nil,
                                           lfZero: inter.isEmpty ? nil : inter.map { $0.is_inter != 0 ? 3 : 0 },
                                           cropsOutput: returnsPlanes)
        let sbCols = sbCols0
        let t2 = CACurrentMediaTime()
        timing.filters = t2 - t1
        timing.filtered = postfilter.lastFilteredShare

        remember(p, search.planes, sbMotion)
        return Writing(cpu: cpu, search: search, sbCols: sbCols, flags: headerFlags(search.params), timing: timing, t0: t0, t2: t2)
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
                var same = now[3 * s + 1] == 0 && now[3 * s + 2] == 0
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

    /// The reference picture (cropped planes, tight) as av1g_ref_planes; nil when there's none.
    static func reference<R>(_ planes: [[UInt8]], gpu: ([UnsafePointer<UInt8>], [Int])?, width: Int,
                             _ body: (UnsafePointer<av1g_ref_planes>?) -> R) -> R {
        if let (p, s) = gpu, p.count == 3, s.count == 3 {
            var r = av1g_ref_planes()
            r.plane = (p[0], p[1], p[2])
            r.stride = (Int32(s[0]), Int32(s[1]), Int32(s[2]))
            return body(&r)
        }
        guard planes.count == 3 else { return body(nil) }
        return planes[0].withUnsafeBufferPointer { y in
            planes[1].withUnsafeBufferPointer { u in
                planes[2].withUnsafeBufferPointer { v in
                    var r = av1g_ref_planes()
                    r.plane = (y.baseAddress, u.baseAddress, v.baseAddress)
                    r.stride = (Int32(width), Int32((width + 1) / 2), Int32((width + 1) / 2))
                    return body(&r)
                }
            }
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
