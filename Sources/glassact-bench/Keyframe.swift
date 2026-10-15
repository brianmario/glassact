// keyframe — whole-frame vs per-tile lossless on one frame: does one image
// win? (The data behind lossless keyframes, §4.7.)
import Foundation
import GlassActCodec
import GlassActCore

let keyframeCommand = Command(
    name: "keyframe",
    summary: "one frame: per-tile best-of vs whole-frame LZ4/LZBITMAP/VP8L (+ striped VP8L)",
    flags: [
        .trace,
        .int("frame", "<n>", 0...Int.max, "frame index to measure (default 100)"),
    ],
    run: { opts in
        let trace = opts.required("trace")
        try cmdKeyframe(try openTrace(trace), traceName: trace, opts: opts)
    }
)

func cmdKeyframe(_ reader: ScapReader, traceName: String, opts: Options) throws {
    let width = reader.header.width
    let height = reader.header.height
    let frameIdx = opts.int("frame", 100)
    let frame = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { frame.deallocate() }
    var rects: [DirtyRect] = []
    var i = 0
    while i <= frameIdx {
        guard try reader.readFrame(rects: &rects, into: frame) != nil else {
            throw BenchError("trace has only \(i) frames")
        }
        i += 1
    }
    print("keyframe: \(traceName) frame \(frameIdx) (\(width)x\(height), raw \(formatBytes(width * height * 4)))")

    func timed(_ name: String, _ body: () -> Int) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let bytes = body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        if bytes > 0 {
            print(String(format: "  %@ %@  (%.0f ms)", pad(name, 26), pad(formatBytes(bytes), 12), ms))
        } else {
            print("  \(pad(name, 26)) failed")
        }
    }

    // Baseline: a per-tile cold start — best-of across the whole grid.
    let grid = TileGrid(width: width, height: height)
    let lz4 = LZ4Codec()
    var tight = [UInt8](repeating: 0, count: 64 * 64 * 4)
    var out = [UInt8](repeating: 0, count: 64 * 64 * 4 + 4096)
    timed("per-tile best-of (today)") {
        var total = 0
        for idx in 0..<grid.count {
            let (x, y, tw, th) = grid.rect(of: idx)
            let tightLen = tight.withUnsafeMutableBytes { dst in
                TileOps.extract(src: UnsafeRawBufferPointer(frame), bytesPerRow: width * 4,
                                x: x, y: y, tw: tw, th: th, into: dst)
            }
            var best = tightLen
            tight.withUnsafeBytes { src in
                let s = UnsafeRawBufferPointer(rebasing: src[0..<tightLen])
                out.withUnsafeMutableBytes { d in
                    let a = lz4.encode(src: s, dst: d)
                    if a > 0 { best = min(best, a) }
                    let b = lz4.encodeBitmap(src: s, dst: d)
                    if b > 0 { best = min(best, b) }
                    let w = WebPTile.encodeLossless(src: s, width: tw, height: th, effort: 4, dst: d)
                    if w > 0 { best = min(best, w) }
                }
            }
            total += best
        }
        return total
    }

    // Whole-frame candidates.
    let big = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { big.deallocate() }
    timed("whole-frame LZ4") {
        lz4.encode(src: UnsafeRawBufferPointer(frame), dst: big)
    }
    timed("whole-frame LZBITMAP") {
        lz4.encodeBitmap(src: UnsafeRawBufferPointer(frame), dst: big)
    }
    for effort in [2, 4, 6] {
        timed("whole-frame VP8L z\(effort)") {
            WebPTile.encodeLossless(src: UnsafeRawBufferPointer(frame),
                                    width: width, height: height, effort: Int32(effort), dst: big)
        }
    }

    // Striped VP8L: N horizontal bands encoded in parallel — closes the
    // single-threaded wall-time gap at a small ratio cost (cross-band
    // redundancy is lost; each band still spans full width).
    for stripes in [4, 8] {
        timed("VP8L z4 ×\(stripes) stripes (par)") {
            let bandH = (height + stripes - 1) / stripes
            // Per-stripe results through a pointer box: writing a shared Swift
            // array from concurrentPerform (even at distinct indices) races
            // on the array's storage.
            struct Stripes: @unchecked Sendable {
                let frame: UnsafeMutableRawBufferPointer
                let outs: [UnsafeMutableRawBufferPointer]
                let sizes: UnsafeMutableBufferPointer<Int>
            }
            let job = Stripes(
                frame: frame,
                outs: (0..<stripes).map { _ in
                    UnsafeMutableRawBufferPointer.allocate(byteCount: width * bandH * 4 + 4096, alignment: 64)
                },
                sizes: .allocate(capacity: stripes))
            job.sizes.initialize(repeating: 0)
            defer {
                for o in job.outs { o.deallocate() }
                job.sizes.deallocate()
            }
            DispatchQueue.concurrentPerform(iterations: stripes) { i in
                let y0 = i * bandH
                let h = min(bandH, height - y0)
                guard h > 0 else { return }
                let band = UnsafeRawBufferPointer(
                    start: job.frame.baseAddress!.advanced(by: y0 * width * 4), count: h * width * 4)
                job.sizes[i] = WebPTile.encodeLossless(src: band, width: width, height: h,
                                                      effort: 4, dst: job.outs[i])
            }
            return job.sizes.contains(0) ? 0 : job.sizes.reduce(0, +)
        }
    }
}
