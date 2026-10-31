// av1seq — sustained speed of the Metal/CPU hybrid AV1 encoder (research,
// GlassActAV1.AV1HybridEncoder) on consecutive trace frames, each coded as an
// intra frame: frames per second, size, luma PSNR, where the time goes, and
// optionally libaom's realtime key frames on the same pictures. Every stream is
// decoded by libaom afterwards and must equal the encoder's picture exactly.
import Foundation
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
    while pictures.count < count, try reader.readFrame(rects: &rects, into: full) != nil {
        defer { index += 1 }
        guard index >= skip else { continue }
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
    print(String(format: "             per frame: GPU analysis %.1f · CPU chroma %.1f · closed loop %.1f · filters %.1f · writer %.1f (ms) · kept: analysis %.0f %%, tiles %.0f %% · filtered %.0f %%",
                 mean { $0.analysis }, mean { $0.chroma }, mean { $0.closedLoop }, mean { $0.filters }, mean { $0.writer },
                 mean { $0.kept } / 10, mean { $0.keptTiles } / 10, mean { $0.filtered } / 10))

    if opts.has("profile") {
        encoder.reusesAnalysis = false
        encoder.profilesStages = true
        _ = try encoder.encode(picture(pictures.count - 1), qindex: qindex)
        let st = encoder.lastStages
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
