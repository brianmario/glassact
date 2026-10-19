// replay — feed a .scap trace through the host engine (§7 Replayer).
// Modes: encode-only (ReplayEncode.swift) and the full faulted host→viewer
// loop with the golden divergence check (ReplayLoop.swift).
import Compression
import GlassActCodec

/// Flags that only mean something in `--mode loop`.
private let loopOnlyFlags = ["drop", "dup", "reorder", "latency", "seed", "video", "golden"]

let replayCommand = Command(
    name: "replay",
    summary: "replay a trace through the host engine (encode-only or full faulted loop)",
    flags: [
        .trace,
        .choice("mode", ["encode", "loop"], "encode-only or full loop (default encode)"),
        .int("drop", "<pct>", 0...100, "loop: datagram drop % (default 0)"),
        .int("dup", "<pct>", 0...100, "loop: datagram duplicate % (default 0)"),
        .int("reorder", "<pct>", 0...100, "loop: datagram reorder % (default 0)"),
        .span("latency", "<lo-hi>", "loop: one-way latency range in ms, e.g. 20-80 (default 0-0)"),
        .int("seed", "<n>", 0...Int.max, "loop: fault RNG seed (default 1)"),
        .choice("video", ["mock", "vt"], "loop: video codec — pinned full-screen video, as the Host app runs it (default none)"),
        .bool("golden", "loop: exit non-zero unless settled with a byte-identical canvas"),
        .bool("no-handoff", "loop experiment: video frames claim the whole region (no per-tile handoff)"),
        .bool("timeline", "loop: print engine state once per virtual second (video coverage, handoffs, tiles, repaint debt)"),
        .int("handoff-ms", "<n>", 50...60_000, "loop experiment: how long a region tile must be still before it goes back to exact (default 1000)"),
        .int("limit-mbit", "<n>", 1...100_000, "cap the tile send rate at n Mbit/s (default: auto)"),
        .bool("encode-headroom", "measure real encode time so Auto is bounded by this machine's encode headroom"),
        .int("vp8l-effort", "<0-9>", 0...9, "libwebp lossless preset for tiles (default: tick-size policy)"),
        .int("keyframe-effort", "<0-9>", 0...9, "libwebp lossless preset for keyframe stripes (default 4)"),
        .bool("no-lzbitmap", "experiment: drop LZBITMAP from the encoder's best-of (Apple-only payload)"),
        .choice("bitmap-codec", ["brotli", "zlib", "lzfse"], "experiment (encode mode only): this codec in LZBITMAP's slot"),
        .bool("count-allocs", "encode mode only: count heap allocations inside encodeTick (scroll vs other ticks)"),
    ],
    notes: """
      modes:
        encode  feed the host engine with instant ACKs; report bytes/frame and encode timings
        loop    host engine -> seeded faults -> viewer engine over virtual time; verify canvas
      --video: mock = deterministic rig codec; vt = hardware HEVC. Real codecs vary in
               bytes but settle byte-exact.
      standard golden run:
        glassact-bench replay --trace t.scap --mode loop --drop 5 --dup 1 --reorder 10 --latency 20-80 --golden
    """,
    validate: { opts in
        guard opts.string("mode") != "loop" else {
            if opts.has("count-allocs") {
                throw UsageError(message: "--count-allocs only applies to --mode encode", command: opts.command)
            }
            return
        }
        if let flag = loopOnlyFlags.first(where: { opts.has($0) }) {
            throw UsageError(message: "--\(flag) only applies to --mode loop", command: opts.command)
        }
    },
    run: cmdReplay
)

func cmdReplay(_ opts: Options) throws {
    let trace = opts.required("trace")
    let reader = try openTrace(trace)
    if opts.has("no-lzbitmap") { LZ4Codec.experimentDisableBitmap = true }
    switch opts.string("bitmap-codec") {
    case "brotli": LZ4Codec.experimentBitmapAlgorithmRaw = COMPRESSION_BROTLI.rawValue
    case "zlib": LZ4Codec.experimentBitmapAlgorithmRaw = COMPRESSION_ZLIB.rawValue
    case "lzfse": LZ4Codec.experimentBitmapAlgorithmRaw = COMPRESSION_LZFSE.rawValue
    default: break
    }
    switch opts.string("mode") ?? "encode" {
    case "loop": try cmdReplayLoop(reader, traceName: trace, opts: opts)
    default: try cmdReplayEncode(reader, traceName: trace, opts: opts)
    }
}
