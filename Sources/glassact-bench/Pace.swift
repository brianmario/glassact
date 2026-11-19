// pace — a region's video encoder driven as the Host's engine drives it, in real time: a trace's
// frames arrive every --every ms (a screen changing at that rate), and each tick does the engine's
// part (extract the region, diff it tile by tile against the last region frame into the change
// map) before handing the frame on, unless --pending frames are already waiting for the encoder:
// then the frame is skipped and the next tick's wins (newest-wins, `submitRegionFrame`). Reports
// what a Viewer would see: frames delivered a second, skips, and each frame's encode latency.
// No network, no Viewer: the encoder and the submission rule alone.
import Foundation
import GlassActCore
import GlassActHybridVideo
import QuartzCore

let paceCommand = Command(
    name: "pace",
    summary: "a trace's frames into a region encoder in real time, as the Host's engine submits them (newest wins past --pending): frames delivered a second, skips, latency",
    flags: [
        .trace,
        .choice("codec", ["hybrid", "hevc"], "the region's encoder: hybrid (Glass Act's AV1, as the Host runs it) or hevc (VideoToolbox) (default hybrid)"),
        .int("frames", "<n>", 2...2000, "trace frames to load and play (default 180; 59 MB each at 5K)"),
        .int("skip", "<n>", 0...100_000, "trace frames to skip first (default 0)"),
        .string("every", "<ms>", "a frame every ms, in real time (default 16.667: 60 fps)"),
        .int("pending", "<n>", 1...16, "frames waiting for the encoder before the engine skips (default 2, videoMaxPendingFrames)"),
        .int("loops", "<n>", 1...100, "play the loaded frames this many times (default 1)"),
    ],
    run: { opts in try runPace(opts) })

private final class PaceState: @unchecked Sendable {
    var pending = 0
    var submittedAt: [Double] = []
    var latencies: [Double] = []
    var delivered = 0
    var empty = 0
    var bytes = 0
    var firstOut = 0.0, lastOut = 0.0
}

func runPace(_ opts: Options) throws {
    guard let path = opts.string("trace") else { throw BenchError("--trace") }
    let codec = opts.string("codec") ?? "hybrid"
    let count = opts.int("frames", 180), skip = opts.int("skip", 0), loops = opts.int("loops", 1)
    let limit = opts.int("pending", 2)
    guard let everyMS = Double(opts.string("every") ?? "16.667"), everyMS > 0 else { throw BenchError("--every: a number of ms") }
    let reader = try ScapReader(url: URL(fileURLWithPath: path))
    let (w, h) = (reader.header.width, reader.header.height)
    for _ in 0..<skip { guard try reader.skimFrame() != nil else { throw BenchError("--skip past the trace's end") } }
    var frames: [UnsafeMutableRawBufferPointer] = []
    defer { frames.forEach { $0.deallocate() } }
    var rects: [DirtyRect] = []
    for _ in 0..<count {
        let f = UnsafeMutableRawBufferPointer.allocate(byteCount: w * h * 4, alignment: 64)
        guard try reader.readFrame(rects: &rects, into: f) != nil else { f.deallocate(); break }
        frames.append(f)
    }
    guard frames.count >= 2 else { throw BenchError("fewer than 2 frames") }

    let queue = DispatchQueue(label: "pace.engine", qos: .userInteractive)
    let encoder: any VideoRegionEncoder
    switch codec {
    case "hevc":
        encoder = VTHEVCRegionEncoder(callbackQueue: queue)
    default:
        guard #available(macOS 27, *), HybridRegionEncoder.isAvailable else { throw BenchError("--codec hybrid needs macOS 27 and an Apple-silicon GPU") }
        let prepared = DispatchSemaphore(value: 0)
        HybridRegionEncoder.prepare { _ in prepared.signal() }
        prepared.wait()
        guard HybridRegionEncoder.isReady else { throw BenchError("the hybrid's kernels didn't compile") }
        encoder = HybridRegionEncoder(callbackQueue: queue)
    }
    let s = PaceState()
    guard encoder.start(width: w, height: h, onFrame: { data, _, _ in
        // (on `queue`, as the engine's)
        s.pending -= 1
        let now = CACurrentMediaTime()
        if !s.submittedAt.isEmpty { s.latencies.append(now - s.submittedAt.removeFirst()) }
        if data.isEmpty { s.empty += 1; return }
        if s.delivered == 0 { s.firstOut = now }
        s.delivered += 1
        s.bytes += data.count
        s.lastOut = now
    }) else { throw BenchError("the encoder didn't start") }

    let run = PaceRun(frames: frames, width: w, height: h, loops: loops, every: everyMS / 1000, limit: limit,
                      encoder: encoder, state: s, queue: queue)
    run.start()
    run.done.wait()
    // what's still waiting comes out
    let end = CACurrentMediaTime() + 3
    while CACurrentMediaTime() < end && queue.sync(execute: { s.pending }) > 0 { usleep(2000) }
    queue.sync {}
    encoder.stop()
    let (ticks, every, skips, submits, late, engineSeconds) = (run.ticks, run.every, run.skips, run.submits, run.late, run.engineSeconds)
    let playSeconds = Double(ticks) * every
    let lat = s.latencies.sorted()
    func pct(_ p: Double) -> Double { lat.isEmpty ? .nan : lat[min(lat.count - 1, Int(p * Double(lat.count)))] * 1000 }
    print(String(format: "pace: %@ %d×%d, %d frames (×%d) every %.3f ms, at most %d waiting",
                 codec, w, h, frames.count, loops, everyMS, limit))
    print(String(format: "  ticks %d · submitted %d · skipped %d (%.1f %%) · delivered %d (%d empty) · %.1f frames a second over %.2f s of play · %.1f KB a frame",
                 ticks, submits, skips, 100 * Double(skips) / Double(ticks), s.delivered, s.empty,
                 Double(s.delivered) / playSeconds, playSeconds, Double(s.bytes) / 1024 / Double(max(1, s.delivered))))
    print(String(format: "  encode latency p50 %.1f ms · p95 %.1f ms · max %.1f ms · the engine's tick %.2f ms on average · ticks late %d",
                 pct(0.5), pct(0.95), lat.last.map { $0 * 1000 } ?? .nan, engineSeconds / Double(ticks) * 1000, late))
}

/// The engine's side of `pace`, on its queue: a tick a frame.
private final class PaceRun: @unchecked Sendable {
    let frames: [UnsafeMutableRawBufferPointer]
    let w: Int, h: Int, cols: Int, rows: Int, ticks: Int, every: Double, limit: Int
    let encoder: any VideoRegionEncoder
    let s: PaceState
    let queue: DispatchQueue
    let done = DispatchSemaphore(value: 0)
    let region: UnsafeMutableRawBufferPointer, last: UnsafeMutableRawBufferPointer
    var changed: [UInt8]
    var known = false
    var skips = 0, submits = 0, late = 0, tick = 0
    var engineSeconds = 0.0
    var t0 = 0.0

    init(frames: [UnsafeMutableRawBufferPointer], width: Int, height: Int, loops: Int, every: Double, limit: Int,
         encoder: any VideoRegionEncoder, state: PaceState, queue: DispatchQueue) {
        (self.frames, w, h, self.every, self.limit, self.encoder, s, self.queue) = (frames, width, height, every, limit, encoder, state, queue)
        (cols, rows) = ((width + 63) / 64, (height + 63) / 64)
        ticks = frames.count * loops
        region = .allocate(byteCount: width * height * 4, alignment: 64)
        last = .allocate(byteCount: width * height * 4, alignment: 64)
        changed = [UInt8](repeating: 0, count: cols * rows)
    }

    deinit {
        region.deallocate()
        last.deallocate()
    }

    func start() {
        t0 = CACurrentMediaTime() + 0.05
        queue.asyncAfter(deadline: .now() + 0.05) { self.step() }
    }

    private func step() {
        let due = t0 + Double(tick) * every
        let te = CACurrentMediaTime()
        if te > due + every { late += 1 }
        let frame = frames[tick % frames.count]
        // the engine's tick: extract, diff into the map (OR-ed until a frame is passed)
        region.copyMemory(from: UnsafeRawBufferPointer(frame))
        if tick > 0 {
            for ty in 0..<rows {
                for tx in 0..<cols where changed[ty * cols + tx] == 0 {
                    let x0 = tx * 64 * 4, n = (min(w, tx * 64 + 64) - tx * 64) * 4
                    for y in ty * 64..<min(h, ty * 64 + 64)
                    where memcmp(region.baseAddress! + y * w * 4 + x0, last.baseAddress! + y * w * 4 + x0, n) != 0 {
                        changed[ty * cols + tx] = 1
                        break
                    }
                }
            }
        }
        last.copyMemory(from: UnsafeRawBufferPointer(region))
        if s.pending >= limit {
            skips += 1  // (newest wins: the next tick's frame goes instead)
        } else {
            s.pending += 1
            s.submittedAt.append(CACurrentMediaTime())
            let known = known
            changed.withUnsafeBufferPointer { map in
                encoder.encode(bgra: UnsafeRawBufferPointer(region), forceSync: tick == 0,
                               timeUS: UInt64(Double(tick) * every * 1e6), changed: known ? map : nil)
            }
            submits += 1
            for i in changed.indices { changed[i] = 0 }
            self.known = true
        }
        engineSeconds += CACurrentMediaTime() - te
        tick += 1
        if tick == ticks {
            done.signal()
            return
        }
        let next = t0 + Double(tick) * every
        queue.asyncAfter(deadline: .now() + max(0, next - CACurrentMediaTime())) { self.step() }
    }
}
