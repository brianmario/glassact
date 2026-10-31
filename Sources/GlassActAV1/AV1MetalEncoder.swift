public import AV1Core
internal import AV1Encoder
internal import Foundation
public import Metal

/// av1gpu's AV1 intra encoder, on Metal (research; DESIGN doesn't cover it
/// yet). So far: the open-loop analysis of every block shape and the
/// partition DP, which decide where the blocks of a picture go.
///
/// Confined to its caller's queue, like the engines of the pixel path (§8.8):
/// one picture at a time, no actors.
///
/// ## Deviations
/// av1gpu batches many pictures per dispatch for throughput; this encodes one
/// picture per call, the shape of a live frame. It sets `smallKernel` off:
/// the thread-per-block kernel for shapes up to 64 pixels isn't ported, and
/// the warp-per-block one covers every shape.
@available(macOS 27, iOS 27, *)
public final class AV1MetalEncoder: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case metal(String)

        public var description: String {
            switch self { case let .metal(m): m }
        }
    }

    /// A picture's blocks in decode order (tiles, then superblocks, then
    /// decode_partition's pre-order), with their sizes and positions set.
    public struct Partition {
        public var blocks: [av1g_block]
        public var tiles: av1g_tiles
    }

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    /// Per AV1 block size: the analysis kernel and its warps per threadgroup.
    let analysis: [Int: (pipeline: any MTLComputePipelineState, warps: Int)]
    let dp: any MTLComputePipelineState
    var params: GpParams

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
            analysis[bsize] = (try device.makeComputePipelineState(function: function), warps)
        }
        self.analysis = analysis
        guard let dpFunction = library.makeFunction(name: "k_dp") else { throw Failure.metal("no k_dp") }
        dp = try device.makeComputePipelineState(function: dpFunction)
        params = Self.defaultParams()
    }

    /// AV1's block sizes in pixels, by `bsize` (128-pixel sizes unused: 0).
    static let blockSizes: [(w: Int, h: Int)] = [
        (4, 4), (4, 8), (8, 4), (8, 8), (8, 16), (16, 8), (16, 16), (16, 32), (32, 16), (32, 32), (32, 64),
        (64, 32), (64, 64), (0, 0), (0, 0), (0, 0), (4, 16), (16, 4), (8, 32), (32, 8), (16, 64), (64, 16),
    ]

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
        p.smallKernel = 0
        p.pruneMinArea = 1024
        p.screenSub = 1
        p.uvDeltas = 1
        return p
    }

    /// The analysis and the partition DP of one 8-bit 4:2:0 picture (planes
    /// tightly packed: Y width × height, U and V half that, rounded up).
    public func partition(y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>,
                          width: Int, height: Int, qindex: Int) throws -> Partition {
        let miCols = 2 * ((width + 7) >> 3), miRows = 2 * ((height + 7) >> 3)
        let sbCols = (miCols + 15) >> 4, sbRows = (miRows + 15) >> 4
        let aw = sbCols * 64, ah = sbRows * 64
        var bufs: [any MTLBuffer] = []
        func make(_ length: Int) throws -> any MTLBuffer {
            guard let b = device.makeBuffer(length: max(16, length), options: .storageModeShared)
            else { throw Failure.metal("no buffer of \(length) bytes") }
            bufs.append(b)
            return b
        }
        // source planes, padded to whole superblocks by edge replication
        let planes = [(y, width, height), (u, (width + 1) / 2, (height + 1) / 2), (v, (width + 1) / 2, (height + 1) / 2)]
        var src: [any MTLBuffer] = []
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
        }
        var tiles = av1g_tiles()
        guard av1g_tile_layout(UInt32(width), UInt32(height), -1, -1, &tiles) == AV1G_OK
        else { throw Failure.metal("tile layout") }

        var image = GpImage()
        image.W = Int32(width); image.H = Int32(height)
        image.MiCols = Int32(miCols); image.MiRows = Int32(miRows)
        image.sbCols = Int32(sbCols); image.sbRows = Int32(sbRows)
        image.baseQ = Int32(qindex)
        image.qctx = qindex <= 20 ? 0 : qindex <= 60 ? 1 : qindex <= 120 ? 2 : 3
        image.qm = (15, 15, 15)
        image.aw = Int32(aw); image.ah = Int32(ah)
        image.src = (Self.address(src[0]), Self.address(src[1]), Self.address(src[2]))
        image.spitch = (Int32(aw), Int32(aw / 2), Int32(aw / 2))
        image.tileCols = Int32(tiles.cols); image.tileRows = Int32(tiles.rows)
        withUnsafeMutableBytes(of: &image.tileColStart) { d in
            withUnsafeBytes(of: tiles.mi_col_starts) { s in
                for k in 0...Int(tiles.cols) {
                    d.storeBytes(of: Int32(s.load(fromByteOffset: k * 4, as: UInt32.self)), toByteOffset: k * 4, as: Int32.self)
                }
            }
        }
        withUnsafeMutableBytes(of: &image.tileRowStart) { d in
            withUnsafeBytes(of: tiles.mi_row_starts) { s in
                for k in 0...Int(tiles.rows) {
                    d.storeBytes(of: Int32(s.load(fromByteOffset: k * 4, as: UInt32.self)), toByteOffset: k * 4, as: Int32.self)
                }
            }
        }
        // analysis grids: every enabled shape over the coded area
        var shTotal = [UInt32](repeating: 0, count: Int(GP_NSHAPES))
        var nbx = [Int32](repeating: 0, count: Int(GP_NSHAPES)), nby = nbx
        var shOff = [UInt32](repeating: 0, count: Int(GP_NSHAPES))
        var blkTotal: UInt32 = 0
        for s in 0..<Int(GP_NSHAPES) {
            shOff[s] = blkTotal
            let size = Self.blockSizes[s]
            guard size.w > 0, (params.shapeMask >> s) & 1 != 0 else { continue }
            nbx[s] = Int32((miCols * 4 + size.w - 1) / size.w)
            nby[s] = Int32((miRows * 4 + size.h - 1) / size.h)
            shTotal[s] = UInt32(nbx[s] * nby[s])
            blkTotal += shTotal[s]
        }
        withUnsafeMutableBytes(of: &image.shOff) { $0.copyMemory(from: UnsafeRawBufferPointer(start: shOff, count: shOff.count * 4)) }
        withUnsafeMutableBytes(of: &image.shNbx) { $0.copyMemory(from: UnsafeRawBufferPointer(start: nbx, count: nbx.count * 4)) }
        withUnsafeMutableBytes(of: &image.shNby) { $0.copyMemory(from: UnsafeRawBufferPointer(start: nby, count: nby.count * 4)) }

        let nSb = sbCols * sbRows
        let imageBuffer = try make(MemoryLayout<GpImage>.stride)
        imageBuffer.contents().storeBytes(of: image, as: GpImage.self)
        let blk = try make(Int(blkTotal) * MemoryLayout<GpBlockRes>.stride)
        // per shape: [first block of image 0, total] (one image)
        let starts = try make(Int(GP_NSHAPES) * 2 * 4)
        for s in 0..<Int(GP_NSHAPES) {
            starts.contents().storeBytes(of: 0, toByteOffset: s * 8, as: UInt32.self)
            starts.contents().storeBytes(of: shTotal[s], toByteOffset: s * 8 + 4, as: UInt32.self)
        }
        let sbImg = try make(nSb * 4)
        let leaves = try make(nSb * Int(GP_MAX_LEAVES) * MemoryLayout<GpLeaf>.stride)
        let leafCount = try make(nSb * 2)
        let sbJ = try make(nSb * 4)

        var batch = GpBatch()
        batch.nimg = 1
        batch.img = Self.address(imageBuffer)
        batch.blk = Self.address(blk)
        batch.shImgStart = Self.address(starts)
        batch.nSb = UInt32(nSb)
        batch.sbImg = Self.address(sbImg)
        batch.leaves = Self.address(leaves)
        batch.leafCountW = Self.address(leafCount)
        batch.sbJ = Self.address(sbJ)

        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
        else { throw Failure.metal("no command encoder") }
        for b in bufs { encoder.useResource(b, usage: [.read, .write]) }
        var params = self.params
        encoder.setBytes(&batch, length: MemoryLayout<GpBatch>.stride, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<GpParams>.stride, index: 1)
        for s in 0..<Int(GP_NSHAPES) where shTotal[s] > 0 {
            guard let (pipeline, warps) = analysis[s] else { continue }
            var n = shTotal[s]
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&n, length: 4, index: 2)
            encoder.dispatchThreadgroups(MTLSize(width: (Int(n) + warps - 1) / warps, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: warps * 32, height: 1, depth: 1))
        }
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(dp)
        encoder.dispatchThreads(MTLSize(width: nSb, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, nSb), height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw Failure.metal("\(error)") }

        // leaves -> blocks, in tile order
        var blocks: [av1g_block] = []
        let leafPtr = leaves.contents().assumingMemoryBound(to: GpLeaf.self)
        let counts = leafCount.contents().assumingMemoryBound(to: UInt16.self)
        let colStarts = withUnsafeBytes(of: tiles.mi_col_starts) { Array($0.bindMemory(to: UInt32.self)) }
        let rowStarts = withUnsafeBytes(of: tiles.mi_row_starts) { Array($0.bindMemory(to: UInt32.self)) }
        for tr in 0..<Int(tiles.rows) {
            for tc in 0..<Int(tiles.cols) {
                for r in stride(from: Int(rowStarts[tr]), to: Int(rowStarts[tr + 1]), by: 16) {
                    for c in stride(from: Int(colStarts[tc]), to: Int(colStarts[tc + 1]), by: 16) {
                        let sb = (r >> 4) * sbCols + (c >> 4)
                        for k in 0..<Int(counts[sb]) {
                            let leaf = leafPtr[sb * Int(GP_MAX_LEAVES) + k]
                            var b = av1g_block()
                            b.mi_row = UInt16(r + Int(leaf.y4))
                            b.mi_col = UInt16(c + Int(leaf.x4))
                            b.bsize = leaf.bsize
                            blocks.append(b)
                        }
                    }
                }
            }
        }
        return Partition(blocks: blocks, tiles: tiles)
    }

    static func address<T>(_ buffer: any MTLBuffer) -> UnsafeMutablePointer<T>? {
        UnsafeMutablePointer(bitPattern: UInt(buffer.gpuAddress))
    }

    static func address<T>(_ buffer: any MTLBuffer) -> UnsafePointer<T>? {
        UnsafePointer(bitPattern: UInt(buffer.gpuAddress))
    }
}
