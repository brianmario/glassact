// codecs — per-tile A/B of Compression.framework algorithms on changed tiles.
import Compression
import Foundation
import GlassActCodec
import GlassActCore

let codecsCommand = Command(
    name: "codecs",
    summary: "per-tile A/B of Compression.framework codecs on changed tiles",
    flags: [.trace, .int("frames", "<n>", 1...Int.max, "stop after N frames (default 120)")],
    run: { opts in
        let trace = opts.required("trace")
        try cmdCodecs(try openTrace(trace), traceName: trace, opts: opts)
    }
)

func cmdCodecs(_ reader: ScapReader, traceName: String, opts: Options) throws {
    let width = reader.header.width
    let height = reader.header.height
    let grid = TileGrid(width: width, height: height)
    let maxFrames = opts.int("frames", 120)
    let algos: [(String, compression_algorithm)] = [
        ("lz4", COMPRESSION_LZ4),
        ("lzfse", COMPRESSION_LZFSE),
        ("zlib", COMPRESSION_ZLIB),
        ("lzbitmap", COMPRESSION_LZBITMAP),
        ("brotli", COMPRESSION_BROTLI),
    ]
    let scratches: [UnsafeMutableRawPointer] = algos.map { _, a in
        .allocate(byteCount: max(1, compression_encode_scratch_buffer_size(a)), alignment: 16)
    }
    defer { for s in scratches { s.deallocate() } }

    let current = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    let previous = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { current.deallocate(); previous.deallocate() }
    var tight = [UInt8](repeating: 0, count: 64 * 64 * 4)
    var out = [UInt8](repeating: 0, count: 64 * 64 * 4 + 4096)
    var rects: [DirtyRect] = []
    var frames = 0
    var tiles = 0
    var totalIn = 0
    var totalOut = [Int](repeating: 0, count: algos.count)
    var rawFallback = [Int](repeating: 0, count: algos.count)
    var nanos = [UInt64](repeating: 0, count: algos.count)

    while frames < maxFrames, let _ = try reader.readFrame(rects: &rects, into: current) {
        defer {
            previous.copyMemory(from: UnsafeRawBufferPointer(current))
            frames += 1
        }
        guard frames > 0 else { continue }
        for idx in 0..<grid.count {
            let (x, y, tw, th) = grid.rect(of: idx)
            var changed = false
            for row in 0..<th {
                let offset = ((y + row) * width + x) * 4
                if memcmp(current.baseAddress! + offset, previous.baseAddress! + offset, tw * 4) != 0 {
                    changed = true
                    break
                }
            }
            guard changed else { continue }
            tiles += 1
            let tightLen = tight.withUnsafeMutableBytes { dst in
                TileOps.extract(src: UnsafeRawBufferPointer(current), bytesPerRow: width * 4,
                                x: x, y: y, tw: tw, th: th, into: dst)
            }
            totalIn += tightLen
            for (i, (_, algo)) in algos.enumerated() {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let n = tight.withUnsafeBytes { src in
                    out.withUnsafeMutableBytes { dst in
                        compression_encode_buffer(
                            dst.baseAddress!.assumingMemoryBound(to: UInt8.self), tightLen - 1,
                            src.baseAddress!.assumingMemoryBound(to: UInt8.self), tightLen,
                            scratches[i], algo)
                    }
                }
                nanos[i] += DispatchTime.now().uptimeNanoseconds - t0
                if n > 0 {
                    totalOut[i] += n
                } else {
                    totalOut[i] += tightLen // RAW fallback
                    rawFallback[i] += 1
                }
            }
        }
    }

    print("codecs: \(traceName) — \(frames) frames, \(tiles) changed tiles, raw \(formatBytes(totalIn))")
    for (i, (name, _)) in algos.enumerated() {
        let mbps = Double(totalIn) / 1_048_576 / (Double(nanos[i]) / 1_000_000_000)
        let pct = String(format: "%.1f", 100.0 * Double(totalOut[i]) / Double(totalIn))
        let avg = String(format: "%.0f", Double(totalOut[i]) / Double(max(tiles, 1)))
        let speed = String(format: "%.0f", mbps)
        print("  \(pad(name, 9)) \(pad(formatBytes(totalOut[i]), 10)) (\(pct)% of raw)  raw-fallbacks \(rawFallback[i])  encode \(speed) MB/s  avg \(avg) B/tile")
    }
}
