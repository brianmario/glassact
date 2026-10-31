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

    /// Skip 32×32-and-up analysis where the source is busy
    /// (`AV1MetalEncoder.busyBlockPrune`; 4 by default, 0 off, 1 faster).
    public var busyBlockPrune: Float {
        get { metal.busyBlockPrune }
        set { metal.busyBlockPrune = newValue }
    }

    /// The largest block whose luma tx type the GPU searches
    /// (`AV1MetalEncoder.leafTxSearchPixels`; 128 by default, 256 for every one).
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

    /// With `interFrames`: search the coded 64×64s for motion too (on). A block
    /// predicted from the previous picture at a vector, with a residual, takes the
    /// place of an intra one where it costs less. Off: copies only.
    public var searchesMotion = true

    /// With `interFrames`: an inter frame starts from the CDFs its reference frame
    /// saved instead of the defaults (on), so a picture that hardly changed costs
    /// few bits. Loss-safe as long as the reference is a frame the decoder has.
    public var carriesCDFs = true

    /// With `searchesMotion`: refine motion vectors to quarter samples (scaled or
    /// animated content moves by fractions of a sample). Off: whole samples.
    public var searchesSubpelMotion: Bool {
        get { metal.searchesSubpelMotion }
        set { metal.searchesSubpelMotion = newValue }
    }

    /// The last picture, for the next inter frame: its source, decoded
    /// output and per-64×64 decisions (copy, dx, dy).
    private var previous: (source: Picture, planes: [[UInt8]], motion: [Int32])?

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
        metal.leafTxSearchPixels = 128
        metal.leafChromaAngledModes = false
        postfilter = try AV1MetalPostfilter(device: device)
        guard let cpu = av1enc_hybrid_create(), let motion = av1enc_motion_create() else { throw Failure.encode("no CPU state") }
        self.cpu = cpu
        self.motion = motion
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
    /// inter frames.
    public func encode(count: Int, qindex: Int, picture: (Int) throws -> Picture,
                       output: (Int, Frame) throws -> Void) throws {
        guard count > 0 else { return }
        previous = nil
        if interFrames { metal.forgetAnalysis() }  // the cache may hold an earlier stream's inter frames
        var current = try picture(0)
        var pending = try begin(current, after: nil, qindex: qindex)
        for i in 0..<count {
            let partition = try pending.partition.wait()
            let t0 = CACurrentMediaTime()
            var timing = Timing()
            timing.analysis = metal.lastGPUSeconds
            let sbs = ((2 * ((current.width + 7) >> 3) + 15) >> 4) * ((2 * ((current.height + 7) >> 3) + 15) >> 4)
            timing.kept = Double(pending.partition.keptSuperblocks) / Double(max(1, sbs))
            timing.motion = pending.motionSeconds
            let motion = pending.motion
            var next: Picture?
            if i + 1 < count {
                let n = try picture(i + 1)
                pending = try begin(n, after: current, qindex: qindex)
                next = n
            }
            let frame = try finish(current, partition: partition, motion: motion, qindex: qindex, timing: timing, started: t0)
            try output(i, frame)
            if let next { current = next }
        }
    }

    /// A picture's analysis under way, and its copies (an inter frame's).
    private struct Pending {
        var partition: AV1MetalEncoder.PendingPartition
        /// Per 64×64: copy, dx, dy (nil: a key frame or a still picture).
        var motion: [Int32]?
        var motionSeconds = 0.0
    }

    /// Starts picture `p`'s analysis. With `interFrames` and the picture before it (`prev`, of the
    /// same size), its 64×64s that copy that picture are decided first and not analyzed.
    private func begin(_ p: Picture, after prev: Picture?, qindex: Int) throws -> Pending {
        var sbMotion: [Int32]?
        var skip: [UInt8]?
        var candidates: [Int32]?
        let tm = CACurrentMediaTime()
        if interFrames, let prev, prev.width == p.width, prev.height == p.height {
            let nsb = ((p.width + 63) / 64) * ((p.height + 63) / 64)
            var m = [Int32](repeating: 0, count: 3 * nsb)
            Self.planes(p) { cur in
                Self.planes(prev) { before in
                    let strides: [Int32] = [Int32(p.width), Int32((p.width + 1) / 2), Int32((p.width + 1) / 2)]
                    _ = av1enc_motion_classify(motion, cur, strides, before, strides, Int32(p.width), Int32(p.height), 3, 8, &m)
                }
            }
            sbMotion = m
            skip = (0..<nsb).map { UInt8(m[3 * $0]) }
            if searchesMotion {
                var c = [Int32](repeating: 0, count: 2 * Int(GP_ME_CANDS))
                c.removeLast(c.count - 2 * Int(av1enc_motion_candidates(motion, &c, GP_ME_CANDS)))
                candidates = c
            }
        }
        let seconds = CACurrentMediaTime() - tm
        let partition = try p.y.withUnsafeBufferPointer { y in
            try p.u.withUnsafeBufferPointer { u in
                try p.v.withUnsafeBufferPointer { v in
                    try metal.beginPartition(y: y.baseAddress!, u: u.baseAddress!, v: v.baseAddress!,
                                             width: p.width, height: p.height, qindex: qindex, skip: skip,
                                             motion: candidates)
                }
            }
        }
        return Pending(partition: partition, motion: sbMotion, motionSeconds: seconds)
    }

    private func finish(_ p: Picture, partition: AV1MetalEncoder.Partition, motion sbMotionIn: [Int32]?, qindex: Int,
                        timing: Timing, started t0: Double) throws -> Frame {
        var timing = timing
        var message = [CChar](repeating: 0, count: 256)
        let sbCols0 = (2 * ((p.width + 7) >> 3) + 15) >> 4, sbRows0 = (2 * ((p.height + 7) >> 3) + 15) >> 4
        // an inter frame: the copies, and the blocks with them
        var video = av1g_frame_params()
        var blocks = partition.blocks, lumaTx = partition.lumaTxTypes, inter: [av1g_block_inter] = []
        var sbMotion: [Int32] = []
        let reference = sbMotionIn != nil ? previous : nil
        if interFrames {
            video.video = 1
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
                            av1enc_motion_apply(motion, sbMotion, b.baseAddress, UInt32(b.count), gpuDecides ? t.baseAddress : nil,
                                                searched.count == b.count ? searched.baseAddress : nil,
                                                Int32(p.width), Int32(p.height), &outBlocks, &outInter, &outTx)
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
        let rc = p.y.withUnsafeBufferPointer { y in
            p.u.withUnsafeBufferPointer { u in
                p.v.withUnsafeBufferPointer { v in
                    blocks.withUnsafeBufferPointer { blocks in
                        lumaTx.withUnsafeBufferPointer { types in
                            inter.withUnsafeBufferPointer { inter in
                                Self.reference(refPlanes, width: p.width) { ref in
                                    withUnsafePointer(to: video) { vp in
                                    av1enc_hybrid_closed_loop_ex(cpu, y.baseAddress, u.baseAddress, v.baseAddress, UInt32(p.width),
                                                                 UInt32(p.height), blocks.baseAddress, UInt32(blocks.count),
                                                                 gpuDecides ? types.baseAddress : nil,
                                                                 gpuDecides && partition.hasChroma ? Int32(AV1ENC_HYBRID_GIVEN_CHROMA) : 0,
                                                                 Int32(qindex), Int32(tiling.columnsLog2), Int32(tiling.rowsLog2),
                                                                 interFrames ? vp : nil, inter.isEmpty ? nil : inter.baseAddress,
                                                                 ref, &message, 256)
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
        var recon: [UnsafePointer<UInt8>] = [], source: [UnsafePointer<UInt8>] = [], strides: [Int] = []
        for plane in 0..<3 {
            var stride: Int32 = 0
            guard let r = av1enc_hybrid_recon(cpu, Int32(plane)), let s = av1enc_hybrid_source(cpu, Int32(plane), &stride)
            else { throw Failure.encode("no reconstruction") }
            recon.append(r)
            source.append(s)
            strides.append(Int(stride))
        }
        let n = Int(record.pointee.n_blocks)
        guard postfilters else {
            let frame = try write(p, record: record, recon: recon, timing: timing, t0: t0, t1: t1)
            remember(p, frame, sbMotion)
            return frame
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
            known = reusesAnalysis && av1enc_hybrid_changed_superblocks(cpu, &changed, Int32(sbCols0), Int32(sbRows0)) != 0
        }
        let search = try postfilter.search(params: record.pointee.fp,
                                           blocks: UnsafeBufferPointer(start: record.pointee.blocks, count: n),
                                           planes: recon, source: source, sourceStrides: strides,
                                           changed: known ? changed : nil, direct: known ? direct : nil,
                                           lfZero: inter.isEmpty ? nil : inter.map(\.is_inter))
        let sbCols = sbCols0
        let t2 = CACurrentMediaTime()
        timing.filters = t2 - t1
        timing.filtered = postfilter.lastFilteredShare

        var params = search.params
        var bytes: UnsafeMutablePointer<UInt8>?
        var size = 0
        let wrc = search.superblockCDEF.withUnsafeBufferPointer { cdef in
            av1enc_hybrid_write(cpu, &params, cdef.baseAddress, Int32(sbCols), &bytes, &size, &message, 256)
        }
        guard wrc == AV1G_OK, let bytes else {
            throw Failure.encode("writer (\(wrc)): \(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))")
        }
        defer { free(bytes) }
        let obu = Array(UnsafeBufferPointer(start: bytes, count: size))
        let t3 = CACurrentMediaTime()
        timing.writer = t3 - t2
        timing.wall = t3 - t0
        let frame = Frame(obu: obu, planes: search.planes, params: search.params, timing: timing)
        remember(p, frame, sbMotion)
        return frame
    }

    /// The picture the next inter frame references.
    private func remember(_ p: Picture, _ frame: Frame, _ sbMotion: [Int32]) {
        previous = interFrames ? (p, frame.planes, sbMotion) : nil
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
    static func reference<R>(_ planes: [[UInt8]], width: Int, _ body: (UnsafePointer<av1g_ref_planes>?) -> R) -> R {
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
    /// reconstruction, cropped.
    private func write(_ p: Picture, record: UnsafeMutablePointer<av1g_decision_record>, recon: [UnsafePointer<UInt8>],
                       timing: Timing, t0: Double, t1: Double) throws -> Frame {
        var timing = timing
        var params = record.pointee.fp
        params.loop_filter_level = (0, 0, 0, 0)
        params.enable_cdef = 0
        params.cdef_bits = 0
        var message = [CChar](repeating: 0, count: 256)
        var bytes: UnsafeMutablePointer<UInt8>?
        var size = 0
        let wrc = av1enc_hybrid_write(cpu, &params, nil, 0, &bytes, &size, &message, 256)
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
