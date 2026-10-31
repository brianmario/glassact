// av1seq — sustained speed of the Metal/CPU hybrid AV1 encoder (research,
// GlassActAV1.AV1HybridEncoder) on consecutive trace frames, each coded as an
// intra frame: frames per second, size, luma PSNR, where the time goes, and
// optionally libaom's realtime key frames on the same pictures. Every stream is
// decoded by libaom afterwards and must equal the encoder's picture exactly.
import Foundation
import AV1Encoder
import GlassActAV1
import GlassActCore
import libaom
import Metal
import QuartzCore

let av1SeqCommand = Command(
    name: "av1seq",
    summary: "consecutive trace frames as AV1 intra frames with the Metal/CPU hybrid encoder (research): fps, size, PSNR",
    flags: [
        .trace,
        .int("frames", "<n>", 1...10_000, "frames to encode (default 60)"),
        .int("skip", "<n>", 0...100_000, "trace frames to skip first (default 0)"),
        .int("width", "<px>", 64...8192, "resample frames to this width (default 1280)"),
        .int("q", "<0-63>", 0...63, "quantizer, libaom's scale; qindex 4q, 63 → 255 (default 20)"),
        .string("preset", "<name>", "analysis preset: slow, base, fast, faster, turbo (default), turbo2, turbo3"),
        .string("tiles", "<c>x<r>", "tiling, log2 of columns and rows (default 2x2)"),
        .int("repeat", "<n>", 1...1000, "encode the sequence n times over (for profiling; default 1)"),
        .bool("profile", "afterwards, time the GPU's analysis of the last picture shape by shape (analyzing every SB)"),
        .bool("serial", "finish every picture before starting the next one's analysis (no overlap)"),
        .string("prune", "<v>", "skip 32x32-and-up analysis where variance > v quantizer steps squared (default 4; 0 off, 1 faster)"),
        .int("leaf-tx", "<px>", 0...256, "largest block whose luma tx type the GPU searches (default 128)"),
        .bool("chroma-angles", "screen the six angled chroma modes too (13 instead of 7)"),
        .bool("no-deltas", "don't search angle deltas (faster on moving content, a little more bytes)"),
        .bool("inter-probe", "estimate inter frames: per picture, the 64x64s that are unchanged or exact copies at a found shift, the rest coded as now"),
        .bool("no-filters", "no deblocking or CDEF (tiles then decode alone as in their frame)"),
        .bool("no-reuse", "analyze every superblock of every picture (no reuse where the source is unchanged)"),
        .bool("cpu-decides", "decide chroma and search luma tx types on the CPU in the closed loop, not up front on the GPU"),
        .int("aom-speed", "<n>", 0...12, "also code the pictures as libaom realtime key frames at this speed"),
        .int("aom-threads", "<n>", 1...64, "libaom worker threads (default 8)"),
    ],
    run: { opts in
        let trace = opts.required("trace")
        try cmdAV1Seq(try openTrace(trace), traceName: trace, opts: opts)
    }
)

func cmdAV1Seq(_ reader: ScapReader, traceName: String, opts: Options) throws {
    guard #available(macOS 27, *) else { throw BenchError("av1seq needs macOS 27 (MSL 4.1)") }
    guard glassact_aom_available() != 0 else { throw BenchError("av1seq needs libaom (Apple silicon)") }
    guard let device = MTLCreateSystemDefaultDevice() else { throw BenchError("no Metal device") }
    let count = opts.int("frames", 60), skip = opts.int("skip", 0)
    let q = opts.int("q", 20), qindex = q == 63 ? 255 : 4 * q
    guard let preset = AV1MetalEncoder.Preset(rawValue: opts.string("preset") ?? "turbo")
    else { throw BenchError("--preset: unknown") }
    let tileParts = (opts.string("tiles") ?? "2x2").split(separator: "x").compactMap { Int($0) }
    guard tileParts.count == 2, tileParts.allSatisfy((0...6).contains) else { throw BenchError("--tiles: <c>x<r>") }

    // the pictures, converted before the clock starts
    let srcW = reader.header.width, srcH = reader.header.height
    let width = opts.int("width", 1280) & ~1, height = (srcH * width / srcW) & ~1
    let full = UnsafeMutableRawBufferPointer.allocate(byteCount: srcW * srcH * 4, alignment: 64)
    let bgra = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { full.deallocate(); bgra.deallocate() }
    var rects: [DirtyRect] = []
    var pictures: [YUV420] = []
    var index = 0
    var stamps: [UInt64] = []
    while pictures.count < count, let meta = try reader.readFrame(rects: &rects, into: full) {
        defer { index += 1 }
        guard index >= skip else { continue }
        stamps.append(meta.timestampUS)
        resample(full, srcW, srcH, into: bgra, width, height)
        pictures.append(try YUV420(bgra: bgra, width: width, height: height))
    }
    guard !pictures.isEmpty else { throw BenchError("no frames after --skip \(skip)") }
    func picture(_ i: Int) -> AV1HybridEncoder.Picture {
        AV1HybridEncoder.Picture(y: pictures[i].planes[0], u: pictures[i].planes[1], v: pictures[i].planes[2],
                                 width: width, height: height)
    }
    let serial = opts.has("serial")
    print("av1seq: \(traceName) frames \(skip)..<\(skip + pictures.count), \(width)×\(height), q\(q), \(preset.rawValue), tiles \(tileParts[0])x\(tileParts[1])\(serial ? ", serial" : ", overlapped")\(opts.has("cpu-decides") ? ", CPU decides chroma and tx" : ", GPU decides chroma and tx")")

    let encoder = try AV1HybridEncoder(device: device)
    encoder.preset = preset
    encoder.tiling = (tileParts[0], tileParts[1])
    encoder.gpuDecides = !opts.has("cpu-decides")
    encoder.reusesAnalysis = !opts.has("no-reuse")
    encoder.postfilters = !opts.has("no-filters")
    encoder.searchesAngleDeltas = !opts.has("no-deltas")
    if opts.has("leaf-tx") { encoder.leafTxSearchPixels = opts.int("leaf-tx", 128) }
    if opts.has("chroma-angles") { encoder.leafChromaAngledModes = true }
    if let v = opts.string("prune") {
        guard let f = Float(v), f >= 0 else { throw BenchError("--prune \(v): not a number >= 0") }
        encoder.busyBlockPrune = f
    }
    _ = try encoder.encode(picture(0), qindex: qindex)  // warm up: pipelines, caches, clocks

    var frames: [AV1HybridEncoder.Frame] = []
    frames.reserveCapacity(pictures.count)
    let repeats = opts.int("repeat", 1)
    var seconds = 0.0
    for r in 0..<repeats {
        if r > 0 { frames.removeAll(keepingCapacity: true) }
        let t0 = CACurrentMediaTime()
        if serial {
            for i in 0..<pictures.count { frames.append(try encoder.encode(picture(i), qindex: qindex)) }
        } else {
            try encoder.encode(count: pictures.count, qindex: qindex, picture: { picture($0) }, output: { _, f in frames.append(f) })
        }
        seconds = CACurrentMediaTime() - t0
    }

    var psnr = 0.0
    for (i, f) in frames.enumerated() {
        let decoded = try YUV420.decode(f.obu, width: width, height: height)
        for p in 0..<3 where decoded.planes[p] != f.planes[p] {
            throw BenchError("frame \(i): libaom's decode differs from the encoder's picture in plane \(p)")
        }
        psnr += decoded.psnrY(pictures[i])
    }
    let n = Double(frames.count)
    func mean(_ f: (AV1HybridEncoder.Timing) -> Double) -> Double { frames.map { f($0.timing) }.reduce(0, +) / n * 1000 }
    let bytes = frames.map(\.obu.count).reduce(0, +)
    print(String(format: "  hybrid     %.1f fps (%.1f ms a frame) · %@ a frame · PSNR-Y %.2f · all %d decoded exactly",
                 n / seconds, seconds / n * 1000, formatBytes(bytes / frames.count), psnr / n, frames.count))
    // the trace's own timing: frames arrive when the screen changes, at most ~60 a second
    if let first = stamps.first, let last = stamps.last, last > first, stamps.count > 1 {
        let span = Double(last - first) / 1e6 * Double(stamps.count) / Double(stamps.count - 1)
        print(String(format: "             the trace's timing: %d frames over %.2f s · %.1f Mbit/s",
                     stamps.count, span, Double(bytes) * 8 / span / 1e6))
    }
    print(String(format: "             per frame: GPU analysis %.1f · CPU chroma %.1f · closed loop %.1f · filters %.1f · writer %.1f (ms) · kept: analysis %.0f %%, tiles %.0f %% · filtered %.0f %%",
                 mean { $0.analysis }, mean { $0.chroma }, mean { $0.closedLoop }, mean { $0.filters }, mean { $0.writer },
                 mean { $0.kept } / 10, mean { $0.keptTiles } / 10, mean { $0.filtered } / 10))

    if opts.has("inter-probe") { try interProbe(pictures, frames.map(\.obu.count), stamps) }

    if opts.has("profile") {
        encoder.reusesAnalysis = false
        encoder.profilesStages = true
        // isolated dispatches run at whatever clock the GPU is at, so take each stage's best of 10
        var st = AV1MetalEncoder.StageTimes()
        for run in 0..<10 {
            _ = try encoder.encode(picture(pictures.count - 1), qindex: qindex)
            let s = encoder.lastStages
            if run == 0 { st = s; continue }
            st.analysis = min(st.analysis, s.analysis)
            st.partition = min(st.partition, s.partition)
            st.leaves = min(st.leaves, s.leaves)
            st.shapes.merge(s.shapes, uniquingKeysWith: min)
        }
        let names = ["4x4", "4x8", "8x4", "8x8", "8x16", "16x8", "16x16", "16x32", "32x16", "32x32", "32x64", "64x32",
                     "64x64", "", "", "", "4x16", "16x4", "8x32", "32x8", "16x64", "64x16"]
        let shapes = st.shapes.sorted { $0.key < $1.key }.map { String(format: "%@ %.1f", names[$0.key], $0.value * 1000) }
        print(String(format: "  GPU, stage by stage (ms): analysis %.1f [%@] · partition %.1f · leaves %.1f",
                     st.analysis * 1000, shapes.joined(separator: " · "), st.partition * 1000, st.leaves * 1000))
        encoder.profilesStages = false
        encoder.reusesAnalysis = !opts.has("no-reuse")
    }

    if opts.has("aom-speed") {
        let speed = opts.int("aom-speed", 9), threads = opts.int("aom-threads", 8)
        var options = glassact_aom_enc_options(speed: Int32(speed), vbr: 1)
        guard let enc = glassact_aom_enc_create_with(Int32(width), Int32(height), Int32(threads), 200_000, &options)
        else { throw BenchError("libaom: no encoder") }
        defer { glassact_aom_enc_destroy(enc) }
        _ = glassact_aom_enc_set_max_quantizer(enc, Int32(q))
        _ = glassact_aom_enc_set_min_quantizer(enc, Int32(q))
        var total = 0, aomPSNR = 0.0, streams: [[UInt8]] = []
        let a0 = CACurrentMediaTime()
        for (i, p) in pictures.enumerated() {
            let rc = p.withFrame { f in withUnsafePointer(to: f) { glassact_aom_enc_encode(enc, $0, Int64(i) * 16_667, 16_667, 1) } }
            guard rc == 0 else { throw BenchError("libaom: \(String(cString: glassact_aom_enc_error(enc)))") }
            var size = 0, key: Int32 = 0, stream: [UInt8] = []
            while let pk = glassact_aom_enc_next_packet(enc, &size, &key) { stream += UnsafeBufferPointer(start: pk, count: size) }
            streams.append(stream)
            total += stream.count
        }
        let aomSeconds = CACurrentMediaTime() - a0
        var header = [UInt8](repeating: 0, count: 256)
        let headerSize = Int(glassact_aom_enc_sequence_header(enc, &header, header.count))
        for (i, s) in streams.enumerated() {
            let full = headerSize > 0 ? Array(header.prefix(headerSize)) + s : s
            aomPSNR += try YUV420.decode(full, width: width, height: height).psnrY(pictures[i])
        }
        print(String(format: "  libaom s%d  %.1f fps (%.1f ms a frame, %d threads) · %@ a frame · PSNR-Y %.2f (key frames)",
                     speed, n / aomSeconds, aomSeconds / n * 1000, threads, formatBytes(total / pictures.count), aomPSNR / n))
    }
}

/// `--inter-probe`: what inter frames could save, from the source alone. Per picture after the first,
/// each 64x64 is unchanged, an exact copy of the previous picture at a candidate shift (the motion
/// finder's, or a neighbour's), or changed. Unchanged and copied ones would be inter blocks with no
/// residual (a few bytes each); changed ones are counted at their share of the key frame's bytes.
private func interProbe(_ pictures: [YUV420], _ keyBytes: [Int], _ stamps: [UInt64]) throws {
    guard let first = pictures.first, pictures.count > 1 else { return }
    let w = first.width, h = first.height, sbCols = (w + 63) / 64, sbRows = (h + 63) / 64, nsb = sbCols * sbRows
    let motion = av1enc_motion_create()
    defer { av1enc_motion_destroy(motion) }
    var unchanged = 0, copied = 0, changedCount = 0, estimate = keyBytes[0]
    var cands = [Int32](repeating: 0, count: 16)
    _ = first.planes[0].withUnsafeBufferPointer { y in
        let all = [UInt8](repeating: 1, count: nsb)
        return av1enc_motion_candidates(motion, y.baseAddress, Int32(w), Int32(w), Int32(h), all, Int32(sbCols), Int32(sbRows), 8, &cands)
    }
    for i in 1..<pictures.count {
        let cur = pictures[i], prev = pictures[i - 1]
        let cw = (w + 1) / 2
        func matches(_ x: Int, _ y: Int, _ dx: Int32, _ dy: Int32) -> Bool {
            cur.planes[0].withUnsafeBufferPointer { c0 in cur.planes[1].withUnsafeBufferPointer { c1 in cur.planes[2].withUnsafeBufferPointer { c2 in
                prev.planes[0].withUnsafeBufferPointer { p0 in prev.planes[1].withUnsafeBufferPointer { p1 in prev.planes[2].withUnsafeBufferPointer { p2 in
                    let c: [UnsafePointer<UInt8>?] = [c0.baseAddress, c1.baseAddress, c2.baseAddress]
                    let p: [UnsafePointer<UInt8>?] = [p0.baseAddress, p1.baseAddress, p2.baseAddress]
                    let strides: [Int32] = [Int32(w), Int32(cw), Int32(cw)]
                    return av1enc_motion_sb_matches(c, strides, p, strides, Int32(w), Int32(h), 3, Int32(x), Int32(y), dx, dy) != 0
                } } }
            } } }
        }
        var changed = [UInt8](repeating: 0, count: nsb)
        for s in 0..<nsb where !matches(s % sbCols, s / sbCols, 0, 0) { changed[s] = 1 }
        let n = cur.planes[0].withUnsafeBufferPointer { y in
            Int(av1enc_motion_candidates(motion, y.baseAddress, Int32(w), Int32(w), Int32(h), changed, Int32(sbCols), Int32(sbRows), 8, &cands))
        }
        var mv = [(Int32, Int32)?](repeating: nil, count: nsb)
        var need = 0
        for s in 0..<nsb {
            guard changed[s] != 0 else { unchanged += 1; continue }
            changedCount += 1
            var tries = (0..<n).map { (cands[2 * $0], cands[2 * $0 + 1]) }
            if s % sbCols > 0, let m = mv[s - 1] { tries.insert(m, at: 0) }
            if s >= sbCols, let m = mv[s - sbCols] { tries.insert(m, at: 0) }
            if let m = tries.first(where: { matches(s % sbCols, s / sbCols, $0.0, $0.1) }) {
                mv[s] = m
                copied += 1
            } else {
                need += 1
            }
        }
        estimate += keyBytes[i] * need / nsb + 2 * (nsb - need)
    }
    let pics = pictures.count - 1
    print(String(format: "  inter probe: per 64x64 after the first picture: unchanged %.1f %% · copied at a shift %.1f %% · changed %.1f %%",
                 100 * Double(unchanged) / Double(pics * nsb), 100 * Double(copied) / Double(pics * nsb),
                 100 * Double(changedCount - copied) / Double(pics * nsb)))
    if let a = stamps.first, let b = stamps.last, b > a {
        let span = Double(b - a) / 1e6 * Double(stamps.count) / Double(stamps.count - 1)
        print(String(format: "  inter probe: estimated %.1f KB a frame, %.2f Mbit/s at the trace's timing (key frames: %.1f Mbit/s)",
                     Double(estimate) / Double(pictures.count) / 1024, Double(estimate) * 8 / span / 1e6,
                     Double(keyBytes.reduce(0, +)) * 8 / span / 1e6))
    }
}
