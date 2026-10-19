// replay --mode encode: the host engine alone with instant ACKs; reports
// bytes/frame, encode timings, and where the steady-state bytes live.
import Foundation
import GlassActCore
import GlassActTransport
import GlassActWire

final class BenchTransport: GlassActTransport {
    var maxDatagramSize: Int = 1452
    var videoBacklogBytes: Int { 0 }
    var pendingDatagrams: [Data] = []
    var totalDatagrams = 0
    var totalBytes = 0

    func sendControl(_ data: Data) {}
    func sendDatagram(_ data: Data) {
        pendingDatagrams.append(data)
        totalDatagrams += 1
        totalBytes += data.count
    }

    var pendingKeyframeSeqs: [UInt32] = []

    func sendVideo(_ data: Data) {
        totalBytes += data.count
        var d = VideoDeframer()
        d.append([UInt8](data))
        while let event = d.next() {
            if case let .message(.keyframe(seq, _, _, _, _, _, _)) = event {
                pendingKeyframeSeqs.append(seq)
            }
        }
    }
}

func datagramHeader(_ d: Data) -> DatagramHeader? {
    d.withUnsafeBytes { raw in
        var r = ByteReader(raw)
        return DatagramHeader.parse(&r)
    }
}

func instantAck(_ host: HostEngine, _ transport: BenchTransport, nowUS: UInt64) {
    // Keyframes ride the reliable stream; a real viewer applies + ACKs them.
    for seq in transport.pendingKeyframeSeqs {
        host.handleControl(Data(ControlMessage.keyframeAck(seq: seq).encoded()), nowUS: nowUS)
    }
    transport.pendingKeyframeSeqs.removeAll()
    var bySeq: [UInt32: (cnt: Int, bits: Set<Int>)] = [:]
    for d in transport.pendingDatagrams {
        guard let h = datagramHeader(d) else { continue }
        var e = bySeq[h.frameSeq] ?? (Int(h.dgramCnt), [])
        e.bits.insert(Int(h.dgramIdx))
        bySeq[h.frameSeq] = e
    }
    transport.pendingDatagrams.removeAll(keepingCapacity: true)
    for (seq, e) in bySeq {
        var bitmap = [UInt8](repeating: 0, count: (e.cnt + 7) / 8)
        for b in e.bits { bitmap[b >> 3] |= 1 << UInt8(b & 7) }
        let ack = ControlMessage.ack(frameSeq: seq, dgramCnt: UInt16(e.cnt), bitmap: bitmap)
        host.handleControl(Data(ack.encoded()), nowUS: nowUS)
    }
}

func cmdReplayEncode(_ reader: ScapReader, traceName: String, opts: Options) throws {
    let width = reader.header.width
    let height = reader.header.height
    let transport = BenchTransport()
    var realTimer: (@Sendable () -> UInt64)?
    if opts.has("encode-headroom") { realTimer = { DispatchTime.now().uptimeNanoseconds / 1000 } }
    let host = HostEngine(width: width, height: height, transport: transport, encodeTimer: realTimer)
    if opts.has("limit-mbit") { host.rateLimit = .megabits(opts.int("limit-mbit", 25)) }
    if opts.has("vp8l-effort") { host.vp8lEffort = Int32(opts.int("vp8l-effort", 4)) }
    if opts.has("keyframe-effort") { host.keyframeEffort = Int32(opts.int("keyframe-effort", 4)) }
    host.start(nowUS: 0)
    host.handleControl(Data(ControlMessage.helloOK(ver: WireVersion.current, caps: 0, geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0).encoded()), nowUS: 0)

    let frameBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { frameBuf.deallocate() }
    var rects: [DirtyRect] = []
    var encodeUS: [Double] = []
    func processCPU() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }
    var encodeCPU = 0.0 // process CPU inside encodeTick (includes its worker threads)
    var frameBytes: [Int] = []
    var tickProfile: [(Int, Int)] = [] // (qualified tiles, bytes)
    var baseTS: UInt64?
    var lastTS: UInt64 = 0
    var frames = 0
    let countAllocs = opts.has("count-allocs")
    if countAllocs && !AllocCounter.install() {
        throw BenchError("--count-allocs: malloc_logger is unavailable (MallocStackLogging or Instruments attached?)")
    }
    // Per tick, excluding cold start: (did the tick emit a SCROLL, allocations).
    var tickAllocs: [(scrolled: Bool, counts: AllocCounter.Counts)] = []

    while let meta = try reader.readFrame(rects: &rects, into: frameBuf) {
        let base = baseTS ?? meta.timestampUS
        baseTS = base
        lastTS = meta.timestampUS
        let now = 1_000 + (meta.timestampUS &- base)
        let bytesBefore = transport.totalBytes
        let c0 = processCPU()
        let scrollsBefore = host.stats.scrollsSent
        let a0 = AllocCounter.counts
        if countAllocs { AllocCounter.arm() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        host.encodeTick(frame: UnsafeRawBufferPointer(frameBuf), bytesPerRow: width * 4,
                        dirtyRects: rects.isEmpty ? nil : rects,
                        captureTimestampUS: meta.timestampUS, nowUS: now)
        let t1 = DispatchTime.now().uptimeNanoseconds
        if countAllocs {
            AllocCounter.disarm()
            if frames > 0 {
                tickAllocs.append((host.stats.scrollsSent > scrollsBefore, AllocCounter.counts - a0))
            }
        }
        encodeCPU += processCPU() - c0
        instantAck(host, transport, nowUS: now)
        encodeUS.append(Double(t1 - t0) / 1000.0)
        let tickBytes = transport.totalBytes - bytesBefore
        frameBytes.append(tickBytes)
        if frames > 0 { // exclude the cold-start tick from the profile
            tickProfile.append((host.stats.lastTickQualifiedTiles, tickBytes))
            if host.stats.lastTickQualifiedTiles > 100,
               ProcessInfo.processInfo.environment["GLASSACT_BURST_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[burst] frame=\(frames) tiles=\(host.stats.lastTickQualifiedTiles) bytes=\(tickBytes)\n".utf8))
            }
        }
        frames += 1
    }

    let coldStartBytes = frameBytes.max() ?? 0
    let steadyBytes = transport.totalBytes - coldStartBytes
    let sorted = encodeUS.sorted()
    // Sustained rate over the trace's own timeline (capture timestamps), not
    // a 60 Hz normalization — traces run at whatever rate change occurred.
    let traceSeconds = frames > 1 ? Double(lastTS &- (baseTS ?? 0)) / 1_000_000 : 0
    let sustained = traceSeconds > 0.001 ? Int(Double(transport.totalBytes) / traceSeconds) : 0
    print("""
    replay (encode-only): \(traceName)
      geometry: \(width)x\(height), \(frames) frames over \(String(format: "%.1f", traceSeconds)) s
      vp8l effort: tiles \(host.vp8lEffort.map(String.init) ?? "auto"), keyframes \(host.keyframeEffort.map(String.init) ?? "auto")   encode cpu: \(String(format: "%.2f", encodeCPU)) s   final rate \(String(format: "%.1f", Double(host.stats.governorRate) / 1e6)) MB/s, encode duty \(host.stats.encodeDutyPercent) %
      encode/batch: p50 \(String(format: "%.0f", percentile(sorted, 0.50))) µs   \
    p95 \(String(format: "%.0f", percentile(sorted, 0.95))) µs   \
    max \(String(format: "%.0f", sorted.last ?? 0)) µs
      bytes out: \(formatBytes(transport.totalBytes)) total, \
    \(formatBytes(frames > 0 ? transport.totalBytes / frames : 0))/frame avg, \
    sustained \(formatBytes(sustained))/s
      excluding cold start: \(formatBytes(steadyBytes)) total, \
    sustained \(formatBytes(traceSeconds > 0.001 ? Int(Double(steadyBytes) / traceSeconds) : 0))/s
      datagrams: \(transport.totalDatagrams)   tiles sent: \(host.stats.tilesSent)   \
    batches: \(host.stats.batchesSent)   captures dropped: \(host.stats.batchesDropped)
      paths: scrolls \(host.stats.scrollsSent) (satisfied \(host.stats.scrollSatisfiedTiles) tiles) · deltas \(host.stats.deltasSent) · cache refs \(host.stats.cacheRefsSent) · keyframes \(host.stats.keyframesSent) (\(formatBytes(host.stats.keyframeBytesSent)))
      vp8l routing: \(host.stats.webpProbes) probes, \(host.stats.webpProbesSkipped) skipped by positional memory \
    (\(String(format: "%.0f", 100.0 * Double(host.stats.webpProbesSkipped) / Double(max(1, host.stats.webpProbes + host.stats.webpProbesSkipped))))% avoided)
    """)
    // Tick-size decomposition: where do the steady-state bytes live?
    if !tickProfile.isEmpty {
        let buckets: [(String, Int, Int)] = [("1–3 tiles (keystroke-ish)", 1, 3),
                                             ("4–20 tiles", 4, 20),
                                             ("21–100 tiles", 21, 100),
                                             (">100 tiles (burst/scroll)", 101, Int.max)]
        print("      tick decomposition (excluding cold start):")
        for (name, lo, hi) in buckets {
            let rows = tickProfile.filter { $0.0 >= lo && $0.0 <= hi }
            let bytes = rows.reduce(0) { $0 + $1.1 }
            print("        \(pad(name, 28)) \(pad("\(rows.count) ticks", 11)) \(pad(formatBytes(bytes), 10)) \(String(format: "%4.1f%%", 100.0 * Double(bytes) / Double(max(steadyBytes, 1))))")
        }
    }
    if countAllocs {
        // All threads includes the encode workers (libwebp allocates per
        // VP8L encode, INV-7); the encode thread is the engine's own queue.
        func line(_ name: String, _ rows: [AllocCounter.Counts]) {
            let all = rows.map { Double($0.allThreads) }.sorted()
            let own = rows.map { Double($0.armedThread) }.sorted()
            let total = rows.reduce(0) { $0 + $1.allThreads }
            let ownTotal = rows.reduce(0) { $0 + $1.armedThread }
            func dist(_ s: [Double]) -> String {
                "p50 \(Int(percentile(s, 0.50))) / p95 \(Int(percentile(s, 0.95))) / max \(Int(s.last ?? 0))"
            }
            print("        \(pad(name, 13)) \(pad("\(rows.count) ticks", 11)) all threads \(total), per tick \(dist(all))")
            print("        \(pad("", 13)) \(pad("", 11)) encode thread \(ownTotal), per tick \(dist(own))")
        }
        print("      heap allocations inside encodeTick (excluding cold start):")
        line("scroll ticks", tickAllocs.filter { $0.scrolled }.map(\.counts))
        line("other ticks", tickAllocs.filter { !$0.scrolled }.map(\.counts))
    }
}
