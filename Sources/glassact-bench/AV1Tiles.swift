// av1tiles — changed 64×64 tiles (a `dumptiles` corpus) through the codecs a tile record could
// use, in process: VP8L lossless (the tile path's codec, at its efforts) and the Metal/CPU hybrid
// AV1 encoder (research) coding each tile as its own 4:2:0 key frame at fixed quantizers, or with
// --chroma 444 as a 4:4:4 one (the High profile). Sizes and time per tile; with --out, each AV1
// quantizer's decoded tiles as a corpus for scoring (SSIMULACRA2 per tile against the source, e.g.
// with scripts outside the package).
import AV1Core
import Foundation
import GlassActAV1
import GlassActCodec
import libaom
import Metal
import QuartzCore

let av1TilesCommand = Command(
    name: "av1tiles",
    summary: "changed 64×64 tiles (a dumptiles corpus) as VP8L lossless and as standalone AV1 key frames (research): size, time",
    flags: [
        .string("corpus", "<file>", required: true, "tiles, raw BGRA 64×64, concatenated (glassact-bench dumptiles)"),
        .string("q", "<list>", "AV1 quantizers 0–63 (libaom's scale), comma-separated (default 8,20,32,44)"),
        .string("out", "<prefix>", "write each quantizer's decoded tiles to <prefix>-q<q>.raw (BGRA, the corpus's order)"),
        .string("obus", "<prefix>", "with --chroma 444: write each quantizer's streams to <prefix>-q<q>.obus (per tile a little-endian u32 length and its OBUs; rust/av1 examples/tile_stats reads them)"),
        .string("preset", "<name>", "with --chroma 444: the analysis's preset (AV1MetalEncoder.Preset; default the encoder's)"),
        .string("shapes", "<hex>", "with --chroma 444: the analysis's shapes (GpParams.shapeMask bits, hex), in place of the preset's"),
        .string("tx-types", "<hex>", "with --chroma 444: the closed loop's luma tx types (AV1HybridEncoder.txTypes bits, hex)"),
        .bool("no-444-palettes", "with --chroma 444: no palettes and every shape, as 4:2:0 pictures are analyzed (AV1HybridEncoder.chroma444Palettes off: the encoder before 2026-11-16's palettes)"),
        .bool("palette", "with --chroma 444: intra blocks may be luma palette blocks, decided by cost (AV1HybridEncoder.palette); prints how many are"),
        .string("chroma", "<420|444>", "AV1 key frames' chroma: 420 (default; BT.709 video range) or 444 (High profile; BT.601 full range, as the sequence header signals; every tile checked against libaom's decode)"),
    ],
    run: { opts in try cmdAV1Tiles(opts: opts) }
)

func cmdAV1Tiles(opts: Options) throws {
    guard #available(macOS 27, *) else { throw BenchError("av1tiles needs macOS 27 (MSL 4.1)") }
    guard let device = MTLCreateSystemDefaultDevice() else { throw BenchError("no Metal device") }
    let path = opts.required("corpus")
    let corpus = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
    let side = 64, tileBytes = side * side * 4
    guard corpus.count >= tileBytes, corpus.count % tileBytes == 0 else { throw BenchError("--corpus: not whole 64×64 BGRA tiles") }
    let n = corpus.count / tileBytes
    let qs = try (opts.string("q") ?? "8,20,32,44").split(separator: ",").map { s -> Int in
        guard let q = Int(s), (0...63).contains(q) else { throw BenchError("--q: \(s)") }
        return q
    }
    let chroma = opts.string("chroma") ?? "420"
    guard chroma == "420" || chroma == "444" else { throw BenchError("--chroma \(chroma): not 420 or 444") }
    if chroma == "444" {
        guard glassact_aom_available() != 0 else { throw BenchError("--chroma 444 needs libaom (Apple silicon) for its decode check") }
        print("av1tiles: \(path), \(n) tiles, AV1 as 4:4:4")
    } else {
        print("av1tiles: \(path), \(n) tiles")
    }
    var dst = [UInt8](repeating: 0, count: tileBytes * 2)

    // VP8L lossless, as the tile path codes a tile (0: not smaller than raw, sent raw)
    for effort: Int32 in [1, 4, 9] {
        var bytes = 0, raw = 0
        let t0 = CACurrentMediaTime()
        for i in 0..<n {
            let size = corpus.withUnsafeBytes { src in
                dst.withUnsafeMutableBytes {
                    WebPTile.encodeLossless(src: UnsafeRawBufferPointer(rebasing: src[i * tileBytes..<(i + 1) * tileBytes]),
                                            width: side, height: side, effort: effort, dst: $0)
                }
            }
            if size == 0 { raw += 1 }
            bytes += size == 0 ? tileBytes : size
        }
        let seconds = CACurrentMediaTime() - t0
        print(String(format: "  VP8L z%d      %7.1f B a tile (lossless) · %6.1f µs a tile, one thread%@",
                     effort, Double(bytes) / Double(n), seconds / Double(n) * 1e6, raw > 0 ? " · \(raw) sent raw" : ""))
    }

    if chroma == "444" {
        try av1Tiles444(corpus: corpus, n: n, qs: qs, device: device, out: opts.string("out"), palette: opts.has("palette"),
                        obus: opts.string("obus"), preset: try opts.string("preset").map {
                            guard let p = AV1MetalEncoder.Preset(rawValue: $0) else { throw BenchError("--preset \($0)") }
                            return p
                        }, shapes: opts.string("shapes").flatMap { Int32($0, radix: 16) },
                        txTypes: opts.string("tx-types").flatMap { UInt32($0, radix: 16) },
                        palettes444: !opts.has("no-444-palettes"))
        return
    }

    // the 4:2:0 conversion alone (BT.709 video range, what the encoder codes): its ceiling
    if let prefix = opts.string("out") {
        var conv = [UInt8]()
        conv.reserveCapacity(corpus.count)
        var t = [UInt8](repeating: 0, count: tileBytes), back = t
        for i in 0..<n {
            t.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: corpus.withUnsafeBytes { $0 }[i * tileBytes..<(i + 1) * tileBytes])) }
            let yuv = try t.withUnsafeMutableBytes { try YUV420(bgra: $0, width: side, height: side) }
            try back.withUnsafeMutableBytes { try yuv.bgra(into: $0) }
            conv += back
        }
        try Data(conv).write(to: URL(fileURLWithPath: "\(prefix)-conv.raw"))
    }

    // each tile as its own AV1 key frame (4:2:0, so lossy in colour even at the finest quantizer)
    let encoder = try AV1HybridEncoder(device: device)
    encoder.reusesAnalysis = false
    encoder.tiling = (0, 0)
    var tile = [UInt8](repeating: 0, count: tileBytes)
    for q in qs {
        let qindex = q == 63 ? 255 : max(1, 4 * q)
        var bytes = 0, payload = 0
        var decoded = [UInt8]()
        decoded.reserveCapacity(corpus.count)
        var seconds = 0.0
        for i in 0..<n {
            tile.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: corpus.withUnsafeBytes { $0 }[i * tileBytes..<(i + 1) * tileBytes])) }
            let yuv = try tile.withUnsafeMutableBytes { try YUV420(bgra: $0, width: side, height: side) }
            let picture = AV1HybridEncoder.Picture(y: yuv.planes[0], u: yuv.planes[1], v: yuv.planes[2], width: side, height: side)
            let t0 = CACurrentMediaTime()
            let frame = try encoder.encode(picture, qindex: qindex)
            seconds += CACurrentMediaTime() - t0
            bytes += frame.obu.count
            var parsed: UnsafeMutablePointer<av1g_parsed>?
            guard av1g_parse(frame.obu, frame.obu.count, &parsed) == AV1G_OK, let p = parsed else {
                throw BenchError("tile \(i): the stream doesn't parse")
            }
            payload += Int(p.pointee.tile_bytes[0])
            av1g_parsed_free(p)
            if opts.has("out") {
                let back = try YUV420.decode(frame.obu, width: side, height: side)
                guard back.planes == frame.planes else { throw BenchError("tile \(i): libaom's decode differs from the encoder's picture") }
                var out = [UInt8](repeating: 0, count: tileBytes)
                try out.withUnsafeMutableBytes { try back.bgra(into: $0) }
                decoded += out
            }
        }
        print(String(format: "  AV1 q%-2d       %7.1f B a tile (stream; tile payload %.1f B) · %6.1f µs a tile (one at a time, GPU round trips included)",
                     q, Double(bytes) / Double(n), Double(payload) / Double(n), seconds / Double(n) * 1e6))
        if let prefix = opts.string("out") {
            try Data(decoded).write(to: URL(fileURLWithPath: "\(prefix)-q\(q).raw"))
        }
    }
}

/// av1tiles --chroma 444: each tile as its own 4:4:4 key frame, from BT.601 full-range YCbCr (what
/// the still picture's sequence header signals: matrix_coefficients 6, full range; avifenc's
/// default too). Every tile is decoded by libaom and must equal the encoder's picture exactly; with
/// `out`, the decoded tiles (and the conversion alone) back to BGRA by the same matrix.
@available(macOS 27, *)
private func av1Tiles444(corpus: [UInt8], n: Int, qs: [Int], device: any MTLDevice, out prefix: String?, palette: Bool,
                         obus: String? = nil, preset: AV1MetalEncoder.Preset? = nil, shapes: Int32? = nil, txTypes: UInt32? = nil, palettes444: Bool = true) throws {
    let side = 64, tileBytes = side * side * 4
    func tile(_ i: Int) -> YUV444 {
        corpus.withUnsafeBytes { YUV444(bgra: UnsafeRawBufferPointer(rebasing: $0[i * tileBytes..<(i + 1) * tileBytes]), width: side, height: side) }
    }
    // the 4:4:4 conversion alone: its ceiling
    if let prefix {
        var conv = [UInt8]()
        conv.reserveCapacity(corpus.count)
        var back = [UInt8](repeating: 0, count: tileBytes)
        for i in 0..<n {
            let yuv = tile(i)
            back.withUnsafeMutableBytes { yuv.bgra(into: $0) }
            conv += back
        }
        try Data(conv).write(to: URL(fileURLWithPath: "\(prefix)-conv.raw"))
    }

    let encoder = try AV1HybridEncoder(device: device)
    encoder.reusesAnalysis = false
    encoder.tiling = (0, 0)
    encoder.palette = palette
    encoder.chroma444Palettes = palettes444
    if let preset { encoder.preset = preset }
    if let shapes { encoder.shapeMask = shapes }
    if let txTypes { encoder.txTypes = txTypes }
    for q in qs {
        let qindex = q == 63 ? 255 : max(1, 4 * q)
        let before = encoder.paletteStats
        var bytes = 0, payload = 0, copied = 0
        var streams = [UInt8]()
        var decoded = [UInt8]()
        decoded.reserveCapacity(prefix == nil ? 0 : corpus.count)
        var seconds = 0.0
        for i in 0..<n {
            let yuv = tile(i)
            let picture = AV1HybridEncoder.Picture(y: yuv.planes[0], u: yuv.planes[1], v: yuv.planes[2], width: side, height: side,
                                                   chroma444: true)
            let t0 = CACurrentMediaTime()
            let frame = try encoder.encode(picture, qindex: qindex)
            seconds += CACurrentMediaTime() - t0
            bytes += frame.obu.count
            if obus != nil {
                withUnsafeBytes(of: UInt32(frame.obu.count).littleEndian) { streams += $0 }
                streams += frame.obu
            }
            if frame.timing.intraCopied > 0 { copied += 1 }
            var parsed: UnsafeMutablePointer<av1g_parsed>?
            guard av1g_parse(frame.obu, frame.obu.count, &parsed) == AV1G_OK, let p = parsed else {
                throw BenchError("tile \(i): the stream doesn't parse")
            }
            payload += Int(p.pointee.tile_bytes[0])
            let format = p.pointee.rec.fp.chroma_format
            av1g_parsed_free(p)
            guard format == UInt8(AV1G_CHROMA_444), frame.params.chroma_format == UInt8(AV1G_CHROMA_444) else {
                throw BenchError("tile \(i): the stream isn't 4:4:4")
            }
            let back = try YUV444.decode(frame.obu, width: side, height: side)
            guard back.planes == frame.planes else { throw BenchError("tile \(i): libaom's decode differs from the encoder's picture") }
            if prefix != nil {
                var out = [UInt8](repeating: 0, count: tileBytes)
                out.withUnsafeMutableBytes { back.bgra(into: $0) }
                decoded += out
            }
        }
        print(String(format: "  AV1 4:4:4 q%-2d %7.1f B a tile (stream; tile payload %.1f B) · %6.1f µs a tile (one at a time, GPU round trips included) · %d copy (intra block copy), the rest unfiltered · libaom decodes all exactly",
                     q, Double(bytes) / Double(n), Double(payload) / Double(n), seconds / Double(n) * 1e6, copied))
        let after = encoder.paletteStats
        if after.count > 5, before.count > 5, after[1] > before[1] {
            print(String(format: "    palette: %.0f of %.0f eligible blocks tried, %.0f chosen (%.1f %% of the eligible area); %.0f chroma palettes",
                         after[2] - before[2], after[1] - before[1], after[3] - before[3], 100 * (after[5] - before[5]) / max(1, after[4] - before[4]),
                         after.count > 11 ? after[11] - before[11] : 0))
        }
        if let prefix {
            try Data(decoded).write(to: URL(fileURLWithPath: "\(prefix)-q\(q).raw"))
        }
        if let obus {
            try Data(streams).write(to: URL(fileURLWithPath: "\(obus)-q\(q).obus"))
        }
    }
}

/// An 8-bit 4:4:4 picture, tightly packed (Y, U and V width × height): YCbCr full range with
/// BT.601's matrix (ITU-T H.273: matrix_coefficients 6, Kr 0.299, Kb 0.114; Cb and Cr offset 128).
struct YUV444 {
    let width: Int, height: Int
    var planes: [[UInt8]]

    init(width: Int, height: Int, planes: [[UInt8]]) {
        (self.width, self.height, self.planes) = (width, height, planes)
    }

    private static let (kr, kb) = (0.299, 0.114)
    private static func sample(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x.rounded()))) }

    init(bgra: UnsafeRawBufferPointer, width: Int, height: Int) {
        (self.width, self.height) = (width, height)
        let n = width * height, kg = 1 - Self.kr - Self.kb
        var y = [UInt8](repeating: 0, count: n), u = y, v = y
        for i in 0..<n {
            let b = Double(bgra[4 * i]), g = Double(bgra[4 * i + 1]), r = Double(bgra[4 * i + 2])
            let l = Self.kr * r + kg * g + Self.kb * b
            y[i] = Self.sample(l)
            u[i] = Self.sample((b - l) / (2 * (1 - Self.kb)) + 128)
            v[i] = Self.sample((r - l) / (2 * (1 - Self.kr)) + 128)
        }
        planes = [y, u, v]
    }

    /// BGRA (alpha 255), by the inverse of the same matrix.
    func bgra(into out: UnsafeMutableRawBufferPointer) {
        let kg = 1 - Self.kr - Self.kb
        for i in 0..<(width * height) {
            let l = Double(planes[0][i]), cb = Double(planes[1][i]) - 128, cr = Double(planes[2][i]) - 128
            let r = l + 2 * (1 - Self.kr) * cr, b = l + 2 * (1 - Self.kb) * cb
            let g = (l - Self.kr * r - Self.kb * b) / kg
            (out[4 * i], out[4 * i + 1], out[4 * i + 2], out[4 * i + 3]) = (Self.sample(b), Self.sample(g), Self.sample(r), 255)
        }
    }

    /// A 4:4:4 still picture decoded by libaom (the caller has checked that the stream is 4:4:4:
    /// the shim's frame doesn't say).
    static func decode(_ stream: [UInt8], width: Int, height: Int) throws -> YUV444 {
        guard let dec = glassact_aom_dec_create(1) else { throw BenchError("libaom: no decoder") }
        defer { glassact_aom_dec_destroy(dec) }
        var f = glassact_aom_frame()
        guard glassact_aom_dec_decode(dec, stream, stream.count, &f) == 0 else { throw BenchError("libaom couldn't decode the stream") }
        guard Int(f.width) == width, Int(f.height) == height else { throw BenchError("libaom decoded \(f.width)×\(f.height)") }
        let ptrs = [f.planes.0, f.planes.1, f.planes.2], strides = [f.strides.0, f.strides.1, f.strides.2]
        let planes = try (0..<3).map { p -> [UInt8] in
            guard let src = ptrs[p], Int(strides[p]) >= width else { throw BenchError("libaom: plane \(p) isn't 4:4:4's") }
            var out = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height { for x in 0..<width { out[y * width + x] = src[y * Int(strides[p]) + x] } }
            return out
        }
        return YUV444(width: width, height: height, planes: planes)
    }
}
