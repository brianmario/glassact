import Foundation
import GlassActCodec
import GlassActTransport
import GlassActWire

/// Lossless keyframes (§4.7; striped VP8L over the video stream) and the
/// lossy cold-start first paint.
/// HostEngine extension: encodeQueue-confined like the engine itself.
extension HostEngine {
    // MARK: - Lossless keyframes

    /// Encode `box` (tile coords, inclusive) as one striped-VP8L keyframe and
    /// send it on the video stream. Returns false (sending nothing) when the
    /// content is too incompressible for the byte budget — callers fall back
    /// to the tile path. On success the covered tiles are marked in flight
    /// under the keyframe's seq (INV-9: overwrites any prior slot).
    func sendKeyframe(c0: Int, r0: Int, c1: Int, r1: Int,
                              frame: UnsafeRawBufferPointer, bytesPerRow: Int,
                              nowUS: UInt64) -> Bool {
        let ts = TileGrid.tileSize
        let x = c0 * ts
        let y = r0 * ts
        let w = min((c1 + 1) * ts, grid.width) - x
        let h = min((r1 + 1) * ts, grid.height) - y
        guard w >= 1, h >= 1 else { return false }
        let rectBytes = w * h * 4
        if kfPixelsCapacity < rectBytes {
            kfPixels?.deallocate()
            kfPixels = .allocate(byteCount: rectBytes, alignment: 64)
            kfPixelsCapacity = rectBytes
        }
        if kfOutCapacity < rectBytes {
            kfOut?.deallocate()
            kfOut = .allocate(byteCount: rectBytes, alignment: 64)
            kfOutCapacity = rectBytes
        }
        guard let pixels = kfPixels, let out = kfOut else { return false }
        let rowBytes = w * 4
        for row in 0..<h {
            pixels.baseAddress!.advanced(by: row * rowBytes)
                .copyMemory(from: frame.baseAddress!.advanced(by: (y + row) * bytesPerRow + x * 4),
                            byteCount: rowBytes)
        }

        // Parallel striped encode (a stripe that cannot beat its own RAW size
        // fails the whole keyframe — the tile path handles incompressible
        // content).
        guard let blobs = encodeStripes(pixels: UnsafeRawBufferPointer(start: pixels.baseAddress, count: rectBytes),
                                        width: w, height: h, into: out, lossyQuality: nil) else {
            return false
        }

        let seq = nextFrameSeq
        nextFrameSeq &+= 1
        if nextFrameSeq == 0 { nextFrameSeq = 1 }

        // Per-covered-tile hashes from the tight rect — the future
        // acked/inflight identities.
        kfHashes.removeAll(keepingCapacity: true)
        for row in r0...r1 {
            for col in c0...c1 {
                let tx = col * ts - x
                let ty = row * ts - y
                let tw = min(ts, w - tx)
                let th = min(ts, h - ty)
                let hash = XXH64.hashRows(
                    frame: UnsafeRawBufferPointer(start: pixels.baseAddress, count: rectBytes),
                    bytesPerRow: rowBytes, x: tx, y: ty, tw: tw, th: th)
                kfHashes.append(hash)
                let idx = row * grid.cols + col
                ledger.markInflight(idx, hash: hash, seq: seq)
                traceTile(idx, "host keyframe send seq=\(seq)")
            }
        }

        let message = VideoMessage.keyframe(seq: seq, x: UInt16(x), y: UInt16(y),
                                            width: UInt16(w), height: UInt16(h),
                                            codec: KeyframeCodec.vp8lStriped, stripes: blobs)
        guard let encoded = message.encodedForSend() else {
            return false // tile path
        }
        transport.sendVideo(Data(encoded))
        kfActive = true
        kfSeq = seq
        kfSentUS = sendStampUS(nowUS)
        kfSentBytes = encoded.count
        kfBox = (c0, r0, c1, r1)
        kfRect = (x, y, w, h)
        stats.keyframesSent += 1
        stats.keyframeBytesSent += encoded.count
        stats.bytesOut += encoded.count
        return true
    }

    /// Striped WebP of a tight `width`×`height` BGRA image, stripes encoded in
    /// parallel into disjoint `bandCap` slices of `out`. Lossless VP8L
    /// (effort 4) when `lossyQuality` is nil. Nil if any stripe fails or the
    /// total exceeds keyframeMaxBytes. (Shared by the lossless keyframe and
    /// the transient lossy paint, which had near-identical copies.)
    func encodeStripes(pixels: UnsafeRawBufferPointer, width: Int, height: Int,
                               into out: UnsafeMutableRawBufferPointer, lossyQuality: Float?) -> [[UInt8]]? {
        let stripes = min(Self.keyframeStripes, height)
        let rowBytes = width * 4
        let bandH = (height + stripes - 1) / stripes
        let bandCap = bandH * rowBytes
        let sizes = UnsafeMutableBufferPointer<Int>.allocate(capacity: stripes)
        sizes.initialize(repeating: 0)
        defer { sizes.deallocate() }
        let job = StripeEncodeJob(pixels: pixels, out: out, sizes: sizes, width: width, height: height,
                                  bandH: bandH, bandCap: bandCap, lossyQuality: lossyQuality,
                                  effort: currentKeyframeEffort)
        DispatchQueue.concurrentPerform(iterations: stripes) { job.encode($0) }
        var total = 0
        for i in 0..<stripes {
            guard sizes[i] > 0 || min(bandH, height - i * bandH) <= 0 else { return nil } // encode failed
            total += sizes[i]
        }
        guard total > 0, total <= Self.keyframeMaxBytes else { return nil }
        var blobs: [[UInt8]] = []
        blobs.reserveCapacity(stripes)
        for i in 0..<stripes where sizes[i] > 0 {
            blobs.append([UInt8](UnsafeRawBufferPointer(
                start: out.baseAddress!.advanced(by: i * bandCap), count: sizes[i])))
        }
        return blobs
    }

    /// `@unchecked Sendable`: each worker reads its own row band of `pixels`
    /// and writes only its own `bandCap` slice of `out` and its own `sizes`
    /// slot; encodeStripes blocks until all finish.
    struct StripeEncodeJob: @unchecked Sendable {
        let pixels: UnsafeRawBufferPointer
        let out: UnsafeMutableRawBufferPointer
        let sizes: UnsafeMutableBufferPointer<Int>
        let width: Int
        let height: Int
        let bandH: Int
        let bandCap: Int
        let lossyQuality: Float?
        let effort: Int32

        func encode(_ i: Int) {
            let y0 = i * bandH
            let bh = min(bandH, height - y0)
            guard bh > 0 else { return }
            let rowBytes = width * 4
            let band = UnsafeRawBufferPointer(start: pixels.baseAddress!.advanced(by: y0 * rowBytes),
                                              count: bh * rowBytes)
            let dst = UnsafeMutableRawBufferPointer(start: out.baseAddress!.advanced(by: i * bandCap),
                                                    count: bandCap)
            sizes[i] = lossyQuality.map {
                WebPTile.encodeLossy(src: band, width: width, height: bh, quality: $0, dst: dst)
            } ?? WebPTile.encodeLossless(src: band, width: width, height: bh, effort: effort, dst: dst)
        }
    }

    /// A transient first paint (§4.7): striped WebP-lossy of `box` (tile
    /// coords, inclusive), fire-and-forget (no inflight tracking, no ACK, no
    /// shadow promotion — the viewer treats it like a video frame). The stamp
    /// is the *unconsumed* nextFrameSeq: the lossless send that follows
    /// claims the same seq and, because the paint never advances tileSeq,
    /// cleanly overwrites it per tile. Only safe over cold tiles with
    /// nothing in flight (the cold start): an older in-flight record landing
    /// first would be painted over while its ACK still promotes the host's
    /// belief.
    @discardableResult
    func sendLossyFirstPaint(c0: Int, r0: Int, c1: Int, r1: Int,
                             frame: UnsafeRawBufferPointer, bytesPerRow: Int) -> Bool {
        let ts = TileGrid.tileSize
        let x = c0 * ts
        let y = r0 * ts
        let w = min((c1 + 1) * ts, grid.width) - x
        let h = min((r1 + 1) * ts, grid.height) - y
        guard w >= 1, h >= 1 else { return false }
        // Shares kfPixels/kfOut with sendKeyframe: while a keyframe is in
        // flight, commitKeyframeAck promotes kfPixels into the shadow, so
        // overwriting them here would corrupt the host's copy of what the
        // viewer has. (A second pair of frame-sized buffers would cost
        // ~120 MB at 5K for a paint that is never needed mid-keyframe.)
        guard !kfActive else { return false }
        let rectBytes = w * h * 4
        if kfPixelsCapacity < rectBytes {
            kfPixels?.deallocate()
            kfPixels = .allocate(byteCount: rectBytes, alignment: 64)
            kfPixelsCapacity = rectBytes
        }
        if kfOutCapacity < rectBytes {
            kfOut?.deallocate()
            kfOut = .allocate(byteCount: rectBytes, alignment: 64)
            kfOutCapacity = rectBytes
        }
        guard let pixels = kfPixels, let out = kfOut else { return false }
        let rowBytes = w * 4
        for row in 0..<h {
            pixels.baseAddress!.advanced(by: row * rowBytes)
                .copyMemory(from: frame.baseAddress!.advanced(by: (y + row) * bytesPerRow + x * 4),
                            byteCount: rowBytes)
        }
        guard let blobs = encodeStripes(pixels: UnsafeRawBufferPointer(start: pixels.baseAddress, count: rectBytes),
                                        width: w, height: h, into: out, lossyQuality: 90) else {
            return false
        }
        let message = VideoMessage.keyframe(seq: nextFrameSeq, x: UInt16(x), y: UInt16(y),
                                            width: UInt16(w), height: UInt16(h),
                                            codec: KeyframeCodec.webpLossyStriped, stripes: blobs)
        guard let encoded = message.encodedForSend() else {
            return false
        }
        stats.lossyFirstPaintsSent += 1
        stats.bytesOut += encoded.count
        transport.sendVideo(Data(encoded))
        return true
    }

    /// KEYFRAME_ACK: the viewer applied it (per-tile LWW permitting) —
    /// promote acked hashes and shadow pixels under the usual seq guard.
    func commitKeyframeAck(seq: UInt32) {
        guard kfActive, seq == kfSeq, let pixels = kfPixels else { return }
        let ts = TileGrid.tileSize
        let rowBytes = kfRect.w * 4
        var k = 0
        for row in kfBox.r0...kfBox.r1 {
            for col in kfBox.c0...kfBox.c1 {
                defer { k += 1 }
                let idx = row * grid.cols + col
                guard ledger.commit(idx, seq: kfSeq, hash: kfHashes[k]) else { continue } // overwritten by a newer send
                noteExactCopyConfirmed(idx, seq: kfSeq)
                let tx = col * ts - kfRect.x
                let ty = row * ts - kfRect.y
                let tw = min(ts, kfRect.w - tx)
                let th = min(ts, kfRect.h - ty)
                var tightOffset = 0
                for r in 0..<th {
                    tileScratch.baseAddress!.advanced(by: tightOffset)
                        .copyMemory(from: pixels.baseAddress!.advanced(by: (ty + r) * rowBytes + tx * 4),
                                    byteCount: tw * 4)
                    tightOffset += tw * 4
                }
                TileOps.apply(tight: UnsafeRawBufferPointer(start: tileScratch.baseAddress, count: tw * th * 4),
                              into: shadow, canvasWidth: grid.width,
                              x: col * ts, y: row * ts, tw: tw, th: th)
                traceTile(idx, "host keyframe ack seq=\(seq)")
            }
        }
        kfActive = false
    }

    /// The stream is reliable, so a missing ACK means a stalled/apply-failed
    /// viewer, not loss — after a generous window, drop the covered tiles to
    /// cold (the §4.4 rule) and let the tile path repaint.
    func resolveKeyframeTimeout(nowUS: UInt64) {
        guard kfActive else { return }
        let budget = max(5 &* srttUS, 2_000_000) &+ UInt64(kfSentBytes / 50)
        guard Self.elapsedUS(nowUS, since: kfSentUS) >= budget else { return }
        for row in kfBox.r0...kfBox.r1 {
            for col in kfBox.c0...kfBox.c1 {
                invalidateAfterTimeout(tile: row * grid.cols + col, seq: kfSeq)
            }
        }
        kfActive = false
    }
}
