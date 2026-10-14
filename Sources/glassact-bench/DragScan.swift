// dragscan — rigid-shift forensics: does probe content from frame A reappear
// byte-identically in frame B at some (dx,dy)? An exact match over a
// textured probe also proves the content is opaque — alpha-blended pixels
// over a different background cannot survive a move byte-for-byte.
import Foundation
import GlassActCore

let dragScanCommand = Command(
    name: "dragscan",
    summary: "rigid-shift forensics: find probe content from frame A in frame B at some (dx,dy)",
    flags: [
        .trace,
        .ints("frames", "<a,b>", count: 2, required: true, "the two frame indices to compare"),
        .ints("probe", "<x,y,w,h>", count: 4, required: true, "probe rect in frame A"),
        .int("search", "<px>", 0...4096, "search radius (default 192)"),
        .ints("window", "<x,y,w,h>", count: 4,
              "also report exact-match fractions over this rect under the winning offset"),
    ],
    validate: { opts in
        func fail(_ message: String) -> UsageError { UsageError(message: message, command: opts.command) }
        let pair = opts.ints("frames") ?? []
        guard pair.count == 2, pair[0] >= 0, pair[1] >= 0, pair[0] != pair[1] else {
            throw fail("--frames expects two distinct non-negative frame indices a,b")
        }
        let p = opts.ints("probe") ?? []
        guard p.count == 4, p[0] >= 0, p[1] >= 0, p[2] > 0, p[3] > 0 else {
            throw fail("--probe expects x,y ≥ 0 and w,h > 0")
        }
        if let q = opts.ints("window"), q[0] < 0 || q[1] < 0 || q[2] <= 0 || q[3] <= 0 {
            throw fail("--window expects x,y ≥ 0 and w,h > 0")
        }
    },
    run: { opts in
        try cmdDragScan(try openTrace(opts.required("trace")), opts: opts)
    }
)

func cmdDragScan(_ reader: ScapReader, opts: Options) throws {
    let width = reader.header.width
    let height = reader.header.height
    let pair = opts.ints("frames") ?? []
    let p = opts.ints("probe") ?? []
    let px = p[0], py = p[1], pw = p[2], ph = p[3]
    guard px + pw <= width, py + ph <= height else {
        throw BenchError("probe (\(px),\(py) \(pw)×\(ph)) is outside the \(width)×\(height) trace")
    }
    let search = opts.int("search", 192)

    let bufA = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    let bufB = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { bufA.deallocate(); bufB.deallocate() }
    var rects: [DirtyRect] = []
    let lo = min(pair[0], pair[1]), hi = max(pair[0], pair[1])
    var idx = 0
    while idx < lo {
        guard try reader.skimFrame() != nil else { throw BenchError("trace ended before frame \(lo)") }
        idx += 1
    }
    guard try reader.readFrame(rects: &rects, into: lo == pair[0] ? bufA : bufB) != nil else {
        throw BenchError("trace ended before frame \(lo)")
    }
    idx += 1
    while idx < hi {
        guard try reader.skimFrame() != nil else { throw BenchError("trace ended before frame \(hi)") }
        idx += 1
    }
    guard try reader.readFrame(rects: &rects, into: hi == pair[0] ? bufA : bufB) != nil else {
        throw BenchError("trace ended before frame \(hi)")
    }

    let a = UnsafeRawBufferPointer(bufA)
    let b = UnsafeRawBufferPointer(bufB)
    @inline(__always) func px32(_ buf: UnsafeRawBufferPointer, _ x: Int, _ y: Int) -> UInt32 {
        buf.loadUnaligned(fromByteOffset: (y * width + x) * 4, as: UInt32.self)
    }

    // Pass 1: sampled SAD (every 8th pixel) across the search window.
    var best = (dx: 0, dy: 0, sad: Int.max)
    var exactCandidates: [(Int, Int)] = []
    for dy in -search...search {
        let sy0 = py + dy
        guard sy0 >= 0, sy0 + ph <= height else { continue }
        for dx in -search...search {
            let sx0 = px + dx
            guard sx0 >= 0, sx0 + pw <= width else { continue }
            var sad = 0
            var yy = 0
            while yy < ph {
                var xx = 0
                while xx < pw {
                    let ca = px32(a, px + xx, py + yy)
                    let cb = px32(b, sx0 + xx, sy0 + yy)
                    if ca != cb {
                        var shift: UInt32 = 0
                        while shift < 32 {
                            sad += abs(Int((ca >> shift) & 0xFF) - Int((cb >> shift) & 0xFF))
                            shift += 8
                        }
                    }
                    xx += 8
                }
                yy += 8
                if sad > 0 && sad >= best.sad { break }
            }
            if sad == 0 { exactCandidates.append((dx, dy)) }
            if sad < best.sad || (sad == best.sad && abs(dx) + abs(dy) < abs(best.dx) + abs(best.dy)) {
                best = (dx, dy, sad)
            }
        }
    }

    // Pass 2: verify sampled-exact candidates byte-for-byte.
    var exact: [(Int, Int)] = []
    for (dx, dy) in exactCandidates {
        var ok = true
        for yy in 0..<ph {
            let ra = a.baseAddress!.advanced(by: ((py + yy) * width + px) * 4)
            let rb = b.baseAddress!.advanced(by: ((py + dy + yy) * width + px + dx) * 4)
            if memcmp(ra, rb, pw * 4) != 0 { ok = false; break }
        }
        if ok { exact.append((dx, dy)) }
    }

    print("dragscan frames \(pair[0])→\(pair[1]) probe (\(px),\(py) \(pw)×\(ph)) search ±\(search)")
    if exact.isEmpty {
        print("  no byte-exact rigid match")
    } else {
        for (dx, dy) in exact { print("  EXACT match at (dx \(dx), dy \(dy))") }
    }
    let samples = ((ph + 7) / 8) * ((pw + 7) / 8)
    print(String(format: "  best sampled offset (dx %d, dy %d): mean |diff| %.2f per channel-byte",
                 best.dx, best.dy, Double(best.sad) / Double(samples * 4)))

    // Optional: under the winning offset, exact-match fractions over a larger
    // rect (separates a rigid interior from re-rendered edges/shadows).
    if let q = opts.ints("window") {
        let wx = q[0], wy = q[1], ww = q[2], wh = q[3]
        let (dx, dy) = exact.first ?? (best.dx, best.dy)
        var matchRows = 0, rowsChecked = 0
        var matchPx = 0, pxChecked = 0
        for yy in 0..<wh {
            let ay = wy + yy, by = ay + dy
            guard ay >= 0, ay < height, by >= 0, by < height else { continue }
            let x0 = max(wx, -dx), x1 = min(wx + ww, width, width - dx)
            guard x1 > x0 else { continue }
            rowsChecked += 1
            pxChecked += x1 - x0
            let ra = a.baseAddress!.advanced(by: (ay * width + x0) * 4)
            let rb = b.baseAddress!.advanced(by: (by * width + x0 + dx) * 4)
            if memcmp(ra, rb, (x1 - x0) * 4) == 0 {
                matchRows += 1
                matchPx += x1 - x0
            } else {
                for xx in 0..<(x1 - x0) where px32(a, x0 + xx, ay) == px32(b, x0 + xx + dx, by) {
                    matchPx += 1
                }
            }
        }
        print(String(format: "  window (%d,%d %d×%d) under (dx %d, dy %d): rows exact %d/%d (%.1f%%), pixels equal %.1f%%",
                     wx, wy, ww, wh, dx, dy, matchRows, rowsChecked,
                     100.0 * Double(matchRows) / Double(max(rowsChecked, 1)),
                     100.0 * Double(matchPx) / Double(max(pxChecked, 1))))
    }
}
