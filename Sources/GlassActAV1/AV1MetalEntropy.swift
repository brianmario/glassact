public import AV1Core
internal import AV1Encoder
internal import Foundation
public import Metal

/// av1gpu's GPU entropy coder, on Metal (research): a DecisionRecord's
/// symbols and range-coded tile payloads, byte for byte what av1core's CPU
/// writer produces, and the OBUs around them.
///
/// Confined to its caller's queue, like the engines of the pixel path (§8.8).
///
/// ## Deviations
/// - One picture per call, not av1gpu's batches.
/// - The record is uploaded from the CPU, because the encoder still packs it
///   there (AV1MetalEncoder's deviations); av1gpu codes it where k_pack left it.
/// - The symbol buffer's size is av1gpu's estimate; when a picture needs more,
///   the GPU reports the exact count and the picture is coded again.
/// - Buffers are made per call. A live encoder would keep them.
///
/// Each tile's range coding is one GPU lane's dependent chain, which is far
/// slower per symbol than a CPU core, so this pays only with many tiles; on
/// unified memory av1core's CPU writer may be the better path for one picture.
@available(macOS 27, iOS 27, *)
public final class AV1MetalEntropy: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case metal(String)
        case record(String)

        public var description: String {
            switch self { case let .metal(m), let .record(m): m }
        }
    }

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipelines: [String: any MTLComputePipelineState]
    /// av1g_cdfs_init's four images, by coefficient q context.
    let cdfDefaults: any MTLBuffer
    /// GPU time of the last picture's command buffer.
    public private(set) var lastGPUSeconds: Double = 0

    static let kernels = ["e_blocks", "e_sbs", "e_tiles", "e_maps", "e_txctx", "e_txsym", "e_sbsym", "e_scan",
                          "e_tilerange", "e_entropy", "e_cdf_defaults"]
    static let cdfBytes = 11_440  // sizeof(av1g_cdfs)
    static let scanThreads = 1024

    public init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.metal("no command queue") }
        self.queue = queue
        let library = try AV1ShaderSource.library(
            AV1ShaderSource.sourceRoot.appending(path: "GlassActAV1/Shaders/entropy.metal"), device: device)
        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in Self.kernels {
            guard let function = library.makeFunction(name: name) else { throw Failure.metal("no \(name)") }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines
        guard let defaults = device.makeBuffer(length: 4 * Self.cdfBytes, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let compute = commands.makeComputeCommandEncoder()
        else { throw Failure.metal("no CDF defaults") }
        compute.setComputePipelineState(pipelines["e_cdf_defaults"]!)
        compute.setBuffer(defaults, offset: 0, index: 0)
        compute.dispatchThreads(MTLSize(width: 4, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1))
        compute.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw Failure.metal("\(error)") }
        cdfDefaults = defaults
    }

    /// The record's tile payloads, in tile raster order.
    public func tilePayloads(_ record: av1g_decision_record) throws -> [[UInt8]] {
        var frame = GaEntFrame()
        var tiles = [GaEntTile](repeating: GaEntTile(), count: Int(GA_ENT_MAX_TILES))
        var fp = record.fp
        let nTiles = tiles.withUnsafeMutableBufferPointer {
            av1enc_ent_plan(&fp, record.n_blocks, record.n_txb, &frame, $0.baseAddress)
        }
        guard nTiles > 0 else { throw Failure.record("no plan: empty record or non-uniform tiles") }
        tiles.removeSubrange(Int(nTiles)...)
        frame.symCap = UInt32(min(UInt64(UInt32.max), UInt64(fp.width) * UInt64(fp.height) * 3 / 4
                                      + 16 * UInt64(record.n_blocks) + 8 * UInt64(record.n_txb)))
        for _ in 0..<2 {
            let run = try Run(entropy: self, record: record, frame: frame, tiles: tiles)
            try run.execute()
            let status = run.status.contents().assumingMemoryBound(to: GaEntStatus.self).pointee
            if status.error & Int32(GA_ENT_ERR_SYMBOLS) != 0, status.symbols > frame.symCap {
                frame.symCap = status.symbols
                continue
            }
            if status.error != 0 { throw Failure.record("GPU entropy error \(status.error)") }
            return run.payloads()
        }
        throw Failure.record("symbol capacity")
    }

    /// The record's OBUs, as av1g_encode writes them (with AV1G_ENC_TD when
    /// `temporalDelimiter`).
    public func encode(_ record: av1g_decision_record, temporalDelimiter: Bool = true) throws -> [UInt8] {
        let payloads = try tilePayloads(record)
        var fp = record.fp
        var out: UnsafeMutablePointer<UInt8>?
        var size = 0
        let sizes = payloads.map(\.count)
        let rc = withPointers(payloads) { pointers in
            av1enc_assemble_obus(&fp, pointers, sizes, UInt32(payloads.count), temporalDelimiter ? 1 : 0, &out, &size)
        }
        guard rc == 0, let out else { throw Failure.record("OBU assembly") }
        defer { free(out) }
        return Array(UnsafeBufferPointer(start: out, count: size))
    }

    private func withPointers<R>(_ arrays: [[UInt8]], _ body: ([UnsafePointer<UInt8>?]) -> R) -> R {
        func nest(_ i: Int, _ acc: [UnsafePointer<UInt8>?]) -> R {
            guard i < arrays.count else { return body(acc) }
            return arrays[i].withUnsafeBufferPointer { nest(i + 1, acc + [$0.baseAddress]) }
        }
        return nest(0, [])
    }

    /// One picture's buffers and dispatches.
    final class Run {
        let entropy: AV1MetalEntropy
        var frame: GaEntFrame
        var bufs = GaEntBufs()
        let status: any MTLBuffer, count: any MTLBuffer, off: any MTLBuffer, capArr: any MTLBuffer
        let capOff: any MTLBuffer, sizes: any MTLBuffer, staging: any MTLBuffer
        var buffers: [any MTLBuffer] = []

        init(entropy: AV1MetalEntropy, record: av1g_decision_record, frame: GaEntFrame, tiles: [GaEntTile]) throws {
            self.entropy = entropy
            self.frame = frame
            let nB = Int(frame.nBlocks), nT = Int(frame.nTxb), nSb = Int(frame.nSb), nTiles = Int(frame.nTiles)
            let nItems = nB + nT
            var made: [any MTLBuffer] = []
            func make(_ length: Int) throws -> any MTLBuffer {
                guard let b = entropy.device.makeBuffer(length: max(16, length), options: .storageModeShared)
                else { throw Failure.metal("no buffer of \(length) bytes") }
                made.append(b)
                return b
            }
            func copy<T>(_ source: UnsafePointer<T>?, _ n: Int) throws -> any MTLBuffer {
                let b = try make(n * MemoryLayout<T>.stride)
                if let source { b.contents().copyMemory(from: source, byteCount: n * MemoryLayout<T>.stride) }
                return b
            }
            let blocks = try copy(record.blocks, nB)
            let blockTxb = try copy(record.block_txb, nB)
            let txb = try copy(record.txb, nT)
            let coeffs = try copy(record.coeffs, Int(record.n_coeffs))
            let tileBuffer = try tiles.withUnsafeBufferPointer { try copy($0.baseAddress, nTiles) }
            let sbs = try make(nSb * MemoryLayout<GaEntSb>.stride)
            status = try make(MemoryLayout<GaEntStatus>.stride)
            let blockTile = try make(4 * nB), blockTxbG = try make(4 * (nB + 1)), txbBlock = try make(4 * nT)
            let sbFirst = try make(4 * nSb)
            memset(sbFirst.contents(), 0xFF, 4 * nSb)
            let miTotal = Int(frame.miTotal), ctxTotal = Int(frame.ctxTotal)
            let maps = try (0..<4).map { _ in try make(miTotal) }
            let ctxLvl = try make(ctxTotal), ctxDc = try make(ctxTotal)
            let txbEob = try make(2 * nT), txbType = try make(nT)
            count = try make(4 * (nItems + 1))
            memset(count.contents(), 0, 4 * (nItems + 1))
            memset(status.contents(), 0, MemoryLayout<GaEntStatus>.stride)
            off = try make(4 * (nItems + 1))
            let syms = try make(4 * Int(frame.symCap))
            let tb = try make(4 * nTiles), te = try make(4 * nTiles), tq = try make(4 * nTiles)
            capArr = try make(4 * (nTiles + 1))
            capOff = try make(4 * (nTiles + 1))
            sizes = try make(4 * nTiles)
            staging = try make(Int(frame.symCap) / 2 + 256 * nTiles)
            func a<T>(_ b: any MTLBuffer) -> UnsafeMutablePointer<T>? { UnsafeMutablePointer(bitPattern: UInt(b.gpuAddress)) }
            func c<T>(_ b: any MTLBuffer) -> UnsafePointer<T>? { UnsafePointer(bitPattern: UInt(b.gpuAddress)) }
            bufs.blocks = c(blocks)
            bufs.blockTxb = c(blockTxb)
            bufs.txb = c(txb)
            bufs.coeffs = c(coeffs)
            bufs.tiles = a(tileBuffer)
            bufs.sbs = a(sbs)
            bufs.status = a(status)
            bufs.blockTile = a(blockTile)
            bufs.blockTxbG = a(blockTxbG)
            bufs.txbBlock = a(txbBlock)
            bufs.sbFirst = a(sbFirst)
            bufs.mMiSize = a(maps[0])
            bufs.mYMode = a(maps[1])
            bufs.mSkip = a(maps[2])
            bufs.mTx = a(maps[3])
            bufs.ctxLvl = a(ctxLvl)
            bufs.ctxDc = a(ctxDc)
            bufs.txbEob = a(txbEob)
            bufs.txbType = a(txbType)
            bufs.count = a(count)
            bufs.off = a(off)
            bufs.syms = a(syms)
            bufs.tb = a(tb)
            bufs.te = a(te)
            bufs.tq = a(tq)
            bufs.capArr = a(capArr)
            bufs.capOff = a(capOff)
            bufs.sizes = a(sizes)
            bufs.staging = a(staging)
            bufs.cdfDefaults = c(entropy.cdfDefaults)
            buffers = made + [entropy.cdfDefaults]
        }

        func execute() throws {
            guard let commands = entropy.queue.makeCommandBuffer(), let compute = commands.makeComputeCommandEncoder()
            else { throw Failure.metal("no command encoder") }
            for b in buffers { compute.useResource(b, usage: [.read, .write]) }
            compute.setBytes(&frame, length: MemoryLayout<GaEntFrame>.stride, index: 0)
            compute.setBytes(&bufs, length: MemoryLayout<GaEntBufs>.stride, index: 1)
            let p = entropy.pipelines
            func threads(_ name: String, _ n: UInt32, emit: UInt32? = nil) {
                guard n > 0 else { return }
                compute.memoryBarrier(scope: .buffers)
                compute.setComputePipelineState(p[name]!)
                if var emit { compute.setBytes(&emit, length: 4, index: 2) }
                compute.dispatchThreads(MTLSize(width: Int(n), height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: min(64, Int(n)), height: 1, depth: 1))
            }
            func perTile(_ name: String) {
                compute.memoryBarrier(scope: .buffers)
                compute.setComputePipelineState(p[name]!)
                compute.dispatchThreadgroups(MTLSize(width: Int(frame.nTiles), height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
            }
            func scan(_ input: any MTLBuffer, _ output: any MTLBuffer, _ n: UInt32) {
                var n = n
                compute.memoryBarrier(scope: .buffers)
                compute.setComputePipelineState(p["e_scan"]!)
                compute.setBuffer(input, offset: 0, index: 0)
                compute.setBuffer(output, offset: 0, index: 1)
                compute.setBytes(&n, length: 4, index: 2)
                compute.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: AV1MetalEntropy.scanThreads, height: 1, depth: 1))
                compute.setBytes(&frame, length: MemoryLayout<GaEntFrame>.stride, index: 0)
                compute.setBytes(&bufs, length: MemoryLayout<GaEntBufs>.stride, index: 1)
            }
            let nItems = frame.nBlocks + frame.nTxb
            threads("e_blocks", frame.nBlocks)
            threads("e_sbs", frame.nSb)
            perTile("e_tiles")
            threads("e_maps", frame.nBlocks)
            threads("e_txctx", frame.nTxb)
            threads("e_txsym", frame.nTxb, emit: 0)
            threads("e_sbsym", frame.nSb, emit: 0)
            scan(count, off, nItems + 1)
            threads("e_txsym", frame.nTxb, emit: 1)
            threads("e_sbsym", frame.nSb, emit: 1)
            threads("e_tilerange", frame.nTiles)
            scan(capArr, capOff, frame.nTiles + 1)
            perTile("e_entropy")
            compute.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw Failure.metal("\(error)") }
            entropy.lastGPUSeconds = commands.gpuEndTime - commands.gpuStartTime
        }

        func payloads() -> [[UInt8]] {
            let offsets = capOff.contents().assumingMemoryBound(to: UInt32.self)
            let lengths = sizes.contents().assumingMemoryBound(to: UInt32.self)
            let bytes = staging.contents().assumingMemoryBound(to: UInt8.self)
            return (0..<Int(frame.nTiles)).map { t in
                Array(UnsafeBufferPointer(start: bytes + Int(offsets[t]), count: Int(lengths[t])))
            }
        }
    }
}
