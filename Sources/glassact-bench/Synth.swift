// synth — write a deterministic synthetic .scap trace.
import Foundation
import GlassActCore

let synthCommand = Command(
    name: "synth",
    summary: "write a synthetic .scap trace (seeded, deterministic)",
    flags: [
        .string("out", "<file.scap>", required: true, "trace to write"),
        .int("width", "<px>", 32...16_384, "frame width (default 640)"),
        .int("height", "<px>", 32...16_384, "frame height (default 400)"),
        .int("frames", "<n>", 1...Int.max, "frame count (default 120)"),
        .int("seed", "<n>", 0...Int.max, "RNG seed (default 1)"),
        .choice("kind", ["mixed", "noise", "ui", "fullscan", "video", "panel", "spinner"], "content model (default mixed)"),
    ],
    notes: """
      kinds:
        mixed     solid + noisy rects, dirty rects recorded
        noise     noisy rects only
        ui        solid rects only
        fullscan  mixed content, no dirty rects (replay full-scans every frame)
        video     a fixed centered region re-noised every frame (video-region workload)
        panel     a text-like page that is replaced once, then only a left-side panel
                  animates every frame — one busy panel on an otherwise still screen
                  (pinned video's worst case: minutes of soft static text)
        spinner   a text page scrolls for 1.5 s, then only a 3-tile spinner changes,
                  10 times a second (a terminal's status line after the output
                  stops): a live region with nothing but small changes left
    """,
    run: cmdSynth
)

func cmdSynth(_ opts: Options) throws {
    let out = opts.required("out")
    let width = opts.int("width", 640)
    let height = opts.int("height", 400)
    let frames = opts.int("frames", 120)
    let seed = UInt64(opts.int("seed", 1))
    let kind = opts.string("kind") ?? "mixed"
    // fullscan = mixed content but no dirty rects recorded: replay full-scans
    // every frame (diff-phase micro-benchmark).
    // video = a fixed centered region fully re-noised every frame — the
    // video-region workload shape (photographic churn, positionally stable) and the demo
    // case for VP8L routing memory.

    var rng = BenchRNG(seed: seed)
    var frame = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: frame.count, by: 4) { // opaque dark background
        frame[i] = 0x20; frame[i + 1] = 0x20; frame[i + 2] = 0x20; frame[i + 3] = 0xFF
    }

    let writer: ScapWriter
    do {
        writer = try ScapWriter(url: URL(fileURLWithPath: out), width: width, height: height)
    } catch {
        throw BenchError("cannot create \(out)")
    }
    var ts: UInt64 = 0

    /// Text-like content: light page, dark word-strokes on 16 px lines —
    /// detailed but compressible, like a document or a terminal.
    func paintText(x: Int, y: Int, w: Int, h: Int) {
        for row in y..<(y + h) {
            for col in x..<(x + w) {
                let o = (row * width + col) * 4
                frame[o] = 0xF4; frame[o + 1] = 0xF2; frame[o + 2] = 0xF0; frame[o + 3] = 0xFF
            }
        }
        var line = y + 4
        while line + 10 <= y + h {
            var col = x + 8 + rng.int(0..<16)
            while col < x + w - 8 {
                let word = min(rng.int(12..<72), x + w - 8 - col)
                for gy in line..<(line + 10) where rng.int(0..<3) > 0 {
                    for gx in col..<(col + word) where rng.int(0..<4) > 0 {
                        let o = (gy * width + gx) * 4
                        frame[o] = 0x30; frame[o + 1] = 0x30; frame[o + 2] = 0x34
                    }
                }
                col += word + rng.int(6..<14)
            }
            line += 16
        }
    }

    // spinner: frames come only on change, as a capture delivers them.
    let spinnerScrollFrames = 90
    func mutate(_ i: Int) -> [DirtyRect] {
        if kind == "spinner" {
            if i < spinnerScrollFrames {
                // Scroll the page up one 16 px line; a new line at the bottom.
                let rowBytes = width * 4, shift = 16 * rowBytes
                frame.withUnsafeMutableBytes { raw in
                    let base = raw.baseAddress!
                    memmove(base, base + shift, raw.count - shift)
                }
                paintText(x: 0, y: height - 16, w: width, h: 16)
                return [DirtyRect(x: 0, y: 0, width: width, height: height)]
            }
            let w = 192, h = 64, x = 0, y = height - 2 * h
            paintText(x: x, y: y, w: w, h: h)
            return [DirtyRect(x: x, y: y, width: w, height: h)]
        }
        if kind == "panel" {
            // Frame 1: the whole page is replaced (the content arrives); then
            // only the panel moves.
            if ts == 16_667 {
                paintText(x: 0, y: 0, w: width, h: height)
                return [DirtyRect(x: 0, y: 0, width: width, height: height)]
            }
            let w = width * 24 / 100, h = height * 2 / 3, y = height / 6
            paintText(x: 0, y: y, w: w, h: h)
            return [DirtyRect(x: 0, y: y, width: w, height: h)]
        }
        if kind == "video" {
            let w = min(width / 2, width), h = min(height / 2, height)
            let x = (width - w) / 2, y = (height - h) / 2
            for row in y..<(y + h) {
                for col in x..<(x + w) {
                    let o = (row * width + col) * 4
                    let v = rng.next()
                    frame[o] = UInt8(truncatingIfNeeded: v)
                    frame[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    frame[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
                    frame[o + 3] = 0xFF
                }
            }
            return [DirtyRect(x: x, y: y, width: w, height: h)]
        }
        var rects: [DirtyRect] = []
        for _ in 0..<rng.int(1..<4) {
            let w = rng.int(16..<min(200, width))
            let h = rng.int(16..<min(200, height))
            let x = rng.int(0..<max(1, width - w))
            let y = rng.int(0..<max(1, height - h))
            let noisy = kind == "noise" || (kind == "mixed" && rng.int(0..<10) < 3)
            let solid = (b: UInt8(truncatingIfNeeded: rng.next()), g: UInt8(truncatingIfNeeded: rng.next() >> 8),
                         r: UInt8(truncatingIfNeeded: rng.next() >> 16))
            for row in y..<(y + h) {
                for col in x..<(x + w) {
                    let o = (row * width + col) * 4
                    if noisy {
                        let v = rng.next()
                        frame[o] = UInt8(truncatingIfNeeded: v)
                        frame[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                        frame[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
                    } else {
                        frame[o] = solid.b; frame[o + 1] = solid.g; frame[o + 2] = solid.r
                    }
                    frame[o + 3] = 0xFF
                }
            }
            rects.append(DirtyRect(x: x, y: y, width: w, height: h))
        }
        return rects
    }

    if kind == "panel" || kind == "spinner" { paintText(x: 0, y: 0, w: width, h: height) }
    for i in 0..<frames {
        var rects = i == 0 ? [DirtyRect(x: 0, y: 0, width: width, height: height)] : mutate(i)
        if kind == "fullscan" { rects = [] }
        try frame.withUnsafeBytes { raw in
            try writer.appendFrame(timestampUS: ts, dirtyRects: rects, frame: raw)
        }
        ts += kind == "spinner" && i >= spinnerScrollFrames ? 100_000 : 16_667
    }
    try writer.finish()
    print("synth: wrote \(frames) frames (\(width)x\(height), kind \(kind), seed \(seed)) to \(out)")
}
