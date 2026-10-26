import Foundation
import GlassActCodec
import GlassActTransport
import GlassActWire

/// Video (§4.6): pinned full-screen region formation, encoder
/// service, per-tile handoff, quality pressure and dissolve.
/// HostEngine extension: encodeQueue-confined like the engine itself.
extension HostEngine {
    // MARK: - Video regions

    /// Reduced video phase for INV-4-dropped ticks: no hashes exist, so there
    /// is no churn evidence and nothing forms — an active region keeps
    /// streaming (its frames don't ride batches) and can still dissolve.
    func videoSaturatedTick(frame: UnsafeRawBufferPointer, bytesPerRow: Int,
                            dirtyRects: [DirtyRect]?, nowUS: UInt64) {
        videoTickCounter += 1
        guard regionActive else { return }
        serviceRegion(frame: frame, bytesPerRow: bytesPerRow, dirtyRects: dirtyRects, nowUS: nowUS)
        if regionActive && regionQuietTicks >= regionQuietLimit {
            dissolveRegion()
        }
    }

    /// `demandCount`: tiles that wanted to send this tick, admitted or
    /// deferred by the governor. Formation keys on it — gated on admitted
    /// tiles alone, a thin (or just-starting) link's small budget would keep
    /// big motion off video, the cheaper path exactly there.
    func videoPhase(frame: UnsafeRawBufferPointer, bytesPerRow: Int,
                    dirtyRects: [DirtyRect]?, demandCount: Int, nowUS: UInt64) {
        videoTickCounter += 1
        // A 3-tick guard after a dissolve only prevents same-instant thrash.
        // The trigger is CHURN, not qualification: a dissolve repaint's cold
        // tiles qualify for their whole ACK round trip, and any lost to
        // datagram loss re-qualify again on timeout — counting those would
        // re-form the full-screen region from its own repaint on a static
        // screen.
        if !regionActive
            && demandCount >= Self.pinnedFormMinTiles
            && videoTickCounter - lastDissolveTick >= 3
            && churningCandidateCount(atLeast: Self.pinnedFormMinTiles) {
            formRegion(frame: frame, bytesPerRow: bytesPerRow, nowUS: nowUS)
            if regionActive { return }
        }
        noteObservedHashes()
        if regionActive {
            serviceRegion(frame: frame, bytesPerRow: bytesPerRow, dirtyRects: dirtyRects, nowUS: nowUS)
            if regionActive && regionQuietTicks >= regionQuietLimit {
                dissolveRegion()
            }
        }
    }

    /// True when at least `threshold` of this tick's candidates actually
    /// changed since their last observation (and differ from the ACKed
    /// copy). Must run before `noteObservedHashes` refreshes
    /// `lastObservedHash`.
    func churningCandidateCount(atLeast threshold: Int) -> Bool {
        var churning = 0
        for i in 0..<worklist.count {
            let idx = Int(worklist[i])
            let h = hashResults[i]
            if h != lastObservedHash[idx] && h != ledger[idx].ackedHash {
                churning += 1
                if churning >= threshold { return true }
            }
        }
        return false
    }

    /// Records this tick's candidate hashes as the last observation of each
    /// position — the churn baseline for the next formation check.
    func noteObservedHashes() {
        for i in 0..<worklist.count {
            lastObservedHash[Int(worklist[i])] = hashResults[i]
        }
    }

    /// Forms the full-screen region (trimmed to even pixel dimensions —
    /// HEVC 4:2:0 needs them) and submits its first frame as a sync frame.
    func formRegion(frame: UnsafeRawBufferPointer, bytesPerRow: Int, nowUS: UInt64) {
        guard let factory = videoEncoderFactory, !videoStalled else { return }
        let c0 = 0, r0 = 0
        var c1 = grid.cols - 1
        var r1 = grid.rows - 1
        let ts = TileGrid.tileSize
        let x = 0, y = 0
        // Drop edge tiles that would make pixel dims odd (HEVC 4:2:0).
        if (min((c1 + 1) * ts, grid.width) - x) & 1 == 1 { c1 -= 1 }
        if (min((r1 + 1) * ts, grid.height) - y) & 1 == 1 { r1 -= 1 }
        let w = min((c1 + 1) * ts, grid.width) - x
        let h = min((r1 + 1) * ts, grid.height) - y
        guard c1 >= c0, r1 >= r0, w >= ts, h >= ts else { return }
        // Paging anti-thrash: re-forming shortly after a dissolve means the
        // quiet limit undershot the workload's gaps — escalate it so the
        // region survives them (each avoided dissolve saves a lossless
        // repaint); a re-form after a long calm resets the limit.
        regionQuietLimit = videoTickCounter - lastDissolveTick <= Self.videoReformWindowTicks
            ? Self.videoQuietTicksMax : Self.videoQuietTicksLimit
        // Try negotiated codecs in preference order; a codec whose encoder
        // won't start simply yields to the next.
        regionGeneration &+= 1
        let generation = regionGeneration
        var started: (encoder: any VideoRegionEncoder, codec: UInt8)?
        for codec in allowedVideoCodecs {
            guard let encoder = factory(codec) else { continue }
            if encoder.start(width: w, height: h, onFrame: { [weak self] data, sync, config in
                self?.videoEncoderDelivered(generation: generation, data: data, sync: sync, config: config)
            }) {
                started = (encoder, codec)
                break
            }
        }
        guard let (encoder, startedCodec) = started else { return }
        if startedCodec != negotiatedVideoCodecs.first, !linkRoom.hasRoom,
           negotiatedVideoCodecs.first.map(LinkRoomPolicy.governs) == true {
            stats.videoRegionsWithoutAV1 += 1
        }
        regionEncoder = encoder
        if effectiveQualityLevel > 0 { encoder.setQualityLevel(effectiveQualityLevel) } // carry policy+level across form
        encoder.setBitrateCap(videoRate.bitrateCap)
        if let qp = regionMaxFrameQP { encoder.setMaxFrameQP(qp) }
        regionActive = true
        regionTileBox = (c0, r0, c1, r1)
        regionPixelRect = (x, y, w, h)
        regionStartSent = false
        regionFrameSeq = 0
        regionFramesPending = 0
        regionPendingSinceUS = 0
        regionSubmitHead = 0
        regionEmptyDeliveries = 0
        regionQuietTicks = 0
        regionLastChangeUS = nowUS
        syncRequestPending = false // the new generation starts on a sync frame
        resetClaimsInFlight()
        for row in r0...r1 {
            for col in c0...c1 {
                let idx = row * grid.cols + col
                regionTileChangedUS[idx] = nowUS // still only after the first frame has shown
                stillHash[idx] = 0
                recordHandoffUS[idx] = 0
                handoffBackoffUS[idx] = 0
                handoffDue[idx] = false
                videoShown[idx] = false
            }
        }
        for t in claimPendingTiles { claimPending[Int(t)] = false }
        claimPendingTiles.removeAll(keepingCapacity: true)
        regionPixels?.deallocate()
        regionScratch?.deallocate()
        regionPixels = .allocate(byteCount: w * h * 4, alignment: 64)
        regionScratch = .allocate(byteCount: w * h * 4, alignment: 64)
        // Video never touches the viewer's canvas (it is an overlay), so the
        // ACKed belief stays true — late ACKs for pre-formation sends
        // describe the canvas correctly — and dissolve compares against it
        // to repaint only what changed.
        for row in r0...r1 {
            for col in c0...c1 { inRegion[row * grid.cols + col] = true }
        }
        stats.videoRegionsFormed += 1
        onVideoCodecChanged?(startedCodec)
        traceDrag("region form tick=\(videoTickCounter) box=(\(c0),\(r0))-(\(c1),\(r1)) bytesOut=\(stats.bytesOut)")
        extractRegion(frame: frame, bytesPerRow: bytesPerRow, into: regionPixels!)
        refreshQuietSinceUS = 0
        submitRegionFrame(forceSync: true)
    }

    func serviceRegion(frame: UnsafeRawBufferPointer, bytesPerRow: Int,
                               dirtyRects: [DirtyRect]?, nowUS: UInt64) {
        var mayTouch = true
        // Damage from skipped ticks (missedDirty) may lie in the region:
        // without it, the region's last frame goes stale and a dissolve's
        // overlay reveal would trust it.
        let missedDamage = tickMissedDamage || missedScanAll || !missedDirtyTiles.isEmpty
        tickMissedDamage = false
        if let rects = dirtyRects, firstBatchSent, !missedDamage {
            let r = regionPixelRect
            mayTouch = rects.contains { rect in
                rect.width > 0 && rect.height > 0
                    && Int(rect.x) < r.x + r.w && Int(rect.x) + Int(rect.width) > r.x
                    && Int(rect.y) < r.y + r.h && Int(rect.y) + Int(rect.height) > r.y
            }
        }
        var changedTiles = 0
        if mayTouch, let scratch = regionScratch, let current = regionPixels {
            // Extraction doubles as the change probe: comparing against the
            // last region frame keeps quiescence detection independent of
            // dirty rect quality (and of the excluded tiles' hash pipeline),
            // and says per tile what changed (claims, handoff).
            extractRegion(frame: frame, bytesPerRow: bytesPerRow, into: scratch)
            changedTiles = diffRegionTiles(new: scratch, old: current, nowUS: nowUS)
            if changedTiles > 0 {
                regionPixels = scratch
                regionScratch = current
            }
        }
        let changed = changedTiles > 0
        // Re-sharpen bookkeeping: how much of the region this update touched
        // (dirty rects; unknown counts as all of it).
        let regionArea = regionPixelRect.w * regionPixelRect.h
        if changed || missedDamage {
            let damage = dirtyRects.map { regionDamagePixels($0) } ?? regionArea
            if damage * Self.refreshSmallUpdateDivisor >= regionArea {
                refreshDamagePixels += damage
                refreshQuietSinceUS = 0
            } else if refreshQuietSinceUS == 0 {
                refreshQuietSinceUS = nowUS
            }
        } else if refreshQuietSinceUS == 0 {
            refreshQuietSinceUS = nowUS
        }
        let refresh = refreshDue(nowUS: nowUS, regionArea: regionArea)
        // The viewer's decoder is waiting for a sync frame: send one now,
        // changed or not (a static region's next frame might be far off).
        let forced = refresh || syncRequestDue
        if changed {
            // A full-screen region must not live on typing. A frame
            // that touches fewer tiles than would FORM a region (caret
            // blink, keystrokes, a spinner) still ships — the change shows
            // now — but counts as quiet, so the region dissolves and the
            // lossless tile path (a few KB/s for typing vs ~0.5 Mbps of
            // HEVC) takes over. Otherwise a blinking caret alone keeps a
            // full-screen region up for a whole session.
            let lowActivity = changedTiles < Self.pinnedFormMinTiles
            if lowActivity {
                regionQuietTicks += 1
            } else {
                regionQuietTicks = 0
                regionLastChangeUS = nowUS
            }
            if submitRegionFrame(forceSync: forced) && refresh { stats.videoRefreshes += 1 }
        } else {
            regionQuietTicks += 1
            if forced && submitRegionFrame(forceSync: true) && refresh { stats.videoRefreshes += 1 }
        }
        handOffStillTiles(nowUS: nowUS)
    }

    /// Region tiles that have been still for `handoffStillUS` and still show
    /// video go back to their exact canvas copy: REVEAL (on the ordered
    /// video stream, after every frame that claimed them) when the canvas
    /// already holds this content, else a lossless record through the tile
    /// path (`handoffDue`), which wins at the viewer by being newer than
    /// the claim.
    func handOffStillTiles(nowUS: UInt64) {
        guard handoffActive, regionStartSent, let pixels = regionPixels else { return }
        let r = regionPixelRect
        let (c0, r0, c1, r1) = regionTileBox
        var reveal: [UInt8] = []
        var revealed = 0
        // Hashing is the cost here (16 KB a tile): only tiles that could be
        // revealed are hashed, and at most `handoffHashesPerTick` a tick —
        // after a drag thousands go still at once, and one tick hashing them
        // all is a visible encode spike. The rest wait a tick or two.
        var hashBudget = Self.handoffHashesPerTick
        // Records only while something keeps the region alive (a real
        // change within the last second): a region whose motion stopped is
        // about to dissolve, and its dissolve repaints the same tiles for
        // about half the bytes (photos' final settle: 9 MB vs 20 MB).
        let recordsAllowed = refreshQuietSinceUS != 0 && nowUS &- refreshQuietSinceUS >= Self.handoffRecordQuietUS
            && nowUS &- regionLastChangeUS < Self.handoffRecordActiveUS
        for row in r0...r1 {
            for col in c0...c1 {
                let idx = row * grid.cols + col
                guard videoShown[idx], nowUS &- regionTileChangedUS[idx] >= handoffStillUS else { continue }
                let t = ledger[idx]
                guard t.inflightSeq == 0 else { continue } // its confirmation decides
                if t.ackedHash != 0 && stillHash[idx] == 0 {
                    guard hashBudget > 0 else { continue }
                    hashBudget -= 1
                    let (x, y, tw, th) = grid.rect(of: idx)
                    stillHash[idx] = XXH64.hashRows(frame: UnsafeRawBufferPointer(pixels), bytesPerRow: r.w * 4,
                                                    x: x - r.x, y: y - r.y, tw: tw, th: th)
                }
                if t.ackedHash != 0 && t.ackedHash == stillHash[idx] {
                    // Free: the canvas already holds it — no backoff.
                    if reveal.isEmpty { reveal = [UInt8](repeating: 0, count: (grid.count + 7) / 8) }
                    reveal[idx >> 3] |= 1 << UInt8(idx & 7)
                    videoShown[idx] = false
                    handoffDue[idx] = false
                    revealed += 1
                } else if recordsAllowed && !handoffDue[idx],
                          nowUS &- regionTileChangedUS[idx] >= max(handoffStillUS, handoffBackoffUS[idx]) {
                    handoffDue[idx] = true
                    ledger.scheduleRepaint(idx)
                }
            }
        }
        if revealed > 0, sendVideoMessage(.reveal(region: 0, generation: regionGeneration, tiles: reveal)) {
            stats.overlayHandoffReveals += revealed
        }
    }

    /// A lossless copy of `idx` sent in batch `seq` was confirmed: if it is
    /// at least as new as the frame that last claimed the tile, the viewer
    /// now shows that exact copy (LWW: records win ties with video).
    func noteExactCopyConfirmed(_ idx: Int, seq: UInt32) {
        guard idx < videoShown.count else { return }
        if videoShown[idx] && !Serial.newer(videoClaimSeq[idx], than: seq) {
            videoShown[idx] = false
            recordHandoffUS[idx] = max(lastEncodeNowUS, 1)
            stats.overlayHandoffRecords += 1
        }
        handoffDue[idx] = false // still owed? the next handoff pass re-decides
    }

    /// A re-sharpening keyframe is owed: the region has been quiet for a
    /// while after large changes (or the budget has grown well past the one
    /// the last keyframe was coded under), and the last keyframe wasn't
    /// recent.
    func refreshDue(nowUS: UInt64, regionArea: Int) -> Bool {
        guard regionStartSent, refreshQuietSinceUS != 0,
              nowUS &- refreshQuietSinceUS >= Self.refreshQuietUS,
              nowUS &- lastRegionSyncUS >= Self.refreshMinIntervalUS,
              // Only while something still keeps the region alive (the
              // handoff's own test). Once nothing has, the region is
              // counting down to its dissolve, whose lossless repaint makes
              // it exact anyway: a keyframe then is a full-screen burst
              // for a second or two of sharper video.
              nowUS &- regionLastChangeUS < Self.handoffRecordActiveUS else { return false }
        let damaged = refreshDamagePixels * Self.refreshDamageDivisor >= max(1, regionArea)
        let cap = videoRate.bitrateCap ?? Int.max
        let budgetGrew = capAtLastSync > 0 && cap / Self.refreshCapGrowth >= capAtLastSync
        return damaged || budgetGrew
    }

    /// SYNC_REQUEST (§3.5), viewer → host: the viewer's decoder for
    /// (region, generation) can't decode and waits for a sync frame. Only the
    /// live region's current generation counts — a stale request (the
    /// region dissolved or re-formed, and a new generation starts on a sync
    /// frame anyway) or one before START is ignored. It is only noted here:
    /// the next serviced tick answers it, no closer than
    /// `syncRequestMinIntervalUS` to the previous answer.
    func noteSyncRequest(region: UInt8, generation: UInt32) {
        guard state == .running, regionActive, regionStartSent,
              region == 0, generation == regionGeneration else {
            stats.videoSyncRequestsIgnored += 1
            return
        }
        stats.videoSyncRequests += 1
        syncRequestPending = true
    }

    /// A SYNC_REQUEST is owed and the rate limit allows answering it now.
    var syncRequestDue: Bool {
        syncRequestPending
            && (lastRequestedSyncUS == 0
                || lastEncodeNowUS &- lastRequestedSyncUS >= Self.syncRequestMinIntervalUS)
    }

    /// Answering a SYNC_REQUEST: the viewer dropped every frame since its
    /// decoder broke, claims included, so a tile the host believes shows
    /// video may show stale overlay pixels — or its old canvas copy —
    /// there. The sync frame claims all of those again (tiles already back
    /// on their exact canvas copy stay there).
    func reclaimShownTiles() {
        let (c0, r0, c1, r1) = regionTileBox
        for row in r0...r1 {
            for col in c0...c1 {
                let idx = row * grid.cols + col
                guard videoShown[idx], !claimPending[idx] else { continue }
                claimPending[idx] = true
                claimPendingTiles.append(Int32(idx))
            }
        }
    }

    /// Pixels of `rects` inside the region (overlaps may count twice).
    func regionDamagePixels(_ rects: [DirtyRect]) -> Int {
        let r = regionPixelRect
        var total = 0
        for rect in rects {
            let x0 = max(Int(rect.x), r.x), x1 = min(Int(rect.x) + Int(rect.width), r.x + r.w)
            let y0 = max(Int(rect.y), r.y), y1 = min(Int(rect.y) + Int(rect.height), r.y + r.h)
            if x1 > x0 && y1 > y0 { total += (x1 - x0) * (y1 - y0) }
        }
        return total
    }

    /// Counts the region tiles whose pixels differ between region frames
    /// `new` and `old` (tight, region-sized); with handoff on, each one is
    /// stamped changed now and queued to be claimed by the next frame.
    /// Whole rows are compared first and only a differing row is split into
    /// tile segments — about one whole-frame compare while a small area
    /// animates, instead of a call per tile row.
    func diffRegionTiles(new: UnsafeMutableRawBufferPointer, old: UnsafeMutableRawBufferPointer,
                         nowUS: UInt64) -> Int {
        let r = regionPixelRect
        let (c0, r0, c1, r1) = regionTileBox
        let stride = r.w * 4
        let ts = TileGrid.tileSize
        var count = 0
        for row in r0...r1 {
            let bandTop = max(row * ts, r.y), bandBottom = min((row + 1) * ts, r.y + r.h)
            var marked = 0
            let cols = c1 - c0 + 1
            for i in 0..<cols { diffBandScratch[i] = false }
            for y in bandTop..<bandBottom where marked < cols {
                let rowOff = (y - r.y) * stride
                guard memcmp(new.baseAddress! + rowOff, old.baseAddress! + rowOff, stride) != 0 else { continue }
                for i in 0..<cols where !diffBandScratch[i] {
                    let x0 = max((c0 + i) * ts, r.x), x1 = min((c0 + i + 1) * ts, r.x + r.w)
                    let off = rowOff + (x0 - r.x) * 4
                    if memcmp(new.baseAddress! + off, old.baseAddress! + off, (x1 - x0) * 4) != 0 {
                        diffBandScratch[i] = true
                        marked += 1
                    }
                }
            }
            guard marked > 0 else { continue }
            count += marked
            guard handoffActive else { continue }
            for i in 0..<cols where diffBandScratch[i] {
                let idx = row * grid.cols + c0 + i
                regionTileChangedUS[idx] = nowUS
                stillHash[idx] = 0
                handoffDue[idx] = false
                if !claimPending[idx] {
                    claimPending[idx] = true
                    claimPendingTiles.append(Int32(idx))
                }
            }
        }
        return count
    }

    /// The frame just handed to the encoder carries the pending claims.
    func takePendingClaims() {
        var buffer = claimBufferPool.popLast() ?? ContiguousArray<Int32>()
        buffer.removeAll(keepingCapacity: true)
        for t in claimPendingTiles {
            claimPending[Int(t)] = false
            buffer.append(t)
        }
        claimPendingTiles.removeAll(keepingCapacity: true)
        claimsInFlight.append(buffer)
    }

    /// Claims of a frame that never made it (dropped encode): they ride the
    /// next one.
    func returnClaims(_ buffer: ContiguousArray<Int32>) {
        for t in buffer where !claimPending[Int(t)] {
            claimPending[Int(t)] = true
            claimPendingTiles.append(t)
        }
        recycleClaims(buffer)
    }

    func recycleClaims(_ buffer: ContiguousArray<Int32>) {
        if claimBufferPool.count < 8 { claimBufferPool.append(buffer) }
    }

    /// A new generation (formation): its first frame claims
    /// everything, so queued claims are moot — and frames of the old
    /// generation still in the encoder are dropped by the generation guard
    /// before they would consume an entry.
    func resetClaimsInFlight() {
        while let buffer = claimsInFlight.popLast() { recycleClaims(buffer) }
    }

    /// `claimed` (grid tile indices) as region-relative runs.
    func claimRuns(_ claimed: ContiguousArray<Int32>) -> [VideoClaims.TileRun] {
        let (c0, r0, c1, _) = regionTileBox
        let cols = c1 - c0 + 1
        var rel = claimed.map { t -> UInt32 in
            let idx = Int(t)
            return UInt32((idx / grid.cols - r0) * cols + (idx % grid.cols - c0))
        }
        rel.sort()
        var runs: [VideoClaims.TileRun] = []
        for v in rel {
            if let last = runs.last, last.start + last.count == v {
                runs[runs.count - 1].count += 1
            } else if runs.last.map({ $0.start + $0.count > v }) != true {
                runs.append(.init(start: v, count: 1))
            }
        }
        return runs
    }

    /// Newest-wins pacing (the video-path INV-4): a frame is submitted only
    /// when the encoder pipeline and the transport backlog have room; a
    /// skipped frame is simply superseded by the next changed capture.
    /// Transport-backlog skips with the encoder keeping up are bandwidth
    /// pressure for the quality ladder; pipeline-full skips are CPU, which a
    /// cheaper bitrate would not help. True when the frame went to the
    /// encoder.
    @discardableResult
    func submitRegionFrame(forceSync: Bool) -> Bool {
        guard let encoder = regionEncoder, let pixels = regionPixels else { return false }
        // Time, not bytes: the allowance is ~60 ms at the measured drain
        // rate (VideoRateController). A byte limit (512 KB) would be 1.6 s of
        // lag at the 2.5 Mbps a remote Wi-Fi link carries.
        let backlog = transport.videoBacklogBytes
        if videoRate.observe(nowUS: lastEncodeNowUS, backlogBytes: backlog, networkQueueUS: videoSmoothedQueueUS,
                             freshQueueUS: freshQueueSignal ? videoPingQueueUS : nil,
                             linkCapacity: linkCapacityBytesPerSecond) {
            regionEncoder?.setBitrateCap(videoRate.bitrateCap)
        }
        let encoderFull = regionFramesPending >= Self.videoMaxPendingFrames
        guard videoRate.allowsFrame(backlogBytes: backlog) else {
            stats.videoBacklogSkips += 1
            // Bandwidth pressure: backlog is full. If the encoder is NOT also
            // full, this is the NETWORK, not the CPU → step quality down
            // (cheaper bytes). If the encoder IS full too, it's CPU pressure,
            // which newest-wins skipping already absorbs.
            notePressure(bandwidth: true, cpu: encoderFull)
            evaluateQualityPressure()
            return false
        }
        // Queueing, not distance: a 250 ms path with an empty queue is not
        // pressure. Transports without an RTT view fall back to PING SRTT.
        let queued = videoNetworkQueueUS.map { $0 > Self.videoQualityQueueUS } ?? (srttUS > Self.videoQualitySrttUS)
        notePressure(bandwidth: queued, cpu: encoderFull)
        evaluateQualityPressure()
        guard !encoderFull else {
            stats.videoEncoderFullSkips += 1
            return false
        }
        regionSubmitUS[(regionSubmitHead + regionFramesPending) % Self.videoMaxPendingFrames] = clock?() ?? 0
        if regionFramesPending == 0 { regionPendingSinceUS = max(lastEncodeNowUS, 1) }
        regionFramesPending += 1
        if stats.videoFramesSent == 0 && firstVideoSubmitUS == 0 {
            firstVideoSubmitUS = clock?() ?? lastEncodeNowUS
        }
        let answersRequest = forceSync && syncRequestPending
        if handoffActive {
            if answersRequest { reclaimShownTiles() }
            takePendingClaims()
        }
        encoder.encode(bgra: UnsafeRawBufferPointer(pixels), forceSync: forceSync, timeUS: lastEncodeNowUS)
        if forceSync {
            // A keyframe re-codes everything at today's budget.
            refreshDamagePixels = 0
            lastRegionSyncUS = lastEncodeNowUS
            capAtLastSync = videoRate.bitrateCap ?? Int.max
        }
        if answersRequest {
            // Any sync frame answers the request (a re-sharpen included);
            // the next answer waits out the minimum interval from this one.
            syncRequestPending = false
            lastRequestedSyncUS = max(lastEncodeNowUS, 1)
            stats.videoSyncRequestSyncs += 1
        }
        return true
    }

    static let videoQualitySrttUS: UInt64 = 45_000 // SRTT above this = video queuing (no transport RTT)
    static let videoQualityQueueUS: UInt64 = 45_000 // standing network queue above this = pressure

    /// Standing queue in the network: transport smoothed − minimum RTT.
    var videoSmoothedQueueUS: UInt64? {
        transport.transportRTT.map { $0.smoothedUS > $0.minUS ? $0.smoothedUS - $0.minUS : 0 }
    }

    /// The latest PING's round trip over the best one (nil without a PONG in
    /// the last 2 s). A smoothed RTT only moves when ACKs come back: once
    /// video is cut to its floor there are few, and a second of queue reads
    /// as present for ~20 s after it drained. The PING, once a second, is
    /// fresh — but one reading, which can land between bursts.
    var videoPingQueueUS: UInt64? {
        guard pingRTTAtUS != 0, lastEncodeNowUS &- pingRTTAtUS < 2_000_000 else { return nil }
        return pingRTTLatestUS &- pingRTTMinUS
    }

    /// The smaller of the two: is a queue standing now?
    public var videoNetworkQueueUS: UInt64? {
        guard let smoothed = videoSmoothedQueueUS else { return nil }
        guard freshQueueSignal, let ping = videoPingQueueUS else { return smoothed }
        return min(smoothed, ping)
    }

    func notePressure(bandwidth: Bool, cpu: Bool) {
        qualityWindowAttempts += 1
        if bandwidth && !cpu { qualityWindowPressure += 1 } // network, not CPU
    }

    /// Bandwidth-driven quality ladder. A window with sustained network
    /// pressure lowers quality one step; sustained health recovers a step.
    func evaluateQualityPressure() {
        guard qualityWindowAttempts >= Self.videoQualityWindow else { return }
        let pressured = qualityWindowPressure * 3 >= qualityWindowAttempts // ≥ 1/3 of the window
        qualityWindowAttempts = 0
        qualityWindowPressure = 0
        let before = effectiveQualityLevel
        updateSharpCeiling(pressured: pressured)
        if pressured {
            qualityHealthyStreak = 0
            // preferSharpness: don't degrade quality on bandwidth pressure —
            // let the backlog governor drop framerate (frames skip newest-wins)
            // while quality stays high.
            if !policyPreferSharpness && qualityLevel < Self.maxQualityLevel {
                qualityLevel += 1
            }
        } else {
            qualityHealthyStreak += 1
            if qualityHealthyStreak >= Self.videoQualityHealthyWindows && qualityLevel > 0 {
                qualityHealthyStreak = 0
                qualityLevel -= 1
            }
        }
        let after = effectiveQualityLevel
        if after != before {
            regionEncoder?.setQualityLevel(after)
            if after > before { stats.qualityDowngrades += 1 } else { stats.qualityUpgrades += 1 }
        }
    }

    /// Prefer sharpness (§4.6): the sharper frame-QP ceiling goes on after
    /// `sharpHealthyNeeded` pressure-free windows in a row and comes off at
    /// the first pressured one. Each fall-back doubles the healthy run the
    /// next try needs (up to `sharpHealthyWindowsMax`), so a link that
    /// can't carry it settles at the default instead of flapping.
    func updateSharpCeiling(pressured: Bool) {
        guard policyPreferSharpness else { return }
        if pressured {
            sharpHealthyStreak = 0
            guard sharpCeiling else { return }
            sharpCeiling = false
            sharpHealthyNeeded = min(sharpHealthyNeeded * 2, Self.sharpHealthyWindowsMax)
            stats.sharpCeilingOff += 1
            regionEncoder?.setMaxFrameQP(nil)
        } else {
            sharpHealthyStreak += 1
            guard !sharpCeiling, sharpHealthyStreak >= sharpHealthyNeeded else { return }
            sharpCeiling = true
            stats.sharpCeilingOn += 1
            regionEncoder?.setMaxFrameQP(Self.sharpMaxFrameQP)
        }
    }

    /// The frame-QP ceiling the viewer's preference puts in force; nil = the
    /// encoder's default.
    var regionMaxFrameQP: Int? {
        sharpCeiling ? Self.sharpMaxFrameQP : smoothFloor ? Self.smoothMaxFrameQP : nil
    }

    /// Prefer smooth motion (§4.6): the looser ceiling while the link has no
    /// room, the default once it has. Follows `linkRoom`, a property of the
    /// link, so the looser frames can't switch it off themselves.
    func updateSmoothFloor() {
        let want = policyPreferSmoothness && !linkRoom.hasRoom
        guard want != smoothFloor else { return }
        smoothFloor = want
        if want { stats.smoothFloorOn += 1 } else { stats.smoothFloorOff += 1 }
        regionEncoder?.setMaxFrameQP(regionMaxFrameQP)
    }

    /// Effective level fed to the encoder: at least the presented-scale floor,
    /// at most the client's quality-floor cap.
    var effectiveQualityLevel: Int {
        min(max(qualityLevel, policyScaleLevel), policyMaxLevel)
    }

    /// Apply a client QUALITY policy (§3.5 TLV): presented scale, quality
    /// floor, sharpness-vs-smoothness — bounds on the automatic loop.
    func applyQualityPolicy(scalePct: Int, floor: UInt8, preferSharpness: Bool, preferSmoothness: Bool = false) {
        policyScaleLevel = scalePct == 0 ? 0
            : scalePct >= 88 ? 0 : scalePct >= 62 ? 1 : scalePct >= 38 ? 2 : 3
        // QualityFloor n (1–3) caps the loop at level n; automatic doesn't.
        policyMaxLevel = floor == QualityFloor.automatic ? Self.maxQualityLevel
            : min(Self.maxQualityLevel, Int(floor))
        policyPreferSharpness = preferSharpness
        if !preferSharpness && sharpCeiling {
            sharpCeiling = false
            regionEncoder?.setMaxFrameQP(nil)
        }
        if !preferSharpness { sharpHealthyStreak = 0; sharpHealthyNeeded = Self.sharpHealthyWindowsMin }
        policyPreferSmoothness = preferSmoothness && !preferSharpness
        updateSmoothFloor()
        regionEncoder?.setQualityLevel(effectiveQualityLevel)
    }

    /// Encoder output, on the engine queue (see VideoRegionEncoder contract).
    /// The generation guard drops async stragglers from a dissolved session.
    func videoEncoderDelivered(generation: UInt32, data: [UInt8], sync: Bool, config: [UInt8]?) {
        guard regionActive, generation == regionGeneration else { return }
        if regionFramesPending > 0 {
            regionFramesPending -= 1
            if let clock {
                stats.videoEncodeUSSum &+= clock() &- regionSubmitUS[regionSubmitHead]
                stats.videoEncodeCount += 1
            }
            regionSubmitHead = (regionSubmitHead + 1) % Self.videoMaxPendingFrames
            regionPendingSinceUS = regionFramesPending == 0 ? 0 : max(lastEncodeNowUS, 1)
        }
        // This delivery's claims (one entry per submit, in order).
        let claimed: ContiguousArray<Int32>? = handoffActive && !claimsInFlight.isEmpty
            ? claimsInFlight.removeFirst() : nil
        // An empty delivery is a failed or dropped encode (the contract's
        // one-delivery-per-submit pacing). Never put it on the wire; a
        // sustained run means the encoder is broken (e.g. a VT session
        // invalidated by sleep/wake) and the region would freeze for as long
        // as motion lasts — dissolve (lossless repaint) and let a fresh
        // encoder re-form it.
        guard !data.isEmpty else {
            if let claimed { returnClaims(claimed) }
            regionEmptyDeliveries += 1
            if regionEmptyDeliveries >= Self.videoMaxEmptyDeliveries {
                stats.videoEncoderFailures += 1
                dissolveRegion()
            }
            return
        }
        regionEmptyDeliveries = 0
        // A generation's first frame claims every tile; later ones, what changed.
        let claimAll = !regionStartSent
        if !regionStartSent {
            guard let config, let encoder = regionEncoder else { return }
            let r = regionPixelRect
            guard sendVideoMessage(.start(region: 0, generation: regionGeneration,
                                          x: UInt16(r.x), y: UInt16(r.y),
                                          width: UInt16(r.w), height: UInt16(r.h),
                                          codec: encoder.codecID, config: config)) else {
                dissolveRegion()
                return
            }
            regionStartSent = true
        }
        // The LWW stamp: any record sent from now on carries a seq ≥ this, so
        // a dissolve repaint (strictly later tick → strictly newer seq) beats
        // this frame at the viewer even if the channels cross in flight.
        regionFrameSeq = nextFrameSeq
        var claims = VideoClaims.all
        if handoffActive {
            let (c0, r0, c1, r1) = regionTileBox
            if claimAll {
                for row in r0...r1 {
                    for col in c0...c1 { claimTile(row * grid.cols + col, stamp: regionFrameSeq) }
                }
            } else if let claimed {
                claims = .runs(claimRuns(claimed))
                for t in claimed { claimTile(Int(t), stamp: regionFrameSeq) }
            } else {
                claims = .runs([])
            }
        }
        if let claimed { recycleClaims(claimed) }
        guard sendVideoMessage(.frame(region: 0, generation: regionGeneration,
                                      seq: regionFrameSeq, sync: sync,
                                      captureUS: currentCaptureUS, claims: claims, data: data)) else {
            // A frame too big for the wire can't be skipped either: every
            // later frame predicts from it. Fall back to lossless tiles.
            dissolveRegion()
            return
        }
        stats.videoFramesSent += 1
        noteUpdateSent(nowUS: clock?() ?? lastEncodeNowUS)
        if sync { stats.videoSyncBytesSent += data.count }
        if stats.videoFramesSent == 1, let onFirstVideoFrame {
            let now = clock?() ?? lastEncodeNowUS
            onFirstVideoFrame(data.count, sync, now > firstVideoSubmitUS ? now - firstVideoSubmitUS : 0)
        }
    }

    /// The negotiated codecs this link allows, in preference order: AV1 only
    /// while `linkRoom` says there's room. Never empty while any is negotiated.
    /// Read when a region forms, so a change waits for the next one: switching
    /// a live region costs a whole-screen sync frame on the new encoder,
    /// mid-motion (6 Mbit/s photos: 68 frames against HEVC's 165; BENCHMARKS
    /// "AV1 only while the link has room").
    var allowedVideoCodecs: [UInt8] {
        guard !linkRoom.hasRoom else { return negotiatedVideoCodecs }
        let others = negotiatedVideoCodecs.filter { !LinkRoomPolicy.governs($0) }
        return others.isEmpty ? negotiatedVideoCodecs : others
    }

    /// A frame in the encoder longer than this means the encoder stopped
    /// answering (a hardware encode takes ~15 ms; libaom at 5K under 50).
    static let videoEncoderStallUS: UInt64 = 3_000_000

    /// The encoder stopped answering: give video up for this session and let
    /// lossless tiles carry the screen. Live (2026-10-26) the system's
    /// encoder service went silent for minutes right after a virtual display
    /// came up; with VideoToolbox's calls off the engine's queue the session
    /// keeps running, and this keeps it from waiting on frames that never
    /// come (`VTHEVCRegionEncoder`'s concurrency note).
    func checkEncoderStall(nowUS: UInt64) {
        guard regionActive, regionFramesPending > 0, regionPendingSinceUS != 0,
              nowUS &- regionPendingSinceUS > Self.videoEncoderStallUS else { return }
        videoStalled = true
        stats.videoEncoderStalls += 1
        onVideoEncoderStalled?()
        dissolveRegion(revealUnchanged: false)
    }

    /// `revealUnchanged: false` repaints the whole region — for a lost video
    /// stream, where the STOP carrying the reveal bitmap may never arrive
    /// and only newer records are sure to clear the overlay.
    func dissolveRegion(revealUnchanged: Bool = true) {
        guard regionActive else { return }
        let (c0, r0, c1, r1) = regionTileBox
        // The viewer's canvas under the video still holds each
        // tile's ACKed content. A tile whose current content (the last
        // region frame) equals it is revealed for free; every other tile
        // gets a fresh send, stamped newer than all video — which is what
        // drops the overlay there. Only changed tiles cost bytes.
        let reveal = revealUnchanged && regionStartSent && regionPixels != nil
        var revealBits = reveal ? [UInt8](repeating: 0, count: (grid.count + 7) / 8) : []
        var revealed = 0
        if regionStartSent {
            if reveal, let pixels = regionPixels {
                let r = regionPixelRect
                for row in r0...r1 {
                    for col in c0...c1 {
                        let idx = row * grid.cols + col
                        let t = ledger[idx]
                        guard t.ackedHash != 0, t.inflightSeq == 0 else { continue }
                        let (x, y, tw, th) = grid.rect(of: idx)
                        let h = XXH64.hashRows(frame: UnsafeRawBufferPointer(pixels), bytesPerRow: r.w * 4,
                                               x: x - r.x, y: y - r.y, tw: tw, th: th)
                        if h == t.ackedHash {
                            revealBits[idx >> 3] |= 1 << UInt8(idx & 7)
                            revealed += 1
                        }
                    }
                }
            }
            sendVideoMessage(.stop(region: 0, generation: regionGeneration, reveal: revealBits))
        }
        stats.overlayTilesRevealed += revealed
        regionEncoder?.stop()
        regionEncoder = nil
        regionActive = false
        syncRequestPending = false
        resetClaimsInFlight()
        for t in claimPendingTiles { claimPending[Int(t)] = false }
        claimPendingTiles.removeAll(keepingCapacity: true)
        for row in r0...r1 {
            for col in c0...c1 {
                let idx = row * grid.cols + col
                inRegion[idx] = false
                videoShown[idx] = false
                handoffDue[idx] = false
                if reveal {
                    if revealBits[idx >> 3] & (1 << UInt8(idx & 7)) == 0 {
                        // Changed under the video. A pre-formation send
                        // still in flight carries an older seq than the
                        // video and can't clear the overlay: go cold for a
                        // fresh absolute send. Otherwise keep the ACKed
                        // base (the canvas holds it exactly — DELTA-able)
                        // and just volunteer the tile.
                        if ledger[idx].inflightSeq != 0 {
                            ledger.clearInflight(idx)
                            ledger.markCold(idx)
                        } else {
                            ledger.scheduleRepaint(idx)
                        }
                    }
                    continue
                }
                // Cold state: forces the lossless repaint (and marks the tile
                // scroll-unsafe until re-ACKed). The pending-repaint mask
                // volunteers it even on a static screen.
                ledger.forget(idx)
                ledger.scheduleRepaint(idx)
            }
        }
        lastDissolveTick = videoTickCounter
        qualityLevel = 0
        qualityWindowAttempts = 0
        qualityWindowPressure = 0
        qualityHealthyStreak = 0
        traceDrag("region dissolve tick=\(videoTickCounter) quietLimit=\(regionQuietLimit) bytesOut=\(stats.bytesOut)")
        stats.videoRegionsDissolved += 1
        onVideoCodecChanged?(nil)
    }

    /// The viewer will show video on `idx` from the frame stamped `stamp`.
    @inline(__always)
    func claimTile(_ idx: Int, stamp: UInt32) {
        if recordHandoffUS[idx] != 0 {
            if lastEncodeNowUS &- recordHandoffUS[idx] < Self.handoffRechurnWindowUS {
                handoffBackoffUS[idx] = min(Self.handoffMaxBackoffUS, max(handoffStillUS, handoffBackoffUS[idx]) * 2)
            }
            recordHandoffUS[idx] = 0
        }
        videoShown[idx] = true
        videoClaimSeq[idx] = stamp
        handoffDue[idx] = false
    }

    /// False when the message exceeds the video family's body bound (the
    /// viewer would tear the stream down) — nothing is sent.
    @discardableResult
    func sendVideoMessage(_ message: VideoMessage) -> Bool {
        guard let bytes = message.encodedForSend() else {
            return false
        }
        stats.videoBytesSent += bytes.count
        stats.bytesOut += bytes.count
        videoRate.noteHanded(bytes.count)
        transport.sendVideo(Data(bytes))
        return true
    }

    func extractRegion(frame: UnsafeRawBufferPointer, bytesPerRow: Int,
                               into buf: UnsafeMutableRawBufferPointer) {
        let r = regionPixelRect
        let rowBytes = r.w * 4
        for row in 0..<r.h {
            let src = frame.baseAddress!.advanced(by: (r.y + row) * bytesPerRow + r.x * 4)
            buf.baseAddress!.advanced(by: row * rowBytes).copyMemory(from: src, byteCount: rowBytes)
        }
    }
}
