// record — ScreenCaptureKit straight to disk, compressed once the capture is done.
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import GlassActCore
import GlassActShare
import GlassActTransport
import ScreenCaptureKit

let recordCommand = Command(
    name: "record",
    summary: "record the screen as a .scap trace, raw to disk, compressed afterwards",
    flags: [
        .string("out", "<file.scap>", "trace to write (default: the traces folder, named as the Host names them)"),
        .int("seconds", "<n>", 1...3600, "how long to record (default 30)"),
        .int("delay", "<n>", 0...600, "seconds to wait first, to get this terminal out of the way (default 5)"),
        .int("fps", "<n>", 1...120, "the most frames a second to capture (default 60)"),
        .bool("no-cursor", "leave the pointer out of the pictures"),
        .string("from-raw", "<file.scapraw>", "don't record: compress a raw capture left behind by a killed run (with --out)"),
    ],
    notes: """
      The same capture as the Host's (BGRA, sRGB, the main display's own pixels), but nothing compresses a
      frame while the screen is recording, so full-screen video keeps its frame rate: the Host's recorder
      compresses on its capture queue, ~55 ms for a 5K frame of video, and drops what arrives meanwhile.
      A 30 s trace takes up to ~106 GB of disk at 60 fps while it's raw (~42 GB at 24).
      Needs Screen Recording for the app this runs in (your terminal).
    """,
    run: cmdRecord
)

/// A stream's frames to the raw file. `queue` only.
private final class RawRecorder: @unchecked Sendable {
    let queue = DispatchQueue(label: "glassact.bench.record", qos: .userInteractive)
    let slot = LatestFrameSlot()
    let writer: ScapRawWriter
    var armed = false
    var failure: String?
    var dropped = 0
    var writeMS: [Double] = []
    var first: UInt64?, last: UInt64?

    init(writer: ScapRawWriter) {
        self.writer = writer
    }

    func drain() {
        guard let taken = slot.take() else { return }
        guard armed, failure == nil else { return }
        guard let pixels = CMSampleBufferGetImageBuffer(taken.buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let (width, height, stride) = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels),
                                       CVPixelBufferGetBytesPerRow(pixels))
        guard let base = CVPixelBufferGetBaseAddress(pixels), width == writer.header.width, height == writer.header.height else {
            failure = "the capture changed size to \(CVPixelBufferGetWidth(pixels))×\(CVPixelBufferGetHeight(pixels))"
            return
        }
        // what changed since the last frame kept, as the Host records it (none: no dirty info)
        var rects = FrameInfo.attachments(of: taken.buffer).flatMap {
            FrameInfo.dirtyRects($0, frameWidth: width, frameHeight: height).rects
        }
        dropped += taken.superseded.count + (taken.overflowed ? 1 : 0)
        if taken.overflowed {
            rects = nil
        } else {
            for attachments in taken.superseded {
                guard let more = FrameInfo.dirtyRects(attachments, frameWidth: width, frameHeight: height).rects else {
                    rects = nil
                    break
                }
                rects?.append(contentsOf: more)
            }
        }
        let pts = taken.buffer.presentationTimeStamp
        let ts = pts.isValid && pts.seconds > 0 ? UInt64(pts.seconds * 1_000_000) : MonotonicClock.nowUS
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            try writer.appendFrame(timestampUS: ts, dirtyRects: rects ?? [],
                                   frame: UnsafeRawBufferPointer(start: base, count: stride * height), bytesPerRow: stride)
        } catch {
            failure = "writing frame \(writer.frameCount): \(error)"
            return
        }
        writeMS.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        first = first ?? ts
        last = ts
    }
}

private func compressRaw(_ raw: URL, to out: URL) throws -> Int {
    let t0 = Date()
    let frames = try ScapRaw.compress(raw: raw, to: out) { done in
        print("\rcompressing: \(done) frames", terminator: "")
        fflush(stdout)
    }
    let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    print(String(format: "\rcompressed %d frames in %.1f s: %@ (%.1f GB)", frames, Date().timeIntervalSince(t0), out.path, Double(size) / 1e9))
    return frames
}

func cmdRecord(_ opts: Options) throws {
    if let from = opts.string("from-raw") {
        let raw = URL(fileURLWithPath: from)
        let out = URL(fileURLWithPath: opts.string("out") ?? raw.deletingPathExtension().appendingPathExtension("scap").path)
        _ = try compressRaw(raw, to: out)
        return
    }
    guard CGPreflightScreenCaptureAccess() else {
        CGRequestScreenCaptureAccess()
        throw BenchError("this needs Screen Recording: allow your terminal in System Settings › Privacy & Security, reopen it and run this again")
    }
    let (seconds, delay, fps) = (opts.int("seconds", 30), opts.int("delay", 5), opts.int("fps", 60))
    let display = CGMainDisplayID()
    guard let mode = CGDisplayCopyDisplayMode(display) else { throw BenchError("no display mode for the main display") }
    let size = CaptureGeometry.clamp(mode.pixelWidth, mode.pixelHeight)
    let out = opts.string("out").map { URL(fileURLWithPath: $0) } ?? {
        AppPaths.dataDirectory.appendingPathComponent("traces").appendingPathComponent("glassact-\(Int(Date().timeIntervalSince1970)).scap")
    }()
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let raw = out.deletingPathExtension().appendingPathExtension("scapraw")
    let need = Int64(seconds) * Int64(fps) * Int64(size.w * size.h * 4)
    let free = (try? out.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
        .volumeAvailableCapacityForImportantUsage ?? .max
    guard free > need else {
        throw BenchError(String(format: "this could take %.0f GB while it's raw, and the disk has %.0f GB free", Double(need) / 1e9, Double(free) / 1e9))
    }

    let recorder = RawRecorder(writer: try ScapRawWriter(url: raw, width: size.w, height: size.h))
    let backend = ScreenCaptureKitBackend()
    let settings = CaptureSettings(width: size.w, height: size.h, framesPerSecond: fps, showsCursor: !opts.has("no-cursor"))
    let state = RecordState()
    Task {
        do {
            let content = try await backend.content(for: .display(display))
            let stream = try backend.makeStream(filter: content.filter, settings: settings, frames: recorder.slot, onFrame: {
                recorder.queue.async { recorder.drain() }
            }, onStop: { stop in
                recorder.queue.async {
                    if case let .system(why) = stop { recorder.failure = why } else { recorder.failure = "the share was stopped" }
                }
            })
            try await stream.start()
            print("capturing \(size.w)×\(size.h)")
            for left in stride(from: delay, to: 0, by: -1) {
                print("recording in \(left)…")
                try await Task.sleep(for: .seconds(1))
            }
            recorder.queue.sync { recorder.armed = true }
            print("recording for \(seconds) s")
            try await Task.sleep(for: .seconds(seconds))
            recorder.queue.sync { recorder.armed = false }
            await stream.stop()
            recorder.queue.sync {}
        } catch {
            recorder.queue.sync { recorder.failure = recorder.failure ?? "\(error)" }
        }
        state.finish()
    }
    // (ScreenCaptureKit may want the main queue, so this thread runs it rather than blocking)
    while !state.isDone { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

    let (frames, dropped, ms, first, last, failure) = recorder.queue.sync {
        (recorder.writer.frameCount, recorder.dropped, recorder.writeMS.sorted(), recorder.first, recorder.last, recorder.failure)
    }
    if let failure, frames == 0 {
        try? FileManager.default.removeItem(at: raw)
        throw BenchError("capture failed: \(failure)")
    }
    if frames == 0 {
        try? FileManager.default.removeItem(at: raw)
        throw BenchError("no frames: nothing changed on the screen")
    }
    if let failure { print("the capture ended early: \(failure)") }
    let span = Double((last ?? 0) - (first ?? 0)) / 1e6
    print(String(format: "recorded %d frames in %.1f s (%.1f a second), %d dropped; a frame's write: median %.1f ms, slowest %.1f",
                 frames, span, Double(max(frames - 1, 0)) / max(span, 0.001), dropped, ms[ms.count / 2], ms[ms.count - 1]))
    _ = try compressRaw(raw, to: out)
    try FileManager.default.removeItem(at: raw)
}

/// When the capture task is done.
private final class RecordState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isDone: Bool { lock.withLock { done } }
    func finish() { lock.withLock { done = true } }
}
