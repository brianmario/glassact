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
/// - The preset search runs on the GPU, a threadgroup per cdef_bits (av1gpu's
///   runs on the CPU), and so does what follows it, so that a picture's
///   filters are one command buffer (two when a changed search copies 64×64s
///   meanwhile).
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
    /// The share of 64×64s the last `search` filtered anew (1 unless `changed` allowed less).
    public private(set) var lastFilteredShare = 1.0

    /// av1g_frame_params up to its last field (the rest is padding).
    private static let keyBytes = MemoryLayout<av1g_frame_params>.offset(of: \av1g_frame_params.golden_slot)!
        + MemoryLayout.size(ofValue: av1g_frame_params().golden_slot)
    /// The last `search`'s filtered picture where it lives (MiCols·4 wide rows, chroma half;
    /// the picture's samples at the top left), valid until the next call: what a caller that
    /// doesn't take `Search.planes` reads instead.
    public private(set) var outputPlanes: [UnsafePointer<UInt8>] = [], outputStrides: [Int] = []

    /// With `keepsReferenceCopy`, a search whose output is its deblocking buffers (no CDEF: they
    /// are `reconstructionBuffers`, which the next closed loop reconstructs into) also copies them
    /// on the GPU, at the end of its command buffer, into buffers of their own: `referenceCopy`,
    /// `outputPlanes`' samples at `outputStrides`, for the next closed loop to predict from
    /// instead of a copy taken on the CPU before it. Empty after any other search.
    public var keepsReferenceCopy = false
    public private(set) var referenceCopy: [UnsafePointer<UInt8>] = []

    /// A search's planes: `planes` cropped into arrays, or (crop false) none; either way it's
    /// `outputPlanes`.
    private func output(_ job: Job, _ planes: [any MTLBuffer], crop: Bool) -> [[UInt8]] {
        outputPlanes = (0..<job.nPlanes).map { UnsafePointer(planes[$0].contents().assumingMemoryBound(to: UInt8.self)) }
        outputStrides = Array(job.pw.prefix(job.nPlanes))
        return crop ? job.cropped(planes) : []
    }

    public init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.metal("no command queue") }
        self.queue = queue
        let library = try AV1ShaderSource.library(
            AV1ShaderSource.sourceRoot.appending(path: "GlassActAV1/Shaders/postfilter.metal"), device: device)
        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in ["p_mark", "p_deblock", "p_cdef_dir", "p_cdef", "l_cdef_idx_norm", "l_cdef_sse", "l_select", "l_choose", "l_assign",
                     "l_finish", "p_deblock_r", "p_cdef_dir_r", "p_cdef_r", "p_copy_r", "l_cdef_sse_r", "l_assign_c"] {
            guard let function = library.makeFunction(name: name) else { throw Failure.metal("no \(name)") }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines
    }

    /// The picture a decoder outputs, from its reconstruction before the
    /// filters: `planes` are MiCols·4 × MiRows·4 (chroma half that each way),
    /// tightly packed, because the filters read past the picture's edge. The
    /// result is cropped: Y width × height, U and V half that, rounded up (Y
    /// only for a monochrome picture). `lfZero` (per block, nonzero where its
    /// loop filter level is 0: an inter block of a frame with lf_inter_off)
    /// defaults to none.
    public func filter(params fp: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>,
                       planes: [UnsafePointer<UInt8>], lfZero: [UInt8]? = nil) throws -> [[UInt8]] {
        let job = try self.job(params: fp, blocks: blocks, planes: planes, lfZero: lfZero)
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
    /// `params` supplies the size, monochrome and base_q_idx (and an inter
    /// frame's video fields and lf_inter_off, with `lfZero` as `filter` takes it).
    ///
    /// With `changed` (per 64×64, raster: nonzero where the reconstruction,
    /// the blocks or the source may differ from the previous call's picture),
    /// only the area around them is filtered and searched anew, and the rest
    /// keeps the previous picture's output. When the presets come out
    /// different, every 64×64's choice is redone and CDEF reruns wherever its
    /// strengths changed. A first picture is filtered whole. The result is
    /// the same either way.
    ///
    /// `direct` (with `changed`, per 64×64): ones that come out of the filters
    /// as they went in, though they differ from the previous picture's (an
    /// inter frame's copies: every block skipped and at level 0, and no intra
    /// block in the 64×64s around them). They're copied, not filtered.
    ///
    /// `planes` may be `reconstructionBuffers`' contents: then they're deblocked in place (and
    /// hold the reconstruction no more), and with `direct` (whose 64×64s and the unchanged ones
    /// come out of the filters as they went in) nothing of the previous picture's deblocking is
    /// needed: the caller has put this picture's whole reconstruction there.
    public func search(params: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>,
                       planes: [UnsafePointer<UInt8>], source: [UnsafePointer<UInt8>],
                       sourceStrides: [Int]? = nil, sourceBuffers: [any MTLBuffer]? = nil, changed: [UInt8]? = nil,
                       direct: [UInt8]? = nil, lfZero: [UInt8]? = nil, cropsOutput: Bool = true,
                       cdef: Bool = true) throws -> Search {
        referenceCopy = []
        var fp = params
        var tf = GaTuneiqFrame()
        av1enc_tuneiq_frame(Int32(fp.base_q_idx), Int32(fp.monochrome), &tf)
        // (`cdef` false: as libaom at qindex 32 and under, one all-zero preset, signalled but inactive)
        if !cdef { tf.cdef_mode = 0 }
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
        // the fields' bytes, not the struct's padding (the record's is whatever its writer left)
        let key = withUnsafeBytes(of: fp) { Array($0.prefix(Self.keyBytes)) }
        if let changed, tf.cdef_mode != 0, let job = lastJob, job.width == Int(fp.width), job.height == Int(fp.height),
           job.nPlanes == (mono ? 1 : 3), job.previousKey == key, changed.count == job.sbCols * job.sbRows,
           let result = try searchChanged(job, fp: fp, tf: tf, blocks: blocks, planes: planes, source: source,
                                          sourceStrides: sourceStrides, sourceBuffers: sourceBuffers, changed: changed,
                                          direct: direct, lfZero: lfZero, cropsOutput: cropsOutput) {
            return result
        }
        let job = try self.job(params: fp, blocks: blocks, planes: planes, lfZero: lfZero)
        job.previousKey = nil
        lastFilteredShare = 1
        let nsb = job.sbCols * job.sbRows
        let nc = Int(Self.candidates.npri * Self.candidates.nsec)
        lastGPUSeconds = 0
        guard tf.cdef_mode != 0 else {
            // libaom CDEF_ADAPTIVE at qindex <= 32: one all-zero preset, signalled but inactive
            let copies = keepsReferenceCopy
                ? try (0..<job.nPlanes).map { try job.scratch("reference\($0)", job.pw[$0] * job.ph[$0]) } : []
            try wait(commit({ compute in
                job.mark(compute)
                job.normalizeCDEF(compute)
                job.deblock(compute)
            }, blit: copies.isEmpty ? nil : { blit in
                for p in 0..<job.nPlanes {
                    blit.copy(from: job.source[p], sourceOffset: 0, to: copies[p], destinationOffset: 0, size: job.pw[p] * job.ph[p])
                }
            }))
            referenceCopy = copies.map { UnsafePointer($0.contents().assumingMemoryBound(to: UInt8.self)) }
            return Search(params: fp, superblockCDEF: job.superblockCDEF(), planes: output(job, job.source, crop: cropsOutput),
                          lumaSSE: [], chromaSSE: [], presets: [], presetSSE: [])
        }

        let target = try (0..<3).map { p -> any MTLBuffer in
            if let b = Self.target(sourceBuffers, sourceStrides, plane: p, job) { return b }
            let b = try job.scratch("target\(p)", job.pw[p] * job.ph[p])
            if p < job.nPlanes { Self.copy(source[p], stride: sourceStrides?[p] ?? job.pw[p], into: b, width: job.pw[p], height: job.ph[p]) }
            return b
        }
        let lumaSSE = try job.scratch("lumaSSE", 4 * nsb * nc), chromaSSE = try job.scratch("chromaSSE", 4 * nsb * nc)
        if job.nPlanes == 1 { memset(chromaSSE.contents(), 0, 4 * nsb * nc) }  // stays 0 for a monochrome picture
        let selection = try job.selection()
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
            job.select(compute, selection, lumaSSE, chromaSSE, tf)
            job.begin(compute, "l_assign")
            job.setSelection(compute, selection, lumaSSE, chromaSSE)
            compute.dispatchThreads(MTLSize(width: nsb, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(64, nsb), height: 1, depth: 1))
            job.cdef(compute)
            job.finish(compute, selection, tf)
        }
        let chosen = job.chosen(selection, tf: tf, params: &fp)
        func words(_ b: any MTLBuffer) -> [UInt32] {
            Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: UInt32.self), count: nsb * nc))
        }
        try job.remember(key: key, params: fp)
        return Search(params: fp, superblockCDEF: job.superblockCDEF(), planes: output(job, job.output, crop: cropsOutput),
                      lumaSSE: words(lumaSSE), chromaSSE: words(chromaSSE), presets: chosen.presets, presetSSE: chosen.totals)
    }

    /// `search` around the changed 64×64s only, on the previous picture's job:
    /// deblocking over them dilated by two (so that one in, it's exact),
    /// directions, SSE rows, assignment and CDEF over them dilated by one (and
    /// CDEF wherever new presets change a 64×64's strengths, which the GPU
    /// lists). Nil without a previous picture.
    private func searchChanged(_ job: Job, fp base: av1g_frame_params, tf: GaTuneiqFrame,
                               blocks: UnsafeBufferPointer<av1g_block>, planes: [UnsafePointer<UInt8>],
                               source: [UnsafePointer<UInt8>], sourceStrides: [Int]?, sourceBuffers: [any MTLBuffer]?,
                               changed: [UInt8],
                               direct: [UInt8]?, lfZero: [UInt8]?, cropsOutput: Bool) throws -> Search? {
        // the reconstruction in the deblocking buffers, which hold none of the previous picture's
        // deblocking then: only `direct`'s promise (everything outside the changed 64×64s'
        // surroundings is deblocked as it was reconstructed) makes that enough
        let inPlace = planes.count >= job.nPlanes
            && (0..<job.nPlanes).allSatisfy { planes[$0] == UnsafePointer(job.source[$0].contents().assumingMemoryBound(to: UInt8.self)) }
        if inPlace, direct?.count != job.sbCols * job.sbRows { return nil }
        guard job.previousParams != nil else { return nil }
        var fp = base
        let sbCols = job.sbCols, sbRows = job.sbRows, nsb = sbCols * sbRows
        let nc = Int(Self.candidates.npri * Self.candidates.nsec)
        func dilate(_ m: [UInt8]) -> [UInt8] {
            var d = m
            for r in 0..<sbRows {
                for c in 0..<sbCols where m[r * sbCols + c] != 0 {
                    for dr in -1...1 {
                        for dc in -1...1 where r + dr >= 0 && r + dr < sbRows && c + dc >= 0 && c + dc < sbCols {
                            d[(r + dr) * sbCols + c + dc] = 1
                        }
                    }
                }
            }
            return d
        }
        let inner = dilate(changed), outer = dilate(inner)
        let innerList = (0..<nsb).filter { inner[$0] != 0 }.map(UInt32.init)
        let outerList = (0..<nsb).filter { outer[$0] != 0 }.map(UInt32.init)
        // Deblocking outer goes wrong near its edge: it reads neighbours that are deblocked
        // already, and filters theirs a second time (an edge's filter reaches 7 samples into
        // both sides). Those 64×64s, outer's that aren't inner's and the ones bordering outer,
        // are unchanged, so their deblocked samples are the previous picture's: kept aside and
        // put back (p_copy_r), so the whole deblocked frame stays exact for whatever reads it
        // later (CDEF where new presets change a strength, in this picture or a later one). In
        // place, the whole buffer is this picture's reconstruction, which only outer's edges
        // change: nothing is deblocked twice, and nothing needs keeping.
        let lumaSSE = try job.scratch("lumaSSE", 4 * nsb * nc), chromaSSE = try job.scratch("chromaSSE", 4 * nsb * nc)
        let around = dilate(outer)
        // direct copies: their filtered and deblocked samples are their reconstruction, and their
        // SSE rows a full search's (CDEF is inactive in them: zero), set before the GPU's search
        // reads them. Those the GPU's deblocking reads (around the changed ones) are copied before
        // it, the rest while it runs and before CDEF, which reads them around the 64×64s it redoes;
        // in place, their deblocked samples are there already, and their output's are written
        // while it runs
        func copyDirect(_ list: [UInt32]) {
            for p in 0..<job.nPlanes {
                for target in inPlace ? [job.output[p]] : [job.source[p], job.output[p]] {
                    Self.copy(planes[p], stride: job.pw[p], into: target, width: job.pw[p], height: job.ph[p],
                              superblocks: list, side: p == 0 ? 64 : 32, sbCols: sbCols)
                }
            }
        }
        var farDirect: [UInt32] = []
        if let direct, direct.count == nsb {
            let ly = lumaSSE.contents().assumingMemoryBound(to: UInt32.self)
            let luv = chromaSSE.contents().assumingMemoryBound(to: UInt32.self)
            for sb in 0..<nsb where direct[sb] != 0 {
                (ly + sb * nc).update(repeating: 0, count: nc)
                (luv + sb * nc).update(repeating: 0, count: nc)
            }
            if inPlace {
                farDirect = (0..<nsb).filter { direct[$0] != 0 }.map(UInt32.init)
            } else {
                copyDirect((0..<nsb).filter { direct[$0] != 0 && around[$0] != 0 }.map(UInt32.init))
                farDirect = (0..<nsb).filter { direct[$0] != 0 && around[$0] == 0 }.map(UInt32.init)
            }
        }
        let ringList = inPlace ? [] : (0..<nsb).filter { around[$0] != 0 && inner[$0] == 0 }.map(UInt32.init)
        let ring = try (0..<job.nPlanes).map { try job.scratch("ring\($0)", inPlace ? 0 : job.pw[$0] * job.ph[$0]) }
        for p in 0..<job.nPlanes where !ringList.isEmpty {
            Self.copy(job.source[p].contents().assumingMemoryBound(to: UInt8.self), stride: job.pw[p], into: ring[p],
                      width: job.pw[p], height: job.ph[p], superblocks: ringList, side: p == 0 ? 64 : 32, sbCols: sbCols)
        }
        try job.load(params: fp, blocks: blocks, planes: planes, lfZero: lfZero, only: outerList)
        let target = try (0..<3).map {
            try Self.target(sourceBuffers, sourceStrides, plane: $0, job) ?? job.scratch("target\($0)", job.pw[$0] * job.ph[$0])
        }
        for p in 0..<job.nPlanes where target[p] !== sourceBuffers?[p] {
            Self.copy(source[p], stride: sourceStrides?[p] ?? job.pw[p], into: target[p], width: job.pw[p], height: job.ph[p],
                      superblocks: innerList, side: p == 0 ? 64 : 32, sbCols: sbCols)
        }
        let innerBuffer = try job.scratch("innerList", 4 * max(1, innerList.count))
        let outerBuffer = try job.scratch("outerList", 4 * max(1, outerList.count))
        let ringBuffer = try job.scratch("ringList", 4 * max(1, ringList.count))
        let innerMask = try job.scratch("innerMask", nsb)
        let redoBuffer = try job.scratch("redoList", 4 * nsb)
        let prevIdx = try job.scratch("previousIndex", nsb)  // the previous picture's assignment (`remember`)
        innerList.withUnsafeBytes { innerBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        outerList.withUnsafeBytes { outerBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        ringList.withUnsafeBytes { ringBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        inner.withUnsafeBytes { innerMask.contents().copyMemory(from: $0.baseAddress!, byteCount: nsb) }
        var innerRegion = (UInt32(innerList.count), UInt32(sbCols)), outerRegion = (UInt32(outerList.count), UInt32(sbCols))
        var ringRegion = (UInt32(ringList.count), UInt32(sbCols))
        var candidates = Self.candidates
        let selection = try job.selection()
        lastGPUSeconds = 0
        try run({ compute in
            job.mark(compute)
            job.normalizeCDEF(compute)
            for pass in Int32(0)..<2 where !outerList.isEmpty {
                var pass = pass
                job.begin(compute, "p_deblock_r")
                compute.setBytes(&pass, length: 4, index: 2)
                compute.setBytes(&outerRegion, length: 8, index: 8)
                compute.setBuffer(outerBuffer, offset: 0, index: 9)
                compute.dispatchThreads(MTLSize(width: outerList.count * 256, height: 1, depth: job.nPlanes),
                                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            }
            if !innerList.isEmpty {
                job.begin(compute, "p_cdef_dir_r")
                compute.setBytes(&innerRegion, length: 8, index: 8)
                compute.setBuffer(innerBuffer, offset: 0, index: 9)
                compute.dispatchThreads(MTLSize(width: innerList.count * 64, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                job.begin(compute, "l_cdef_sse_r")
                compute.setBytes(&candidates, length: MemoryLayout<GaCdefCand>.stride, index: 1)
                for p in 0..<3 { compute.setBuffer(target[p], offset: 0, index: 3 + p) }
                compute.setBuffer(lumaSSE, offset: 0, index: 6)
                compute.setBuffer(chromaSSE, offset: 0, index: 7)
                compute.setBytes(&innerRegion, length: 8, index: 8)
                compute.setBuffer(innerBuffer, offset: 0, index: 9)
                compute.dispatchThreadgroups(MTLSize(width: innerList.count, height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }
            if !ringList.isEmpty {
                job.begin(compute, "p_copy_r")
                for p in 0..<3 { compute.setBuffer(ring[min(p, job.nPlanes - 1)], offset: 0, index: 3 + p) }
                compute.setBytes(&ringRegion, length: 8, index: 8)
                compute.setBuffer(ringBuffer, offset: 0, index: 9)
                compute.dispatchThreads(MTLSize(width: ringList.count * 4096, height: 1, depth: job.nPlanes),
                                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            }
            job.select(compute, selection, lumaSSE, chromaSSE, tf)
            job.begin(compute, "l_assign_c")
            job.setSelection(compute, selection, lumaSSE, chromaSSE)
            compute.setBuffer(redoBuffer, offset: 0, index: 9)
            compute.setBuffer(prevIdx, offset: 0, index: 11)
            compute.setBuffer(innerMask, offset: 0, index: 12)
            compute.dispatchThreads(MTLSize(width: nsb, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(64, nsb), height: 1, depth: 1))
            job.finish(compute, selection, tf)
        }, meanwhile: farDirect.isEmpty ? nil : { copyDirect(farDirect) }, then: { compute in
            // CDEF over the listed 64×64s (it reads the far direct copies' samples around them)
            job.begin(compute, "p_cdef_r")
            for p in 0..<3 { compute.setBuffer(job.output[p], offset: 0, index: 3 + p) }
            compute.setBuffer(selection.buffer, offset: Job.Selection.regionOffset, index: 8)
            compute.setBuffer(redoBuffer, offset: 0, index: 9)
            compute.dispatchThreadgroups(indirectBuffer: selection.buffer, indirectBufferOffset: 0,
                                         threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        })
        let chosen = job.chosen(selection, tf: tf, params: &fp)
        func words(_ b: any MTLBuffer) -> [UInt32] {
            Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: UInt32.self), count: nsb * nc))
        }
        try job.remember(key: job.previousKey!, params: fp)
        lastFilteredShare = Double(chosen.redone) / Double(nsb)
        return Search(params: fp, superblockCDEF: job.superblockCDEF(), planes: output(job, job.output, crop: cropsOutput),
                      lumaSSE: words(lumaSSE), chromaSSE: words(chromaSSE), presets: chosen.presets, presetSSE: chosen.totals)
    }

    /// `search`'s preset search alone, on SSE tables of `[nsb][4]` (luma, and chroma: zero for a
    /// monochrome picture) of a picture `sbCols` 64×64s wide, at base_q_idx `qindex`: per
    /// cdef_bits the presets (8 luma, then 8 chroma candidate indices) and their total SSE, the
    /// cdef_bits chosen, and the GPU's time.
    public func presetSearch(lumaSSE: [UInt32], chromaSSE: [UInt32], sbCols: Int, mono: Bool, qindex: Int = 120) throws
        -> (presets: [[Int32]], totals: [UInt64], bits: Int, gpuSeconds: Double) {
        let nc = Int(Self.candidates.npri * Self.candidates.nsec), nsb = lumaSSE.count / nc
        guard nsb % sbCols == 0, chromaSSE.count == lumaSSE.count else { throw Failure.metal("tables aren't \(sbCols) wide") }
        var fp = av1g_frame_params()
        fp.width = UInt32(sbCols * 64)
        fp.height = UInt32(nsb / sbCols * 64)
        fp.monochrome = mono ? 1 : 0
        fp.base_q_idx = UInt8(qindex)
        let job = try Job(self, params: fp)
        var tf = GaTuneiqFrame()
        av1enc_tuneiq_frame(Int32(qindex), mono ? 1 : 0, &tf)
        memset(job.cdefIdx.contents(), 0, nsb)
        let luma = try job.make(4 * nsb * nc), chroma = try job.make(4 * nsb * nc)
        lumaSSE.withUnsafeBytes { luma.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        chromaSSE.withUnsafeBytes { chroma.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let selection = try job.selection()
        memset(selection.kept.contents(), 0, selection.kept.length)
        lastGPUSeconds = 0
        try run { job.select($0, selection, luma, chroma, tf) }
        let chosen = job.chosen(selection, tf: tf, params: &fp)
        return (chosen.presets, chosen.totals, Int(fp.cdef_bits), lastGPUSeconds)
    }

    /// The caller's source buffer for plane `p` when the CDEF search can read it as its target in
    /// place (rows the job's plane width apart, and at least its height); nil otherwise.
    static func target(_ buffers: [any MTLBuffer]?, _ strides: [Int]?, plane p: Int, _ job: Job) -> (any MTLBuffer)? {
        guard let buffers, let strides, buffers.count == 3, strides.count == 3, strides[p] == job.pw[p],
              buffers[p].length >= job.pw[p] * job.ph[p] else { return nil }
        return buffers[p]
    }

    /// The listed 64×64s' rectangles of a plane (`side` pixels square) from rows
    /// `stride` apart into `buffer` (`width` × `height`, tight).
    static func copy(_ plane: UnsafePointer<UInt8>, stride: Int, into buffer: any MTLBuffer, width: Int, height: Int,
                     superblocks: [UInt32], side: Int, sbCols: Int) {
        // many 64×64s (a moving 5K picture's copies are tens of MB): in parallel
        let chunks = superblocks.count * side * side >= 1 << 20 ? min(8, superblocks.count / 64) : 1
        superblocks.withUnsafeBufferPointer { list in
            let job = CopyJob(plane: plane, stride: stride, into: buffer.contents().assumingMemoryBound(to: UInt8.self),
                              width: width, height: height, superblocks: list, side: side, sbCols: sbCols, chunks: chunks)
            DispatchQueue.concurrentPerform(iterations: chunks) { job.run($0) }
        }
    }

    /// `copy(_:stride:into:width:height:superblocks:side:sbCols:)`'s work, a chunk at a time.
    private struct CopyJob: @unchecked Sendable {
        let plane: UnsafePointer<UInt8>, stride: Int, into: UnsafeMutablePointer<UInt8>, width: Int, height: Int
        let superblocks: UnsafeBufferPointer<UInt32>, side: Int, sbCols: Int, chunks: Int

        func run(_ c: Int) {
            for i in Swift.stride(from: c, to: superblocks.count, by: chunks) {
                let sb = Int(superblocks[i])
                let x0 = sb % sbCols * side, y0 = sb / sbCols * side
                guard x0 < width, y0 < height else { continue }
                let w = min(side, width - x0)
                for row in y0..<min(y0 + side, height) { (into + row * width + x0).update(from: plane + row * stride + x0, count: w) }
            }
        }
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

    /// The job for this picture: the last one's buffers when the geometry is
    /// the same (nothing allocated or cleared per picture), loaded with its inputs.
    private var lastJob: Job?
    private func job(params fp: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>,
                     planes: [UnsafePointer<UInt8>], lfZero: [UInt8]?) throws -> Job {
        let job = try job(geometry: fp)
        try job.load(params: fp, blocks: blocks, planes: planes, lfZero: lfZero)
        return job
    }

    private func job(geometry fp: av1g_frame_params) throws -> Job {
        if let j = lastJob, j.width == Int(fp.width), j.height == Int(fp.height), j.nPlanes == (fp.monochrome != 0 ? 1 : 3) {
            return j
        }
        let job = try Job(self, params: fp)
        lastJob = job
        return job
    }

    /// The buffers `search` deblocks a picture of `fp`'s size (and monochrome) in: MiCols·4 ×
    /// MiRows·4 (chroma half), tight. A closed loop that reconstructs into them saves `search`
    /// copying its reconstruction there. They stay this geometry's until `search` filters
    /// another.
    public func reconstructionBuffers(params fp: av1g_frame_params) throws -> [any MTLBuffer] {
        let job = try job(geometry: fp)
        return Array(job.source.prefix(job.nPlanes))
    }

    /// Encodes `body`'s work and runs it.
    private func run(_ body: (any MTLComputeCommandEncoder) -> Void) throws {
        try wait(commit(body))
    }

    /// `first`'s work then `then`'s, doing `meanwhile` (CPU work that `first`'s doesn't touch and
    /// `then`'s needs done) while the first runs: one command buffer without it, two with.
    private func run(_ first: (any MTLComputeCommandEncoder) -> Void, meanwhile: (() -> Void)?,
                     then: (any MTLComputeCommandEncoder) -> Void) throws {
        guard let meanwhile else { return try run { first($0); then($0) } }
        let commands = try commit(first, last: false)
        meanwhile()
        let next = try commit(then)
        try wait(commands)
        try wait(next)
    }

    /// Raised on the GPU as the next search's work ends (its last command buffer signals it), then
    /// cleared: what a caller orders other GPU work behind (`AV1HybridEncoder`'s analyses, by
    /// `AV1MetalEncoder.gate`) starts without waiting for the CPU to learn the filters are done.
    /// The value only rises: the caller raises it on the CPU no sooner than the search returns.
    public var signalsWhenDone: (event: any MTLSharedEvent, value: UInt64)?

    /// `body`'s work, then `blit`'s, in one command buffer, committed; the search's last one
    /// (`last`) signals `signalsWhenDone`.
    private func commit(_ body: (any MTLComputeCommandEncoder) -> Void,
                        blit: ((any MTLBlitCommandEncoder) -> Void)? = nil, last: Bool = true) throws -> any MTLCommandBuffer {
        guard let commands = queue.makeCommandBuffer(), let compute = commands.makeComputeCommandEncoder()
        else { throw Failure.metal("no command encoder") }
        commands.label = "AV1 filters"  // for Instruments
        body(compute)
        compute.endEncoding()
        if let blit {
            guard let b = commands.makeBlitCommandEncoder() else { throw Failure.metal("no blit encoder") }
            blit(b)
            b.endEncoding()
        }
        if last, let signal = signalsWhenDone {
            commands.encodeSignalEvent(signal.event, value: signal.value)
            signalsWhenDone = nil
        }
        commands.commit()
        AV1HybridEncoder.trace("filters commit")
        return commands
    }

    private func wait(_ commands: any MTLCommandBuffer) throws {
        commands.waitUntilCompleted()
        if let error = commands.error { throw Failure.metal("\(error)") }
        lastGPUSeconds += commands.gpuEndTime - commands.gpuStartTime
        AV1HybridEncoder.trace("filters gpu \(String(format: "%.3f %.3f", commands.gpuStartTime * 1000, commands.gpuEndTime * 1000))")
    }

    /// One picture's planes, maps and frame.
    final class Job {
        let filter: AV1MetalPostfilter
        let width: Int, height: Int, miCols: Int, miRows: Int, sbCols: Int, sbRows: Int, nPlanes: Int
        let pw: [Int], ph: [Int]
        var made: [any MTLBuffer] = []
        var source: [any MTLBuffer] = [], output: [any MTLBuffer] = []
        var cdefIdx: (any MTLBuffer)!, blockBuffer: (any MTLBuffer)!, lfZeroBuffer: (any MTLBuffer)!
        var addrs = GaPfAddrs()
        /// The frame (av1g_pf_frame) every kernel reads, which l_select writes the presets into.
        var frame: (any MTLBuffer)!
        var params: av1g_frame_params
        var blockCount = 0
        var scratchBuffers: [String: any MTLBuffer] = [:]
        /// The previous picture's base parameters and result, when its state
        /// (deblocked planes, directions, SSE rows, presets, output) is all here.
        var previousKey: [UInt8]?
        var previousParams: av1g_frame_params?

        /// The buffers of a picture of fp's geometry; `load` fills them.
        init(_ filter: AV1MetalPostfilter, params fp: av1g_frame_params) throws {
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
            source = try (0..<3).map { try make(pw[$0] * ph[$0]) }
            output = try (0..<3).map { try make(pw[$0] * ph[$0]) }
            let nmi = miRows * miCols, nuv = (miRows / 2) * (miCols / 2)
            let skip = try make(nmi), txY = try make(nmi), txU = try make(nuv), txV = try make(nuv)
            cdefIdx = try make(sbCols * sbRows)
            let dirVar = try make(4 * nuv)
            blockBuffer = try make(16)
            lfZeroBuffer = try make(16)
            frame = try make(av1enc_pf_frame(nil, nil, nil, 0))
            addrs.plane = (source[0].gpuAddress, source[1].gpuAddress, source[2].gpuAddress)
            addrs.stride = (Int32(pw[0]), Int32(pw[1]), Int32(pw[2]))
            addrs.skip = skip.gpuAddress
            addrs.lfTx = (txY.gpuAddress, txU.gpuAddress, txV.gpuAddress)
            addrs.cdefIdx = cdefIdx.gpuAddress
            addrs.cdefDirVar = dirVar.gpuAddress
        }

        /// A picture's reconstruction before the filters (there already when `planes` are the
        /// buffers' contents), blocks and parameters.
        func load(params fp: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>, planes: [UnsafePointer<UInt8>],
                  lfZero: [UInt8]?) throws {
            guard planes.count >= nPlanes else { throw Failure.metal("\(nPlanes) planes needed") }
            for p in 0..<nPlanes where planes[p] != UnsafePointer(source[p].contents().assumingMemoryBound(to: UInt8.self)) {
                source[p].contents().copyMemory(from: planes[p], byteCount: pw[p] * ph[p])
            }
            try load(params: fp, blocks: blocks, lfZero: lfZero)
        }

        /// As `load`, but the reconstruction of the listed 64×64s only.
        func load(params fp: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>, planes: [UnsafePointer<UInt8>],
                  lfZero: [UInt8]?, only superblocks: [UInt32]) throws {
            guard planes.count >= nPlanes else { throw Failure.metal("\(nPlanes) planes needed") }
            for p in 0..<nPlanes where planes[p] != UnsafePointer(source[p].contents().assumingMemoryBound(to: UInt8.self)) {
                AV1MetalPostfilter.copy(planes[p], stride: pw[p], into: source[p], width: pw[p], height: ph[p],
                                        superblocks: superblocks, side: p == 0 ? 64 : 32, sbCols: sbCols)
            }
            try load(params: fp, blocks: blocks, lfZero: lfZero)
        }

        private func load(params fp: av1g_frame_params, blocks: UnsafeBufferPointer<av1g_block>, lfZero: [UInt8]?) throws {
            if let lfZero, lfZero.count != blocks.count { throw Failure.metal("\(lfZero.count) lfZero entries for \(blocks.count) blocks") }
            memset(cdefIdx.contents(), 0xFF, sbCols * sbRows)
            let bytes = blocks.count * MemoryLayout<av1g_block>.stride
            if blockBuffer.length < bytes {
                made.removeAll { $0 === blockBuffer }
                blockBuffer = try make(bytes + bytes / 4)
            }
            if let base = blocks.baseAddress { blockBuffer.contents().copyMemory(from: base, byteCount: bytes) }
            if lfZeroBuffer.length < blocks.count {
                made.removeAll { $0 === lfZeroBuffer }
                lfZeroBuffer = try make(blocks.count + blocks.count / 4)
            }
            if let lfZero, !lfZero.isEmpty {
                lfZero.withUnsafeBytes { lfZeroBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            } else {
                memset(lfZeroBuffer.contents(), 0, blocks.count)
            }
            blockCount = blocks.count
            setParams(fp)
        }

        /// Keeps this picture's result for the next: its key, parameters and assignment.
        func remember(key: [UInt8], params: av1g_frame_params) throws {
            previousKey = key
            previousParams = params
            let prev = try scratch("previousIndex", sbCols * sbRows)
            prev.contents().copyMemory(from: cdefIdx.contents(), byteCount: sbCols * sbRows)
        }

        /// A buffer of at least `length` bytes kept for the next picture.
        func scratch(_ name: String, _ length: Int) throws -> any MTLBuffer {
            if let b = scratchBuffers[name], b.length >= length { return b }
            if let old = scratchBuffers[name] { made.removeAll { $0 === old } }
            let b = try make(length)
            scratchBuffers[name] = b
            return b
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
            _ = av1enc_pf_frame(&p, &addrs, frame.contents(), frame.length)
        }

        func begin(_ compute: any MTLComputeCommandEncoder, _ name: String) {
            compute.memoryBarrier(scope: .buffers)
            for b in made { compute.useResource(b, usage: [.read, .write]) }
            compute.setBuffer(frame, offset: 0, index: 0)
            compute.setComputePipelineState(filter.pipelines[name]!)
        }

        private func grid(_ compute: any MTLComputeCommandEncoder, _ w: Int, _ h: Int, _ d: Int, tw: Int, th: Int) {
            compute.dispatchThreads(MTLSize(width: w, height: h, depth: d),
                                    threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }

        /// The preset search's buffers: its choice (PfSel), per cdef_bits the presets (8 luma, then 8
        /// chroma candidate indices) and their total SSE, and the presets the last picture applied
        /// (PfCdef), kept for the next.
        struct Selection {
            let buffer: any MTLBuffer, levels: any MTLBuffer, totals: any MTLBuffer, kept: any MTLBuffer
            /// PfSel's PfRegion (the redo list's), after p_cdef_r's threadgroups
            static let regionOffset = 12
        }

        func selection() throws -> Selection {
            let bits = AV1MetalPostfilter.maxCDEFBits + 1
            return try Selection(buffer: scratch("selection", 32), levels: scratch("levels", 4 * 16 * bits),
                                 totals: scratch("totals", 8 * bits), kept: scratch("presetsKept", 4 * 33))
        }

        /// l_select and l_choose: the joint preset search (a threadgroup per cdef_bits), cdef_bits
        /// and the presets into the frame.
        func select(_ compute: any MTLComputeCommandEncoder, _ s: Selection, _ lumaSSE: any MTLBuffer,
                    _ chromaSSE: any MTLBuffer, _ tf: GaTuneiqFrame) {
            begin(compute, "l_select")
            compute.setBuffer(lumaSSE, offset: 0, index: 2)
            compute.setBuffer(chromaSSE, offset: 0, index: 3)
            compute.setBuffer(s.levels, offset: 0, index: 4)
            compute.setBuffer(s.totals, offset: 0, index: 5)
            setSelectArgs(compute, tf)
            compute.setBuffer(s.buffer, offset: 0, index: 7)
            // 128 threads to 256 64×64s, 256 past that (measured: fewer SIMD-groups wait less on
            // each other, more share a large picture's work), up to what the pipeline allows
            let most = filter.pipelines["l_select"]!.maxTotalThreadsPerThreadgroup / 32 * 32
            let threads = min(most, sbCols * sbRows <= 256 ? 128 : 256)
            compute.dispatchThreadgroups(MTLSize(width: AV1MetalPostfilter.maxCDEFBits + 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
            begin(compute, "l_choose")
            var candidates = AV1MetalPostfilter.candidates
            compute.setBytes(&candidates, length: MemoryLayout<GaCdefCand>.stride, index: 1)
            compute.setBuffer(s.levels, offset: 0, index: 4)
            compute.setBuffer(s.totals, offset: 0, index: 5)
            setSelectArgs(compute, tf)
            compute.setBuffer(s.buffer, offset: 0, index: 7)
            compute.setBuffer(s.kept, offset: 0, index: 10)
            compute.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }

        private func setSelectArgs(_ compute: any MTLComputeCommandEncoder, _ tf: GaTuneiqFrame) {
            var args: (Int32, Int32, Int32, Int32, Int32, Int32, Int32) = (
                Int32(sbCols * sbRows), nPlanes == 1 ? 1 : 0, Int32(AV1MetalPostfilter.maxCDEFBits),
                Int32(AV1MetalPostfilter.refinements), tf.cdef_mode, tf.rdmult, Int32(nPlanes))
            compute.setBytes(&args, length: MemoryLayout.size(ofValue: args), index: 6)
        }

        /// An assignment kernel's inputs: the SSE tables, the presets and the search's choice.
        func setSelection(_ compute: any MTLComputeCommandEncoder, _ s: Selection, _ lumaSSE: any MTLBuffer,
                          _ chromaSSE: any MTLBuffer) {
            var args: [Int32] = [AV1MetalPostfilter.candidates.npri * AV1MetalPostfilter.candidates.nsec,
                                 Int32(sbCols * sbRows), nPlanes == 1 ? 1 : 0]
            compute.setBuffer(lumaSSE, offset: 0, index: 1)
            compute.setBuffer(chromaSSE, offset: 0, index: 2)
            compute.setBuffer(s.levels, offset: 0, index: 3)
            compute.setBytes(&args, length: 4 * args.count, index: 4)
            compute.setBuffer(s.buffer, offset: 0, index: 7)
            compute.setBuffer(s.kept, offset: 0, index: 10)
        }

        /// l_finish: the redo list's dispatch, and the presets kept for the next picture.
        func finish(_ compute: any MTLComputeCommandEncoder, _ s: Selection, _ tf: GaTuneiqFrame) {
            begin(compute, "l_finish")
            setSelectArgs(compute, tf)
            compute.setBuffer(s.buffer, offset: 0, index: 7)
            compute.setBuffer(s.kept, offset: 0, index: 10)
            compute.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }

        /// What the GPU chose, read back once it's done: the presets and totals per cdef_bits, how
        /// many 64×64s CDEF redid, and `fp` with the cdef_bits and presets the GPU applied.
        func chosen(_ s: Selection, tf: GaTuneiqFrame, params fp: inout av1g_frame_params)
            -> (presets: [[Int32]], totals: [UInt64], redone: Int) {
            let count = AV1MetalPostfilter.maxCDEFBits + 1
            let totals = Array(UnsafeBufferPointer(start: s.totals.contents().assumingMemoryBound(to: UInt64.self), count: count))
            let lev = s.levels.contents().assumingMemoryBound(to: Int32.self)
            let presets = (0..<count).map { Array(UnsafeBufferPointer(start: lev + 16 * $0, count: 16)) }
            let sel = s.buffer.contents().assumingMemoryBound(to: Int32.self)
            let bits = Int(sel[5])
            assert(bits == Int(totals.withUnsafeBufferPointer {
                av1enc_cdef_bits($0.baseAddress, Int32(AV1MetalPostfilter.maxCDEFBits),
                                 Int32(superblockCDEF().filter { $0 >= 0 }.count), nPlanes == 1 ? 1 : 0, tf.rdmult)
            }), "l_select's cdef_bits isn't av1enc_cdef_bits'")
            var candidates = AV1MetalPostfilter.candidates
            av1enc_cdef_presets(presets[bits], Int32(bits), tf.cdef_mode, &candidates, &fp)
            setParams(fp)
            return (presets, totals, Int(UInt32(bitPattern: sel[3])))
        }

        func mark(_ compute: any MTLComputeCommandEncoder) {
            guard blockCount > 0 else { return }
            begin(compute, "p_mark")
            var n = UInt32(blockCount)
            compute.setBuffer(blockBuffer, offset: 0, index: 1)
            compute.setBytes(&n, length: 4, index: 2)
            compute.setBuffer(lfZeroBuffer, offset: 0, index: 3)
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
                grid(compute, miCols, miRows, nPlanes, tw: 8, th: 8)  // (8 x 8: −11 % against 32 x 4, BENCHMARKS)
            }
        }

        func cdefDirections(_ compute: any MTLComputeCommandEncoder) {
            begin(compute, "p_cdef_dir")
            grid(compute, miCols / 2, miRows / 2, 1, tw: 16, th: 8)
        }

        func cdef(_ compute: any MTLComputeCommandEncoder) {
            begin(compute, "p_cdef")
            for p in 0..<3 { compute.setBuffer(output[p], offset: 0, index: 3 + p) }
            // a thread a 4x4 of luma, or a 4x2 of chroma: U beside V in the second layer
            grid(compute, miCols, miRows, nPlanes > 1 ? 2 : 1, tw: 8, th: 8)
        }

        func superblockCDEF() -> [Int8] {
            Array(UnsafeBufferPointer(start: cdefIdx.contents().assumingMemoryBound(to: Int8.self), count: sbCols * sbRows))
        }

        func cropped(_ planes: [any MTLBuffer]) -> [[UInt8]] {
            (0..<nPlanes).map { p in
                let w = p == 0 ? width : (width + 1) / 2, h = p == 0 ? height : (height + 1) / 2
                let base = planes[p].contents().assumingMemoryBound(to: UInt8.self)
                return [UInt8](unsafeUninitializedCapacity: w * h) { d, count in
                    for row in 0..<h { (d.baseAddress! + row * w).update(from: base + row * pw[p], count: w) }
                    count = w * h
                }
            }
        }
    }
}
