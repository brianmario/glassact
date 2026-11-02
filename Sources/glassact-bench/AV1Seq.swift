// av1seq — sustained speed of the Metal/CPU hybrid AV1 encoder (research,
// GlassActAV1.AV1HybridEncoder) on consecutive trace frames, each coded as an
// intra frame, or (--inter) as one stream of inter frames after a key frame:
// frames per second, size, luma PSNR, where the time goes, and optionally
// libaom's realtime key frames on the same pictures. Every frame is decoded by
// libaom afterwards and must equal the encoder's picture exactly.
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
        .bool("profile", "afterwards, time the GPU's analysis of the last picture shape by shape (analyzing every SB; with --inter, as an inter frame after the one before)"),
        .bool("serial", "finish every picture before starting the next one's analysis (no overlap)"),
        .string("prune", "<v>", "skip 32x32-and-up analysis where variance > v quantizer steps squared (default 4; 0 off, 1 faster)"),
        .int("leaf-tx", "<px>", 0...256, "largest block whose luma tx type the GPU searches (default 128)"),
        .bool("chroma-angles", "screen the six angled chroma modes too (13 instead of 7)"),
        .bool("no-deltas", "don't search angle deltas (faster on moving content, a little more bytes)"),
        .string("deltas-up-to", "<share>", "search angle deltas only in pictures that analyze at most this share of their superblocks (0–1; default 0.5; 1: always)"),
        .bool("inter", "inter frames after the first: 64x64s that are exact copies of the previous picture (unchanged, scrolled, dragged) as skip inter blocks, the rest intra or motion-searched"),
        .bool("no-motion-search", "with --inter: copies only, no motion search in the coded 64x64s"),
        .bool("no-subpel", "with --inter: whole-sample motion vectors only in the motion search"),
        .string("inter-preset", "<name>", "with --inter: the inter frames' analysis preset (default: --preset's)"),
        .bool("intra-everywhere", "with --inter: search intra modes even where the inter residual quantizes to nothing"),
        .bool("digest", "also print a hash (FNV-1a 64) of every frame's bytes, to check that a change keeps the stream the same"),
        .string("gpu-capture", "<path.gputrace>", "afterwards, write a Metal GPU capture of the last picture (with --inter, as an inter frame after the one before) for Xcode; run with MTL_CAPTURE_ENABLED=1"),
        .bool("no-planes", "with --inter: frames without their decoded pictures (the speed without copying them out; not decode-checked)"),
        .bool("no-cdf-carry", "with --inter: every inter frame starts from the default CDFs, not its reference's"),
        .bool("no-filters", "no deblocking or CDEF (tiles then decode alone as in their frame)"),
        .bool("no-intrabc", "key frames don't copy what repeats inside them (AV1 intra block copy, on by default)"),
        .string("crop", "<w>x<h>+<x>+<y>", "code this rectangle of the trace's frames at their own size (not with --width or --score-rgb)"),
        .bool("no-reuse", "analyze every superblock of every picture (no reuse where the source is unchanged)"),
        .bool("cpu-decides", "decide chroma and search luma tx types on the CPU in the closed loop, not up front on the GPU"),
        .int("aom-speed", "<n>", 0...12, "also code the pictures as libaom realtime key frames at this speed"),
        .int("aom-threads", "<n>", 1...64, "libaom worker threads (default 8)"),
        .bool("score-rgb", "also score every frame as vquality scores HEVC: BT.601 luma of the decoded picture in BGRA against the trace frame (SSIM on 8x8 blocks, PSNR)"),
        .bool("aom-inter", "with --aom-speed: libaom codes one stream of inter frames after a key frame, not key frames"),
        .int("stream-width", "<px>", 64...8192, "with --inter: the stream's width; the pictures are coded at --width inside it and shown scaled up to it (AV1 reduced frames), and --score-rgb scores them at its size"),
        .string("ivf", "<path>", "also write the hybrid's stream as IVF"),
        .string("ml-prune", "<weights.bin>", "learned pruning of the analysis with these weights instead of the shipped ones (prune_train's raw export)"),
        .string("ml-eps", "<p>", "learned pruning: a cell keeps its likeliest levels until all but this much probability is kept (default 0.02)"),
        .bool("no-ml-prune", "no learned pruning (the variance rule instead)"),
        .string("ml-over", "<share>", "with --ml-prune: only in pictures coding more than this share of their superblocks (default 0.5; key frames count as all)"),
        .string("dump-partition", "<dir>", "instead of encoding: each picture's luma and the GPU's full search's leaf blocks (no pruning, no angle deltas), for offline study"),
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
    var crop: (w: Int, h: Int, x: Int, y: Int)?
    if let c = opts.string("crop") {
        let n = c.split(whereSeparator: { "x+".contains($0) }).compactMap { Int($0) }
        guard n.count == 4, n[0] >= 64, n[1] >= 64, n[0] + n[2] <= srcW, n[1] + n[3] <= srcH,
              !opts.has("width"), !opts.has("score-rgb")
        else { throw BenchError("--crop: <w>x<h>+<x>+<y> inside the frame, without --width or --score-rgb") }
        crop = (n[0] & ~1, n[1] & ~1, n[2], n[3])
    }
    let width = crop?.w ?? opts.int("width", 1280) & ~1, height = crop?.h ?? (srcH * width / srcW) & ~1
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
        if let crop {
            for row in 0..<height {
                (bgra.baseAddress! + row * width * 4).copyMemory(
                    from: full.baseAddress! + ((crop.y + row) * srcW + crop.x) * 4, byteCount: width * 4)
            }
        } else {
            resample(full, srcW, srcH, into: bgra, width, height)
        }
        pictures.append(try YUV420(bgra: bgra, width: width, height: height))
    }
    guard !pictures.isEmpty else { throw BenchError("no frames after --skip \(skip)") }
    func picture(_ i: Int) -> AV1HybridEncoder.Picture {
        AV1HybridEncoder.Picture(y: pictures[i].planes[0], u: pictures[i].planes[1], v: pictures[i].planes[2],
                                 width: width, height: height)
    }
    let serial = opts.has("serial"), inter = opts.has("inter")
    if serial && inter { throw BenchError("--serial codes every picture alone: not with --inter") }
    // reduced frames: the stream's size, which the pictures are shown at
    var stream: (width: Int, height: Int)?
    if opts.has("stream-width") {
        let w = opts.int("stream-width", width) & ~1
        guard inter, crop == nil, w >= width else { throw BenchError("--stream-width: with --inter, at least --width, not with --crop") }
        stream = (w, (srcH * w / srcW) & ~1)
    }
    print("av1seq: \(traceName) frames \(skip)..<\(skip + pictures.count), \(width)×\(height), q\(q), \(preset.rawValue), tiles \(tileParts[0])x\(tileParts[1])\(serial ? ", serial" : ", overlapped")\(opts.has("cpu-decides") ? ", CPU decides chroma and tx" : ", GPU decides chroma and tx")\(inter ? ", inter frames" : ", intra frames")")

    if let dir = opts.string("dump-partition") {
        try dumpPartitions(pictures, width: width, height: height, qindex: qindex, preset: preset, device: device, to: dir)
        return
    }
    let encoder = try AV1HybridEncoder(device: device)
    encoder.preset = preset
    encoder.tiling = (tileParts[0], tileParts[1])
    encoder.gpuDecides = !opts.has("cpu-decides")
    encoder.reusesAnalysis = !opts.has("no-reuse")
    encoder.postfilters = !opts.has("no-filters")
    encoder.intraBlockCopy = !opts.has("no-intrabc")
    encoder.searchesAngleDeltas = !opts.has("no-deltas")
    if opts.has("no-ml-prune") {
        encoder.learnedPrune = nil
    } else if opts.has("ml-prune") || opts.has("ml-eps") || opts.has("ml-over") {
        var weights = AV1PrunerWeights.cellV1
        if let path = opts.string("ml-prune") {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            weights = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard weights.count == 982 else { throw BenchError("--ml-prune: \(weights.count) floats, not 982 (k_ml.h ML_FLOATS)") }
        }
        encoder.learnedPrune = (weights, Float(opts.string("ml-eps").flatMap(Float.init) ?? 0.02),
                                Double(opts.string("ml-over").flatMap(Double.init) ?? 0.5))
    }
    if let v = opts.string("deltas-up-to") {
        guard let f = Double(v), (0...1).contains(f) else { throw BenchError("--deltas-up-to \(v): a share 0–1") }
        encoder.angleDeltasUpToShare = f
    }
    encoder.interFrames = inter
    encoder.streamSize = stream
    encoder.searchesMotion = !opts.has("no-motion-search")
    encoder.carriesCDFs = !opts.has("no-cdf-carry")
    encoder.returnsPlanes = !opts.has("no-planes")
    encoder.interSkipsIntra = !opts.has("intra-everywhere")
    if let name = opts.string("inter-preset") {
        guard let p = AV1MetalEncoder.Preset(rawValue: name) else { throw BenchError("--inter-preset: unknown") }
        encoder.interPreset = p
    }
    encoder.searchesSubpelMotion = !opts.has("no-subpel")
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
    var outputAt: [Double] = []  // when each frame came out (overlapped runs)
    var seconds = 0.0
    for r in 0..<repeats {
        if r > 0 { frames.removeAll(keepingCapacity: true) }
        let t0 = CACurrentMediaTime()
        if serial {
            for i in 0..<pictures.count { frames.append(try encoder.encode(picture(i), qindex: qindex)) }
        } else {
            outputAt.removeAll(keepingCapacity: true)
            try encoder.encode(count: pictures.count, qindex: qindex, picture: { picture($0) }, output: { _, f in
                frames.append(f)
                outputAt.append(CACurrentMediaTime())
            })
        }
        seconds = CACurrentMediaTime() - t0
    }

    var psnr = 0.0
    let scoreRGB = opts.has("score-rgb")
    let rgb = scoreRGB ? try RGBScorer(trace: traceName, skip: skip, width: stream?.width ?? width, height: stream?.height ?? height,
                                       coded: stream == nil ? nil : (width, height)) : nil
    guard let decoder = glassact_aom_dec_create(4) else { throw BenchError("libaom: no decoder") }
    defer { glassact_aom_dec_destroy(decoder) }
    for (i, f) in frames.enumerated() {
        // intra frames each alone; a stream in order
        let decoded = inter ? try YUV420.decode(f.obu, width: width, height: height, with: decoder)
                            : try YUV420.decode(f.obu, width: width, height: height)
        for p in 0..<3 where !f.planes.isEmpty && decoded.planes[p] != f.planes[p] {
            throw BenchError("frame \(i): libaom's decode differs from the encoder's picture in plane \(p)")
        }
        psnr += decoded.psnrY(pictures[i])
        try rgb?.add(decoded)
    }
    let n = Double(frames.count)
    func mean(_ f: (AV1HybridEncoder.Timing) -> Double) -> Double { frames.map { f($0.timing) }.reduce(0, +) / n * 1000 }
    let bytes = frames.map(\.obu.count).reduce(0, +)
    print(String(format: "  hybrid     %.1f fps (%.1f ms a frame) · %@ a frame · PSNR-Y %.2f · all %d decoded exactly",
                 n / seconds, seconds / n * 1000, formatBytes(bytes / frames.count), psnr / n, frames.count))
    if let rgb { print(rgb.summary(stream.map { "hybrid at \(width)×\(height) shown at \($0.width)×\($0.height)" } ?? "hybrid")) }
    if let path = opts.string("ivf") {
        try writeIVF(frames.map(\.obu), width: stream?.width ?? width, height: stream?.height ?? height, to: path)
        print("             stream written to \(path)")
    }
    if opts.has("digest") {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for f in frames { for b in f.obu { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 } }
        print(String(format: "             stream digest %016llx (%d frames)", h, frames.count))
    }
    // the trace's own timing: frames arrive when the screen changes, at most ~60 a second
    if let first = stamps.first, let last = stamps.last, last > first, stamps.count > 1 {
        let span = Double(last - first) / 1e6 * Double(stamps.count) / Double(stamps.count - 1)
        print(String(format: "             the trace's timing: %d frames over %.2f s · %.1f Mbit/s",
                     stamps.count, span, Double(bytes) * 8 / span / 1e6))
    }
    if !opts.has("no-intrabc") {
        // the key frames: the first of a stream, or every picture
        let keys = inter ? Array(frames.prefix(1)) : frames
        let copied = keys.map { $0.timing.intraCopied }
        print(String(format: "             intra block copy: %d of %d key frames copy, %.1f %% of their pictures on average",
                     copied.filter { $0 > 0 }.count, keys.count, copied.reduce(0, +) / Double(max(1, keys.count)) * 100))
    }
    print(String(format: "             per frame: GPU analysis %.1f · CPU chroma %.1f · closed loop %.1f · filters %.1f · writer %.1f (ms) · kept: analysis %.0f %%, tiles %.0f %% · filtered %.0f %%",
                 mean { $0.analysis }, mean { $0.chroma }, mean { $0.closedLoop }, mean { $0.filters }, mean { $0.writer },
                 mean { $0.kept } / 10, mean { $0.keptTiles } / 10, mean { $0.filtered } / 10))

    if inter, frames.count > 1 {
        let rest = frames.dropFirst()
        let m = Double(rest.count)
        func avg(_ f: (AV1HybridEncoder.Timing) -> Double) -> Double { rest.map { f($0.timing) }.reduce(0, +) / m }
        let steady = outputAt.count == frames.count && frames.count > 1
            ? String(format: " · %.1f inter frames a second", Double(frames.count - 1) / (outputAt[frames.count - 1] - outputAt[0])) : ""
        print(String(format: "             key frame %@ · inter frames %@ on average%@ · copied %.1f %% of 64x64s (%.1f %% at a shift) · deciding them %.2f ms · motion-searched blocks %.1f %% of the picture",
                     formatBytes(frames[0].obu.count), formatBytes(rest.map(\.obu.count).reduce(0, +) / rest.count), steady,
                     avg { $0.copied } * 100, avg { $0.shifted } * 100, avg { $0.motion } * 1000, avg { $0.searched } * 100))
    }

    if opts.has("profile") {
        // an inter frame: its copies aren't analyzed, so the analysis of the rest is kept on
        encoder.reusesAnalysis = inter
        encoder.profilesStages = true
        // isolated dispatches run at whatever clock the GPU is at, so take each stage's best of 10
        var st = AV1MetalEncoder.StageTimes()
        for run in 0..<10 {
            if inter, pictures.count > 1 {
                try encoder.encode(count: 2, qindex: qindex, picture: { picture(pictures.count - 2 + $0) }, output: { _, _ in })
            } else {
                _ = try encoder.encode(picture(pictures.count - 1), qindex: qindex)
            }
            let s = encoder.lastStages
            if run == 0 { st = s; continue }
            st.motionSearch = min(st.motionSearch, s.motionSearch)
            st.interSearch = min(st.interSearch, s.interSearch)
            st.analysis = min(st.analysis, s.analysis)
            st.partition = min(st.partition, s.partition)
            st.leaves = min(st.leaves, s.leaves)
            st.mlPrune = min(st.mlPrune, s.mlPrune)
            st.shapes.merge(s.shapes, uniquingKeysWith: min)
        }
        let names = ["4x4", "4x8", "8x4", "8x8", "8x16", "16x8", "16x16", "16x32", "32x16", "32x32", "32x64", "64x32",
                     "64x64", "", "", "", "4x16", "16x4", "8x32", "32x8", "16x64", "64x16"]
        let shapes = st.shapes.sorted { $0.key < $1.key }.map { String(format: "%@ %.2f", names[$0.key], $0.value * 1000) }
        let motion = inter ? String(format: "motion search %.2f · inter candidates %.2f · ", st.motionSearch * 1000, st.interSearch * 1000) : ""
        print(String(format: "  GPU, stage by stage (ms): %@analysis %.1f [%@] · partition %.1f · leaves %.1f%@",
                     motion, st.analysis * 1000, shapes.joined(separator: " · "), st.partition * 1000, st.leaves * 1000,
                     st.mlPrune > 0 ? String(format: " · learned pruning %.2f", st.mlPrune * 1000) : ""))
        encoder.profilesStages = false
        encoder.reusesAnalysis = !opts.has("no-reuse")
    }

    if let path = opts.string("gpu-capture") {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let capture = MTLCaptureManager.shared()
        guard capture.supportsDestination(.gpuTraceDocument) else { throw BenchError("--gpu-capture: run with MTL_CAPTURE_ENABLED=1") }
        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = device
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = url
        // the key frame first (not captured), then the inter frame alone
        if inter, pictures.count > 1 {
            var started = false
            try encoder.encode(count: 2, qindex: qindex, picture: { i in
                if i == 1 { try capture.startCapture(with: descriptor); started = true }
                return picture(pictures.count - 2 + i)
            }, output: { _, _ in })
            if started { capture.stopCapture() }
        } else {
            encoder.reusesAnalysis = false  // the run's analysis of this picture would be kept
            try capture.startCapture(with: descriptor)
            _ = try encoder.encode(picture(pictures.count - 1), qindex: qindex)
            capture.stopCapture()
            encoder.reusesAnalysis = !opts.has("no-reuse")
        }
        print("  GPU capture: \(url.path)")
    }

    if opts.has("aom-speed") {
        let speed = opts.int("aom-speed", 9), threads = opts.int("aom-threads", 8), aomInter = opts.has("aom-inter")
        var options = glassact_aom_enc_options(speed: Int32(speed), vbr: 1)
        guard let enc = glassact_aom_enc_create_with(Int32(width), Int32(height), Int32(threads), 200_000, &options)
        else { throw BenchError("libaom: no encoder") }
        defer { glassact_aom_enc_destroy(enc) }
        _ = glassact_aom_enc_set_max_quantizer(enc, Int32(q))
        _ = glassact_aom_enc_set_min_quantizer(enc, Int32(q))
        var total = 0, aomPSNR = 0.0, streams: [[UInt8]] = [], keySeconds = 0.0
        let a0 = CACurrentMediaTime()
        for (i, p) in pictures.enumerated() {
            let forceKey: Int32 = aomInter && i > 0 ? 0 : 1
            let rc = p.withFrame { f in withUnsafePointer(to: f) { glassact_aom_enc_encode(enc, $0, Int64(i) * 16_667, 16_667, forceKey) } }
            guard rc == 0 else { throw BenchError("libaom: \(String(cString: glassact_aom_enc_error(enc)))") }
            var size = 0, key: Int32 = 0, stream: [UInt8] = []
            while let pk = glassact_aom_enc_next_packet(enc, &size, &key) { stream += UnsafeBufferPointer(start: pk, count: size) }
            streams.append(stream)
            total += stream.count
            if i == 0 { keySeconds = CACurrentMediaTime() - a0 }
        }
        let aomSeconds = CACurrentMediaTime() - a0
        var header = [UInt8](repeating: 0, count: 256)
        let headerSize = Int(glassact_aom_enc_sequence_header(enc, &header, header.count))
        guard let aomDecoder = glassact_aom_dec_create(4) else { throw BenchError("libaom: no decoder") }
        defer { glassact_aom_dec_destroy(aomDecoder) }
        let aomRGB = scoreRGB ? try RGBScorer(trace: traceName, skip: skip, width: width, height: height) : nil
        for (i, s) in streams.enumerated() {
            let full = headerSize > 0 && (!aomInter || i == 0) ? Array(header.prefix(headerSize)) + s : s
            let decoded = aomInter ? try YUV420.decode(full, width: width, height: height, with: aomDecoder)
                                   : try YUV420.decode(full, width: width, height: height)
            aomPSNR += decoded.psnrY(pictures[i])
            try aomRGB?.add(decoded)
        }
        print(String(format: "  libaom s%d  %.1f fps (%.1f ms a frame, %d threads) · %@ a frame · PSNR-Y %.2f (%@)",
                     speed, n / aomSeconds, aomSeconds / n * 1000, threads, formatBytes(total / pictures.count), aomPSNR / n,
                     aomInter ? "inter frames" : "key frames"))
        if let aomRGB { print(aomRGB.summary("libaom")) }
        if aomInter, streams.count > 1, let first = stamps.first, let last = stamps.last, last > first {
            let span = Double(last - first) / 1e6 * Double(stamps.count) / Double(stamps.count - 1)
            print(String(format: "             key frame %@ · inter frames %@ on average · %.1f inter frames a second · %.2f Mbit/s at the trace's timing",
                         formatBytes(streams[0].count), formatBytes(streams.dropFirst().map(\.count).reduce(0, +) / (streams.count - 1)),
                         Double(streams.count - 1) / (aomSeconds - keySeconds), Double(total) * 8 / span / 1e6))
        }
    }
}

/// `--score-rgb`: decoded pictures scored as vquality scores HEVC (lumaQuality: BT.601 luma of BGRA,
/// SSIM on 8x8 blocks and PSNR), against the trace's frames resampled to the canvas as av1seq
/// resamples them before converting to 4:2:0. Reads the trace a second time, in step.
final class RGBScorer {
    let reader: ScapReader
    let width: Int, height: Int
    /// Reduced frames: the size they're coded at, scaled up to width × height to be scored.
    let coded: (width: Int, height: Int)?
    let full: UnsafeMutableRawBufferPointer, reference: UnsafeMutableRawBufferPointer, shown: UnsafeMutableRawBufferPointer
    let small: UnsafeMutableRawBufferPointer
    var rects: [DirtyRect] = []
    var ssim = 0.0, psnr = 0.0, frames = 0

    init(trace: String, skip: Int, width: Int, height: Int, coded: (width: Int, height: Int)? = nil) throws {
        reader = try openTrace(trace)
        self.width = width
        self.height = height
        self.coded = coded
        full = .allocate(byteCount: reader.header.width * reader.header.height * 4, alignment: 64)
        reference = .allocate(byteCount: width * height * 4, alignment: 64)
        shown = .allocate(byteCount: width * height * 4, alignment: 64)
        small = .allocate(byteCount: coded.map { $0.width * $0.height * 4 } ?? 0, alignment: 64)
        for _ in 0..<skip { _ = try reader.readFrame(rects: &rects, into: full) }
    }

    deinit {
        full.deallocate()
        reference.deallocate()
        shown.deallocate()
        small.deallocate()
    }

    func add(_ decoded: YUV420) throws {
        guard try reader.readFrame(rects: &rects, into: full) != nil else { throw BenchError("--score-rgb: the trace ended early") }
        resample(full, reader.header.width, reader.header.height, into: reference, width, height)
        if let coded {
            try decoded.bgra(into: small)
            resample(small, coded.width, coded.height, into: shown, width, height)
        } else {
            try decoded.bgra(into: shown)
        }
        let (s, p) = lumaQuality(UnsafeRawBufferPointer(reference), UnsafeRawBufferPointer(shown), width, height)
        ssim += s
        if p.isFinite { psnr += p }
        frames += 1
    }

    func summary(_ name: String) -> String {
        String(format: "             %@, scored as vquality: SSIM mean %.4f · PSNR mean %.2f dB", name,
               ssim / Double(max(1, frames)), psnr / Double(max(1, frames)))
    }
}

/// `--ivf`: frames (temporal units) in an IVF file, as dav1d, aomdec and ffmpeg read them.
func writeIVF(_ frames: [[UInt8]], width: Int, height: Int, to path: String) throws {
    var v: [UInt8] = Array("DKIF".utf8)
    func le(_ x: UInt64, _ n: Int) { for i in 0..<n { v.append(UInt8(truncatingIfNeeded: x >> (8 * i))) } }
    le(0, 2); le(32, 2); v += Array("AV01".utf8)
    le(UInt64(width), 2); le(UInt64(height), 2); le(60, 4); le(1, 4); le(UInt64(frames.count), 4); le(0, 4)
    for (k, f) in frames.enumerated() {
        le(UInt64(f.count), 4); le(UInt64(k), 8)
        v += f
    }
    try Data(v).write(to: URL(fileURLWithPath: path))
}

/// `--dump-partition`: for each picture, `<dir>/pNNN.bin`: width, height, qindex (UInt32 each), the
/// luma plane, the leaf count (UInt32) and the leaves as av1g_block records, then the DP's node
/// costs (count, floats: GP_DP_DEBUG per 64x64, raster).
@available(macOS 27, *)
func dumpPartitions(_ pictures: [YUV420], width: Int, height: Int, qindex: Int, preset: AV1MetalEncoder.Preset,
                    device: any MTLDevice, to dir: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let metal = try AV1MetalEncoder(device: device)
    metal.preset = preset
    metal.decidesLeaves = true
    metal.busyBlockPrune = 0
    metal.searchesAngleDeltas = false
    metal.tiling = (2, 0)
    metal.dumpsNodeCosts = true
    for (i, p) in pictures.enumerated() {
        let part = try metal.partition(y: p.planes[0], u: p.planes[1], v: p.planes[2], width: width, height: height, qindex: qindex)
        var data = Data()
        for v in [width, height, qindex] { withUnsafeBytes(of: UInt32(v)) { data.append(contentsOf: $0) } }
        data.append(contentsOf: p.planes[0].prefix(width * height))
        withUnsafeBytes(of: UInt32(part.blocks.count)) { data.append(contentsOf: $0) }
        part.blocks.withUnsafeBytes { data.append(contentsOf: $0) }
        // then the DP's node costs: their count (UInt32) and the floats
        withUnsafeBytes(of: UInt32(part.nodeCosts.count)) { data.append(contentsOf: $0) }
        part.nodeCosts.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "p%03d.bin", i)))
    }
    print("av1seq: \(pictures.count) partitions written to \(dir)")
}
