import Foundation
import GlassActCodec
import GlassActWire

/// Scroll detection & emission (§4.8): global/windowed shift estimation, 2D
/// drag probes, per-tile verification against the ACKed shadow, in-place
/// SCROLL emission and SCROLL_ACK repair.
/// HostEngine extension: encodeQueue-confined like the engine itself.
extension HostEngine {
    static let scrollProbeCount = 24
    static let scrollMaxDy = 600
    static let scrollMinVotes = 6

    /// Grid-aware engagement thresholds: detection costs a shadow row-index
    /// build, so only heavy ticks bother; small test grids scale down.
    var scrollMinQualified: Int { min(64, max(8, grid.count / 4)) }
    var scrollMinSatisfied: Int { min(48, max(6, grid.count / 4)) }

    /// Cheap row signature over a horizontal range: three pixel spans folded
    /// into one hash — collisions only cost a wasted dy candidate, which
    /// per-tile memcmp verification then rejects. The window-scoped
    /// detector passes the churn bbox rather than the full screen width.
    func rowSignature(_ base: UnsafeRawPointer, rowStride: Int, row: Int,
                              x0: Int, w: Int) -> UInt64 {
        let rowBase = base.advanced(by: row * rowStride + x0 * 4)
        var state = XXH64.Streaming()
        // Never wider than the box's row (a < 4 px box used to read 16 B).
        let span = min(128 * 4, max(16, w), w * 4)
        state.update(UnsafeRawBufferPointer(start: rowBase, count: span))
        state.update(UnsafeRawBufferPointer(start: rowBase.advanced(by: max(0, (w / 2) * 4 - span / 2)), count: span))
        state.update(UnsafeRawBufferPointer(start: rowBase.advanced(by: max(0, w * 4 - span)), count: span))
        return state.finalize()
    }

    /// Column analog for horizontal scroll detection: three vertical pixel
    /// spans (strided reads) within [y0, y0+h).
    func colSignature(_ base: UnsafeRawPointer, rowStride: Int, col: Int,
                              y0: Int, h: Int) -> UInt64 {
        var state = XXH64.Streaming()
        let span = min(64, max(4, h / 4), h) // never taller than the box
        for start in [y0, y0 + max(0, h / 2 - span / 2), y0 + max(0, h - span)] {
            for row in start..<(start + span) {
                var px: UInt32 = 0
                withUnsafeMutableBytes(of: &px) { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(
                        start: base.advanced(by: row * rowStride + col * 4), count: 4))
                }
                withUnsafeBytes(of: px) { state.update($0) }
            }
        }
        return state.finalize()
    }

    func maybeEmitScroll(frame: UnsafeRawBufferPointer, bytesPerRow: Int) {
        guard state == .running else { return }
        // Only bother on heavy ticks.
        for i in 0..<scrollQualified.count { scrollQualified[i] = false }
        var qualifyCount = 0
        for i in 0..<worklist.count {
            let idx = Int(worklist[i])
            let h = hashResults[i]
            if ledger.qualifies(idx, hash: h) {
                scrollQualified[idx] = true
                qualifyCount += 1
            }
        }
        guard qualifyCount >= scrollMinQualified else { return }

        // Scope detection to the churn bounding box: terminal/window scrolls
        // — measured at 95 % of the typing trace's bytes — move a sub-rect,
        // not the whole screen. Signatures, the shadow
        // index, and the shift search all live inside the bbox.
        let width = grid.width
        let height = grid.height
        let ts = TileGrid.tileSize
        var bc0 = grid.cols, bc1 = -1, br0 = grid.rows, br1 = -1
        for idx in 0..<grid.count where scrollQualified[idx] {
            let col = idx % grid.cols
            let row = idx / grid.cols
            bc0 = min(bc0, col); bc1 = max(bc1, col)
            br0 = min(br0, row); br1 = max(br1, row)
        }
        guard bc1 >= bc0, br1 >= br0 else { return }
        let bx0 = bc0 * ts
        let by0 = br0 * ts
        let bx1 = min((bc1 + 1) * ts, width)
        let by1 = min((br1 + 1) * ts, height)
        let bw = bx1 - bx0
        let bh = by1 - by0

        let shadowBase = shadow.baseAddress!
        let frameBase = frame.baseAddress!

        // Vertical pass: match probe-row signatures of the frame against an
        // index of shadow rows, all scoped to the bbox. Voting is pure
        // heuristic — INV-3 is enforced at verification below.
        var dx = 0
        var dy = 0
        do {
            var shadowRows: [UInt64: [Int]] = [:]
            shadowRows.reserveCapacity(bh)
            for row in by0..<by1 {
                shadowRows[rowSignature(shadowBase, rowStride: width * 4, row: row,
                                        x0: bx0, w: bw), default: []].append(row)
            }
            var votes: [Int: Int] = [:]
            let step = max(1, bh / Self.scrollProbeCount)
            var probe = by0 + step / 2
            while probe < by1 {
                defer { probe += step }
                let sig = rowSignature(frameBase, rowStride: bytesPerRow, row: probe,
                                       x0: bx0, w: bw)
                guard let matches = shadowRows[sig] else { continue }
                for m in matches {
                    let candidate = m - probe
                    if candidate != 0 && abs(candidate) <= min(Self.scrollMaxDy, bh - 1) {
                        votes[candidate, default: 0] += 1
                    }
                }
            }
            if let (best, voteCount) = votes.max(by: {
                ($0.value, -abs($0.key), -$0.key) < ($1.value, -abs($1.key), -$1.key)
            }), voteCount >= Self.scrollMinVotes {
                dy = best
            }
        }

        // Horizontal pass, only when vertical found nothing and the bbox has
        // room for meaningful column signatures.
        if dy == 0 && bw >= 128 && bh >= 64 {
            var shadowCols: [UInt64: [Int]] = [:]
            shadowCols.reserveCapacity(bw)
            for col in bx0..<bx1 {
                shadowCols[colSignature(shadowBase, rowStride: width * 4, col: col,
                                        y0: by0, h: bh), default: []].append(col)
            }
            var votes: [Int: Int] = [:]
            let step = max(1, bw / Self.scrollProbeCount)
            var probe = bx0 + step / 2
            while probe < bx1 {
                defer { probe += step }
                let sig = colSignature(frameBase, rowStride: bytesPerRow, col: probe,
                                       y0: by0, h: bh)
                guard let matches = shadowCols[sig] else { continue }
                for m in matches {
                    let candidate = m - probe
                    if candidate != 0 && abs(candidate) <= min(Self.scrollMaxDy, bw - 1) {
                        votes[candidate, default: 0] += 1
                    }
                }
            }
            if let (best, voteCount) = votes.max(by: {
                ($0.value, -abs($0.key), -$0.key) < ($1.value, -abs($1.key), -$1.key)
            }), voteCount >= Self.scrollMinVotes {
                dx = best
            }
        }
        // 1-D result first (when the votes found something), then the 2-D
        // pass as a fallback — NOT only when 1-D found nothing: repetitive
        // content (a terminal's identical blank rows) reliably produces a
        // spurious 1-D vote that fails verification, and it must not mask
        // the probe search. Window drags move diagonally (dx and dy at once —
        // dragscan measured byte-rigid shifts like (+106, +32) between
        // consecutive frames), which defeats both 1-D signature passes by
        // construction: a shifted row never hashes equal when the columns
        // moved too. The 2-D pass locates one textured probe block of the
        // frame inside the shadow by sampled-equality search; sampled hits
        // are memcmp-confirmed on the full block. All of it is pure candidate
        // generation — per-tile verification stays the only authority (INV-3).
        traceDrag("tick qualify=\(qualifyCount) bbox=(\(bx0),\(by0) \(bw)×\(bh)) 1d=(\(dx),\(dy))")
        if dx != 0 || dy != 0 {
            if verifyAndEmitScroll(dx: dx, dy: dy, qualifyCount: qualifyCount,
                                   frame: frame, bytesPerRow: bytesPerRow) {
                return
            }
        }
        guard bw >= 192, bh >= 192 else { return }
        let probeStart = glassactDragDebug ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if glassactDragDebug {
                let us = (DispatchTime.now().uptimeNanoseconds - probeStart) / 1000
                traceDrag("2d pass took \(us) µs")
            }
        }
        for candidate in probe2DShift(frameBase: frameBase, bytesPerRow: bytesPerRow,
                                      shadowBase: shadowBase,
                                      bx0: bx0, by0: by0, bx1: bx1, by1: by1) {
            if verifyAndEmitScroll(dx: candidate.dx, dy: candidate.dy,
                                   qualifyCount: qualifyCount, relaxed: true,
                                   frame: frame, bytesPerRow: bytesPerRow) {
                return
            }
        }
    }

    static let dragProbeSize = 128
    static let dragProbeSampleGrid = 16 // 16×16 samples at stride 8
    /// ±640, not ±224: live, the ACKed shadow lags a fast drag by several
    /// steps (deferral + ACK RTT), so the frame-vs-shadow offset is the
    /// CUMULATIVE motion since the last successful sync — measured drags
    /// move ~100 px/frame at 5K. The anchor/memmem search makes the wider
    /// window cheap (rows scanned scale linearly).
    static let dragSearchRadius = 640
    static let dragMaxCandidates = 4
    static let dragMaxProbes = 3
    static let dragProbeMinDistinct = 12

    static let dragAnchorBytes = 16
    static let dragMaxAnchorHitsPerRow = 64
    static let dragMaxBlockVerifies = 32

    /// Find (dx, dy) candidates such that the shadow at +(dx, dy) equals the
    /// frame for one 128×128 probe block. Probe positions form a 3×3 grid
    /// over the bbox ranked by texture (distinct sampled pixels — measured
    /// terminal content at 5K is ~90 % flat background, so a 64×64 probe
    /// rarely spanned a glyph line and the probe size/threshold are tuned for
    /// that), and the best few are each searched until one produces
    /// candidates.
    ///
    /// The search is anchor-based, NOT an offset sweep: 16 distinctive bytes
    /// from the probe's center row are located in the shadow's search window
    /// with memmem row by row (~1 MB of linear scanning), and only anchor
    /// hits get the sampled check + full-block memcmp. A naive ±radius²
    /// offset sweep was measured breaking the QUIC sustained test's real-time
    /// deadlines at -Onone — same candidates, ~200× the work. Candidates are
    /// ordered by |dx|+|dy| — consecutive drag frames move a small distance.
    func probe2DShift(frameBase: UnsafeRawPointer, bytesPerRow: Int,
                              shadowBase: UnsafeRawPointer,
                              bx0: Int, by0: Int, bx1: Int, by1: Int) -> [(dx: Int, dy: Int)] {
        let ps = Self.dragProbeSize
        let sg = Self.dragProbeSampleGrid
        let width = grid.width
        let height = grid.height
        @inline(__always) func pixel(_ base: UnsafeRawPointer, _ stride: Int, _ x: Int, _ y: Int) -> UInt32 {
            var px: UInt32 = 0
            withUnsafeMutableBytes(of: &px) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(
                    start: base.advanced(by: y * stride + x * 4), count: 4))
            }
            return px
        }

        // 3×3 grid of candidate positions across the bbox, ranked by texture.
        let clampX = { (x: Int) in min(max(x, bx0), max(bx0, min(bx1, width) - ps)) }
        let clampY = { (y: Int) in min(max(y, by0), max(by0, min(by1, height) - ps)) }
        var ranked: [(x: Int, y: Int, distinct: Int, samples: [UInt32])] = []
        for fy in 1...3 {
            for fx in 1...3 {
                let px0 = clampX(bx0 + fx * (bx1 - bx0) / 4 - ps / 2)
                let py0 = clampY(by0 + fy * (by1 - by0) / 4 - ps / 2)
                guard px0 + ps <= width, py0 + ps <= height else { continue }
                var samples = [UInt32](repeating: 0, count: sg * sg)
                var distinct = Set<UInt32>()
                var s = 0
                for sy in 0..<sg {
                    for sx in 0..<sg {
                        let v = pixel(frameBase, bytesPerRow, px0 + sx * 8 + 4, py0 + sy * 8 + 4)
                        samples[s] = v
                        s += 1
                        distinct.insert(v)
                    }
                }
                ranked.append((px0, py0, distinct.count, samples))
            }
        }
        ranked.sort { $0.distinct > $1.distinct }

        let r = Self.dragSearchRadius
        let shadowStride = width * 4
        var probesTried = 0
        // Candidates are collected across ALL textured probes, not first-hit:
        // under live deferral the shadow is mixed-generation, and only some
        // areas match at the true cumulative offset.
        var collected: [(dx: Int, dy: Int)] = []
        for position in ranked {
            guard probesTried < Self.dragMaxProbes else { break }
            let probeX = position.x, probeY = position.y
            let samples = position.samples
            guard position.distinct >= Self.dragProbeMinDistinct else {
                traceDrag("probe (\(probeX),\(probeY)) rejected: distinct=\(position.distinct)")
                break // ranked: everything after is flatter
            }
            probesTried += 1

            // Anchor: a 16-byte window with enough byte diversity to be
            // distinctive (flat background bytes would hit everywhere).
            // Scan rows outward from the probe's center — text content leaves
            // many rows blank, and a probe must not die because its exact
            // center row fell between glyph lines.
            let al = Self.dragAnchorBytes
            var anchorRow = -1
            var anchorOffset = -1
            rowScan: for step in 0...14 {
                let row = probeY + ps / 2 + (step % 2 == 0 ? 1 : -1) * ((step + 1) / 2) * 8
                guard row >= probeY, row < probeY + ps else { continue }
                let rowBase = frameBase.advanced(by: row * bytesPerRow + probeX * 4)
                var window = 0
                while window + al <= ps * 4 {
                    var distinctBytes = Set<UInt8>()
                    for b in 0..<al {
                        distinctBytes.insert(rowBase.load(fromByteOffset: window + b, as: UInt8.self))
                    }
                    if distinctBytes.count >= 8 {
                        anchorRow = row
                        anchorOffset = window
                        break rowScan
                    }
                    window += al
                }
            }
            guard anchorRow >= 0 else {
                traceDrag("probe (\(probeX),\(probeY)) no distinctive anchor")
                continue
            }
            let anchor = frameBase.advanced(by: anchorRow * bytesPerRow + probeX * 4 + anchorOffset)
            let anchorByteX = probeX * 4 + anchorOffset // byte column of the anchor

            var found: [(dx: Int, dy: Int)] = []
            var blockVerifies = 0
            let syLo = max(0, anchorRow - r)
            let syHi = min(height - 1, anchorRow + r)
            let xLo = max(0, anchorByteX - r * 4)
            let xHi = min(width * 4, anchorByteX + r * 4 + al)
            outer: for sy in syLo...syHi {
                var cursor = shadowBase.advanced(by: sy * shadowStride + xLo)
                var remaining = xHi - xLo
                var hitsThisRow = 0
                while remaining >= al, hitsThisRow < Self.dragMaxAnchorHitsPerRow,
                      let hit = memmem(cursor, remaining, anchor, al) {
                    hitsThisRow += 1
                    let hitPtr = UnsafeRawPointer(hit)
                    let advance = hitPtr - cursor + 1
                    defer {
                        cursor = cursor.advanced(by: advance)
                        remaining -= advance
                    }
                    let absByteX = hitPtr - shadowBase.advanced(by: sy * shadowStride)
                    let byteDx = absByteX - anchorByteX
                    guard byteDx % 4 == 0 else { continue }
                    let ddx = byteDx / 4
                    let ddy = sy - anchorRow
                    if ddx == 0 && ddy == 0 { continue } // unmoved ≠ a scroll
                    let sx = probeX + ddx
                    let syTop = probeY + ddy
                    guard sx >= 0, sx + ps <= width, syTop >= 0, syTop + ps <= height else { continue }
                    // Sampled check, then the full block, budgeted.
                    var si = 0
                    var match = true
                    sampleLoop: for syy in 0..<sg {
                        for sxx in 0..<sg {
                            if samples[si] != pixel(shadowBase, shadowStride,
                                                    sx + sxx * 8 + 4, syTop + syy * 8 + 4) {
                                match = false
                                break sampleLoop
                            }
                            si += 1
                        }
                    }
                    guard match else { continue }
                    guard blockVerifies < Self.dragMaxBlockVerifies else { break outer }
                    blockVerifies += 1
                    var exact = true
                    for row in 0..<ps {
                        if memcmp(frameBase.advanced(by: (probeY + row) * bytesPerRow + probeX * 4),
                                  shadowBase.advanced(by: ((syTop + row) * width + sx) * 4),
                                  ps * 4) != 0 {
                            exact = false
                            break
                        }
                    }
                    if exact {
                        found.append((ddx, ddy))
                        if found.count >= Self.dragMaxCandidates { break outer }
                    }
                }
            }
            traceDrag("probe (\(probeX),\(probeY)) distinct=\(position.distinct) candidates=\(found)")
            for c in found where !collected.contains(where: { $0.dx == c.dx && $0.dy == c.dy }) {
                collected.append(c)
            }
            if collected.count >= Self.dragMaxCandidates { break }
        }
        collected.sort { abs($0.dx) + abs($0.dy) < abs($1.dx) + abs($1.dy) }
        return collected
    }

    /// Verify one (dx, dy) candidate per qualifying tile — current tile ==
    /// shadow at +(dx, dy), with all corner source tiles ACKed and idle — and
    /// emit the scroll if enough tiles are satisfied. The record-vs-TLV race
    /// is closed after the fact by SCROLL_ACK repair. Returns true iff a
    /// scroll was emitted.
    func verifyAndEmitScroll(dx: Int, dy: Int, qualifyCount: Int, relaxed: Bool = false,
                                     frame: UnsafeRawBufferPointer, bytesPerRow: Int) -> Bool {
        let width = grid.width
        let height = grid.height
        let ts = TileGrid.tileSize
        let shadowBase = shadow.baseAddress!
        let frameBase = frame.baseAddress!
        for i in 0..<scrollSatisfied.count { scrollSatisfied[i] = false }
        func sourceSafe(_ srcIdx: Int) -> Bool {
            ledger.isSettled(srcIdx)
        }
        var satisfiedCount = 0
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        for i in 0..<worklist.count {
            let idx = Int(worklist[i])
            guard scrollQualified[idx] else { continue }
            let (x, y, tw, th) = grid.rect(of: idx)
            let srcX0 = x + dx
            let srcY0 = y + dy
            guard srcX0 >= 0, srcX0 + tw <= width, srcY0 >= 0, srcY0 + th <= height else { continue }
            var cornersSafe = true
            for cy in [srcY0, srcY0 + th - 1] {
                for cx in [srcX0, srcX0 + tw - 1] {
                    if !sourceSafe((cy / ts) * grid.cols + cx / ts) { cornersSafe = false }
                }
            }
            guard cornersSafe else { continue }
            var ok = true
            for row in 0..<th {
                if memcmp(frameBase.advanced(by: (y + row) * bytesPerRow + x * 4),
                          shadowBase.advanced(by: ((srcY0 + row) * width + srcX0) * 4),
                          tw * 4) != 0 {
                    ok = false
                    break
                }
            }
            guard ok else { continue }
            scrollSatisfied[idx] = true
            satisfiedCount += 1
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x + tw); maxY = max(maxY, y + th)
        }
        // 2-D (drag) candidates verify against a mixed-generation shadow under
        // live deferral — only the still-synced fraction can match. The digest
        // check (SCROLL_ACK) makes an over-eager scroll a one-RTT repair, so the
        // relaxed bar trades a rare repair for shipping drags as ops.
        let required = max(scrollMinSatisfied, qualifyCount / (relaxed ? 8 : 4))
        traceDrag("verify (\(dx),\(dy)) satisfied=\(satisfiedCount) required=\(required)")
        guard satisfiedCount >= required else { return false }

        // An active region's tiles show lossy video on the viewer, not the
        // host's shadow. A scroll whose rect — destination, or source at
        // +(dx, dy), which the viewer copies wholesale — overlaps the region
        // can only fail the SCROLL_ACK digest and demote its ENTIRE rect: a
        // guaranteed full-rect repaint one RTT later. Ship tiles instead.
        if regionActive {
            let r = regionPixelRect
            func overlapsRegion(_ x: Int, _ y: Int) -> Bool {
                x < r.x + r.w && r.x < x + (maxX - minX) && y < r.y + r.h && r.y < y + (maxY - minY)
            }
            guard !overlapsRegion(minX, minY), !overlapsRegion(minX + dx, minY + dy) else {
                return false
            }
        }

        emitScroll(dx: dx, dy: dy, rectX: minX, rectY: minY,
                   rectW: maxX - minX, rectH: maxY - minY,
                   satisfiedCount: satisfiedCount, frame: frame, bytesPerRow: bytesPerRow)
        return true
    }



    /// SCROLL_ACK repair: the viewer LWW-skipped `skipped` tiles when
    /// applying scroll `frameSeq` — a newer record had beaten the TLV, so the
    /// viewer's pre-scroll snapshot (and thus every destination that sourced
    /// from those tiles) may not match the host's shifted shadow. Invalidate
    /// those destinations; the hash gate re-verifies and residuals repair.
    func repairAfterScrollAck(frameSeq: UInt32, skipped: [UInt16], digest: UInt64) {
        guard let at = recentScrolls.firstIndex(where: { $0.frameSeq == frameSeq }) else { return }
        let scroll = recentScrolls.remove(at: at)
        let ts = TileGrid.tileSize
        for s in skipped {
            let idx = Int(s)
            guard idx < grid.count else { continue } // INV-6: hostile index
            let (sx, sy, stw, sth) = grid.rect(of: idx)
            // Destinations that read from this source rect live at -(dx, dy).
            for dstRow in [sy - scroll.dy, sy + sth - 1 - scroll.dy]
            where dstRow >= 0 && dstRow < grid.height {
                for dstCol in [sx - scroll.dx, sx + stw - 1 - scroll.dx]
                where dstCol >= 0 && dstCol < grid.width {
                    let dstIdx = (dstRow / ts) * grid.cols + dstCol / ts
                    ledger.markCold(dstIdx)
                    traceTile(dstIdx, "host scrollAck-repair-invalidate (skipped source \(idx), scroll seq=\(frameSeq))")
                }
            }
        }

        // Verified promotion: fold the emit-time mirror marks over
        // rect ∖ skipped (the tiles the viewer wrote) and compare the
        // viewer's digest of what it actually wrote. Mismatch means the two
        // sides computed different results for the same op — possible when
        // the host's source beliefs were mid-heal at emit — so every
        // promotion from this scroll is suspect: demote the whole rect and
        // let the hash gate re-verify (one-RTT heal, cost only bandwidth).
        var skippedSet = Set<Int>()
        for s in skipped { skippedSet.insert(Int(s)) }
        var expected: UInt64 = 0
        let tr0 = scroll.rectY / ts, tr1 = (scroll.rectY + scroll.rectH - 1) / ts
        let tc0 = scroll.rectX / ts, tc1 = (scroll.rectX + scroll.rectW - 1) / ts
        for tr in tr0...tr1 {
            for tc in tc0...tc1 {
                let idx = tr * grid.cols + tc
                guard !skippedSet.contains(idx) else { continue }
                expected ^= scrollDigestMix(tile: idx,
                                            hash: scroll.marks[(tr - tr0) * (tc1 - tc0 + 1) + (tc - tc0)])
            }
        }
        if expected != digest {
            stats.scrollDigestRepairs += 1
            for tr in tr0...tr1 {
                for tc in tc0...tc1 {
                    let idx = tr * grid.cols + tc
                    ledger.markCold(idx)
                    traceTile(idx, "host scrollDigest-demote seq=\(frameSeq)")
                }
            }
        }
    }

    func emitScroll(dx: Int, dy: Int, rectX: Int, rectY: Int, rectW: Int, rectH: Int,
                            satisfiedCount: Int, frame: UnsafeRawBufferPointer, bytesPerRow: Int) {
        let scrollSeq = nextFrameSeq
        nextFrameSeq &+= 1
        if nextFrameSeq == 0 { nextFrameSeq = 1 }
        sendControl(.scroll(frameSeq: scrollSeq,
                            x: UInt16(rectX), y: UInt16(rectY),
                            width: UInt16(rectW), height: UInt16(rectH),
                            dx: Int16(clamping: dx), dy: Int16(clamping: dy)))
        stats.scrollsSent += 1
        stats.scrollSatisfiedTiles += satisfiedCount

        // Mirror the viewer's op on the shadow, using exactly the viewer's
        // skip rules (out-of-canvas sources leave rows untouched) — in place,
        // no snapshot (it was a full-canvas copy per scroll: 59 MB at 5K).
        let width = grid.width
        let height = grid.height
        let x0 = rectX, y0 = rectY, x1 = rectX + rectW, y1 = rectY + rectH
        let ts = TileGrid.tileSize
        let tr0 = y0 / ts, tr1 = (y1 - 1) / ts
        let tc0 = x0 / ts, tc1 = (x1 - 1) / ts
        let markCols = tc1 - tc0 + 1
        var marks = ContiguousArray<UInt64>(repeating: 0, count: (tr1 - tr0 + 1) * markCols)

        // Pass 1 — plan from the PRE-shift state (pass 3 mutates the ledger):
        // a tile's post-scroll content is known iff every source row existed
        // and came from ACKed, idle tiles, and the tile scrolled in full
        // (partial-span tiles keep unscrolled columns — still known if the
        // tile itself was ACKed before).
        @inline(__always) func sourceSafe(_ i: Int) -> Bool {
            ledger.isSettled(i)
        }
        for tr in tr0...tr1 {
            for tc in tc0...tc1 {
                let idx = tr * grid.cols + tc
                let (tx, ty, tw, th) = grid.rect(of: idx)
                let spanX0 = max(tx, x0), spanX1 = min(tx + tw, x1)
                let rowY0 = max(ty, y0), rowY1 = min(ty + th, y1)
                guard spanX0 < spanX1, rowY0 < rowY1 else {
                    scrollPlan[idx] = 0
                    continue
                }
                let srcSpanX0 = spanX0 + dx, srcSpanX1 = spanX1 + dx
                var sourceComplete = srcSpanX0 >= 0 && srcSpanX1 <= width
                if sourceComplete {
                    for row in rowY0..<rowY1 {
                        let srcRow = row + dy
                        guard srcRow >= 0, srcRow < height,
                              sourceSafe((srcRow / ts) * grid.cols + srcSpanX0 / ts),
                              sourceSafe((srcRow / ts) * grid.cols + (srcSpanX1 - 1) / ts) else {
                            sourceComplete = false
                            break
                        }
                    }
                }
                let fullTile = spanX0 == tx && spanX1 == tx + tw && rowY0 == ty && rowY1 == ty + th
                scrollPlan[idx] = sourceComplete && (fullTile || ledger[idx].ackedHash != 0) ? 2 : 1
            }
        }

        // Pass 2 — shift in place. Rows move away from their sources (dy > 0
        // reads below → ascending; dy < 0 → descending), so a source row is
        // always still pre-op when read; within a row (dy == 0) spans go in
        // the direction of dx, and memmove handles the overlap.
        let rowStride = width * 4
        let base = shadow.baseAddress!
        func shiftRow(_ row: Int) {
            let srcRow = row + dy
            guard srcRow >= 0, srcRow < height else { return }
            let tr = row / ts
            for step in 0..<markCols {
                let tc = dx >= 0 ? tc0 + step : tc1 - step
                guard scrollPlan[tr * grid.cols + tc] != 0 else { continue }
                let spanX0 = max(tc * ts, x0), spanX1 = min(tc * ts + ts, x1, width)
                guard spanX0 + dx >= 0, spanX1 + dx <= width else { continue }
                memmove(base.advanced(by: row * rowStride + spanX0 * 4),
                        base.advanced(by: srcRow * rowStride + (spanX0 + dx) * 4),
                        (spanX1 - spanX0) * 4)
            }
        }
        if dy > 0 {
            for row in y0..<y1 { shiftRow(row) }
        } else {
            for row in stride(from: y1 - 1, through: y0, by: -1) { shiftRow(row) }
        }

        // Pass 3 — marks, promotion, in-flight slots.
        for tr in tr0...tr1 {
            for tc in tc0...tc1 {
                let idx = tr * grid.cols + tc
                let plan = scrollPlan[idx]
                guard plan != 0 else { continue }
                scrollPlan[idx] = 0
                let (tx, ty, tw, th) = grid.rect(of: idx)
                // Verified promotion: every rect tile's post-mirror hash goes
                // into the marks (the mirror replicates the viewer's op given
                // identical pre-state, so this is the expected written result
                // whether or not the tile is promoted below).
                let mirrorHash = XXH64.hashRows(
                    frame: UnsafeRawBufferPointer(shadow), bytesPerRow: rowStride,
                    x: tx, y: ty, tw: tw, th: th)
                marks[(tr - tr0) * markCols + (tc - tc0)] = mirrorHash
                if plan == 2 {
                    ledger.setAcked(idx, hash: mirrorHash)
                    traceTile(idx, "host scroll-KNOWN seq=\(scrollSeq) dx=\(dx) dy=\(dy) newAcked=\(String(mirrorHash, radix: 16))")
                } else {
                    ledger.setAcked(idx, hash: 0)
                    traceTile(idx, "host scroll-UNKNOWN seq=\(scrollSeq) dx=\(dx) dy=\(dy)")
                }
                // In-flight sends into the rect are LWW-blocked at the viewer
                // (scrollSeq is newer) — clear the slot so their stale ACKs
                // are ignored and residuals are not skip-if-inflight'ed away.
                ledger.clearInflight(idx)
            }
        }

        recentScrolls.append(RecentScroll(frameSeq: scrollSeq, dx: dx, dy: dy,
                                          rectX: rectX, rectY: rectY,
                                          rectW: rectW, rectH: rectH, marks: marks))
        while recentScrolls.count > Self.recentScrollCap {
            // Never ACKed within the cap: the viewer's result for this rect
            // can't be verified any more — demote it (bandwidth, not truth).
            let evicted = recentScrolls.removeFirst()
            stats.scrollsEvictedUnacked += 1
            for tr in (evicted.rectY / ts)...((evicted.rectY + evicted.rectH - 1) / ts) {
                for tc in (evicted.rectX / ts)...((evicted.rectX + evicted.rectW - 1) / ts) {
                    ledger.markCold(tr * grid.cols + tc)
                }
            }
        }

        // Every rect tile must be (re)considered this tick — static content
        // inside the rect was moved by the scroll and needs restoring.
        var added = false
        for tr in (y0 / ts)...((y1 - 1) / ts) {
            for tc in (x0 / ts)...((x1 - 1) / ts) {
                let idx = tr * grid.cols + tc
                if candidateMark[idx] != candidateEpoch && !inRegion[idx] {
                    candidateMark[idx] = candidateEpoch
                    worklist.append(Int32(idx))
                    added = true
                }
            }
        }
        if added {
            hashCandidates(frame: frame, bytesPerRow: bytesPerRow)
        }
    }
}
