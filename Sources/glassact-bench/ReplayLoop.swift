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
    // --video mock (deterministic rig codec) or vt (hardware HEVC) —
    // real codecs are nondeterministic in bytes but still byte-exact at settle.
    let videoMode = opts.string("video") // nil | mock | vt
    var encoderFactory: ((UInt8) -> any VideoRegionEncoder?)?
    var decoderFactory: (() -> any VideoRegionDecoder)?
    var hostCodecs: [UInt8] = []
    var viewerCodecs: [UInt8] = []
    let vtQueue = DispatchQueue(label: "bench.vt.callback")
    switch videoMode {
    case nil:
        break
    case "mock":
        encoderFactory = { MockVideoEncoder(codecID: $0) }
        decoderFactory = { MockVideoDecoder() }
        hostCodecs = [MockVideoEncoder.mockCodecID]
        viewerCodecs = [MockVideoEncoder.mockCodecID]
    case "vt":
        encoderFactory = { $0 == VideoCodec.hevc ? VTHEVCRegionEncoder(callbackQueue: vtQueue) : nil }
        decoderFactory = { VTRegionDecoder() }
        hostCodecs = [VideoCodec.hevc]
        viewerCodecs = [VideoCodec.hevc]
    default:
        throw BenchError("--video expects mock or vt")
    }
    let host = HostEngine(width: width, height: height, transport: link.a,
                          videoEncoderFactory: encoderFactory,
                          videoCodecPreference: hostCodecs)
    if opts.has("no-handoff") { host.overlayHandoff = false }
    if opts.has("handoff-ms") { host.handoffStillUS = UInt64(opts.int("handoff-ms", 1000)) * 1000 }
    if opts.has("limit-mbit") { host.rateLimit = .megabits(opts.int("limit-mbit", 25)) }
    if opts.has("vp8l-effort") { host.vp8lEffort = Int32(opts.int("vp8l-effort", 4)) }
    if opts.has("keyframe-effort") { host.keyframeEffort = Int32(opts.int("keyframe-effort", 4)) }
    let viewer = ViewerEngine(transport: link.b, videoDecoderFactory: decoderFactory,
                              supportedVideoCodecs: viewerCodecs)
    viewer.onFailed = { reason in print("  VIEWER FAILED: \(reason)") }
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
    func drainVTOutput() {
        // Give the async VT callback queue a chance to enqueue deliveries
        // between virtual-time steps (mock is synchronous; vt is not).
        if videoMode == "vt" {
            usleep(500)
        }
    }

    // Video coverage: how much of the replay's screen-time the viewer
    // presented from lossy video rather than its exact canvas (sampled every
    // 16 ms of virtual time while frames play).
    var coverageSamples = 0, coverageVideoTiles = 0, sampling = false
    var nextCoverageSampleUS: UInt64 = 0
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
                      + "viewer \(viewer.state) acks \(viewer.stats.acksSent) rx \(viewer.stats.datagramsReceived)")
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

    while let meta = try reader.readFrame(rects: &rects, into: frameBuf) {
        let base = baseTS ?? meta.timestampUS
        baseTS = base
        drive(untilUS: replayStartUS + (meta.timestampUS &- base))
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
        frames += 1
    }

    sampling = false
    // §7 settle: keep ticking the encoder on the final frame until quiescent.
    var settled = false
    var sinceEncodeMS = 16
    for _ in 0..<60_000 {
        if sinceEncodeMS >= 16 {
            host.encodeTick(frame: UnsafeRawBufferPointer(frameBuf), bytesPerRow: width * 4,
                            dirtyRects: nil, captureTimestampUS: link.nowUS, nowUS: link.nowUS)
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
    viewer applied \(viewer.stats.videoFramesApplied)
      video coverage: \(String(format: "%.1f", coverageSamples == 0 ? 0 : 100 * Double(coverageVideoTiles) / Double(coverageSamples * TileGrid(width: width, height: height).count)))% of screen-time on video  \
    handoffs: reveal \(host.stats.overlayHandoffReveals)  record \(host.stats.overlayHandoffRecords)  \
    re-sharpens \(host.stats.videoRefreshes)
      rate: \(opts.has("limit-mbit") ? "limit \(opts.int("limit-mbit", 25)) Mbit/s" : "auto")  \
    governor \(String(format: "%.1f", Double(host.stats.governorRate) / 1e6)) MB/s at end  \
    tiles deferred \(host.stats.governorDeferredTiles)
      settled: \(settled)   canvas byte-identical: \(identical)
    """)
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
    if opts.has("golden") && !(settled && identical) {
        throw BenchError("golden check FAILED")
    }
}
