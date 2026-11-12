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
        .string("mix", "<trace.scap>[,<trace.scap>...]", "interleave the pictures with these traces' (each from the same --skip, resampled the same), in turn: every superblock changes from picture to picture"),
        .int("skip", "<n>", 0...100_000, "trace frames to skip first (default 0)"),
        .int("step", "<n>", 1...1000, "after --skip, every nth trace frame (default 1: each), for a long stretch of a trace in few pictures"),
        .int("width", "<px>", 64...8192, "resample frames to this width (default 1280)"),
        .int("q", "<0-63>", 0...63, "quantizer, libaom's scale; qindex 4q, 63 → 255 (default 20)"),
        .string("preset", "<name>", "analysis preset: slow, base, fast, faster, turbo (default), turbo2, turbo3"),
        .string("tiles", "<c>x<r>", "tiling, log2 of columns and rows (default 2x2)"),
        .int("repeat", "<n>", 1...1000, "encode the sequence n times over (for profiling; default 1)"),
        .bool("profile", "afterwards, time the GPU's analysis of the last picture shape by shape (analyzing every SB; with --inter, as an inter frame after the one before)"),
        .bool("serial", "finish every picture before starting the next one's analysis (no overlap)"),
        .string("prune", "<v>", "skip 32x32-and-up analysis where variance > v quantizer steps squared (default 4; 0 off, 1 faster)"),
        .int("leaf-tx", "<px>", 0...256, "largest block whose luma tx type the GPU searches (default 0: the closed loop searches its own)"),
        .bool("chroma-angles", "screen the six angled chroma modes too (13 instead of 7)"),
        .bool("no-deltas", "don't search angle deltas (faster on moving content, a little more bytes)"),
        .string("deltas-up-to", "<share>", "search angle deltas only in pictures that analyze at most this share of their superblocks (0–1; default 0.5; 1: always)"),
        .bool("inter", "inter frames after the first: 64x64s that are exact copies of the previous picture (unchanged, scrolled, dragged) as skip inter blocks, the rest intra or motion-searched"),
        .bool("no-motion-search", "with --inter: copies only, no motion search in the coded 64x64s"),
        .string("motion-skip", "<share>,<every>[,<k>]", "with --inter: an inter frame skips the motion search (as --no-motion-search) when the last k frames that searched (default 2) each found motion in less than this share of what they coded; every <every>th frame searches anyway (AV1HybridEncoder.motionSkip; default the encoder's, 0.2,8); off: every inter frame searches"),
        .bool("no-subpel", "with --inter: whole-sample motion vectors only in the motion search"),
        .string("inter-preset", "<name>", "with --inter: the inter frames' analysis preset (default: --preset's)"),
        .string("new-shapes", "<hex>", "with --inter: inter frames coding most of their 64x64s analyze only these shapes (GpParams.shapeMask bits, e.g. 13CF: no 8x16 or 16x8; 124F: squares, 4x8 and 8x4; 1249: squares, the default; off: every shape)"),
        .bool("intra-everywhere", "with --inter: search intra modes even where the inter residual quantizes to nothing"),
        .bool("motion-shares", "with --inter: print which inter frames searched for motion and what each found (as --motion-skip does)"),
        .bool("digest", "also print a hash (FNV-1a 64) of every frame's bytes, to check that a change keeps the stream the same"),
        .string("gpu-capture", "<path.gputrace>", "afterwards, write a Metal GPU capture of the last picture (with --inter, as an inter frame after the one before) for Xcode; run with MTL_CAPTURE_ENABLED=1"),
        .bool("no-planes", "with --inter: frames without their decoded pictures (the speed without copying them out; not decode-checked)"),
        .bool("no-cdf-carry", "with --inter: every inter frame starts from the default CDFs, not its reference's"),
        .bool("no-filters", "no deblocking or CDEF (tiles then decode alone as in their frame)"),
        .bool("no-intrabc", "key frames don't copy what repeats inside them (AV1 intra block copy, on by default)"),
        .bool("no-golden", "with --inter: inter frames copy only the picture before them, not GOLDEN_FRAME (a long-term picture: the end of a scene left)"),
        .int("key-delta", "<n>", -255...255, "the key frame's qindex this much from the inter frames' (AV1HybridEncoder.keyFrameQindexDelta; default the encoder's, -16; negative: finer)"),
        .bool("per-frame", "with --score-rgb: also each frame's bytes, RGB PSNR and SSIMULACRA2 (where scored), the hybrid's and libaom's, as lines \"frame <who> <i> <bytes> <psnr> <ssimulacra2 or ->\""),
        .int("long-term", "<n>", 1...7, "with --inter: long-term pictures kept for GOLDEN_FRAME (default the encoder's; 1: the end of the last scene left)"),
        .string("crop", "<w>x<h>+<x>+<y>", "code this rectangle of the trace's frames at their own size (not with --width or --score-rgb)"),
        .bool("no-reuse", "analyze every superblock of every picture (no reuse where the source is unchanged)"),
        .bool("cpu-decides", "decide chroma and search luma tx types on the CPU in the closed loop, not up front on the GPU"),
        .int("aom-speed", "<n>", 0...12, "also code the pictures as libaom realtime key frames at this speed"),
        .int("aom-threads", "<n>", 1...64, "libaom worker threads (default 8)"),
        .bool("score-rgb", "also score every frame as vquality scores HEVC: BT.601 luma of the decoded picture in BGRA against the trace frame (SSIM on 8x8 blocks, PSNR)"),
        .bool("aom-inter", "with --aom-speed: libaom codes one stream of inter frames after a key frame, not key frames"),
        .int("ssimulacra2-every", "<n>", 1...1000, "with --score-rgb: also SSIMULACRA2 (the ssimulacra2 binary on PATH) on every nth frame"),
        .int("stream-width", "<px>", 64...8192, "with --inter: the stream's width; the pictures are coded at --width inside it and shown scaled up to it (AV1 reduced frames), and --score-rgb scores them at its size"),
        .string("ivf", "<path>", "also write the hybrid's stream as IVF"),
        .string("ml-prune", "<weights.bin>", "learned pruning of the analysis with these weights instead of the shipped ones (prune_train's raw export: the level model, then the mode model's if present)"),
        .string("ml-mode-eps", "<p>", "learned mode pruning: a node keeps its likeliest modes until all but this much probability is kept (default: the encoder's)"),
        .string("dq", "<kind>:<n>", "per-64x64 qindex (delta-q): random:<n> offsets of up to ±n (a correctness check), or text:<n>, n finer where a 64x64 looks like text or UI (few distinct values, strong edges) and n coarser where it looks like a photo"),
        .string("inter-gate", "<f>", "with --inter, in pictures most of which is new: no motion windows or inter RD where nothing predicts better than f times a block's SAD to its mean (default 2; 0: off)"),
        .bool("no-rdoq", "the closed loop keeps the dead-zone quantizer's levels (no RDOQ)"),
        .bool("rdoq-trials", "the luma tx type search compares each type after RDOQ"),
        .int("rdoq-range", "<0-255>", 0...255, "RDOQ only in tx blocks whose source spans this many values (default 40; 0: all)"),
        .int("rdoq-coeffs", "<n>", 0...4096, "RDOQ only in tx blocks of at least this many coefficients (default the encoder's; 0: all; 17: not 4x4s)"),
        .string("tx-model-eps", "<p>", "the closed loop's learned tx type pruning at this eps (off by default)"),
        .string("tx-types", "<hex>", "the tx types the closed loop's luma search tries (bit t: type t; default E01: DCT, IDTX, V_DCT, H_DCT; FFFFFFFF: all)"),
        .bool("exact-tx-trials", "the tx type search's exact reconstruction SSE for every type (default: transform-domain distortion, stopping where DCT_DCT codes nothing)"),
        .bool("no-tx-search", "the closed loop codes DCT_DCT (or the analysis's types, with --leaf-tx) instead of searching luma tx types"),
        .int("two-steps", "<0-63>", 0...63, "with --inter, a measurement: code each picture twice in one stream, at this q first (as the other options say) and then at --q against the first's decoded picture (no copies, motion searched from no shift), one picture at a time; each step's bytes and scores are printed, and with --profile its GPU stages"),
        .bool("print-size", "print the trace's own width and height and stop (scripts/train-pruner)"),
        .bool("no-ml-modes", "learned pruning of tree levels only (every block screens all 13 modes)"),
        .bool("no-ml-chroma", "no learned chroma pruning (every leaf screens all its chroma modes, and CfL)"),
        .string("ml-chroma-eps", "<p>", "learned chroma pruning: a leaf keeps its likeliest chroma modes until all but this much probability is kept (default: the encoder's)"),
        .string("ml-eps", "<p>", "learned pruning: a cell keeps its likeliest levels until all but this much probability is kept (default 0.02)"),
        .bool("no-ml-prune", "no learned pruning (the variance rule instead)"),
        .int("ml-min-sbs", "<n>", 0...1_000_000, "learned pruning only in pictures of at least this many 64x64s (default the encoder's, 900: 1440p and up)"),
        .int("ml-min-coded", "<n>", 1...1_000_000, "with --ml-prune: also in pictures coding at least this many 64x64s"),
        .string("ml-over", "<share>", "with --ml-prune: only in pictures coding more than this share of their superblocks (default 0.5; key frames count as all)"),
        .string("dump-sse", "<dir>", "also write each decoded frame's squared error by 4x4 (UInt32, Y then U then V, rows of ceil(w/4)), the hybrid's as hNNN.sse and libaom's as aNNN.sse, and each picture's 64x64 luma statistics as sNNN.stats (Float32 per 64x64: variance, distinct values, share of strong horizontal or vertical edges), for per-block study"),
        .string("dump-partition", "<dir>", "instead of encoding: each picture's luma and the GPU's full search's leaf blocks (no pruning, no angle deltas), for offline study"),
    ],
    run: { opts in
        let trace = opts.required("trace")
        try cmdAV1Seq(try openTrace(trace), traceName: trace, opts: opts)
    }
)

func cmdAV1Seq(_ reader: ScapReader, traceName: String, opts: Options) throws {
    if opts.has("print-size") {
        print("\(reader.header.width) \(reader.header.height)")
        return
    }
    guard #available(macOS 27, *) else { throw BenchError("av1seq needs macOS 27 (MSL 4.1)") }
    guard glassact_aom_available() != 0 else { throw BenchError("av1seq needs libaom (Apple silicon)") }
    guard let device = MTLCreateSystemDefaultDevice() else { throw BenchError("no Metal device") }
    let count = opts.int("frames", 60), skip = opts.int("skip", 0), every = opts.int("step", 1)
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
    // --mix: after each of the trace's pictures, one from each of these traces in turn (their own
    // frames from --skip), the same size
    let mixes = try mixTraces(opts).map { try ScapReader(url: URL(fileURLWithPath: $0)) }
    let mixFull = mixes.map { UnsafeMutableRawBufferPointer.allocate(byteCount: $0.header.width * $0.header.height * 4, alignment: 64) }
    defer { mixFull.forEach { $0.deallocate() } }
    var mixIndex = [Int](repeating: 0, count: mixes.count), mixRects: [DirtyRect] = []
    func mixPicture(_ k: Int) throws -> YUV420? {
        guard crop == nil else { return nil }
        while let _ = try pooledRead(mixes[k], &mixRects, into: mixFull[k]) {
            defer { mixIndex[k] += 1 }
            guard mixIndex[k] >= skip else { continue }
            resample(mixFull[k], mixes[k].header.width, mixes[k].header.height, into: bgra, width, height)
            return try YUV420(bgra: bgra, width: width, height: height)
        }
        return nil
    }
    while pictures.count < count, let meta = try pooledRead(reader, &rects, into: full) {
        defer { index += 1 }
        guard index >= skip, (index - skip) % every == 0 else { continue }
        if pictures.count > 0 {
            for k in mixes.indices where pictures.count < count {
                guard let m = try mixPicture(k) else { break }
                pictures.append(m)
                stamps.append(meta.timestampUS)
            }
            if pictures.count == count { break }
        }
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
    encoder.goldenFrames = !opts.has("no-golden")
    if opts.has("long-term") { encoder.longTermReferences = opts.int("long-term", 1) }
    if opts.has("key-delta") { encoder.keyFrameQindexDelta = opts.int("key-delta", 0) }
    encoder.searchesAngleDeltas = !opts.has("no-deltas")
    if opts.has("no-ml-prune") {
        encoder.learnedPrune = nil
    } else {
        var lp = AV1HybridEncoder.defaultLearnedPrune
        if let path = opts.string("ml-prune") {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let weights = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let (level, mode, chroma) = (AV1PrunerWeights.cellV1.count, AV1PrunerWeights.modeV1.count, AV1PrunerWeights.chromaV1.count)
            guard [level, level + mode, level + mode + chroma].contains(weights.count)
            else { throw BenchError("--ml-prune: \(weights.count) floats, not \(level), \(level + mode) or \(level + mode + chroma) (levels, modes, chroma)") }
            lp.levelWeights = Array(weights.prefix(level))
            lp.modeWeights = weights.count > level ? Array(weights[level..<(level + mode)]) : nil
            lp.chromaWeights = weights.count > level + mode ? Array(weights.suffix(chroma)) : nil
        }
        if let v = opts.string("ml-eps").flatMap(Float.init) { lp.eps = v }
        if let v = opts.string("ml-mode-eps").flatMap(Float.init) { lp.modeEps = v }
        if let v = opts.string("ml-over").flatMap(Double.init) { lp.overShare = v }
        if opts.int("ml-min-coded", 0) > 0 { lp.minCoded = opts.int("ml-min-coded", 0) }
        encoder.learnedPruneMinSuperblocks = opts.int("ml-min-sbs", encoder.learnedPruneMinSuperblocks)
        if opts.has("no-ml-modes") { lp.modeWeights = nil }
        if let v = opts.string("ml-chroma-eps").flatMap(Float.init) { lp.chromaEps = v }
        if opts.has("no-ml-chroma") { lp.chromaWeights = nil }
        encoder.learnedPrune = lp
    }
    if let v = opts.string("deltas-up-to") {
        guard let f = Double(v), (0...1).contains(f) else { throw BenchError("--deltas-up-to \(v): a share 0–1") }
        encoder.angleDeltasUpToShare = f
    }
    encoder.interFrames = inter
    if opts.has("no-tx-search") { encoder.searchesTxTypes = false }
    if opts.has("no-rdoq") { encoder.usesRDOQ = false }
    if let v = opts.string("inter-gate").flatMap(Float.init) { encoder.interGate = v }
    if opts.has("rdoq-trials") { encoder.rdoqInTrials = true }
    encoder.rdoqMinRange = opts.int("rdoq-range", encoder.rdoqMinRange)
    encoder.rdoqMinCoefficients = opts.int("rdoq-coeffs", encoder.rdoqMinCoefficients)
    if let v = opts.string("tx-model-eps").flatMap(Float.init) { encoder.txModelEps = v }
    if opts.has("exact-tx-trials") { encoder.quickTxTrials = false }
    if let m = opts.string("tx-types") {
        guard let v = UInt32(m.replacingOccurrences(of: "0x", with: ""), radix: 16) else { throw BenchError("--tx-types: hex") }
        encoder.txTypes = v
    }
    if let spec = opts.string("dq") {
        let parts = spec.split(separator: ":")
        guard parts.count == 2, let amount = Int(parts[1]), (0...64).contains(amount), ["random", "text"].contains(parts[0])
        else { throw BenchError("--dq: random:<n> or text:<n>, n 0-64") }
        encoder.sbQindex = deltaQMap(kind: String(parts[0]), amount: amount)
    }
    encoder.streamSize = stream
    encoder.searchesMotion = !opts.has("no-motion-search")
    if let v = opts.string("motion-skip"), v == "off" {
        encoder.motionSkip = nil
    } else if let v = opts.string("motion-skip") {
        let parts = v.split(separator: ",").map(String.init)
        guard (2...3).contains(parts.count), let share = Double(parts[0]), (0...1).contains(share),
              let every = Int(parts[1]), every >= 1, let k = parts.count > 2 ? Int(parts[2]) : 2, k >= 1
        else { throw BenchError("--motion-skip \(v): <share 0-1>,<every >= 1>[,<k >= 1>], or off") }
        encoder.motionSkip = (share, every)
        encoder.motionSkipLookback = k
    }
    encoder.carriesCDFs = !opts.has("no-cdf-carry")
    encoder.returnsPlanes = !opts.has("no-planes")
    encoder.interSkipsIntra = !opts.has("intra-everywhere")
    if opts.string("new-shapes") == "off" {
        encoder.newPictureShapeMask = nil
    } else if let m = opts.string("new-shapes") {
        guard let v = Int32(m.replacingOccurrences(of: "0x", with: ""), radix: 16) else { throw BenchError("--new-shapes: hex") }
        encoder.newPictureShapeMask = v
    }
    if let name = opts.string("inter-preset") {
        guard let p = AV1MetalEncoder.Preset(rawValue: name) else { throw BenchError("--inter-preset: unknown") }
        encoder.interPreset = p
    }
    encoder.searchesSubpelMotion = !opts.has("no-subpel")
    if opts.has("leaf-tx") { encoder.leafTxSearchPixels = opts.int("leaf-tx", 0) }
    if opts.has("chroma-angles") { encoder.leafChromaAngledModes = true }
    if let v = opts.string("prune") {
        guard let f = Float(v), f >= 0 else { throw BenchError("--prune \(v): not a number >= 0") }
        encoder.busyBlockPrune = f
    }
    _ = try encoder.encode(picture(0), qindex: qindex)  // warm up: pipelines, caches, clocks

    // --two-steps: frames 2i and 2i + 1 are picture i's two steps
    let coarseQindex: Int? = opts.has("two-steps") ? (opts.int("two-steps", 0) == 63 ? 255 : 4 * opts.int("two-steps", 0)) : nil
    if coarseQindex != nil, !inter { throw BenchError("--two-steps: with --inter") }
    let steps = coarseQindex == nil ? 1 : 2
    var frames: [AV1HybridEncoder.Frame] = []
    frames.reserveCapacity(pictures.count * steps)
    let repeats = opts.int("repeat", 1)
    var outputAt: [Double] = []  // when each frame came out (overlapped runs)
    var seconds = 0.0
    for r in 0..<repeats {
        if r > 0 { frames.removeAll(keepingCapacity: true) }
        let t0 = CACurrentMediaTime()
        if let coarseQindex {
            try encoder.encodeTwoSteps(count: pictures.count, coarseQindex: coarseQindex, qindex: qindex, picture: { picture($0) },
                                       output: { _, _, f in frames.append(f) })
        } else if serial {
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
    func scorer() throws -> RGBScorer {
        try RGBScorer(trace: traceName, mix: mixTraces(opts), skip: skip, step: every, width: stream?.width ?? width, height: stream?.height ?? height,
                      coded: stream == nil ? nil : (width, height),
                      ssimulacra2Every: opts.has("ssimulacra2-every") ? opts.int("ssimulacra2-every", 1) : nil)
    }
    let rgb = scoreRGB ? try scorer() : nil
    // (--two-steps: the second step's, reading the trace again in step)
    let rgbAgain = scoreRGB && steps == 2 ? try scorer() : nil
    var psnrAgain = 0.0
    guard let decoder = glassact_aom_dec_create(4) else { throw BenchError("libaom: no decoder") }
    defer { glassact_aom_dec_destroy(decoder) }
    for (i, f) in frames.enumerated() {
        // intra frames each alone; a stream in order
        let decoded = inter ? try YUV420.decode(f.obu, width: width, height: height, with: decoder)
                            : try YUV420.decode(f.obu, width: width, height: height)
        for p in 0..<3 where !f.planes.isEmpty && decoded.planes[p] != f.planes[p] {
            throw BenchError("frame \(i): libaom's decode differs from the encoder's picture in plane \(p)")
        }
        if steps == 2, i % 2 == 1 {
            psnrAgain += decoded.psnrY(pictures[i / 2])
            try rgbAgain?.add(decoded)
            continue
        }
        psnr += decoded.psnrY(pictures[i / steps])
        try rgb?.add(decoded)
        if let dir = opts.string("dump-sse") {
            try writeSSE(decoded, pictures[i / steps], to: "\(dir)/h\(String(format: "%03d", i)).sse")
            try write64Stats(pictures[i / steps], to: "\(dir)/s\(String(format: "%03d", i)).stats")
        }
    }
    if let coarseQindex {
        // each step's bytes, quality and times, and the two together a picture
        for step in 0..<2 {
            let fs = stride(from: step, to: frames.count, by: 2).map { frames[$0] }
            let m = Double(fs.count)
            func ms(_ f: (AV1HybridEncoder.Timing) -> Double) -> Double { fs.map { f($0.timing) }.reduce(0, +) / m * 1000 }
            print(String(format: "  step %d     qindex %d · %@ a frame · PSNR-Y %.2f · GPU analysis %.1f · closed loop %.1f · filters %.1f (GPU %.1f) · writer %.1f (ms) · motion-searched blocks %.1f %% of the picture",
                         step + 1, step == 0 ? coarseQindex : qindex, formatBytes(fs.map(\.obu.count).reduce(0, +) / fs.count),
                         (step == 0 ? psnr : psnrAgain) / m, ms { $0.analysis }, ms { $0.closedLoop }, ms { $0.filters },
                         ms { $0.filtersGPU }, ms { $0.writer }, ms { $0.searched } / 10))
            if let s = step == 0 ? rgb : rgbAgain { print(s.summary("step \(step + 1)")) }
        }
        print(String(format: "  both       %@ a picture · all %d frames decoded exactly",
                     formatBytes(frames.map(\.obu.count).reduce(0, +) / pictures.count), frames.count))
        if opts.has("digest") {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for f in frames { for b in f.obu { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 } }
            print(String(format: "             stream digest %016llx (%d frames)", h, frames.count))
        }
        if let path = opts.string("ivf") {
            try writeIVF(frames.map(\.obu), width: stream?.width ?? width, height: stream?.height ?? height, to: path)
            print("             stream written to \(path)")
        }
        if opts.has("profile"), pictures.count > 1 {
            // the last picture's two steps after the one before it, each stage's best of 10
            encoder.profilesStages = true
            var best = [AV1MetalEncoder.StageTimes](repeating: AV1MetalEncoder.StageTimes(), count: 2)
            for run in 0..<10 {
                try encoder.encodeTwoSteps(count: 2, coarseQindex: coarseQindex, qindex: qindex,
                                           picture: { picture(pictures.count - 2 + $0) }, output: { i, step, _ in
                    guard i == 1 else { return }
                    let s = encoder.lastStages
                    if run == 0 { best[step] = s; return }
                    best[step].motionSearch = min(best[step].motionSearch, s.motionSearch)
                    best[step].interSearch = min(best[step].interSearch, s.interSearch)
                    best[step].analysis = min(best[step].analysis, s.analysis)
                    best[step].partition = min(best[step].partition, s.partition)
                    best[step].leaves = min(best[step].leaves, s.leaves)
                    best[step].mlPrune = min(best[step].mlPrune, s.mlPrune)
                })
            }
            for (step, st) in best.enumerated() {
                print(String(format: "  step %d GPU, stage by stage (ms): motion search %.2f · inter candidates %.2f · analysis %.1f · partition %.1f · leaves %.2f · learned pruning %.2f · sum %.1f",
                             step + 1, st.motionSearch * 1000, st.interSearch * 1000, st.analysis * 1000, st.partition * 1000,
                             st.leaves * 1000, st.mlPrune * 1000,
                             (st.motionSearch + st.interSearch + st.analysis + st.partition + st.leaves + st.mlPrune) * 1000))
            }
            encoder.profilesStages = false
        }
        return
    }
    let n = Double(frames.count)
    func mean(_ f: (AV1HybridEncoder.Timing) -> Double) -> Double { frames.map { f($0.timing) }.reduce(0, +) / n * 1000 }
    let bytes = frames.map(\.obu.count).reduce(0, +)
    print(String(format: "  hybrid     %.1f fps (%.1f ms a frame) · %@ a frame · PSNR-Y %.2f · all %d decoded exactly",
                 n / seconds, seconds / n * 1000, formatBytes(bytes / frames.count), psnr / n, frames.count))
    if let rgb { print(rgb.summary(stream.map { "hybrid at \(width)×\(height) shown at \($0.width)×\($0.height)" } ?? "hybrid")) }
    if let rgb, opts.has("per-frame") { rgb.printFrames("hybrid", bytes: frames.map(\.obu.count)) }
    if encoder.keyFrameQindex(qindex) != qindex {
        print("             key frame at qindex \(encoder.keyFrameQindex(qindex)), inter frames at \(qindex)")
    }
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
    print(String(format: "             per frame: GPU analysis %.1f · CPU chroma %.1f · closed loop %.1f · filters %.1f (GPU %.1f) · writer %.1f (ms) · kept: analysis %.0f %%, tiles %.0f %% · filtered %.0f %%",
                 mean { $0.analysis }, mean { $0.chroma }, mean { $0.closedLoop }, mean { $0.filters }, mean { $0.filtersGPU },
                 mean { $0.writer },
                 mean { $0.kept } / 10, mean { $0.keptTiles } / 10, mean { $0.filtered } / 10))

    if inter, frames.count > 1 {
        let rest = frames.dropFirst()
        let m = Double(rest.count)
        func avg(_ f: (AV1HybridEncoder.Timing) -> Double) -> Double { rest.map { f($0.timing) }.reduce(0, +) / m }
        let steady = outputAt.count == frames.count && frames.count > 1
            ? String(format: " · %.1f inter frames a second", Double(frames.count - 1) / (outputAt[frames.count - 1] - outputAt[0])) : ""
        print(String(format: "             key frame %@ · inter frames %@ on average%@ · copied %.1f %% of 64x64s (%.1f %% at a shift, %.1f %% from GOLDEN_FRAME) · deciding them %.2f ms · motion-searched blocks %.1f %% of the picture",
                     formatBytes(frames[0].obu.count), formatBytes(rest.map(\.obu.count).reduce(0, +) / rest.count), steady,
                     avg { $0.copied } * 100, avg { $0.shifted } * 100, avg { $0.copiedGolden } * 100, avg { $0.motion } * 1000,
                     avg { $0.searched } * 100))
        if encoder.motionSkip != nil || opts.has("motion-shares") {
            // which frames searched, what each found (of what it coded), and their GPU analysis
            let searched = rest.filter { $0.timing.searchedMotion }, skipped = rest.filter { !$0.timing.searchedMotion }
            func gpu(_ fs: [AV1HybridEncoder.Frame]) -> String {
                fs.isEmpty ? "-" : String(format: "%.1f", fs.map(\.timing.analysis).reduce(0, +) / Double(fs.count) * 1000)
            }
            let shares = rest.map { $0.timing.searchedMotion ? ($0.timing.motionFound < 0 ? "?" : String(format: "%.0f", $0.timing.motionFound * 100)) : "-" }
            print("             motion search: \(skipped.count) of \(rest.count) inter frames skipped it · GPU analysis \(gpu(searched)) ms searched, \(gpu(skipped)) skipped · found (% of coded; -: skipped) \(shares.joined(separator: " "))")
        }
        // GOLDEN_FRAME: how often each long-term picture was chosen, by its rank by use and by AV1 slot
        if !opts.has("no-golden") {
            var ranks = [Int](repeating: 0, count: 8), slots = [Int](repeating: 0, count: 8)
            for f in rest where f.timing.goldenSlot >= 0 {
                ranks[max(0, min(7, f.timing.goldenRank))] += 1
                slots[f.timing.goldenSlot] += 1
            }
            print("             GOLDEN_FRAME (\(encoder.longTermReferences) long-term) in \(slots.reduce(0, +)) of \(rest.count) inter frames · by rank of use \(ranks.prefix(encoder.longTermReferences).map(String.init).joined(separator: " ")) · by slot \(slots.map(String.init).joined(separator: " "))")
        }
    }

    if opts.has("profile") {
        // an inter frame: its copies aren't analyzed, so the analysis of the rest is kept on
        encoder.reusesAnalysis = inter
        encoder.profilesStages = true
        // isolated dispatches run at whatever clock the GPU is at, so take each stage's best of 10
        var st = AV1MetalEncoder.StageTimes()
        // (with --motion-skip, the last picture as the stream coded it: searched or not)
        let lastSearched = !inter || frames.count < 2 || frames[frames.count - 1].timing.searchedMotion
        let searches = encoder.searchesMotion
        encoder.searchesMotion = searches && lastSearched
        defer { encoder.searchesMotion = searches }
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
        let motion = inter ? String(format: "motion search %.2f · inter candidates %.2f%@ · ", st.motionSearch * 1000, st.interSearch * 1000,
                                    lastSearched ? "" : " (skipped)") : ""
        print(String(format: "  GPU, stage by stage (ms): %@analysis %.1f [%@] · partition %.1f · leaves %.2f%@",
                     motion, st.analysis * 1000, shapes.joined(separator: " · "), st.partition * 1000, st.leaves * 1000,
                     st.mlPrune > 0 ? String(format: " · learned pruning %.2f", st.mlPrune * 1000) : ""))
        print("             analysis's 32x32 forward DCT: \(encoder.analysisUsesMatrixUnits ? "matrix units (checked exact on this GPU)" : "fma passes")")
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
        let aomRGB = scoreRGB ? try RGBScorer(trace: traceName, mix: mixTraces(opts), skip: skip, step: every, width: width, height: height,
                                              ssimulacra2Every: opts.has("ssimulacra2-every") ? opts.int("ssimulacra2-every", 1) : nil) : nil
        for (i, s) in streams.enumerated() {
            let full = headerSize > 0 && (!aomInter || i == 0) ? Array(header.prefix(headerSize)) + s : s
            let decoded = aomInter ? try YUV420.decode(full, width: width, height: height, with: aomDecoder)
                                   : try YUV420.decode(full, width: width, height: height)
            aomPSNR += decoded.psnrY(pictures[i])
            try aomRGB?.add(decoded)
            if let dir = opts.string("dump-sse") { try writeSSE(decoded, pictures[i], to: "\(dir)/a\(String(format: "%03d", i)).sse") }
        }
        print(String(format: "  libaom s%d  %.1f fps (%.1f ms a frame, %d threads) · %@ a frame · PSNR-Y %.2f (%@)",
                     speed, n / aomSeconds, aomSeconds / n * 1000, threads, formatBytes(total / pictures.count), aomPSNR / n,
                     aomInter ? "inter frames" : "key frames"))
        if let aomRGB { print(aomRGB.summary("libaom")) }
        if let aomRGB, opts.has("per-frame") { aomRGB.printFrames("libaom", bytes: streams.map(\.count)) }
        if aomInter, streams.count > 1, let first = stamps.first, let last = stamps.last, last > first {
            let span = Double(last - first) / 1e6 * Double(stamps.count) / Double(stamps.count - 1)
            print(String(format: "             key frame %@ · inter frames %@ on average · %.1f inter frames a second · %.2f Mbit/s at the trace's timing",
                         formatBytes(streams[0].count), formatBytes(streams.dropFirst().map(\.count).reduce(0, +) / (streams.count - 1)),
                         Double(streams.count - 1) / (aomSeconds - keySeconds), Double(total) * 8 / span / 1e6))
        }
    }
}

/// `--dump-sse`: the decoded picture's squared error against the source by 4x4, plane by plane
/// (UInt32, rows of ceil(w/4) for each plane's own width).
func writeSSE(_ decoded: YUV420, _ source: YUV420, to path: String) throws {
    var out: [UInt32] = []
    for p in 0..<3 {
        let (w, h) = p == 0 ? (decoded.width, decoded.height) : (decoded.chromaWidth, decoded.chromaHeight)
        let (cols, rows) = ((w + 3) / 4, (h + 3) / 4)
        var map = [UInt32](repeating: 0, count: cols * rows)
        decoded.planes[p].withUnsafeBufferPointer { d in
            source.planes[p].withUnsafeBufferPointer { s in
                for y in 0..<h {
                    for x in 0..<w {
                        let e = Int(d[y * w + x]) - Int(s[y * w + x])
                        map[(y / 4) * cols + x / 4] &+= UInt32(e * e)
                    }
                }
            }
        }
        out += map
    }
    try out.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: path)) }
}

/// `--dump-sse`: each 64x64's luma statistics (Float32 ×3, raster order): variance, distinct
/// values, and the share of samples with a horizontal or vertical step over 32.
func write64Stats(_ source: YUV420, to path: String) throws {
    let (w, h) = (source.width, source.height)
    let (cols, rows) = ((w + 63) / 64, (h + 63) / 64)
    var out = [Float](repeating: 0, count: cols * rows * 3)
    source.planes[0].withUnsafeBufferPointer { y in
        for sb in 0..<(cols * rows) {
            let (x0, y0) = ((sb % cols) * 64, (sb / cols) * 64)
            var seen = [Bool](repeating: false, count: 256)
            var distinct = 0, edges = 0, n = 0, sum = 0, sum2 = 0
            for r in y0..<min(y0 + 64, h) {
                for c in x0..<min(x0 + 64, w) {
                    let v = Int(y[r * w + c])
                    if !seen[v] { seen[v] = true; distinct += 1 }
                    if (c + 1 < w && abs(v - Int(y[r * w + c + 1])) > 32) || (r + 1 < h && abs(v - Int(y[(r + 1) * w + c])) > 32) { edges += 1 }
                    sum += v; sum2 += v * v; n += 1
                }
            }
            let mean = Double(sum) / Double(n)
            out[sb * 3] = Float(Double(sum2) / Double(n) - mean * mean)
            out[sb * 3 + 1] = Float(distinct)
            out[sb * 3 + 2] = Float(edges) / Float(n)
        }
    }
    try out.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: path)) }
}

/// `--mix`'s traces (comma-separated).
func mixTraces(_ opts: Options) -> [String] {
    opts.string("mix").map { $0.split(separator: ",").map(String.init) } ?? []
}

/// `--score-rgb`: decoded pictures scored as vquality scores HEVC (lumaQuality: BT.601 luma of BGRA,
/// SSIM on 8x8 blocks and PSNR), against the trace's frames resampled to the canvas as av1seq
/// resamples them before converting to 4:2:0. Reads the trace a second time, in step.
/// A trace frame, read in an autorelease pool of its own: FileHandle's reads return autoreleased
/// buffers, which a command-line loop otherwise keeps until it ends (each frame's compressed bytes,
/// tens of MB a frame of new content at 5K: --skip and --step read many).
func pooledRead(_ r: ScapReader, _ rects: inout [DirtyRect], into f: UnsafeMutableRawBufferPointer) throws -> ScapFrameMeta? {
    try autoreleasepool { try r.readFrame(rects: &rects, into: f) }
}

final class RGBScorer {
    let reader: ScapReader
    /// `--mix`: the traces whose pictures come in turn after each of the trace's, and their frames
    let mix: [ScapReader], mixFull: [UnsafeMutableRawBufferPointer]
    /// `--ssimulacra2-every`: its scorer and period, and the pairs added
    let ssimu2: SSIMULACRA2Scorer?, ssimu2Every: Int
    var ssimu2Count = 0
    let width: Int, height: Int
    /// Reduced frames: the size they're coded at, scaled up to width × height to be scored.
    let coded: (width: Int, height: Int)?
    let full: UnsafeMutableRawBufferPointer, reference: UnsafeMutableRawBufferPointer, shown: UnsafeMutableRawBufferPointer
    let small: UnsafeMutableRawBufferPointer
    var rects: [DirtyRect] = []
    var ssim = 0.0, psnr = 0.0, frames = 0
    /// Each frame's PSNR (`--per-frame`), and the SSIMULACRA2 scores (scored once: the scorer's
    /// files go when it has)
    var psnrs: [Double] = []
    private var ssimu2Scores: [Double]?
    /// `--step`: the trace's frames apart (its pictures read so far)
    let step: Int
    var read = 0

    init(trace: String, mix mixTraces: [String] = [], skip: Int, step: Int = 1, width: Int, height: Int,
         coded: (width: Int, height: Int)? = nil, ssimulacra2Every: Int? = nil) throws {
        reader = try openTrace(trace)
        mix = try mixTraces.map { try ScapReader(url: URL(fileURLWithPath: $0)) }
        mixFull = mix.map { .allocate(byteCount: $0.header.width * $0.header.height * 4, alignment: 64) }
        ssimu2 = try ssimulacra2Every.flatMap { _ in try SSIMULACRA2Scorer.make(setting: nil) }
        ssimu2Every = ssimulacra2Every ?? 0
        if ssimulacra2Every != nil, ssimu2 == nil { throw BenchError("--ssimulacra2-every: no ssimulacra2 on PATH") }
        self.width = width
        self.height = height
        self.coded = coded
        self.step = step
        full = .allocate(byteCount: reader.header.width * reader.header.height * 4, alignment: 64)
        reference = .allocate(byteCount: width * height * 4, alignment: 64)
        shown = .allocate(byteCount: width * height * 4, alignment: 64)
        small = .allocate(byteCount: coded.map { $0.width * $0.height * 4 } ?? 0, alignment: 64)
        for _ in 0..<skip { _ = try pooledRead(reader, &rects, into: full) }
        for (m, f) in zip(mix, mixFull) { for _ in 0..<skip { _ = try pooledRead(m, &rects, into: f) } }
    }

    deinit {
        full.deallocate()
        mixFull.forEach { $0.deallocate() }
        reference.deallocate()
        shown.deallocate()
        small.deallocate()
    }

    func add(_ decoded: YUV420) throws {
        let k = frames % (mix.count + 1)
        let (r, f) = k == 0 ? (reader, full) : (mix[k - 1], mixFull[k - 1])
        if k == 0 {
            if read > 0 { for _ in 1..<step { _ = try pooledRead(r, &rects, into: f) } }
            read += 1
        }
        guard try pooledRead(r, &rects, into: f) != nil else { throw BenchError("--score-rgb: the trace ended early") }
        resample(f, r.header.width, r.header.height, into: reference, width, height)
        if let coded {
            try decoded.bgra(into: small)
            resample(small, coded.width, coded.height, into: shown, width, height)
        } else {
            try decoded.bgra(into: shown)
        }
        let (s, p) = lumaQuality(UnsafeRawBufferPointer(reference), UnsafeRawBufferPointer(shown), width, height)
        if let ssimu2, frames % ssimu2Every == 0 {
            _ = try ssimu2.add(reference: reference, distorted: shown, width: width, height: height)
            ssimu2Count += 1
        }
        ssim += s
        if p.isFinite { psnr += p }
        psnrs.append(p)
        frames += 1
    }

    func ssimulacra2Scores() throws -> [Double] {
        if let ssimu2Scores { return ssimu2Scores }
        let scores = try ssimu2?.scoreAll() ?? []
        ssimu2Scores = scores
        return scores
    }

    /// `--per-frame`: a line a frame, `frame <name> <i> <bytes> <psnr> <ssimulacra2 or ->`.
    func printFrames(_ name: String, bytes: [Int]) {
        let scores = (try? ssimulacra2Scores()) ?? []
        for (i, p) in psnrs.enumerated() {
            let k = ssimu2Every > 0 && i % ssimu2Every == 0 ? i / ssimu2Every : -1
            let s = k >= 0 && k < scores.count ? String(format: "%.3f", scores[k]) : "-"
            print(String(format: "frame %@ %d %d %.4f %@", name, i, i < bytes.count ? bytes[i] : 0, p, s))
        }
    }

    func summary(_ name: String) -> String {
        var line = String(format: "             %@, scored as vquality: SSIM mean %.4f · PSNR mean %.2f dB", name,
                          ssim / Double(max(1, frames)), psnr / Double(max(1, frames)))
        if ssimu2 != nil, let scores = try? ssimulacra2Scores(), !scores.isEmpty {
            line += String(format: " · SSIMULACRA2 mean %.2f, min %.2f (%d frames)", scores.reduce(0, +) / Double(scores.count),
                           scores.min() ?? 0, scores.count)
        }
        return line
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

/// `--dump-partition`: for each picture, `<dir>/pNNN.bin`, the learned pruning's training data
/// (rust/av1/examples/prune_train.rs reads it): "GAML", version 2, then tagged sections: PICT
/// (size, qindex, luma), CHRO (chroma), LEAF (the full search's leaves, with the GPU's chroma
/// decisions), NODE (the DP's node costs), MODE (each analyzed block's best luma candidate).
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
    metal.dumpsTrainingData = true
    for (i, p) in pictures.enumerated() {
        let part = try metal.partition(y: p.planes[0], u: p.planes[1], v: p.planes[2], width: width, height: height, qindex: qindex)
        // "GAML", version 2, then tagged sections (4-byte tag, UInt32 length, payload); readers
        // skip tags they don't know, so a new model's data is a new section
        var data = Data("GAML".utf8)
        func u32(_ v: Int, into d: inout Data) { withUnsafeBytes(of: UInt32(v)) { d.append(contentsOf: $0) } }
        u32(2, into: &data)
        func section(_ tag: String, _ body: (inout Data) -> Void) {
            var payload = Data()
            body(&payload)
            data.append(contentsOf: Data(tag.utf8))
            u32(payload.count, into: &data)
            data.append(payload)
        }
        section("PICT") { d in  // width, height, qindex, the luma plane
            for v in [width, height, qindex] { u32(v, into: &d) }
            d.append(contentsOf: p.planes[0].prefix(width * height))
        }
        section("CHRO") { d in  // the U and V planes, ((width + 1) / 2) x ((height + 1) / 2) each
            let n = ((width + 1) / 2) * ((height + 1) / 2)
            d.append(contentsOf: p.planes[1].prefix(n))
            d.append(contentsOf: p.planes[2].prefix(n))
        }
        section("LEAF") { d in part.blocks.withUnsafeBytes { d.append(contentsOf: $0) } }  // av1g_block records
        section("NODE") { d in part.nodeCosts.withUnsafeBytes { d.append(contentsOf: $0) } }  // GP_DP_DEBUG floats per SB
        section("MODE") { d in  // per shape: bsize, columns, rows, each block's best candidate
            for m in part.blockModes {
                for v in [m.shape, m.columns, m.rows] { u32(v, into: &d) }
                d.append(contentsOf: m.modes)
            }
        }
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "p%03d.bin", i)))
    }
    print("av1seq: \(pictures.count) partitions written to \(dir)")
}

/// `--dq`: a per-64x64 qindex map from the picture's luma (AV1HybridEncoder.sbQindex).
@available(macOS 27, *)
func deltaQMap(kind: String, amount: Int) -> @Sendable (AV1HybridEncoder.Picture, Int) -> [UInt8]? {
    { p, qindex in
        let (cols, rows) = ((p.width + 63) / 64, (p.height + 63) / 64)
        var map = [UInt8](repeating: UInt8(qindex), count: cols * rows)
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15 &* UInt64(qindex + 1)
        for sb in 0..<map.count {
            var offset = 0
            if kind == "random" {
                rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                offset = Int(rng % UInt64(2 * amount + 1)) - amount
            } else {
                // few distinct values and strong edges: text or UI; many distinct values: a photo
                let (x0, y0) = ((sb % cols) * 64, (sb / cols) * 64)
                var seen = [Bool](repeating: false, count: 256)
                var distinct = 0, edges = 0, n = 0
                for y in y0..<min(y0 + 64, p.height) {
                    for x in x0..<min(x0 + 64, p.width) {
                        let v = Int(p.y[y * p.width + x])
                        if !seen[v] { seen[v] = true; distinct += 1 }
                        if x + 1 < p.width, abs(v - Int(p.y[y * p.width + x + 1])) > 48 { edges += 1 }
                        n += 1
                    }
                }
                if distinct > 1, distinct <= 64, edges * 50 >= n { offset = -amount }
                else if distinct > 160 { offset = amount }
            }
            map[sb] = UInt8(clamping: max(1, min(255, qindex + offset)))
        }
        return map
    }
}
