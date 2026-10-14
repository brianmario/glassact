import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// SCROLL control op + host scroll pipeline (§4.8).
@Suite struct ScrollTests {
    private func scrollTLV(seq: UInt32, x: Int, y: Int, w: Int, h: Int, dy: Int) -> Data {
        Data(ControlMessage.scroll(frameSeq: seq, x: UInt16(x), y: UInt16(y),
                                   width: UInt16(w), height: UInt16(h),
                                   dx: 0, dy: Int16(dy)).encoded())
    }

    /// The op itself: content shifts by +dy (destination reads source below),
    /// out-of-canvas sources leave rows untouched.
    @Test func viewerScrollShiftsContent() {
        let (viewer, _) = makeRunningViewer(width: 64, height: 192) // 3 stacked tiles
        var rng = SplitMix64(seed: 5)
        let a = rng.bytes(64 * 64 * 4)
        let b = rng.bytes(64 * 64 * 4)
        let c = rng.bytes(64 * 64 * 4)
        viewer.handleDatagram(makeDatagram(seq: 1, records: [(0, a)]), nowUS: 0)
        viewer.handleDatagram(makeDatagram(seq: 2, records: [(1, b)]), nowUS: 0)
        viewer.handleDatagram(makeDatagram(seq: 3, records: [(2, c)]), nowUS: 0)
        // Scroll the whole canvas up by one tile: dst row r reads r+64.
        viewer.handleControl(scrollTLV(seq: 4, x: 0, y: 0, w: 64, h: 192, dy: 64), nowUS: 0)
        #expect(viewer.stats.scrollsApplied == 1)
        #expect(canvasTile(viewer, 0) == b)
        #expect(canvasTile(viewer, 1) == c)
        #expect(canvasTile(viewer, 2) == c) // source out of canvas: rows untouched
    }

    /// The scroll op is defined against the PRE-op canvas: every destination
    /// pixel takes the pre-op content at +(dx, dy); LWW-newer tiles are left
    /// alone (and still serve as pre-op sources); out-of-canvas sources leave
    /// rows untouched. Randomized against a reference that snapshots — any
    /// in-place implementation must match it exactly, for every direction
    /// (including 2-D drags and same-row pans).
    @Test func scrollMatchesSnapshotSemanticsRandomized() {
        var rng = SplitMix64(seed: 1401)
        let width = 320, height = 256
        let grid = TileGrid(width: width, height: height)
        for trial in 0..<200 {
            let (viewer, _) = makeRunningViewer(width: width, height: height)
            for idx in 0..<grid.count {
                let (_, _, tw, th) = grid.rect(of: idx)
                viewer.handleDatagram(makeDatagram(seq: UInt32(1 + idx), records: [(UInt16(idx), rng.bytes(tw * th * 4))]),
                                      nowUS: 0)
            }
            var newer = Set<Int>()
            for idx in 0..<grid.count where rng.int(0..<5) == 0 { // LWW-newer than the scroll
                let (_, _, tw, th) = grid.rect(of: idx)
                viewer.handleDatagram(makeDatagram(seq: 1000, records: [(UInt16(idx), rng.bytes(tw * th * 4))]),
                                      nowUS: 0)
                newer.insert(idx)
            }
            let before: [UInt8] = viewer.withCanvas { [UInt8]($0) } ?? []
            let rx = rng.int(0..<width - 1), ry = rng.int(0..<height - 1)
            let rw = rng.int(1..<(width - rx + 1)), rh = rng.int(1..<(height - ry + 1))
            let dirs = [-1, 0, 1]
            let dx = dirs[rng.int(0..<3)] * rng.int(1..<130)
            let dy = dirs[rng.int(0..<3)] * rng.int(1..<130)
            viewer.handleControl(Data(ControlMessage.scroll(
                frameSeq: 500, x: UInt16(rx), y: UInt16(ry), width: UInt16(rw), height: UInt16(rh),
                dx: Int16(dx), dy: Int16(dy)).encoded()), nowUS: 0)

            var expected = before
            let x1 = rx + rw, y1 = ry + rh
            for idx in 0..<grid.count where !newer.contains(idx) {
                let (tx, ty, tw, th) = grid.rect(of: idx)
                let sx0 = max(tx, rx), sx1 = min(tx + tw, x1)
                let ry0 = max(ty, ry), ry1 = min(ty + th, y1)
                guard sx0 < sx1, ry0 < ry1 else { continue }
                for row in ry0..<ry1 {
                    let srcRow = row + dy
                    guard srcRow >= 0, srcRow < height, sx0 + dx >= 0, sx1 + dx <= width else { continue }
                    for x in sx0..<sx1 {
                        for c in 0..<4 {
                            expected[(row * width + x) * 4 + c] = before[(srcRow * width + x + dx) * 4 + c]
                        }
                    }
                }
            }
            let after: [UInt8] = viewer.withCanvas { [UInt8]($0) } ?? []
            #expect(after == expected, "trial \(trial): rect (\(rx),\(ry)) \(rw)×\(rh) d=(\(dx),\(dy))")
            if after != expected { break }
        }
    }

    /// LWW commutativity: a residual record (newer seq) and the scroll op must
    /// converge to the same canvas in either arrival order.
    @Test func scrollAndResidualCommute() {
        var rng = SplitMix64(seed: 6)
        let base = rng.bytes(64 * 64 * 4)
        let mid = rng.bytes(64 * 64 * 4)
        let residual = rng.bytes(64 * 64 * 4)

        func run(residualFirst: Bool) -> [[UInt8]?] {
            let (viewer, _) = makeRunningViewer(width: 64, height: 128) // 2 tiles
            viewer.handleDatagram(makeDatagram(seq: 1, records: [(0, base)]), nowUS: 0)
            viewer.handleDatagram(makeDatagram(seq: 2, records: [(1, mid)]), nowUS: 0)
            let scroll = { viewer.handleControl(self.scrollTLV(seq: 3, x: 0, y: 0, w: 64, h: 128, dy: 64), nowUS: 0) }
            let record = { viewer.handleDatagram(makeDatagram(seq: 4, records: [(0, residual)]), nowUS: 0) }
            if residualFirst { record(); scroll() } else { scroll(); record() }
            return [canvasTile(viewer, 0), canvasTile(viewer, 1)]
        }
        let orderA = run(residualFirst: false)
        let orderB = run(residualFirst: true)
        #expect(orderA == orderB)
        #expect(orderA[0] == residual) // newer record wins over the scroll
        #expect(orderA[1] == mid)      // tile 1's source (out of canvas) untouched
    }

    /// Stale records from before the scroll must be LWW-blocked afterwards.
    @Test func scrollBlocksOlderRecords() {
        var rng = SplitMix64(seed: 7)
        let a = rng.bytes(64 * 64 * 4)
        let b = rng.bytes(64 * 64 * 4)
        let stale = rng.bytes(64 * 64 * 4)
        let (viewer, _) = makeRunningViewer(width: 64, height: 128)
        viewer.handleDatagram(makeDatagram(seq: 5, records: [(0, a)]), nowUS: 0)
        viewer.handleDatagram(makeDatagram(seq: 6, records: [(1, b)]), nowUS: 0)
        viewer.handleControl(scrollTLV(seq: 7, x: 0, y: 0, w: 64, h: 128, dy: 64), nowUS: 0)
        viewer.handleDatagram(makeDatagram(seq: 4, records: [(0, stale)]), nowUS: 0) // in-flight straggler
        #expect(canvasTile(viewer, 0) == b) // scroll result stands; stale blocked
        #expect(viewer.stats.recordsStale == 1)
    }

    /// Host emits a SCROLL when a heavy tick is explained by a global dy of
    /// ACKed content, and residuals cover the revealed rows — never before
    /// content is ACKed (INV-3).
    @Test func hostEmitsScrollAgainstAckedShadowOnly() {
        var rng = SplitMix64(seed: 8)
        let width = 640, height = 640 // 10×10 tiles
        let (host, capture) = makeRunningHost(width: width, height: height)
        var frame = TestFrame(width: width, height: height)
        frame.fillRandom(&rng)

        // Tick 1: cold start. No scroll possible (nothing ACKed).
        frame.encode(host: host, nowUS: 10_000)
        #expect(host.stats.scrollsSent == 0)
        for ack in fullAcks(for: capture.sentDatagrams) {
            host.handleControl(ack, nowUS: 20_000)
        }

        // Scroll the frame content up by 128 px, fill revealed bottom rows.
        let shifted = frame.bytes
        let rowBytes = width * 4
        frame.bytes.withUnsafeMutableBytes { dst in
            shifted.withUnsafeBytes { src in
                dst.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: 128 * rowBytes),
                                            byteCount: (height - 128) * rowBytes)
            }
        }
        frame.fillRect(x: 0, y: height - 128, w: width, h: 128, &rng)

        let sentBefore = capture.sentDatagrams.count
        frame.encode(host: host, nowUS: 30_000)
        #expect(host.stats.scrollsSent == 1)
        let scrolls = controlMessages(capture.sentControl).filter {
            if case .scroll = $0 { return true } else { return false }
        }
        guard case let .scroll(_, _, _, _, _, dx, dy)? = scrolls.first else {
            Issue.record("expected SCROLL TLV")
            return
        }
        #expect(dx == 0 && dy == 128)
        // Residuals: only the revealed strip (plus any partial-source tiles),
        // far fewer than a full re-send of the 90 moved tiles.
        let residualTiles = decodeTilePayloads(Array(capture.sentDatagrams[sentBefore...])).count
        #expect(residualTiles > 0 && residualTiles <= 30, "residuals \(residualTiles) — scroll should satisfy most tiles")
    }

    /// The decisive test: a continuously scrolling synthetic workload through
    /// the faulted full loop stays byte-exact, with scrolls actually used.
    @Test(arguments: [UInt64(11), 12])
    func scrollingGoldenUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = seed

        let harness = Harness(width: 320, height: 320, faults: faults)
        var rng = SplitMix64(seed: seed &* 77)
        harness.frame.fillRandom(&rng)
        harness.encodeFrame()
        harness.run(untilUS: harness.now + 500_000) // let cold start fully ACK

        let rowBytes = harness.frame.width * 4
        for _ in 0..<25 {
            let dy = [32, 64, 96][rng.int(0..<3)]
            let keep = (harness.frame.height - dy) * rowBytes
            let snapshot = harness.frame.bytes
            harness.frame.bytes.withUnsafeMutableBytes { dst in
                snapshot.withUnsafeBytes { src in
                    dst.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: dy * rowBytes),
                                                byteCount: keep)
                }
            }
            harness.frame.fillRect(x: 0, y: harness.frame.height - dy,
                                   w: harness.frame.width, h: dy, &rng)
            if rng.int(0..<3) == 0 { // occasional non-scroll edit on top
                _ = harness.mutateRandomRects(&rng, count: 1)
            }
            harness.encodeFrame()
            harness.run(untilUS: harness.now + 33_000)
        }
        #expect(harness.settle(), "failed to settle")
        #expect(harness.canvasMatchesFrame(), "scrolling golden diverged (seed \(seed))")
        // Engagement is not asserted here: at 25 tiles, steady 5% loss keeps
        // enough tiles un-ACKed that signature voting starves (a small-grid
        // artifact — the spans cover every column). Engagement is asserted
        // below at low loss, and on the real 5K trace via glassact-bench.
    }

    /// Scroll must actually engage and pay off when the link is healthy.
    @Test func scrollingEngagesAndSavesBytes() {
        var faults = FaultConfig()
        faults.latencyMinUS = 2_000
        faults.latencyMaxUS = 8_000
        faults.seed = 3
        let harness = Harness(width: 320, height: 320, faults: faults)
        var rng = SplitMix64(seed: 44)
        harness.frame.fillRandom(&rng)
        harness.encodeFrame()
        harness.run(untilUS: harness.now + 300_000)

        let rowBytes = harness.frame.width * 4
        let bytesAfterCold = harness.host.stats.bytesOut
        for _ in 0..<20 {
            let dy = 64
            let keep = (harness.frame.height - dy) * rowBytes
            let snapshot = harness.frame.bytes
            harness.frame.bytes.withUnsafeMutableBytes { dst in
                snapshot.withUnsafeBytes { src in
                    dst.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: dy * rowBytes),
                                                byteCount: keep)
                }
            }
            harness.frame.fillRect(x: 0, y: harness.frame.height - dy,
                                   w: harness.frame.width, h: dy, &rng)
            harness.encodeFrame()
            harness.run(untilUS: harness.now + 40_000)
        }
        #expect(harness.settle())
        #expect(harness.canvasMatchesFrame())
        #expect(harness.host.stats.scrollsSent >= 10, "scrolls sent: \(harness.host.stats.scrollsSent)")
        #expect(harness.viewer.stats.scrollsApplied >= 10)
        #expect(harness.host.stats.scrollSatisfiedTiles >= 200)
        // 20 full-frame scrolls of a 25-tile canvas would be ~20×25 RAW tiles
        // without SCROLL; with it, only the revealed strip (5 tiles/frame) ships.
        let scrollPhaseBytes = harness.host.stats.bytesOut - bytesAfterCold
        #expect(scrollPhaseBytes < 20 * 12 * 17_000,
                "scroll phase shipped \(scrollPhaseBytes) B — expected far below full re-sends")
    }

    /// Verified promotion: a SCROLL_ACK whose digest does not match
    /// the host's emit-time mirror marks demotes every rect tile, and the
    /// hash gate re-ships them. Scroll promotion is checked, never trusted.
    @Test func scrollDigestMismatchDemotesRect() {
        var rng = SplitMix64(seed: 1301)
        let width = 640, height = 640
        let (host, capture) = makeRunningHost(width: width, height: height)
        var frame = TestFrame(width: width, height: height)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        for ack in fullAcks(for: capture.sentDatagrams) { host.handleControl(ack, nowUS: 20_000) }

        // Scroll up 128 px; residuals + scroll; ack everything → stable.
        let rowBytes = width * 4
        let shifted = frame.bytes
        frame.bytes.withUnsafeMutableBytes { dst in
            shifted.withUnsafeBytes { src in
                dst.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: 128 * rowBytes),
                                            byteCount: (height - 128) * rowBytes)
            }
        }
        frame.fillRect(x: 0, y: height - 128, w: width, h: 128, &rng)
        let preScroll = capture.sentDatagrams.count
        frame.encode(host: host, nowUS: 30_000)
        #expect(host.stats.scrollsSent == 1)
        for ack in fullAcks(for: Array(capture.sentDatagrams[preScroll...])) {
            host.handleControl(ack, nowUS: 40_000)
        }
        guard case let .scroll(scrollSeq, _, _, _, _, _, _)? = controlMessages(capture.sentControl)
            .first(where: { if case .scroll = $0 { return true } else { return false } }) else {
            Issue.record("expected SCROLL TLV")
            return
        }

        // Baseline: fully acked, same frame → nothing re-ships.
        let baseline = capture.sentDatagrams.count
        frame.encode(host: host, nowUS: 50_000)
        #expect(capture.sentDatagrams.count == baseline, "stable frame must be silent")

        // A digest that cannot match → the whole rect demotes and re-ships.
        let bad = Data(ControlMessage.scrollAck(frameSeq: scrollSeq, skipped: [],
                                               digest: 0xBAD_C0DE).encoded())
        host.handleControl(bad, nowUS: 60_000)
        #expect(host.stats.scrollDigestRepairs == 1)
        // Count raw records (cache REFs included — demoted content the host
        // already stored re-ships as tiny references, not payloads). The
        // governor paces the re-ship across ticks, so drive several
        // paced ticks and ACK as we go.
        var reshipped = Set<UInt16>()
        var now: UInt64 = 70_000
        for _ in 0..<20 {
            let mark = capture.sentDatagrams.count
            frame.encode(host: host, nowUS: now)
            for d in capture.sentDatagrams[mark...] {
                _ = d.withUnsafeBytes { raw in
                    Datagram.parse(raw) { _, rec in
                        if rec.fragIdx == 0 { reshipped.insert(rec.tileIdx) }
                    }
                }
            }
            for ack in fullAcks(for: Array(capture.sentDatagrams[mark...])) {
                host.handleControl(ack, nowUS: now + 1_000)
            }
            now += 100_000
        }
        #expect(reshipped.count >= 60, "digest mismatch must demote the rect (re-shipped \(reshipped.count))")
    }

    /// Scrolls `count` times (128 px up, fresh bottom band), ACKing every
    /// datagram but withholding SCROLL_ACKs; returns the scroll seqs.
    private func scrollRepeatedly(_ host: HostEngine, _ capture: CaptureTransport,
                                  _ frame: inout TestFrame, _ rng: inout SplitMix64,
                                  count: Int, now: inout UInt64) -> [UInt32] {
        let rowBytes = frame.width * 4
        for _ in 0..<count {
            let shifted = frame.bytes
            let height = frame.height
            frame.bytes.withUnsafeMutableBytes { dst in
                shifted.withUnsafeBytes { src in
                    dst.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: 128 * rowBytes),
                                                byteCount: (height - 128) * rowBytes)
                }
            }
            frame.fillRect(x: 0, y: height - 128, w: frame.width, h: 128, &rng)
            let mark = capture.sentDatagrams.count
            frame.encode(host: host, nowUS: now)
            for ack in fullAcks(for: Array(capture.sentDatagrams[mark...])) {
                host.handleControl(ack, nowUS: now + 1_000)
            }
            now += 16_000
        }
        return controlMessages(capture.sentControl).compactMap {
            if case let .scroll(seq, _, _, _, _, _, _) = $0 { return seq } else { return nil }
        }
    }

    /// A SCROLL_ACK for a scroll older than the 8 most recent must still
    /// be verified — the old fixed 8-entry ring dropped it silently.
    @Test func scrollAckForOlderScrollStillRepairs() {
        var rng = SplitMix64(seed: 1302)
        let (host, capture) = makeRunningHost(width: 640, height: 640)
        var frame = TestFrame(width: 640, height: 640)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        for ack in fullAcks(for: capture.sentDatagrams) { host.handleControl(ack, nowUS: 20_000) }
        var now: UInt64 = 30_000
        let seqs = scrollRepeatedly(host, capture, &frame, &rng, count: 10, now: &now)
        #expect(seqs.count == 10, "precondition: every step must ship a scroll")
        guard let first = seqs.first else { return }
        let bad = Data(ControlMessage.scrollAck(frameSeq: first, skipped: [], digest: 0xBAD_C0DE).encoded())
        host.handleControl(bad, nowUS: now)
        #expect(host.stats.scrollDigestRepairs == 1, "the oldest scroll's ACK must still be verified")
    }

    /// A scroll never ACKed within the cap can't be verified any more: its
    /// rect is demoted (and scheduled) instead of silently trusted.
    @Test func unackedScrollEvictionDemotesRect() {
        var rng = SplitMix64(seed: 1303)
        let (host, capture) = makeRunningHost(width: 640, height: 640)
        var frame = TestFrame(width: 640, height: 640)
        frame.fillRandom(&rng)
        frame.encode(host: host, nowUS: 10_000)
        for ack in fullAcks(for: capture.sentDatagrams) { host.handleControl(ack, nowUS: 20_000) }
        var now: UInt64 = 30_000
        let seqs = scrollRepeatedly(host, capture, &frame, &rng,
                                    count: HostEngine.recentScrollCap + 1, now: &now)
        #expect(seqs.count == HostEngine.recentScrollCap + 1, "precondition: every step must ship a scroll")
        #expect(host.stats.scrollsEvictedUnacked == 1)
        #expect(host.pendingRepaintTiles > 0, "the evicted scroll's rect must be scheduled")
    }

    /// Window-scoped scroll: a sub-rect of the screen scrolls while
    /// the rest stays put; the detector must find it and ship one op.
    @Test func windowScopedScrollShipsOneOp() {
        var rng = SplitMix64(seed: 1101)
        let h = Harness(width: 640, height: 640) // 10×10 tiles
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 400_000)
        #expect(h.settle())

        // "Terminal window" = x 128..512, y 64..576. Scroll its content up
        // by 64 px; everything outside stays identical.
        let winX = 128, winY = 64, winW = 384, winH = 512
        let dy = 64
        var next = h.frame.bytes
        for row in winY..<(winY + winH - dy) {
            for col in winX..<(winX + winW) {
                let dstO = (row * 640 + col) * 4
                let srcO = ((row + dy) * 640 + col) * 4
                for b in 0..<4 { next[dstO + b] = h.frame.bytes[srcO + b] }
            }
        }
        for row in (winY + winH - dy)..<(winY + winH) { // fresh revealed rows
            for col in winX..<(winX + winW) {
                let o = (row * 640 + col) * 4
                next[o] = UInt8(truncatingIfNeeded: rng.next())
                next[o + 1] = 0x33; next[o + 2] = 0x66; next[o + 3] = 0xFF
            }
        }
        h.frame.bytes = next
        let scrollsBefore = h.host.stats.scrollsSent
        let bytesBefore = h.host.stats.bytesOut
        h.encodeFrame(dirtyRects: [DirtyRect(x: winX, y: winY, width: winW, height: winH)])
        h.run(untilUS: h.now + 300_000)
        #expect(h.host.stats.scrollsSent == scrollsBefore + 1, "window scroll must ship as one op")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "window scroll must converge byte-exactly")
        #expect(h.host.stats.scrollDigestRepairs == 0, "an honest viewer digest must verify")
        let cost = h.host.stats.bytesOut - bytesBefore
        #expect(cost < 500_000, "one window scroll should cost far less than re-encoding it (got \(cost))")
    }

    /// Horizontal scroll (dx): sideways pan of a wide region.
    @Test func horizontalScrollShipsOneOp() {
        var rng = SplitMix64(seed: 1102)
        let h = Harness(width: 640, height: 640)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 400_000)
        #expect(h.settle())

        let dx = 64 // content moves left by 64: dest(x) = prev(x + 64)
        var next = h.frame.bytes
        for row in 0..<640 {
            for col in 0..<(640 - dx) {
                let dstO = (row * 640 + col) * 4
                let srcO = (row * 640 + col + dx) * 4
                for b in 0..<4 { next[dstO + b] = h.frame.bytes[srcO + b] }
            }
            for col in (640 - dx)..<640 {
                let o = (row * 640 + col) * 4
                next[o] = 0x11; next[o + 1] = UInt8(truncatingIfNeeded: rng.next())
                next[o + 2] = 0x99; next[o + 3] = 0xFF
            }
        }
        h.frame.bytes = next
        let scrollsBefore = h.host.stats.scrollsSent
        h.encodeFrame()
        h.run(untilUS: h.now + 300_000)
        #expect(h.host.stats.scrollsSent == scrollsBefore + 1, "horizontal pan must ship as one op")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "dx scroll must converge byte-exactly")
    }

    /// Window-scroll faulted golden: repeated window scrolls. Two regimes per seed:
    /// realistic faults (engagement asserted — shadow coherence holds) and
    /// brutal jitter (convergence only: generational shadow skew may
    /// legitimately starve the *detector*, but never correctness).
    @Test(arguments: [UInt64(81), 82])
    func windowScrollGoldenUnderFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 10       // realistic: 1 % loss
        faults.dupPermille = 5
        faults.reorderPermille = 50
        faults.latencyMinUS = 5_000    // LAN-ish RTT
        faults.latencyMaxUS = 15_000
        faults.seed = seed
        var rng = SplitMix64(seed: seed &* 1117)
        let h = Harness(width: 640, height: 640, faults: faults)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 600_000)
        #expect(h.settle(maxSimMS: 120_000), "seed \(seed): cold start must converge first")

        let winX = 64, winY = 128, winW = 448, winH = 384
        for _ in 0..<12 { // repeated one-tile window scrolls, like a terminal
            var next = h.frame.bytes
            for row in winY..<(winY + winH - 64) {
                let dstO = (row * 640 + winX) * 4
                let srcO = ((row + 64) * 640 + winX) * 4
                next.replaceSubrange(dstO..<(dstO + winW * 4),
                                     with: h.frame.bytes[srcO..<(srcO + winW * 4)])
            }
            for row in (winY + winH - 64)..<(winY + winH) {
                for col in winX..<(winX + winW) {
                    let o = (row * 640 + col) * 4
                    next[o] = UInt8(truncatingIfNeeded: rng.next())
                    next[o + 1] = 0x44; next[o + 2] = 0x88; next[o + 3] = 0xFF
                }
            }
            h.frame.bytes = next
            h.encodeFrame(dirtyRects: [DirtyRect(x: winX, y: winY, width: winW, height: winH)])
            h.run(untilUS: h.now + 150_000) // ACKs land between line-scrolls (sources quiesce)
        }
        #expect(h.host.stats.scrollsSent > 0, "seed \(seed): window scrolls must engage")
        #expect(h.viewer.stats.cacheRefMisses == 0, "seed \(seed): REF misses are structurally impossible now")
        #expect(h.settle(maxSimMS: 120_000), "seed \(seed)")
        #expect(h.canvasMatchesFrame(), "seed \(seed): byte-exact after window scrolls under faults")
    }

    /// Brutal-jitter regime: the detector may starve (generationally skewed
    /// shadow rows match nothing) — correctness must not care.
    @Test(arguments: [UInt64(83), 84])
    func windowScrollBrutalFaultsConvergesRegardless(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.dupPermille = 10
        faults.reorderPermille = 100
        faults.latencyMinUS = 20_000
        faults.latencyMaxUS = 80_000
        faults.seed = seed
        var rng = SplitMix64(seed: seed &* 1123)
        let h = Harness(width: 640, height: 640, faults: faults)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 600_000)
        let winX = 64, winY = 128, winW = 448, winH = 384
        for _ in 0..<12 {
            var next = h.frame.bytes
            for row in winY..<(winY + winH - 64) {
                let dstO = (row * 640 + winX) * 4
                let srcO = ((row + 64) * 640 + winX) * 4
                next.replaceSubrange(dstO..<(dstO + winW * 4),
                                     with: h.frame.bytes[srcO..<(srcO + winW * 4)])
            }
            for row in (winY + winH - 64)..<(winY + winH) {
                for col in winX..<(winX + winW) {
                    let o = (row * 640 + col) * 4
                    next[o] = UInt8(truncatingIfNeeded: rng.next())
                    next[o + 1] = 0x44; next[o + 2] = 0x88; next[o + 3] = 0xFF
                }
            }
            h.frame.bytes = next
            h.encodeFrame(dirtyRects: [DirtyRect(x: winX, y: winY, width: winW, height: winH)])
            h.run(untilUS: h.now + 60_000)
        }
        #expect(h.settle(maxSimMS: 120_000), "seed \(seed)")
        #expect(h.canvasMatchesFrame(), "seed \(seed): exact even when the detector starves")
        #expect(h.viewer.stats.cacheRefMisses == 0, "seed \(seed)")
    }
}
