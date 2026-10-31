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

    public init(device: any MTLDevice) throws {
        metal = try AV1MetalEncoder(device: device)
        metal.preset = .turbo
        metal.decidesLeaves = true
        metal.reusesAnalysis = true
        metal.prunesBusyLargeBlocks = true
        postfilter = try AV1MetalPostfilter(device: device)
        guard let cpu = av1enc_hybrid_create() else { throw Failure.encode("no CPU state") }
        self.cpu = cpu
    }

    deinit { av1enc_hybrid_destroy(cpu) }

    /// One picture.
    public func encode(_ picture: Picture, qindex: Int) throws -> Frame {
        var frame: Frame?
        try encode(count: 1, qindex: qindex, picture: { _ in picture }, output: { _, f in frame = f })
        guard let frame else { throw Failure.encode("no frame") }
        return frame
    }

    /// Pictures 0..<count, each an intra frame: picture i + 1's analysis runs
    /// on the GPU while picture i is finished on the CPU. `output` gets them
    /// in order.
    public func encode(count: Int, qindex: Int, picture: (Int) throws -> Picture,
                       output: (Int, Frame) throws -> Void) throws {
        guard count > 0 else { return }
        var current = try picture(0)
        var pending = try begin(current, qindex: qindex)
        for i in 0..<count {
            let partition = try pending.wait()
            let t0 = CACurrentMediaTime()
            var timing = Timing()
            timing.analysis = metal.lastGPUSeconds
            let sbs = ((2 * ((current.width + 7) >> 3) + 15) >> 4) * ((2 * ((current.height + 7) >> 3) + 15) >> 4)
            timing.kept = Double(pending.keptSuperblocks) / Double(max(1, sbs))
            var next: Picture?
            if i + 1 < count {
                let n = try picture(i + 1)
                pending = try begin(n, qindex: qindex)
                next = n
            }
            let frame = try finish(current, partition: partition, qindex: qindex, timing: timing, started: t0)
            try output(i, frame)
            if let next { current = next }
        }
    }

    private func begin(_ p: Picture, qindex: Int) throws -> AV1MetalEncoder.PendingPartition {
        try p.y.withUnsafeBufferPointer { y in
            try p.u.withUnsafeBufferPointer { u in
                try p.v.withUnsafeBufferPointer { v in
                    try metal.beginPartition(y: y.baseAddress!, u: u.baseAddress!, v: v.baseAddress!,
                                             width: p.width, height: p.height, qindex: qindex)
                }
            }
        }
    }

    private func finish(_ p: Picture, partition: AV1MetalEncoder.Partition, qindex: Int, timing: Timing,
                        started t0: Double) throws -> Frame {
        var timing = timing
        var message = [CChar](repeating: 0, count: 256)
        let rc = p.y.withUnsafeBufferPointer { y in
            p.u.withUnsafeBufferPointer { u in
                p.v.withUnsafeBufferPointer { v in
                    partition.blocks.withUnsafeBufferPointer { blocks in
                        partition.lumaTxTypes.withUnsafeBufferPointer { types in
                            av1enc_hybrid_closed_loop(cpu, y.baseAddress, u.baseAddress, v.baseAddress, UInt32(p.width),
                                                      UInt32(p.height), blocks.baseAddress, UInt32(blocks.count),
                                                      gpuDecides ? types.baseAddress : nil,
                                                      gpuDecides && partition.hasChroma ? Int32(AV1ENC_HYBRID_GIVEN_CHROMA) : 0,
                                                      Int32(qindex), Int32(tiling.columnsLog2), Int32(tiling.rowsLog2), &message, 256)
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
        let search = try postfilter.search(params: record.pointee.fp,
                                           blocks: UnsafeBufferPointer(start: record.pointee.blocks, count: n),
                                           planes: recon, source: source, sourceStrides: strides)
        let sbCols = (2 * ((p.width + 7) >> 3) + 15) >> 4
        let t2 = CACurrentMediaTime()
        timing.filters = t2 - t1

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
        return Frame(obu: obu, planes: search.planes, params: search.params, timing: timing)
    }
}
