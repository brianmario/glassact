import Dispatch
import GlassActCodec // WebPTile
import GlassActWire  // KeyframeCodec, Serial

/// Lossless keyframe apply (§4.7). A keyframe is a batch of one giant record: decode
/// the striped image (stripes in parallel), then per-tile LWW apply (blit +
/// tileSeq advance — unlike lossy video frames, this is definitive
/// content). The engine ACKs only on successful application; a decode
/// failure sends nothing and the host's timeout repaints via the tile path.
///
/// Queue confinement: stored inline in `ViewerEngine` and called only on
/// the engine's confining queue (the app's `applyQueue`); the stripe
/// workers it fans out to are joined before `apply` returns. Noncopyable
/// because it owns the decode scratch (freed in `deinit`).
struct KeyframeApplier: ~Copyable {
    enum Outcome {
        /// Invalid geometry/codec or a stripe failed to decode: nothing
        /// applied, no ACK.
        case dropped
        /// Lossy first paint (video-frame semantics): blitted under the
        /// LWW gate without advancing tileSeq; never ACKed.
        case appliedTransient
        /// Lossless keyframe: blitted and tileSeq advanced; ACK it.
        case applied
    }

    /// Grow-only decode target for the keyframe rect.
    private var scratch: UnsafeMutableRawBufferPointer?
    private var scratchCapacity = 0

    init() {}

    deinit {
        scratch?.deallocate()
    }

    /// Frees the scratch (in-session geometry change); it regrows on demand.
    mutating func releaseScratch() {
        scratch?.deallocate()
        scratch = nil
        scratchCapacity = 0
    }

    /// Decodes the keyframe and applies it to the canvas, per tile under the
    /// LWW gate.
    mutating func apply(seq: UInt32, x: Int, y: Int, w: Int, h: Int,
                        codec: UInt8, stripes: [[UInt8]],
                        canvas: UnsafeMutableRawBufferPointer, grid: TileGrid,
                        tileSeq: inout ContiguousArray<UInt32>,
                        dirty: inout DirtyTiles) -> Outcome {
        guard codec == KeyframeCodec.vp8lStriped || codec == KeyframeCodec.webpLossyStriped,
              !stripes.isEmpty, // the parser guarantees ≥ 1; the band math divides by it
              w >= 1, h >= 1, x >= 0, y >= 0,
              x + w <= grid.width, y + h <= grid.height,
              x % TileGrid.tileSize == 0, y % TileGrid.tileSize == 0 else {
            return .dropped
        }
        // A lossy first paint has video-frame semantics — blit under the
        // LWW gate, but never advance tileSeq and never ACK. Everything that
        // follows (the lossless keyframe, any record) overwrites it.
        let transient = codec == KeyframeCodec.webpLossyStriped
        let rectBytes = w * h * 4
        if scratchCapacity < rectBytes {
            scratch?.deallocate()
            scratch = .allocate(byteCount: rectBytes, alignment: 64)
            scratchCapacity = rectBytes
        }
        let scratch = scratch!
        let rowBytes = w * 4
        let bandH = (h + stripes.count - 1) / stripes.count
        // Every stripe must own rows, and together they must cover h exactly.
        guard (stripes.count - 1) * bandH < h else { return .dropped }
        // Stripes decode into disjoint row bands of the scratch, so they run
        // in parallel — the host encodes them that way; decoding them one by
        // one would stall datagram apply, ACKs and present for the whole frame.
        let job = StripeJob(stripes: stripes, scratch: scratch, rowBytes: rowBytes,
                            bandH: bandH, width: w, height: h, lossless: !transient)
        guard job.run() else {
            return .dropped // no ACK — the host times out and repaints via tiles
        }

        let ts = TileGrid.tileSize
        for tr in (y / ts)...((y + h - 1) / ts) {
            for tc in (x / ts)...((x + w - 1) / ts) {
                let idx = tr * grid.cols + tc
                guard Serial.newer(seq, than: tileSeq[idx]) else { continue }
                let tx = tc * ts
                let ty = tr * ts
                let copyW = min(tx + ts, x + w) - tx
                let copyH = min(ty + ts, y + h) - ty
                for r in 0..<copyH {
                    canvas.baseAddress!
                        .advanced(by: ((ty + r) * grid.width + tx) * 4)
                        .copyMemory(from: scratch.baseAddress!
                            .advanced(by: (ty - y + r) * rowBytes + (tx - x) * 4),
                                    byteCount: copyW * 4)
                }
                if !transient {
                    tileSeq[idx] = seq
                }
                dirty.mark(idx)
                traceTile(idx, "viewer keyframe apply seq=\(seq) transient=\(transient)")
            }
        }
        return transient ? .appliedTransient : .applied
    }

    /// Parallel stripe decode. `@unchecked Sendable`: each worker writes
    /// only its own stripe's row band of `scratch` and its own result slot;
    /// the caller blocks until all finish.
    private struct StripeJob: @unchecked Sendable {
        let stripes: [[UInt8]]
        let scratch: UnsafeMutableRawBufferPointer
        let rowBytes: Int
        let bandH: Int
        let width: Int
        let height: Int
        let lossless: Bool

        func run() -> Bool {
            let results = UnsafeMutableBufferPointer<Bool>.allocate(capacity: stripes.count)
            results.initialize(repeating: false)
            defer { results.deallocate() }
            let work = Work(job: self, results: results)
            DispatchQueue.concurrentPerform(iterations: stripes.count) { work.decode($0) }
            return results.allSatisfy { $0 }
        }

        private struct Work: @unchecked Sendable {
            let job: StripeJob
            let results: UnsafeMutableBufferPointer<Bool>

            func decode(_ i: Int) {
                let row = i * job.bandH
                let bh = min(job.bandH, job.height - row)
                let dst = UnsafeMutableRawBufferPointer(
                    start: job.scratch.baseAddress!.advanced(by: row * job.rowBytes), count: bh * job.rowBytes)
                let n = job.stripes[i].withUnsafeBytes { src in
                    job.lossless
                        ? WebPTile.decodeLossless(src: src, width: job.width, height: bh, dst: dst)
                        : WebPTile.decodeBGRA(src: src, width: job.width, height: bh, dst: dst)
                }
                results[i] = n == bh * job.rowBytes
            }
        }
    }
}
