// replay --mode loop: host engine -> seeded faults -> viewer engine over
// virtual time, then the §7 settle and the golden canvas check.
import Foundation
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActWire

func cmdReplayLoop(_ reader: ScapReader, traceName: String, opts: Options) throws {
    var faults = FaultConfig()
    faults.dropPermille = opts.int("drop", 0) * 10
    faults.dupPermille = opts.int("dup", 0) * 10
    faults.reorderPermille = opts.int("reorder", 0) * 10
    faults.seed = UInt64(opts.int("seed", 1))
    if let latency = opts.span("latency") {
        faults.latencyMinUS = UInt64(latency.lo) * 1000
        faults.latencyMaxUS = UInt64(latency.hi) * 1000
    }

    let width = reader.header.width
    let height = reader.header.height
    let link = InProcLink(faults: faults)
    // --link-mbit: one bottleneck for everything the host sends (tile
    // datagrams, video, control), with a deep buffer, as on airline Wi-Fi.
    if opts.has("link-mbit") {
        let rate = opts.int("link-mbit", 2) * 1_000_000 / 8
        let bufferMS = opts.int("link-buffer-ms", 2000)
        link.bottleneck = .init(bytesPerSecond: rate, bufferBytes: rate * bufferMS / 1000)
    }
    // --video mock (deterministic rig codec), vt (hardware HEVC) or av1
    // (libaom, decoded in hardware as the Viewer does, else with libaom) —
    // real codecs are nondeterministic in bytes but still byte-exact at settle.
    let videoMode = opts.string("video") // nil | mock | vt | av1
    var encoderFactory: ((UInt8) -> any VideoRegionEncoder?)?
    var decoderFactory: (() -> any VideoRegionDecoder)?
    var hostCodecs: [UInt8] = []
    var viewerCodecs: [UInt8] = []
    let vtPipeline = BenchVTPipeline()
    if opts.has("max-qp") { vtPipeline.defaultMaxFrameQP = opts.int("max-qp", 34) }
    if opts.has("min-encoder-cap") { vtPipeline.minEncoderCap = opts.int("min-encoder-cap", 2000) * 1000 }
    switch videoMode {
    case nil:
        break
    case "mock":
        encoderFactory = { MockVideoEncoder(codecID: $0) }
        decoderFactory = { MockVideoDecoder() }
        hostCodecs = [MockVideoEncoder.mockCodecID]
        viewerCodecs = [MockVideoEncoder.mockCodecID]
    case "vt":
        encoderFactory = {
            $0 == VideoCodec.hevc ? BenchPipelinedEncoder(VTHEVCRegionEncoder(callbackQueue: .main), vtPipeline) : nil
        }
        decoderFactory = { VTRegionDecoder() }
        hostCodecs = [VideoCodec.hevc]
        viewerCodecs = [VideoCodec.hevc]
    case "av1":
        guard AOMRegionEncoder.isAvailable else { throw BenchError("--video av1 needs Apple silicon (libaom is arm64 only)") }
        encoderFactory = {
            guard $0 == VideoCodec.av1 else { return nil }
            let aom = AOMRegionEncoder(callbackQueue: .main)
            aom.vbr = opts.has("av1-vbr")
            aom.targetPercent = opts.int("av1-target-pct", 40)
            if opts.has("av1-qmax") { aom.quantizerCeiling = opts.int("av1-qmax", 42) }
            return BenchPipelinedEncoder(aom, vtPipeline)
        }
        // The Viewer's path, hardware decode, where this Mac has it.
        decoderFactory = { VTRegionDecoder.canDecodeAV1 ? VTRegionDecoder() as any VideoRegionDecoder : AOMRegionDecoder() }
        hostCodecs = [VideoCodec.av1]
        viewerCodecs = [VideoCodec.av1]
    case "av1-hevc":
        // The product's pair: the Host prefers AV1 and falls back to HEVC on a
        // thin link (AV1LinkPolicy); the Viewer decodes both in hardware.
        guard AOMRegionEncoder.isAvailable, VTRegionDecoder.canDecodeAV1 else {
            throw BenchError("--video av1-hevc needs Apple silicon with hardware AV1 decode")
        }
        encoderFactory = {
            switch $0 {
            case VideoCodec.av1:
                let aom = AOMRegionEncoder(callbackQueue: .main)
                aom.targetPercent = opts.int("av1-target-pct", 40)
                return BenchPipelinedEncoder(aom, vtPipeline)
            case VideoCodec.hevc:
                return BenchPipelinedEncoder(VTHEVCRegionEncoder(callbackQueue: .main), vtPipeline)
            default:
                return nil
            }
        }
        decoderFactory = { VTRegionDecoder() }
        hostCodecs = [VideoCodec.av1, VideoCodec.hevc]
        viewerCodecs = [VideoCodec.av1, VideoCodec.hevc]
    default:
        throw BenchError("--video expects mock, vt, av1 or av1-hevc")
    }
    let host = HostEngine(width: width, height: height, transport: link.a,
                          videoEncoderFactory: encoderFactory,
                          videoCodecPreference: hostCodecs)
    if opts.has("no-handoff") { host.overlayHandoff = false }
    // The resolution rung (§4.9): the app would halve the capture here; the
    // loop only reports when it would have.
    nonisolated(unsafe) var autoScaleUS: UInt64?
    host.onScalePressureConstrained = { if autoScaleUS == nil { autoScaleUS = link.nowUS } }
    if opts.has("no-fresh-queue") { host.freshQueueSignal = false }
    if opts.has("no-link-reports") { host.requestDeliveryReports = false }
    if opts.has("handoff-ms") { host.handoffStillUS = UInt64(opts.int("handoff-ms", 1000)) * 1000 }
    if opts.has("limit-mbit") { host.rateLimit = .megabits(opts.int("limit-mbit", 25)) }
    if opts.has("vp8l-effort") { host.vp8lEffort = Int32(opts.int("vp8l-effort", 4)) }
    if opts.has("keyframe-effort") { host.keyframeEffort = Int32(opts.int("keyframe-effort", 4)) }
    let viewer = ViewerEngine(transport: link.b, videoDecoderFactory: decoderFactory,
                              supportedVideoCodecs: viewerCodecs)
    var viewerFailure: String?
    viewer.onFailed = { reason in
        viewerFailure = reason
        print("  VIEWER FAILED at \(link.nowUS / 1000) ms: \(reason)")
    }
    // CPU time per engine entry point (single-threaded rig: wall ≈ CPU).
    // Section-5 perf work is judged on these (BENCHMARKS.md).
    final class LoopTimings {
        var hostEncode: UInt64 = 0, hostControl: UInt64 = 0, hostTick: UInt64 = 0
        var viewerDatagram: UInt64 = 0, viewerVideo: UInt64 = 0
        var viewerControl: UInt64 = 0, viewerTick: UInt64 = 0
        var encodeSamplesUS: [Double] = []
    }
    let timings = LoopTimings()
    @inline(__always) func timed(_ bucket: inout UInt64, _ body: () -> Void) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        bucket &+= DispatchTime.now().uptimeNanoseconds &- t0
    }
    link.a.onControl = { data in timed(&timings.hostControl) { host.handleControl(data, nowUS: link.nowUS) } }
    link.b.onControl = { data in timed(&timings.viewerControl) { viewer.handleControl(data, nowUS: link.nowUS) } }
    link.b.onDatagram = { data in timed(&timings.viewerDatagram) { viewer.handleDatagram(data, nowUS: link.nowUS) } }
    link.b.onVideo = { data in timed(&timings.viewerVideo) { viewer.handleVideo(data, nowUS: link.nowUS) } }
    // Mock delivers inside encode(); VT delivers later, from its own threads,
    // onto the main queue (this rig's engine queue). Every submitted frame is
    // delivered before virtual time moves on (BenchVTPipeline).
    func drainVTOutput() {
        if videoMode == "vt" || videoMode == "av1" || videoMode == "av1-hevc" { vtPipeline.drain() }
    }

    // Video coverage: how much of the replay's screen-time the viewer
    // presented from lossy video rather than its exact canvas (sampled every
    // 16 ms of virtual time while frames play).
    var coverageSamples = 0, coverageVideoTiles = 0, sampling = false
    var nextCoverageSampleUS: UInt64 = 0
    // Bottleneck queueing delay, sampled every 10 ms of virtual time.
    var backlogSamplesUS: [UInt64] = []
    var nextBacklogSampleUS: UInt64 = 0
    let timeline = opts.has("timeline")
    var nextTimelineUS: UInt64 = 0
    func drive(untilUS: UInt64) {
        var t = link.nowUS
        while t < untilUS {
            t = min(t + 1_000, untilUS)
            link.advance(toUS: t)
            drainVTOutput()
            timed(&timings.viewerTick) { viewer.tick(nowUS: link.nowUS) }
            timed(&timings.hostTick) { host.tick(nowUS: link.nowUS) }
            if timeline && t >= nextTimelineUS {
                nextTimelineUS = t + 1_000_000
                print("  t=\(t / 1_000_000)s video \(viewer.overlayVisibleTileCount) region \(host.activeVideoRegionCount) "
                      + "reveal \(host.stats.overlayHandoffReveals) record \(host.stats.overlayHandoffRecords) "
                      + "tiles \(host.stats.tilesSent) owed \(host.pendingRepaintTiles) open \(host.openBatchCount) "
                      + "formed \(host.stats.videoRegionsFormed) vframes \(host.stats.videoFramesSent) "
                      + "bytes \(host.stats.bytesOut / 1_000_000) MB gov \(host.stats.governorRate / 1000) KB/s "
                      + "duty \(host.stats.encodeDutyPercent)% ackDelay \(host.ackDelayUS / 1000) ms "
                      + "viewer \(viewer.state) acks \(viewer.stats.acksSent) rx \(viewer.stats.datagramsReceived) "
                      + "vrate \(String(format: "%.2f", Double(host.videoRate.rate * 8) / 1e6)) Mbit/s "
                      + "vcap \(host.videoRate.bitrateCap.map { String(format: "%.2f", Double($0) / 1e6) } ?? "none") "
                      + "backoffs \(host.videoRate.backoffs) vskips \(host.stats.videoBacklogSkips) "
                      + "netq \((host.videoNetworkQueueUS ?? 0) / 1000) ms "
                      + "ldeliv \(String(format: "%.2f", Double(host.linkDeliveredBytesPerSecond * 8) / 1e6)) lcap \(String(format: "%.2f", Double(host.linkCapacityBytesPerSecond * 8) / 1e6))")
            }
            if link.bottleneck != nil && t >= nextBacklogSampleUS {
                nextBacklogSampleUS = t + 10_000
                backlogSamplesUS.append(link.bottleneckBacklogUS)
            }
            if sampling && t >= nextCoverageSampleUS {
                nextCoverageSampleUS = t + 16_000
                coverageSamples += 1
                coverageVideoTiles += viewer.overlayVisibleTileCount
            }
        }
    }

    host.start(nowUS: 0)
    drive(untilUS: 300_000)
    guard host.state == .running && viewer.state == .running else { throw BenchError("handshake failed") }

    let frameBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { frameBuf.deallocate() }
    var lastFrame = [UInt8](repeating: 0, count: width * height * 4)
    var rects: [DirtyRect] = []
    var baseTS: UInt64?
    var frames = 0
    let replayStartUS = link.nowUS + 16_000
    sampling = true

    // Time to exact: once the screen stops changing for `stillGapUS`, how
    // long until the viewer shows the host's frame exactly (canvas
    // byte-identical, no video over it). Checked every 50 ms of virtual
    // time inside each still period, until exact.
    let stillGapUS: UInt64 = 500_000
    var exactAfterUS: [UInt64] = []
    var stillPeriods = 0
    func viewerExact() -> Bool {
        guard viewer.overlayVisibleTileCount == 0 else { return false }
        return viewer.withCanvas { canvas in
            lastFrame.withUnsafeBytes { expected in
                canvas.count == expected.count
                    && memcmp(canvas.baseAddress, expected.baseAddress, expected.count) == 0
            }
        } ?? false
    }
    /// Drives to `untilUS`; if the gap from `stillSinceUS` is a still period,
    /// records when the viewer became exact within it.
    func driveStill(since stillSinceUS: UInt64, untilUS: UInt64) {
        guard frames > 0, untilUS > stillSinceUS, untilUS - stillSinceUS >= stillGapUS else {
            drive(untilUS: untilUS)
            return
        }
        stillPeriods += 1
        while link.nowUS < untilUS {
            if viewerExact() {
                exactAfterUS.append(link.nowUS - stillSinceUS)
                break
            }
            drive(untilUS: min(untilUS, link.nowUS + 50_000))
        }
        drive(untilUS: untilUS)
    }
    var lastFeedUS = link.nowUS

    while let meta = try reader.readFrame(rects: &rects, into: frameBuf) {
        let base = baseTS ?? meta.timestampUS
        baseTS = base
        driveStill(since: lastFeedUS, untilUS: replayStartUS + (meta.timestampUS &- base))
        lastFeedUS = link.nowUS
        lastFrame.withUnsafeMutableBytes { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(frameBuf))
        }
        let e0 = DispatchTime.now().uptimeNanoseconds
        host.encodeTick(frame: UnsafeRawBufferPointer(frameBuf), bytesPerRow: width * 4,
                        dirtyRects: rects.isEmpty ? nil : rects,
                        captureTimestampUS: meta.timestampUS, nowUS: link.nowUS)
        let e1 = DispatchTime.now().uptimeNanoseconds
        timings.hostEncode &+= e1 &- e0
        timings.encodeSamplesUS.append(Double(e1 &- e0) / 1000)
        drainVTOutput()
        frames += 1
    }

    sampling = false
    // §7 settle: keep ticking the encoder on the final frame until quiescent.
    var settled = false
    var sinceEncodeMS = 16
    var finalExactUS: UInt64?
    for _ in 0..<(opts.int("settle-s", 60) * 1000) {
        if finalExactUS == nil && frames > 0 && (link.nowUS - lastFeedUS) % 50_000 < 1_000 && viewerExact() {
            finalExactUS = link.nowUS - lastFeedUS
        }
        if sinceEncodeMS >= 16 {
            host.encodeTick(frame: UnsafeRawBufferPointer(frameBuf), bytesPerRow: width * 4,
                            dirtyRects: nil, captureTimestampUS: link.nowUS, nowUS: link.nowUS)
            drainVTOutput()
            sinceEncodeMS = 0
            if host.openBatchCount == 0 && host.stats.lastTickQualifiedTiles == 0
                && host.activeVideoRegionCount == 0 && host.pendingRepaintTiles == 0
                && !host.keyframeInFlight
                && link.pendingDatagramCount == 0 {
                settled = true
                break
            }
        }
        drive(untilUS: link.nowUS + 1_000)
        sinceEncodeMS += 1
    }

    let identical = viewer.withCanvas { canvas in
        lastFrame.withUnsafeBytes { expected in
            canvas.count == expected.count
                && memcmp(canvas.baseAddress, expected.baseAddress, expected.count) == 0
        }
    } ?? false

    if !identical {
        // Divergence forensics: which tiles differ, and what does each side
        // believe about them?
        let grid = TileGrid(width: width, height: height)
        var divergent: [Int] = []
        var tileBuf = [UInt8](repeating: 0, count: 64 * 64 * 4)
        var frameTileBuf = [UInt8](repeating: 0, count: 64 * 64 * 4)
        viewer.withCanvas { canvas in
            lastFrame.withUnsafeBytes { expected in
                for idx in 0..<grid.count {
                    let (x, y, tw, th) = grid.rect(of: idx)
                    let n = tw * th * 4
                    tileBuf.withUnsafeMutableBytes { d in
                        _ = TileOps.extract(src: canvas, bytesPerRow: width * 4, x: x, y: y, tw: tw, th: th, into: d)
                    }
                    frameTileBuf.withUnsafeMutableBytes { d in
                        _ = TileOps.extract(src: expected, bytesPerRow: width * 4, x: x, y: y, tw: tw, th: th, into: d)
                    }
                    if !tileBuf[0..<n].elementsEqual(frameTileBuf[0..<n]) {
                        divergent.append(idx)
                    }
                }
            }
        }
        print("  DIVERGENT TILES: \(divergent.count) of \(grid.count)")
        for idx in divergent.prefix(5) {
            let (x, y, tw, th) = grid.rect(of: idx)
            let n = tw * th * 4
            var canvasHash: UInt64 = 0
            viewer.withCanvas { canvas in
                tileBuf.withUnsafeMutableBytes { d in
                    _ = TileOps.extract(src: canvas, bytesPerRow: width * 4, x: x, y: y, tw: tw, th: th, into: d)
                }
                canvasHash = tileBuf[0..<n].withUnsafeBytes { XXH64.hash($0) }
            }
            let frameHash = lastFrame.withUnsafeBytes { expected -> UInt64 in
                frameTileBuf.withUnsafeMutableBytes { d in
                    _ = TileOps.extract(src: expected, bytesPerRow: width * 4, x: x, y: y, tw: tw, th: th, into: d)
                }
                return frameTileBuf[0..<n].withUnsafeBytes { XXH64.hash($0) }
            }
            let acked = host.ackedHash(forTile: idx)
            let inflight = host.inflight(forTile: idx)
            let shadowHash = host.debugShadowHash(forTile: idx)
            print("    tile \(idx) (\(x),\(y) \(tw)x\(th)): frameHash=\(String(frameHash, radix: 16)) "
                + "canvasHash=\(String(canvasHash, radix: 16)) acked=\(String(acked, radix: 16)) "
                + "shadow=\(String(shadowHash, radix: 16)) "
                + "inflight=\(String(inflight.hash, radix: 16))/\(inflight.seq)")
        }
        print("  viewer: skipped \(viewer.stats.recordsSkipped)  malformed \(viewer.stats.malformedDatagrams)  "
            + "received \(viewer.stats.datagramsReceived)")
    }

    let virtualS = Double(link.nowUS) / 1_000_000
    print("""
    replay (full loop): \(traceName)
      geometry: \(width)x\(height), \(frames) frames, \(String(format: "%.1f", virtualS)) s virtual
      faults: drop \(faults.dropPermille / 10)%  dup \(faults.dupPermille / 10)%  \
    reorder \(faults.reorderPermille / 10)%  latency \(faults.latencyMinUS / 1000)-\(faults.latencyMaxUS / 1000) ms  \
    seed \(faults.seed)
      datagrams: sent \(host.stats.datagramsSent)  dropped \(link.droppedDatagrams)  \
    duplicated \(link.duplicatedDatagrams)  bytes \(formatBytes(host.stats.bytesOut))
      viewer: applied \(viewer.stats.recordsApplied)  stale \(viewer.stats.recordsStale)  \
    acks \(viewer.stats.acksSent)
      video: regions formed \(host.stats.videoRegionsFormed) dissolved \(host.stats.videoRegionsDissolved)  \
    frames \(host.stats.videoFramesSent)  video bytes \(formatBytes(host.stats.videoBytesSent))  \
    viewer applied \(viewer.stats.videoFramesApplied)  undecodable \(viewer.stats.videoDecodeFailures)  \
    sync requests \(viewer.stats.videoSyncRequests) (answered \(host.stats.videoSyncRequestSyncs))  \
    gate skips: backlog \(host.stats.videoBacklogSkips) encoder-full \(host.stats.videoEncoderFullSkips)  \
    link: \(host.linkReports) reports, capacity \(String(format: "%.2f", Double(host.linkCapacityBytesPerSecond * 8) / 1e6)) Mbit/s  \
    regions without AV1 (thin link) \(host.stats.videoRegionsWithoutAV1)  \
    auto-scale \(autoScaleUS.map { String(format: "at %.1f s", Double($0) / 1e6) } ?? "never")  \
    gate at end: rate \(String(format: "%.2f", Double(host.videoRate.rate * 8) / 1e6)) Mbit/s, \
    \(host.videoRate.linkMeasurements) link measurements, \(host.videoRate.backoffs) backoffs, \
    startup cap \(host.videoRate.startupCap.map { String(format: "%.1f Mbit/s", Double($0) / 1e6) } ?? "none")
      video coverage: \(String(format: "%.1f", coverageSamples == 0 ? 0 : 100 * Double(coverageVideoTiles) / Double(coverageSamples * TileGrid(width: width, height: height).count)))% of screen-time on video  \
    handoffs: reveal \(host.stats.overlayHandoffReveals)  record \(host.stats.overlayHandoffRecords)  \
    re-sharpens \(host.stats.videoRefreshes)
      rate: \(opts.has("limit-mbit") ? "limit \(opts.int("limit-mbit", 25)) Mbit/s" : "auto")  \
    governor \(String(format: "%.3f", Double(host.stats.governorRate) / 1e6)) MB/s at end  \
    tiles deferred \(host.stats.governorDeferredTiles)
      settled: \(settled)   canvas byte-identical: \(identical)
    """)
    // What a bandwidth experiment compares: where the bytes went, how deep
    // the bottleneck queued, and how long a still screen took to be exact.
    let videoDeltaBytes = host.stats.videoBytesSent - host.stats.videoSyncBytesSent
    print("  bytes: tiles \(formatBytes(host.stats.tileBytesOut))  video \(formatBytes(videoDeltaBytes))  "
          + "video sync frames \(formatBytes(host.stats.videoSyncBytesSent))  "
          + "striped keyframes \(formatBytes(host.stats.keyframeBytesSent))")
    if let bottleneck = link.bottleneck {
        let sorted = backlogSamplesUS.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        print("  link: \(String(format: "%.1f", Double(bottleneck.bytesPerSecond) * 8 / 1e6)) Mbit/s, "
              + "buffer \(formatBytes(bottleneck.bufferBytes))  queue p95 \(p95 / 1000) ms  "
              + "worst \((sorted.last ?? 0) / 1000) ms  datagrams dropped \(link.bottleneckDroppedDatagrams)")
    }
    let exact = exactAfterUS.sorted()
    let exactP50 = exact.isEmpty ? "-" : "\(exact[exact.count / 2] / 1000) ms"
    let exactMax = exact.isEmpty ? "-" : "\(exact.last! / 1000) ms"
    print("  time to exact: \(exact.count)/\(stillPeriods) still periods exact  p50 \(exactP50)  max \(exactMax)  "
          + "after the last frame \(finalExactUS.map { "\($0 / 1000) ms" } ?? "never")")
    func ms(_ ns: UInt64) -> String { String(format: "%.1f ms", Double(ns) / 1e6) }
    let sortedEnc = timings.encodeSamplesUS.sorted()
    func pct(_ p: Double) -> Double {
        sortedEnc.isEmpty ? 0 : sortedEnc[min(sortedEnc.count - 1, Int(Double(sortedEnc.count) * p))]
    }
    print("""
      cpu host:   encode \(ms(timings.hostEncode)) (p50 \(Int(pct(0.5))) µs, p95 \(Int(pct(0.95))) µs)  \
    control/ACK \(ms(timings.hostControl))  tick \(ms(timings.hostTick))
      cpu viewer: datagrams \(ms(timings.viewerDatagram))  video \(ms(timings.viewerVideo))  \
    control \(ms(timings.viewerControl))  tick \(ms(timings.viewerTick))
    """)
    if videoMode == "vt" || videoMode == "av1" || videoMode == "av1-hevc" {
        print("  \(videoMode!): \(vtPipeline.submits) submits took \(ms(vtPipeline.submitNS)) of host encode  "
              + "waited \(ms(vtPipeline.waitNS)) for output (max \(ms(vtPipeline.maxWaitNS)) at one step)  "
              + "stalls \(vtPipeline.stalls)")
    }
    if opts.has("golden") && !(settled && identical) {
        throw BenchError("golden check FAILED" + (viewerFailure.map { " (viewer failed: \($0))" } ?? ""))
    }
}

/// VideoToolbox in the virtual-time loop. VT encodes on its own threads, and
/// the VideoRegionEncoder contract puts each delivery on the engine's
/// confining queue. Here that is the main thread, which drives the host, the
/// link and the viewer, so deliveries go to the main queue and `drain()` runs
/// them, waiting in real time until every submitted frame is back. Virtual
/// time never advances past an encode still in flight: whatever the CPU
/// load, a frame lands at its submit's virtual instant, as with the mock.
///
/// The loop used to hand VT a private callback queue and sleep 0.5 ms per
/// virtual millisecond. That ran `videoEncoderDelivered` on a second thread,
/// concurrently with the main thread's engine calls and the link's event
/// queue (a data race on both), and let encoder latency under load slide
/// frames arbitrarily far along virtual time.
final class BenchVTPipeline {
    /// `--max-qp`: the frame-QP ceiling (HEVC scale) in place of the
    /// default, for every encoder made after it's set.
    var defaultMaxFrameQP: Int?
    /// `--min-encoder-cap`: the encoder's bitrate cap never goes under this
    /// (bits/s); the send gate still decides what goes.
    var minEncoderCap: Int?
    /// Frames submitted to an encoder and not yet delivered.
    fileprivate(set) var outstanding = 0
    /// Drains that gave up on an encoder that never answered.
    private(set) var stalls = 0
    /// Real time spent waiting for VT.
    private(set) var waitNS: UInt64 = 0
    private(set) var maxWaitNS: UInt64 = 0
    /// Time inside VT's submit (the pixel-buffer copy and EncodeFrame) —
    /// part of the host's encode time.
    fileprivate(set) var submitNS: UInt64 = 0
    fileprivate(set) var submits = 0
    static let stallLimitNS: UInt64 = 5_000_000_000

    func drain() {
        dispatchPrecondition(condition: .onQueue(.main))
        let start = DispatchTime.now().uptimeNanoseconds
        var waited: UInt64 = 0
        repeat {
            // Runs the main queue's pending blocks (VT's deliveries); while
            // frames are outstanding, sleeps until the next one arrives.
            _ = RunLoop.main.run(mode: .default,
                                 before: Date(timeIntervalSinceNow: outstanding > 0 ? 0.01 : 0))
            waited = DispatchTime.now().uptimeNanoseconds &- start
        } while outstanding > 0 && waited < Self.stallLimitNS
        if outstanding > 0 {
            stalls += 1
            outstanding = 0
        }
        waitNS &+= waited
        maxWaitNS = max(maxWaitNS, waited)
    }
}

/// An asynchronous encoder (VideoToolbox HEVC, libaom AV1) delivering to
/// the main queue, counting submits against deliveries for
/// `BenchVTPipeline.drain()`. Both deliver exactly once per submit (an empty
/// frame for a failed encode) until `stop()`.
final class BenchPipelinedEncoder: VideoRegionEncoder {
    private let inner: any VideoRegionEncoder
    private let pipeline: BenchVTPipeline
    private var pending = 0

    init(_ inner: any VideoRegionEncoder, _ pipeline: BenchVTPipeline) {
        self.inner = inner
        self.pipeline = pipeline
        if let qp = pipeline.defaultMaxFrameQP { inner.setMaxFrameQP(qp) }
    }

    var codecID: UInt8 { inner.codecID }

    func start(width: Int, height: Int,
               onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
        inner.start(width: width, height: height) { [weak self] data, sync, config in
            if let self, self.pending > 0 {
                self.pending -= 1
                self.pipeline.outstanding = max(0, self.pipeline.outstanding - 1)
            }
            onFrame(data, sync, config)
        }
    }

    func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
        pending += 1
        pipeline.outstanding += 1
        let t0 = DispatchTime.now().uptimeNanoseconds
        inner.encode(bgra: bgra, forceSync: forceSync, timeUS: timeUS)
        pipeline.submitNS &+= DispatchTime.now().uptimeNanoseconds &- t0
        pipeline.submits += 1
    }

    func setQualityLevel(_ level: Int) { inner.setQualityLevel(level) }
    func setBitrateCap(_ bitsPerSecond: Int?) {
        inner.setBitrateCap(bitsPerSecond.map { max($0, pipeline.minEncoderCap ?? 0) })
    }
    func setMaxFrameQP(_ qp: Int?) { inner.setMaxFrameQP(qp ?? pipeline.defaultMaxFrameQP) }

    /// The stopped encoder drops deliveries still queued.
    func stop() {
        pipeline.outstanding = max(0, pipeline.outstanding - pending)
        pending = 0
        inner.stop()
    }
}
