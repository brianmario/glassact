import Foundation
import GlassActCodec
import GlassActWire

/// Encode tick (§4.3): hashing candidates in parallel (§4.5) and the
/// per-tile payload encode (RAW / LZ4 / LZBITMAP / VP8L / DELTA selection).
/// HostEngine extension: encodeQueue-confined like the engine itself.
extension HostEngine {
    // MARK: - Diff (hash phase)

    struct HashJob: @unchecked Sendable {
        let frame: UnsafeRawBufferPointer
        let bytesPerRow: Int
        let grid: TileGrid
        let candidates: UnsafeBufferPointer<Int32>
        let results: UnsafeMutableBufferPointer<UInt64>
        let chunkSize: Int

        func run(_ chunk: Int) {
            let lo = chunk * chunkSize
            let hi = min(lo + chunkSize, candidates.count)
            for i in lo..<hi {
                let (x, y, tw, th) = grid.rect(of: Int(candidates[i]))
                results[i] = XXH64.hashRows(frame: frame, bytesPerRow: bytesPerRow,
                                            x: x, y: y, tw: tw, th: th)
            }
        }
    }

    static let parallelHashThreshold = 128
    static let hashChunkSize = 32

    func hashCandidates(frame: UnsafeRawBufferPointer, bytesPerRow: Int) {
        let count = worklist.count
        guard count > 0 else { return }
        worklist.withUnsafeBufferPointer { candidates in
            hashResults.withUnsafeMutableBufferPointer { results in
                if count >= Self.parallelHashThreshold {
                    let job = HashJob(frame: frame, bytesPerRow: bytesPerRow, grid: grid,
                                      candidates: candidates, results: results,
                                      chunkSize: Self.hashChunkSize)
                    let chunks = (count + Self.hashChunkSize - 1) / Self.hashChunkSize
                    DispatchQueue.concurrentPerform(iterations: chunks) { job.run($0) }
                } else {
                    for i in 0..<count {
                        let (x, y, tw, th) = grid.rect(of: Int(candidates[i]))
                        results[i] = XXH64.hashRows(frame: frame, bytesPerRow: bytesPerRow,
                                                    x: x, y: y, tw: tw, th: th)
                    }
                }
            }
        }
    }

    // MARK: - Per-tile codec limits

    static let webpTileLimit = 320 // z4 ≈ 240 µs/tile serial; fanned out across workers ≈ 8 ms worst case
    static let webpTileLimitSettleCap = 4096 // ~100 ms fanned out: a one-time stall on a quiet queue
    /// DELTA — per-worker per-tick pixel budget for VP8L sub-rect trials
    /// (~250k px ≈ 4–8 ms of VP8L per worker, in parallel).
    static let deltaWebpPixelBudgetPerWorker = 250_000

    /// Parallel payload-encode job: strided ownership (worker w takes tiles
    /// w, w+W, …) so each worker exclusively owns one codec-scratch context.
    /// All writes are disjoint per tile (INV-safe data parallelism, §8.8).
    struct PayloadEncodeJob: @unchecked Sendable {
        let frame: UnsafeRawBufferPointer
        let bytesPerRow: Int
        let grid: TileGrid
        let tiles: UnsafeBufferPointer<Int32>
        let retentionBase: UnsafeMutableRawPointer
        let outBase: UnsafeMutableRawPointer
        let meta: UnsafeMutableBufferPointer<EncodedMeta>
        let count: Int
        let workers: [EncodeWorker]
        let webpTry: UnsafeBufferPointer<UInt8>
        let deltaBases: UnsafeBufferPointer<UInt64>
        let shadow: UnsafeRawBufferPointer
        let canvasWidth: Int
        let vp8lEffort: Int32

        func run(_ worker: Int) {
            let ctx = workers[worker]
            var q = worker
            while q < count {
                encodeOne(q, ctx)
                q += workers.count
            }
        }

        func runSerially() {
            let ctx = workers[0]
            for q in 0..<count {
                encodeOne(q, ctx)
            }
        }

        private func encodeOne(_ q: Int, _ ctx: EncodeWorker) {
            let idx = Int(tiles[q])
            let (x, y, tw, th) = grid.rect(of: idx)
            let tightLen = tw * th * 4
            let tightDst = UnsafeMutableRawBufferPointer(
                start: retentionBase.advanced(by: q * HostEngine.tileBytes), count: HostEngine.tileBytes)
            TileOps.extract(src: frame, bytesPerRow: bytesPerRow, x: x, y: y, tw: tw, th: th, into: tightDst)
            let tight = UnsafeRawBufferPointer(start: tightDst.baseAddress!, count: tightLen)
            let out = UnsafeMutableRawBufferPointer(
                start: outBase.advanced(by: q * HostEngine.tileBytes), count: HostEngine.tileBytes)

            // INV-1: every candidate fully defines the tile. Best-of wins.
            var bestOp = Opcode.raw
            var bestLen = tightLen
            let lz4Len = ctx.codec.encode(src: tight, dst: out)
            if lz4Len > 0 && lz4Len < bestLen {
                bestOp = Opcode.lz4
                bestLen = lz4Len
            }
            let bitmapLen = ctx.codec.encodeBitmap(src: tight, dst: ctx.scratch)
            if bitmapLen > 0 && bitmapLen < bestLen {
                out.baseAddress!.copyMemory(from: ctx.scratch.baseAddress!, byteCount: bitmapLen)
                bestOp = Opcode.lzbitmap
                bestLen = bitmapLen
            }
            // DELTA (§4.8) — hash-pinned delta vs the ACKed shadow. Two candidates:
            // whole-tile XOR (sparse → compresses hard) and absolute
            // changed-bbox sub-rect; whichever beats the full-tile best-of
            // ships as Opcode.delta with the base hash pinned. Measured on
            // the typing trace: combined ≈ 59 % of full-tile bytes.
            func tryDelta(_ bestLen: inout Int, _ bestOp: inout UInt8) {
                let baseHash = deltaBases[q]
                guard baseHash != 0 else { return }
                let baseDst = UnsafeMutableRawBufferPointer(
                    start: ctx.base.baseAddress, count: HostEngine.tileBytes)
                _ = TileOps.extract(src: shadow, bytesPerRow: canvasWidth * 4,
                                    x: x, y: y, tw: tw, th: th, into: baseDst)
                // XOR + changed bbox in one pass (u32 words).
                var minX = tw, maxX = -1, minY = th, maxY = -1
                let curW = tight.bindMemory(to: UInt32.self)
                let baseW = UnsafeRawBufferPointer(start: ctx.base.baseAddress, count: tightLen)
                    .bindMemory(to: UInt32.self)
                let deltaW = ctx.delta.bindMemory(to: UInt32.self)
                for row in 0..<th {
                    for col in 0..<tw {
                        let i = row * tw + col
                        let d = curW[i] ^ baseW[i]
                        deltaW[i] = d
                        if d != 0 {
                            minX = min(minX, col); maxX = max(maxX, col)
                            minY = min(minY, row); maxY = max(maxY, row)
                        }
                    }
                }
                guard maxX >= minX else { return } // identical to base (hash collision)
                // Candidate 0: whole-tile XOR, best-of inner.
                let xorSrc = UnsafeRawBufferPointer(start: ctx.delta.baseAddress, count: tightLen)
                var innerOp0: UInt8 = 0
                var innerLen0 = Int.max
                let inner0 = UnsafeMutableRawBufferPointer(
                    start: ctx.inner.baseAddress, count: HostEngine.tileBytes)
                let xl = ctx.codec.encode(src: xorSrc, dst: inner0)
                if xl > 0 { innerOp0 = Opcode.lz4; innerLen0 = xl }
                let xb = ctx.codec.encodeBitmap(src: xorSrc, dst: ctx.scratch)
                if xb > 0 && xb < innerLen0 {
                    ctx.inner.baseAddress!.copyMemory(from: ctx.scratch.baseAddress!, byteCount: xb)
                    innerOp0 = Opcode.lzbitmap; innerLen0 = xb
                }
                let total0 = innerLen0 == Int.max ? Int.max : DeltaPayload.wholeTileHeaderBytes + innerLen0
                // Candidate 1: absolute sub-rect, best-of inner.
                let sw = maxX - minX + 1
                let sh = maxY - minY + 1
                let subLen = sw * sh * 4
                for row in 0..<sh {
                    ctx.sub.baseAddress!.advanced(by: row * sw * 4)
                        .copyMemory(from: tight.baseAddress!.advanced(by: ((minY + row) * tw + minX) * 4),
                                    byteCount: sw * 4)
                }
                let subSrc = UnsafeRawBufferPointer(start: ctx.sub.baseAddress, count: subLen)
                var innerOp1 = Opcode.raw
                var innerLen1 = subLen
                var subInInner = false
                let sl = ctx.codec.encode(src: subSrc, dst: ctx.scratch)
                if sl > 0 && sl < innerLen1 {
                    ctx.inner.baseAddress!.advanced(by: HostEngine.tileBytes)
                        .copyMemory(from: ctx.scratch.baseAddress!, byteCount: sl)
                    innerOp1 = Opcode.lz4; innerLen1 = sl; subInInner = true
                }
                let sb = ctx.codec.encodeBitmap(src: subSrc, dst: ctx.scratch)
                if sb > 0 && sb < innerLen1 {
                    ctx.inner.baseAddress!.advanced(by: HostEngine.tileBytes)
                        .copyMemory(from: ctx.scratch.baseAddress!, byteCount: sb)
                    innerOp1 = Opcode.lzbitmap; innerLen1 = sb; subInInner = true
                }
                // VP8L on the sub-rect draws from a per-worker pixel budget —
                // sub-rect probes are where the scroll-residual win lives
                // (measured 8.5 → 5.4 MB/s), but unbounded they double the
                // tick p95. Tiny rects ride free.
                let subPx = sw * sh
                var allowWebp = webpTry[q] != 0 || subPx <= 1024
                if !allowWebp && ctx.webpSubPixelBudget >= subPx {
                    ctx.webpSubPixelBudget -= subPx
                    allowWebp = true
                }
                let sww = allowWebp
                    ? WebPTile.encodeLossless(src: subSrc, width: sw, height: sh,
                                              effort: vp8lEffort, dst: ctx.scratch)
                    : 0
                if sww > 0 && sww < innerLen1 {
                    ctx.inner.baseAddress!.advanced(by: HostEngine.tileBytes)
                        .copyMemory(from: ctx.scratch.baseAddress!, byteCount: sww)
                    innerOp1 = Opcode.webpl; innerLen1 = sww; subInInner = true
                }
                let total1 = DeltaPayload.subRectHeaderBytes + innerLen1
                // Pick the winner (must beat the full-tile best strictly).
                let useSub = total1 < total0
                let total = useSub ? total1 : total0
                guard total < bestLen, total <= HostEngine.tileBytes else { return }
                var w = DeltaPayload.writeHeader(
                    baseHash: baseHash,
                    subRect: useSub ? (x: minX, y: minY, width: sw, height: sh) : nil,
                    innerOpcode: useSub ? innerOp1 : innerOp0, into: out)
                if useSub {
                    if subInInner {
                        out.baseAddress!.advanced(by: w).copyMemory(
                            from: ctx.inner.baseAddress!.advanced(by: HostEngine.tileBytes),
                            byteCount: innerLen1)
                    } else {
                        out.baseAddress!.advanced(by: w).copyMemory(
                            from: ctx.sub.baseAddress!, byteCount: innerLen1)
                    }
                    w += innerLen1
                } else {
                    out.baseAddress!.advanced(by: w).copyMemory(
                        from: ctx.inner.baseAddress!, byteCount: innerLen0)
                    w += innerLen0
                }
                bestOp = Opcode.delta
                bestLen = w
            }

            var webpOutcome: UInt8 = 0
            if webpTry[q] != 0 {
                let webpLen = WebPTile.encodeLossless(src: tight, width: tw, height: th,
                                                      effort: vp8lEffort, dst: ctx.scratch)
                if webpLen > 0 && webpLen < bestLen {
                    // Any strict win still ships (INV-free byte savings)…
                    out.baseAddress!.copyMemory(from: ctx.scratch.baseAddress!, byteCount: webpLen)
                    bestOp = Opcode.webpl
                    // …but only a decisive win keeps the position probing.
                    webpOutcome = webpLen + max(bestLen >> 4, 32) <= bestLen ? 1 : 2
                    bestLen = webpLen
                } else {
                    webpOutcome = 2 // failed the RAW gate or lost to a cheap codec
                }
            }
            tryDelta(&bestLen, &bestOp)
            meta[q] = EncodedMeta(opcode: bestOp, length: Int32(bestLen), webpOutcome: webpOutcome)
        }
    }
}
