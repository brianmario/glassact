import GlassActWire // Serial

/// Viewer video regions (§5): a small fixed set of region slots fed by the
/// dedicated video stream, each with its decoder. Video decodes into the
/// overlay layer (never the canvas, INV-8) and marks present-dirty but does
/// NOT touch tileSeq — a tile shows its video only while the frame's stamp
/// is newer than the canvas record, so after STOP the lossless repaint
/// (newer seqs) takes the tile back.
///
/// It owns decoder lifecycle (start / stop / stop-all), the per-frame
/// LWW-gated blit, and the undecodable-streak escalation; the engine keeps
/// the stream deframing, stats, callbacks and the decision to fail.
///
/// Queue confinement: stored inline in `ViewerEngine` and called only on
/// the engine's confining queue (the app's `applyQueue`); decoders deliver
/// pixels synchronously on it.
struct VideoRegionTable {
    static let slotCount = 4
    /// A region undecodable for this long (no sync frame arrives to resync a
    /// rebuilt decoder — encoders send them only on demand) fails the
    /// session: a reconnect's cold start beats a frozen region.
    static let undecodableLimitUS: UInt64 = 1_000_000

    private struct Slot {
        var active = false
        var generation: UInt32 = 0
        var x = 0, y = 0, w = 0, h = 0
        var codec: UInt8 = 0
        var decoder: (any VideoRegionDecoder)?
        var failingSinceUS: UInt64 = 0 // first undecodable frame of the current streak
    }

    /// What one video FRAME did.
    struct FrameResult {
        /// No live region matches (region, generation): nothing decoded.
        var dropped = false
        /// Pixel deliveries that reached the overlay (the decoder's
        /// `onPixels` with a well-formed buffer) — 0 or 1 for the in-tree
        /// decoders.
        var blits = 0
        /// The decoder reported success.
        var decoded = true
        /// The region has now been undecodable for longer than
        /// `undecodableLimitUS`: the engine fails the session.
        var undecodableTooLong = false
    }

    private let decoderFactory: (() -> any VideoRegionDecoder)?
    private var slots = [Slot](repeating: Slot(), count: slotCount)

    init(decoderFactory: (() -> any VideoRegionDecoder)?) {
        self.decoderFactory = decoderFactory
    }

    /// Whether region video can be decoded at all (a decoder factory was
    /// supplied) — gates the video-codec caps the viewer advertises.
    var decodesRegions: Bool { decoderFactory != nil }

    /// Codec of the (first) active region, nil when none is live.
    var activeCodec: UInt8? {
        slots.first(where: { $0.active })?.codec
    }

    /// START: (re)builds the region's decoder. Returns false — region
    /// dropped — for an out-of-range slot or rect, no decoder factory, or a
    /// codec/config the decoder refuses (the host's dissolve repaint
    /// eventually restores the area losslessly).
    mutating func start(region: Int, generation: UInt32, x: Int, y: Int, w: Int, h: Int,
                        codec: UInt8, config: [UInt8], grid: TileGrid) -> Bool {
        guard region < Self.slotCount,
              w >= 1, h >= 1, x + w <= grid.width, y + h <= grid.height,
              let factory = decoderFactory else {
            return false
        }
        slots[region].decoder?.stop()
        let decoder = factory()
        guard decoder.start(codec: codec, config: config, width: w, height: h) else {
            slots[region] = Slot()
            return false
        }
        slots[region] = Slot(active: true, generation: generation,
                             x: x, y: y, w: w, h: h, codec: codec, decoder: decoder)
        return true
    }

    /// FRAME: decodes into the region's rect of the viewer's `overlay`
    /// layer, tile-wise, LWW-gated by the frame's `stamp` (not advancing
    /// tileSeq); `overlaySeq`/`overlayOn` record the stamp each claimed tile
    /// now shows. Tracks the region's undecodable streak.
    mutating func applyFrame(region: Int, generation: UInt32, stamp: UInt32,
                             sync: Bool, claims: VideoClaims = .all, data: [UInt8], nowUS: UInt64,
                             overlay: UnsafeMutableRawBufferPointer, grid: TileGrid,
                             tileSeq: ContiguousArray<UInt32>,
                             dirty: inout DirtyTiles,
                             overlaySeq: inout ContiguousArray<UInt32>,
                             overlayOn: inout ContiguousArray<Bool>) -> FrameResult {
        guard region < Self.slotCount,
              slots[region].active,
              slots[region].generation == generation,
              let decoder = slots[region].decoder else {
            return FrameResult(dropped: true)
        }
        let slot = slots[region]
        var blits = 0
        let decoded = decoder.decode(data, sync: sync) { pixels, rowBytes in
            guard rowBytes >= slot.w * 4, pixels.count >= (slot.h - 1) * rowBytes + slot.w * 4 else { return }
            // Tile-wise blit, LWW-gated by the frame's stamp: a tile that a
            // NEWER record already wrote (dissolve repaint that crossed this
            // frame on the datagram path) is left alone; the video write does
            // NOT advance tileSeq — any newer record takes the tile back.
            let ts = TileGrid.tileSize
            let boxC0 = slot.x / ts, boxR0 = slot.y / ts
            let boxCols = (slot.x + slot.w - 1) / ts - boxC0 + 1
            // Claims are ascending runs over the same row-major order this
            // loop walks: one cursor, no per-frame allocation.
            var runIndex = 0
            for tr in boxR0...((slot.y + slot.h - 1) / ts) {
                for tc in boxC0...((slot.x + slot.w - 1) / ts) {
                    let idx = tr * grid.cols + tc
                    var claimed = true
                    if case let .runs(runs) = claims {
                        let rel = UInt32((tr - boxR0) * boxCols + (tc - boxC0))
                        while runIndex < runs.count,
                              UInt64(runs[runIndex].start) + UInt64(runs[runIndex].count) <= UInt64(rel) {
                            runIndex += 1
                        }
                        claimed = runIndex < runs.count && runs[runIndex].start <= rel
                    }
                    guard Serial.newer(stamp, than: tileSeq[idx]) else { continue }
                    let tx = tc * ts
                    let ty = tr * ts
                    let copyX = max(tx, slot.x)
                    let copyY = max(ty, slot.y)
                    let copyW = min(tx + ts, slot.x + slot.w) - copyX
                    let copyH = min(ty + ts, slot.y + slot.h) - copyY
                    guard copyW > 0, copyH > 0 else { continue }
                    for row in 0..<copyH {
                        overlay.baseAddress!
                            .advanced(by: ((copyY + row) * grid.width + copyX) * 4)
                            .copyMemory(from: pixels.baseAddress!
                                .advanced(by: (copyY - slot.y + row) * rowBytes + (copyX - slot.x) * 4),
                                        byteCount: copyW * 4)
                    }
                    // Remember which video this tile shows — only where the
                    // frame claims it. An unclaimed tile's overlay pixels
                    // still refresh (a re-sharpen shows on tiles still on
                    // video), but a tile showing its exact canvas copy stays
                    // on it.
                    if claimed {
                        overlaySeq[idx] = stamp
                        overlayOn[idx] = true
                    }
                    dirty.mark(idx)
                }
            }
            blits += 1
        }
        var result = FrameResult(blits: blits, decoded: decoded)
        if decoded {
            slots[region].failingSinceUS = 0
        } else if slots[region].failingSinceUS == 0 {
            slots[region].failingSinceUS = max(nowUS, 1)
        } else if nowUS &- slots[region].failingSinceUS > Self.undecodableLimitUS {
            result.undecodableTooLong = true
        }
        return result
    }

    /// STOP: tears the region down. False (ignored) unless (region,
    /// generation) is live.
    /// The region's live generation is `generation` (REVEAL's guard).
    func isCurrent(region: Int, generation: UInt32) -> Bool {
        region < Self.slotCount && slots[region].active && slots[region].generation == generation
    }

    mutating func stop(region: Int, generation: UInt32) -> Bool {
        guard region < Self.slotCount,
              slots[region].active,
              slots[region].generation == generation else { return false }
        slots[region].decoder?.stop()
        slots[region] = Slot()
        return true
    }

    /// Stops every region's decoder and clears all slots (in-session
    /// geometry change: regions are old-canvas scoped). Stale frames are then
    /// dropped by the generation guard.
    mutating func stopAll() {
        for i in 0..<slots.count {
            slots[i].decoder?.stop()
            slots[i] = Slot()
        }
    }
}
