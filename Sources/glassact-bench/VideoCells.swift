// vcells — would a fixed grid of video cells cost less than one
// full-screen region? The same trace frames go through two setups at one
// fixed quantizer (bytes measure content, not a rate target):
//   - full: one encoder for the whole canvas;
//   - cells: a cols×rows grid on 64-px tile boundaries, an encoder per cell.
// Each area runs the pinned region's lifecycle: a frame that changes any of
// its tiles is encoded (the first after quiet as a key frame, a new
// session); `--quiet-ms` without a change ends it with one re-sharpen key
// frame of what's showing. Bytes split into start keys, re-sharpens and
// inter frames; quality is luma PSNR pooled over every encoded pixel.
// What this leaves out: small changes the Host sends as lossless tiles
// instead of video (both setups encode every change), and rate control.
import Foundation
import GlassActCore
import GlassActWire

let videoCellsCommand = Command(
    name: "vcells",
    summary: "video cells vs one full-screen region: bytes and quality at a fixed quantizer",
    flags: [
        .trace,
        .choice("codec", ["hevc", "av1"], "video codec: hardware HEVC (default) or software AV1, as the Host runs them"),
        .int("qp", "<n>", 10...51, "HEVC frame QP, pinned (default 30); AV1 uses libaom's scale of it (×63/51)"),
        .int("cols", "<n>", 1...16, "grid columns (default 4)"),
        .int("rows", "<n>", 1...16, "grid rows (default 4)"),
        .int("width", "<px>", 64...8192, "canvas width to resample the trace to first (default 2900, a live session's size)"),
        .int("frames", "<n>", 1...100_000, "trace frames to read (default all)"),
        .int("quiet-ms", "<n>", 100...60_000, "an area with no change this long ends, with a re-sharpen (default 2100, the region's quiet limit)"),
        .bool("keep-sessions", "a quiet area re-sharpens but keeps its encoder: its next change is an inter frame, not a new session's key frame"),
        .bool("count-cold-start", "count the first frame (every area starts) instead of taking it as the shared baseline"),
    ],
    run: { opts in
        let trace = opts.required("trace")
        try cmdVideoCells(try openTrace(trace), traceName: trace, opts: opts)
    }
)

private final class Area {
    let name: String
    let x: Int, y: Int, w: Int, h: Int
    let crop: UnsafeMutableRawBufferPointer
    let decoded: UnsafeMutableRawBufferPointer
    var encoder: (any VideoRegionEncoder)?
    var decoder: (any VideoRegionDecoder)?
    var decoderStarted = false
    var lastChangeUS: UInt64 = 0
    /// Re-sharpened since its last change (`--keep-sessions`: idle, encoder kept).
    var quiet = false
    // Results, kept in the setup's totals.
    init(name: String, x: Int, y: Int, w: Int, h: Int) {
        self.name = name
        self.x = x; self.y = y; self.w = w; self.h = h
        crop = .allocate(byteCount: w * h * 4, alignment: 64)
        decoded = .allocate(byteCount: w * h * 4, alignment: 64)
    }
    deinit { crop.deallocate(); decoded.deallocate() }
}

private struct Totals {
    var sessions = 0, refused = 0, maxLive = 0
    var frames = 0, keyBytes = 0, resharpenBytes = 0, interBytes = 0
    var pixels = 0, sqErr = 0.0, decodeFailures = 0
    var total: Int { keyBytes + resharpenBytes + interBytes }
}

func cmdVideoCells(_ reader: ScapReader, traceName: String, opts: Options) throws {
    let srcW = reader.header.width, srcH = reader.header.height
    let canvasW = opts.int("width", 2900) & ~1
    let canvasH = (srcH * canvasW / srcW) & ~1
    let cols = opts.int("cols", 4), rows = opts.int("rows", 4)
    let av1 = opts.string("codec") == "av1"
    if av1 && !AOMRegionEncoder.isAvailable { throw BenchError("--codec av1 needs Apple silicon (libaom is arm64 only)") }
    let codec = av1 ? VideoCodec.av1 : VideoCodec.hevc
    let qp = opts.int("qp", 30)
    let aomQ = min(63, Int((Double(qp) * 63 / 51).rounded()))
    let quietUS = UInt64(opts.int("quiet-ms", 2100)) * 1000
    let maxFrames = opts.int("frames", 100_000)
    let keepSessions = opts.has("keep-sessions")
    let countColdStart = opts.has("count-cold-start")
    let tile = 64

    // Cell edges on tile boundaries; the last row and column take the rest.
    func edges(_ total: Int, _ n: Int) -> [Int] {
        (0...n).map { i in i == n ? total : min(total, (total * i / n + tile / 2) / tile * tile) }
    }
    let xs = edges(canvasW, cols), ys = edges(canvasH, rows)
    let full = [Area(name: "full", x: 0, y: 0, w: canvasW, h: canvasH)]
    var cells: [Area] = []
    for r in 0..<rows {
        for c in 0..<cols where xs[c + 1] > xs[c] && ys[r + 1] > ys[r] {
            cells.append(Area(name: "cell \(c),\(r)", x: xs[c], y: ys[r], w: (xs[c + 1] - xs[c]) & ~1, h: (ys[r + 1] - ys[r]) & ~1))
        }
    }

    let src = UnsafeMutableRawBufferPointer.allocate(byteCount: srcW * srcH * 4, alignment: 64)
    let canvas = UnsafeMutableRawBufferPointer.allocate(byteCount: canvasW * canvasH * 4, alignment: 64)
    let previous = UnsafeMutableRawBufferPointer.allocate(byteCount: canvasW * canvasH * 4, alignment: 64)
    defer { [src, canvas, previous].forEach { $0.deallocate() } }
    let tilesX = (canvasW + tile - 1) / tile, tilesY = (canvasH + tile - 1) / tile
    var changed = [Bool](repeating: false, count: tilesX * tilesY)

    let queue = DispatchQueue(label: "vcells.encoder")
    let delivered = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var lastData: [UInt8] = []
    nonisolated(unsafe) var lastSync = false
    nonisolated(unsafe) var lastConfig: [UInt8]?

    func makeEncoder() -> any VideoRegionEncoder {
        if av1 {
            let aom = AOMRegionEncoder(callbackQueue: queue)
            aom.fixedQuantizer = aomQ
            return aom
        }
        let vt = VTHEVCRegionEncoder(callbackQueue: queue)
        vt.pinnedFrameQP = qp
        return vt
    }

    /// Encode `area`'s crop of the canvas; returns the bytes (0: dropped).
    func encode(_ area: Area, forceSync: Bool, timeUS: UInt64, into totals: inout Totals) throws -> Int {
        for row in 0..<area.h {
            area.crop.baseAddress!.advanced(by: row * area.w * 4)
                .copyMemory(from: canvas.baseAddress!.advanced(by: ((area.y + row) * canvasW + area.x) * 4),
                            byteCount: area.w * 4)
        }
        guard let encoder = area.encoder else { return 0 }
        encoder.encode(bgra: UnsafeRawBufferPointer(area.crop), forceSync: forceSync, timeUS: timeUS)
        guard delivered.wait(timeout: .now() + 5) == .success else { throw BenchError("\(area.name): encoder stalled") }
        let (data, sync, config) = queue.sync { (lastData, lastSync, lastConfig) }
        guard !data.isEmpty else { return 0 }
        if !area.decoderStarted {
            let decoder: any VideoRegionDecoder = av1 ? AOMRegionDecoder() : VTRegionDecoder()
            guard let config, decoder.start(codec: codec, config: config, width: area.w, height: area.h) else {
                throw BenchError("\(area.name): decoder failed to start")
            }
            area.decoder = decoder
            area.decoderStarted = true
        }
        let w = area.w, h = area.h, out = area.decoded
        let ok = area.decoder!.decode(data, sync: sync) { pixels, rowBytes in
            for row in 0..<h {
                out.baseAddress!.advanced(by: row * w * 4)
                    .copyMemory(from: pixels.baseAddress!.advanced(by: row * rowBytes), byteCount: w * 4)
            }
        }
        if ok {
            let (_, psnr) = lumaQuality(UnsafeRawBufferPointer(area.crop), UnsafeRawBufferPointer(out), w, h)
            let mse = psnr.isFinite ? 255 * 255 / pow(10, psnr / 10) : 0
            totals.sqErr += mse * Double(w * h)
            totals.pixels += w * h
        } else {
            totals.decodeFailures += 1
        }
        totals.frames += 1
        return data.count
    }

    func start(_ area: Area, into totals: inout Totals) -> Bool {
        let encoder = makeEncoder()
        guard encoder.start(width: area.w, height: area.h, onFrame: { data, sync, config in
            lastData = data
            lastSync = sync
            if let config { lastConfig = config }
            delivered.signal()
        }) else {
            totals.refused += 1
            return false
        }
        area.encoder = encoder
        area.decoder?.stop()
        area.decoder = nil
        area.decoderStarted = false
        queue.sync { lastConfig = nil }
        totals.sessions += 1
        return true
    }

    func stop(_ area: Area) {
        area.encoder?.stop()
        area.encoder = nil
    }

    /// One frame through one setup's areas.
    func step(_ areas: [Area], nowUS: UInt64, first: Bool, totals: inout Totals) throws {
        for area in areas {
            let tx0 = area.x / tile, tx1 = (area.x + area.w - 1) / tile
            let ty0 = area.y / tile, ty1 = (area.y + area.h - 1) / tile
            var moved = first
            if !moved {
                outer: for ty in ty0...ty1 { for tx in tx0...tx1 where changed[ty * tilesX + tx] { moved = true; break outer } }
            }
            if moved {
                var fresh = false
                if area.encoder == nil {
                    guard start(area, into: &totals) else { continue }
                    fresh = true
                }
                area.lastChangeUS = nowUS
                area.quiet = false
                let bytes = try encode(area, forceSync: fresh, timeUS: nowUS, into: &totals)
                if fresh { totals.keyBytes += bytes } else { totals.interBytes += bytes }
            } else if area.encoder != nil, !area.quiet, nowUS &- area.lastChangeUS >= quietUS {
                totals.resharpenBytes += try encode(area, forceSync: true, timeUS: nowUS, into: &totals)
                if keepSessions { area.quiet = true } else { stop(area) }
            }
        }
        totals.maxLive = max(totals.maxLive, areas.filter { $0.encoder != nil && !$0.quiet }.count)
    }

    var fullTotals = Totals(), cellTotals = Totals()
    var rects: [DirtyRect] = []
    var firstUS: UInt64?, lastUS: UInt64 = 0, read = 0
    while read < maxFrames, let meta = try reader.readFrame(rects: &rects, into: src) {
        resample(src, srcW, srcH, into: canvas, canvasW, canvasH)
        let first = firstUS == nil
        let t0 = firstUS ?? meta.timestampUS
        firstUS = t0
        let nowUS = meta.timestampUS &- t0
        lastUS = nowUS
        // Which tiles changed since the last frame (all of them, the first).
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                var diff = first
                let x0 = tx * tile, w = min(tile, canvasW - x0)
                var y = ty * tile
                while !diff && y < min(canvasH, (ty + 1) * tile) {
                    let o = (y * canvasW + x0) * 4
                    diff = memcmp(canvas.baseAddress!.advanced(by: o), previous.baseAddress!.advanced(by: o), w * 4) != 0
                    y += 1
                }
                changed[ty * tilesX + tx] = diff
            }
        }
        previous.copyMemory(from: UnsafeRawBufferPointer(canvas))
        guard !first || countColdStart else { read += 1; continue } // the cold start: the same for both
        try step(full, nowUS: nowUS, first: first, totals: &fullTotals)
        try step(cells, nowUS: nowUS, first: first, totals: &cellTotals)
        read += 1
    }
    // What's still live at the end goes quiet as it would: one re-sharpen each.
    for (areas, isFull) in [(full, true), (cells, false)] {
        for area in areas where area.encoder != nil && !area.quiet {
            if isFull {
                fullTotals.resharpenBytes += try encode(area, forceSync: true, timeUS: lastUS + quietUS, into: &fullTotals)
            } else {
                cellTotals.resharpenBytes += try encode(area, forceSync: true, timeUS: lastUS + quietUS, into: &cellTotals)
            }
            stop(area)
        }
    }
    for area in full + cells { stop(area) }

    func kb(_ b: Int) -> String { String(format: "%.1f KB", Double(b) / 1024) }
    func line(_ name: String, _ t: Totals) -> String {
        let psnr = t.pixels == 0 ? 0 : 10 * log10(255 * 255 / max(1e-9, t.sqErr / Double(t.pixels)))
        return "  \(name): total \(kb(t.total))  (start keys \(kb(t.keyBytes)), re-sharpens \(kb(t.resharpenBytes)), inter \(kb(t.interBytes)))  "
            + "sessions \(t.sessions)\(t.refused > 0 ? " (\(t.refused) refused)" : "")  most live \(t.maxLive)  "
            + "frames \(t.frames)  pixels \(String(format: "%.0f", Double(t.pixels) / 1e6)) Mpx  "
            + "PSNR \(String(format: "%.2f", psnr)) dB\(t.decodeFailures > 0 ? "  decode failures \(t.decodeFailures)" : "")"
    }
    print("vcells: \(traceName)")
    print("  canvas \(canvasW)×\(canvasH), \(read) frames over \(String(format: "%.1f", Double(lastUS) / 1e6)) s, "
          + "codec \(VideoCodec.name(codec)) at \(av1 ? "quantizer \(aomQ)" : "QP \(qp)"), grid \(cols)×\(rows), quiet \(quietUS / 1000) ms"
          + (keepSessions ? ", sessions kept" : "") + (countColdStart ? ", cold start counted" : ", cold start excluded"))
    print(line("full ", fullTotals))
    print(line("cells", cellTotals))
    if fullTotals.total > 0 {
        print(String(format: "  cells / full: %.1f %% of the bytes", Double(cellTotals.total) * 100 / Double(fullTotals.total)))
    }
}
