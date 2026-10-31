// av1still — one trace frame as an AV1 key frame, two ways: the Metal port of
// av1gpu (research, GlassActAV1: GPU analysis, partition and closed loop, GPU
// strength search and filters, av1core's CPU writer) and libaom's realtime
// screen-content encoder (the retired AV1 video path's), both at fixed
// quantizers. Size, luma PSNR, SSIMULACRA2 against the source, and time per
// stage. Every Metal stream is decoded by libaom and must equal the GPU's
// filtered picture exactly.
import Accelerate
import AV1Core
import Foundation
import GlassActAV1
import GlassActCore
import libaom
import Metal
import QuartzCore

let av1StillCommand = Command(
    name: "av1still",
    summary: "one frame as an AV1 key frame: the Metal encoder (research) vs libaom realtime, at fixed quantizers",
    flags: [
        .trace,
        .int("frame", "<n>", 0...Int.max, "frame index (default 100)"),
        .string("q", "<list>", "libaom quantizers 0–63, comma-separated (default 16,24,32,40); the Metal encoder uses the same qindex (4q, 63 → 255)"),
        .int("width", "<px>", 64...8192, "resample the frame to this width first (default: the trace's)"),
        .string("aom-speed", "<list>", "libaom realtime speeds, comma-separated (default 9, the product's)"),
        .int("aom-threads", "<n>", 1...64, "libaom worker threads (default 8)"),
        .int("repeat", "<n>", 1...100, "time each Metal encode n times and report the median (default 3)"),
        .string("ssimulacra2", "<path|off>", "SSIMULACRA2 binary (default: `ssimulacra2` on PATH, if any)"),
        .string("preset", "<list>", "Metal encoder presets, comma-separated: slow, base (default), fast, faster, turbo, turbo2, turbo3"),
        .string("tiles", "<list>", "Metal encoder tilings: log2 of the tile columns and rows, comma-separated, e.g. 2x2 (default auto, the fewest legal)"),
        .bool("gpu-entropy", "also time the GPU entropy coder (output checked against the CPU writer's)"),
    ],
    run: { opts in
        let trace = opts.required("trace")
        try cmdAV1Still(try openTrace(trace), traceName: trace, opts: opts)
    }
)

func cmdAV1Still(_ reader: ScapReader, traceName: String, opts: Options) throws {
    guard #available(macOS 27, *) else { throw BenchError("av1still needs macOS 27 (MSL 4.1)") }
    guard glassact_aom_available() != 0 else { throw BenchError("av1still needs libaom (Apple silicon)") }
    guard let device = MTLCreateSystemDefaultDevice() else { throw BenchError("no Metal device") }
    func list(_ name: String, _ fallback: [Int], _ range: ClosedRange<Int>) throws -> [Int] {
        guard let text = opts.string(name) else { return fallback }
        let values = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.allSatisfy(range.contains) else { throw BenchError("--\(name) \(text): not a list in \(range)") }
        return values
    }
    let quantizers = try list("q", [16, 24, 32, 40], 0...63)
    let speeds = try list("aom-speed", [9], 0...12)
    let threads = opts.int("aom-threads", 8)
    let repeats = opts.int("repeat", 3)
    let tilings = try (opts.string("tiles") ?? "auto").split(separator: ",").map { t -> (Int, Int) in
        if t == "auto" { return (-1, -1) }
        let parts = t.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts.allSatisfy((0...6).contains) else { throw BenchError("--tiles \(t): not auto or <c>x<r>") }
        return (parts[0], parts[1])
    }

    // the frame, as BGRA and as BT.709 video-range 4:2:0 (what both encoders take)
    let srcW = reader.header.width, srcH = reader.header.height
    let frameIdx = opts.int("frame", 100)
    let full = UnsafeMutableRawBufferPointer.allocate(byteCount: srcW * srcH * 4, alignment: 64)
    defer { full.deallocate() }
    var rects: [DirtyRect] = []
    for i in 0...frameIdx where try reader.readFrame(rects: &rects, into: full) == nil {
        throw BenchError("trace has only \(i) frames")
    }
    let width = opts.int("width", srcW) & ~1, height = (srcH * width / srcW) & ~1
    let bgra = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { bgra.deallocate() }
    resample(full, srcW, srcH, into: bgra, width, height)
    let source = try YUV420(bgra: bgra, width: width, height: height)
    let scorer = try SSIMULACRA2Scorer.make(setting: opts.string("ssimulacra2"))
    print("av1still: \(traceName) frame \(frameIdx), \(width)×\(height)\(scorer == nil ? " (no ssimulacra2 on PATH)" : "")")

    struct Row {
        var name: String, q: Int, bytes: Int, psnr: Double, scoreIndex: Int?
        var timing: String
    }
    var rows: [Row] = []
    var distorted: [UnsafeMutableRawBufferPointer] = []
    defer { distorted.forEach { $0.deallocate() } }
    func score(_ yuv: YUV420) throws -> Int? {
        guard let scorer else { return nil }
        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
        distorted.append(out)
        try yuv.bgra(into: out)
        return try scorer.add(reference: bgra, distorted: out, width: width, height: height)
    }

    // the Metal encoder
    let encoder = try AV1MetalEncoder(device: device)
    encoder.profilesStages = true
    let postfilter = try AV1MetalPostfilter(device: device)
    let entropy = opts.has("gpu-entropy") ? try AV1MetalEntropy(device: device) : nil
    let miCols = 2 * ((width + 7) >> 3), miRows = 2 * ((height + 7) >> 3), sbCols = (miCols + 15) >> 4
    let padded = source.padded(width: miCols * 4, height: miRows * 4)
    let presets = try (opts.string("preset") ?? "base").split(separator: ",").map { name -> AV1MetalEncoder.Preset in
        guard let p = AV1MetalEncoder.Preset(rawValue: String(name)) else { throw BenchError("--preset \(name): unknown") }
        return p
    }
    for preset in presets {
    encoder.preset = preset
    for tiling in tilings {
    encoder.tiling = tiling
    let tileName = (preset == .base ? "metal" : preset.rawValue) + (tiling.0 < 0 ? "" : " \(tiling.0)x\(tiling.1)")
    for q in quantizers {
        let qindex = q == 63 ? 255 : 4 * q
        var stageRuns: [AV1MetalEncoder.StageTimes] = []
        var encoded: AV1MetalEncoder.Encoded?
        for _ in 0..<repeats {
            encoded = try source.withPlanes { y, u, v in
                try encoder.encode(y: y, u: u, v: v, width: width, height: height, qindex: qindex)
            }
            stageRuns.append(encoder.lastStages)
        }
        guard var encoded else { continue }
        func median(_ f: (AV1MetalEncoder.StageTimes) -> Double) -> Double {
            let s = stageRuns.map(f).sorted()
            return s[s.count / 2]
        }

        let t0 = CACurrentMediaTime()
        let search = try withPlaneArrays(encoded.filterInput) { planes in
            try withPlaneArrays(padded) { sources in
                try encoded.blocks.withUnsafeBufferPointer { blocks in
                    try postfilter.search(params: encoded.params, blocks: blocks, planes: planes, source: sources)
                }
            }
        }
        let searchWall = CACurrentMediaTime() - t0
        for i in encoded.blocks.indices {
            let b = encoded.blocks[i]
            encoded.blocks[i].cdef_idx = max(0, search.superblockCDEF[(Int(b.mi_row) >> 4) * sbCols + (Int(b.mi_col) >> 4)])
        }
        encoded.params = search.params

        // av1core's writer: symbol coding only (the GPU reconstructed already)
        var obu: [UInt8] = []
        var writerTimes: [Double] = []
        for _ in 0..<repeats {
            var output = av1g_output()
            let t1 = CACurrentMediaTime()
            let rc = encoded.withRecord { record -> Int32 in
                var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_TD) | UInt32(AV1G_ENC_BITSTREAM_ONLY), seq_level_idx: -1)
                return av1g_encode(&record, &options, &output)
            }
            writerTimes.append(CACurrentMediaTime() - t1)
            defer { av1g_output_free(&output) }
            guard rc == AV1G_OK else { throw BenchError("q\(q): av1core rejected the record (\(rc))") }
            obu = Array(UnsafeBufferPointer(start: output.obu, count: output.obu_size))
        }
        let writer = writerTimes.sorted()[writerTimes.count / 2]
        // the same writer reconstructing too: the decoder's half of a CPU closed loop
        var reconTimes: [Double] = []
        for _ in 0..<repeats {
            var output = av1g_output()
            let t1 = CACurrentMediaTime()
            _ = encoded.withRecord { record -> Int32 in
                var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_TD) | UInt32(AV1G_ENC_PREFILTER_RECON), seq_level_idx: -1)
                return av1g_encode(&record, &options, &output)
            }
            reconTimes.append(CACurrentMediaTime() - t1)
            av1g_output_free(&output)
        }
        let writerRecon = reconTimes.sorted()[reconTimes.count / 2]
        var entropyNote = ""
        if let entropy {
            let gpu = try encoded.withRecord { try entropy.encode($0) }
            guard gpu == obu else { throw BenchError("q\(q): the GPU entropy coder's stream isn't the CPU writer's") }
            entropyNote = String(format: " · GPU entropy %.1f", entropy.lastGPUSeconds * 1000)
        }

        // decoded by libaom: must be exactly the GPU's filtered picture
        let decoded = try YUV420.decode(obu, width: width, height: height)
        for p in 0..<3 where decoded.planes[p] != search.planes[p] {
            throw BenchError("q\(q): libaom's decode differs from the GPU's picture in plane \(p)")
        }
        let s = median { $0.analysis }, d = median { $0.partition }, c = median { $0.closedLoop }
        let timing = String(format: "GPU %.1f (analysis %.1f · partition %.1f · closed loop %.1f in %d steps) · filters %.1f GPU / %.1f wall · writer %.1f (with recon %.1f)%@ · wall %.0f",
                            (s + d + c) * 1000, s * 1000, d * 1000, c * 1000, encoder.lastStages.wavefrontSteps,
                            postfilter.lastGPUSeconds * 1000, searchWall * 1000, writer * 1000, writerRecon * 1000, entropyNote,
                            (median { $0.wall } + searchWall + writer) * 1000)
        rows.append(Row(name: tileName, q: q, bytes: obu.count, psnr: decoded.psnrY(source), scoreIndex: try score(decoded), timing: timing))
    }
    }
    }

    // libaom realtime key frames
    for speed in speeds {
        for q in quantizers {
            var options = glassact_aom_enc_options(speed: Int32(speed), vbr: 1)
            guard let enc = glassact_aom_enc_create_with(Int32(width), Int32(height), Int32(threads), 200_000, &options)
            else { throw BenchError("libaom: no encoder") }
            defer { glassact_aom_enc_destroy(enc) }
            _ = glassact_aom_enc_set_max_quantizer(enc, Int32(q))
            _ = glassact_aom_enc_set_min_quantizer(enc, Int32(q))
            var stream: [UInt8] = []
            let t0 = CACurrentMediaTime()
            let rc = source.withFrame { frame in withUnsafePointer(to: frame) { glassact_aom_enc_encode(enc, $0, 0, 16_667, 1) } }
            guard rc == 0 else { throw BenchError("libaom: \(String(cString: glassact_aom_enc_error(enc)))") }
            var size = 0, key: Int32 = 0
            while let p = glassact_aom_enc_next_packet(enc, &size, &key) { stream += UnsafeBufferPointer(start: p, count: size) }
            let wall = CACurrentMediaTime() - t0
            var header = [UInt8](repeating: 0, count: 256)
            let headerSize = Int(glassact_aom_enc_sequence_header(enc, &header, header.count))
            let full = stream.starts(with: [0x12, 0x00]) || headerSize <= 0 ? stream : Array(header.prefix(headerSize)) + stream
            let decoded = try YUV420.decode(full, width: width, height: height)
            rows.append(Row(name: "libaom s\(speed)", q: q, bytes: stream.count, psnr: decoded.psnrY(source),
                            scoreIndex: try score(decoded), timing: String(format: "CPU wall %.0f (%d threads)", wall * 1000, threads)))
        }
    }

    let scores = try scorer?.scoreAll() ?? []
    print("  \(pad("encoder", 16)) \(pad("q", 4)) \(pad("size", 10)) \(pad("PSNR-Y", 8)) \(pad("SSIMU2", 7)) time (ms)")
    for r in rows {
        let ss = r.scoreIndex.map { String(format: "%.2f", scores[$0]) } ?? "–"
        print("  \(pad(r.name, 16)) \(pad("\(r.q)", 4)) \(pad(formatBytes(r.bytes), 10)) \(pad(String(format: "%.2f", r.psnr), 8)) \(pad(ss, 7)) \(r.timing)")
    }
}

private func withPlaneArrays<R>(_ planes: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) throws -> R) rethrows -> R {
    try planes[0].withUnsafeBufferPointer { y in
        try planes[1].withUnsafeBufferPointer { u in
            try planes[2].withUnsafeBufferPointer { v in try body([y.baseAddress!, u.baseAddress!, v.baseAddress!]) }
        }
    }
}

/// An 8-bit 4:2:0 picture, tightly packed: Y width × height, U and V half
/// that (rounded up). BT.709 video range, as the Host's encoders take it.
struct YUV420 {
    let width: Int, height: Int
    var planes: [[UInt8]]

    var chromaWidth: Int { (width + 1) / 2 }
    var chromaHeight: Int { (height + 1) / 2 }

    init(width: Int, height: Int, planes: [[UInt8]]) {
        self.width = width
        self.height = height
        self.planes = planes
    }

    init(bgra: UnsafeMutableRawBufferPointer, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        var y = [UInt8](repeating: 0, count: width * height), u = [UInt8](repeating: 0, count: cw * ch), v = u
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var matrix = vImage_ARGBToYpCbCrMatrix(R_Yp: 0.2126, G_Yp: 0.7152, B_Yp: 0.0722,
                                               R_Cb: -0.2126 / 1.8556, G_Cb: -0.7152 / 1.8556,
                                               B_Cb_R_Cr: 0.5, G_Cr: -0.7152 / 1.5748, B_Cr: -0.0722 / 1.5748)
        var conversion = vImage_ARGBToYpCbCr()
        guard vImageConvert_ARGBToYpCbCr_GenerateConversion(&matrix, &range, &conversion, kvImageARGB8888,
                                                            kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { throw BenchError("vImage: no BGRA → 4:2:0 conversion") }
        var permute: [UInt8] = [3, 2, 1, 0]  // BGRA → ARGB
        let rc = y.withUnsafeMutableBytes { yp in
            u.withUnsafeMutableBytes { up in
                v.withUnsafeMutableBytes { vp in
                    var s = vImage_Buffer(data: bgra.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    var dy = vImage_Buffer(data: yp.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                    var du = vImage_Buffer(data: up.baseAddress, height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: cw)
                    var dv = vImage_Buffer(data: vp.baseAddress, height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: cw)
                    return vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&s, &dy, &du, &dv, &conversion, &permute, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        guard rc == kvImageNoError else { throw BenchError("vImage: BGRA → 4:2:0 failed (\(rc))") }
        planes = [y, u, v]
    }

    func bgra(into out: UnsafeMutableRawBufferPointer) throws {
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var matrix = vImage_YpCbCrToARGBMatrix(Yp: 1, Cr_R: 1.5748, Cr_G: -0.4681, Cb_G: -0.1873, Cb_B: 1.8556)
        var conversion = vImage_YpCbCrToARGB()
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(&matrix, &range, &conversion, kvImage420Yp8_Cb8_Cr8,
                                                            kvImageARGB8888, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { throw BenchError("vImage: no 4:2:0 → BGRA conversion") }
        var permute: [UInt8] = [3, 2, 1, 0]
        let cw = chromaWidth, ch = chromaHeight
        var py = planes[0], pu = planes[1], pv = planes[2]
        let rc = py.withUnsafeMutableBytes { yp in
            pu.withUnsafeMutableBytes { up in
                pv.withUnsafeMutableBytes { vp in
                    var sy = vImage_Buffer(data: yp.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                    var su = vImage_Buffer(data: up.baseAddress, height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: cw)
                    var sv = vImage_Buffer(data: vp.baseAddress, height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: cw)
                    var d = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    return vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&sy, &su, &sv, &d, &conversion, &permute, 255, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        guard rc == kvImageNoError else { throw BenchError("vImage: 4:2:0 → BGRA failed (\(rc))") }
    }

    /// Edge-replicated to `width` × `height` (chroma half that).
    func padded(width pw: Int, height ph: Int) -> [[UInt8]] {
        let sizes = [(width, height, pw, ph), (chromaWidth, chromaHeight, pw / 2, ph / 2), (chromaWidth, chromaHeight, pw / 2, ph / 2)]
        return (0..<3).map { p in
            let (w, h, tw, th) = sizes[p]
            var out = [UInt8](repeating: 0, count: tw * th)
            for y in 0..<th {
                let sr = min(y, h - 1) * w
                for x in 0..<tw { out[y * tw + x] = planes[p][sr + min(x, w - 1)] }
            }
            return out
        }
    }

    func withPlanes<R>(_ body: (UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafePointer<UInt8>) throws -> R) rethrows -> R {
        try planes[0].withUnsafeBufferPointer { y in
            try planes[1].withUnsafeBufferPointer { u in
                try planes[2].withUnsafeBufferPointer { v in try body(y.baseAddress!, u.baseAddress!, v.baseAddress!) }
            }
        }
    }

    func withFrame<R>(_ body: (glassact_aom_frame) throws -> R) rethrows -> R {
        try withPlanes { y, u, v in
            var f = glassact_aom_frame()
            f.planes = (y, u, v)
            f.strides = (Int32(width), Int32(chromaWidth), Int32(chromaWidth))
            f.width = Int32(width)
            f.height = Int32(height)
            return try body(f)
        }
    }

    static func decode(_ stream: [UInt8], width: Int, height: Int) throws -> YUV420 {
        guard let dec = glassact_aom_dec_create(4) else { throw BenchError("libaom: no decoder") }
        defer { glassact_aom_dec_destroy(dec) }
        var f = glassact_aom_frame()
        guard glassact_aom_dec_decode(dec, stream, stream.count, &f) == 0 else { throw BenchError("libaom couldn't decode the stream") }
        guard Int(f.width) == width, Int(f.height) == height else { throw BenchError("libaom decoded \(f.width)×\(f.height)") }
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        let sizes = [(width, height), (cw, ch), (cw, ch)]
        let ptrs = [f.planes.0, f.planes.1, f.planes.2], strides = [f.strides.0, f.strides.1, f.strides.2]
        let planes = (0..<3).map { p -> [UInt8] in
            let (w, h) = sizes[p]
            var out = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { out[y * w + x] = ptrs[p]![y * Int(strides[p]) + x] } }
            return out
        }
        return YUV420(width: width, height: height, planes: planes)
    }

    func psnrY(_ reference: YUV420) -> Double {
        var sse = 0
        for i in 0..<(width * height) {
            let d = Int(planes[0][i]) - Int(reference.planes[0][i])
            sse += d * d
        }
        return sse == 0 ? .infinity : 10 * log10(255 * 255 * Double(width * height) / Double(sse))
    }
}
