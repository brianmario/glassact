// av1tiles — changed 64×64 tiles (a `dumptiles` corpus) through the codecs a tile record could
// use, in process: VP8L lossless (the tile path's codec, at its efforts) and the Metal/CPU hybrid
// AV1 encoder (research) coding each tile as its own 4:2:0 key frame at fixed quantizers. Sizes and
// time per tile; with --out, each AV1 quantizer's decoded tiles as a corpus for scoring
// (SSIMULACRA2 per tile against the source, e.g. with scripts outside the package).
import AV1Core
import Foundation
import GlassActAV1
import GlassActCodec
import Metal
import QuartzCore

let av1TilesCommand = Command(
    name: "av1tiles",
    summary: "changed 64×64 tiles (a dumptiles corpus) as VP8L lossless and as standalone AV1 key frames (research): size, time",
    flags: [
        .string("corpus", "<file>", required: true, "tiles, raw BGRA 64×64, concatenated (glassact-bench dumptiles)"),
        .string("q", "<list>", "AV1 quantizers 0–63 (libaom's scale), comma-separated (default 8,20,32,44)"),
        .string("out", "<prefix>", "write each quantizer's decoded tiles to <prefix>-q<q>.raw (BGRA, the corpus's order)"),
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
    print("av1tiles: \(path), \(n) tiles")
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
