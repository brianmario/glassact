// vquality — what the video layer looks like at a given bitrate: trace
// frames through the real VideoToolbox HEVC encoder and the viewer's
// decoder, scored against the source (luma SSIM on 8×8 blocks + PSNR).
// --scale 50 encodes at half resolution and scales back up for scoring —
// the question "starve full-res or send a sharp half-res?" at a fixed rate.
// With an `ssimulacra2` binary on PATH, sampled frames are also scored with
// SSIMULACRA2 (SSIMULACRA2.swift), which tells soft text apart better.
import Accelerate
import Foundation
import GlassActCore
import GlassActWire

let videoQualityCommand = Command(
    name: "vquality",
    summary: "video-layer quality at a bitrate: VT HEVC encode → decode → SSIM/PSNR vs source",
    flags: [
        .trace,
        .int("mbit", "<n>", 1...200, "target average bitrate in Mbit/s (default 3)"),
        .int("kbit", "<n>", 50...200_000, "target average bitrate in kbit/s (overrides --mbit; thin links)"),
        .int("submit-fps", "<n>", 1...60, "submit at most this many frames per second of trace time — what newest-wins pacing does on a thin link (default: every trace frame)"),
        .bool("settle-sync", "make the first settle resubmission a keyframe: the re-sharpen a quiet screen could get"),
        .bool("from-black", "start from a blank keyframe, so the content arrives as inter frames — a session whose first capture was empty (a virtual display coming online)"),
        .int("settle", "<n>", 1...100, "after the run, resubmit the final frame n times, 250 ms apart: does the picture sharpen once motion stops?"),
        .int("width", "<px>", 64...8192, "canvas width to resample the trace to first (default: trace width; the live Client Resolution canvas is 2880)"),
        .int("scale", "<pct>", 10...100, "encode resolution as % of the canvas (default 100); scored after scaling back up"),
        .int("frames", "<n>", 1...100_000, "frames to encode (default 300)"),
        .int("skip", "<n>", 0...100_000, "trace frames to skip first (default 0)"),
        .bool("low-latency", "request VideoToolbox's low-latency rate control"),
        .int("cqf", "<0-100>", 0...100, "experiment: constant-quality factor ×100 (kVTCompressionPropertyKey_ConstantQualityFactor, macOS 27)"),
        .bool("no-realtime", "experiment: kVTCompressionPropertyKey_RealTime = false"),
        .bool("chroma444", "experiment: HEVC Main 4:4:4 (full-resolution chroma) instead of Main 4:2:0"),
        .bool("cqf-vbv", "experiment: with --cqf, cap the rate as a VBV peak (1 s) instead of an average"),
        .int("max-qp", "<n>", 1...51, "quality floor: cap frame QP (kVTCompressionPropertyKey_MaxAllowedFrameQP; default \(VTHEVCRegionEncoder.defaultMaxFrameQP), as in the product; 51 = none)"),
        .string("ssimulacra2", "<path|off>", "also score SSIMULACRA2 with this binary (default: `ssimulacra2` on PATH, if any; off = SSIM/PSNR only)"),
        .int("ssimulacra2-every", "<n>", 1...100_000, "SSIMULACRA2 on every nth scored frame (default 5), plus the SSIM-worst frame and every settle step"),
    ],
    run: { opts in
        let trace = opts.required("trace")
        try cmdVideoQuality(try openTrace(trace), traceName: trace, opts: opts)
    }
)

func cmdVideoQuality(_ reader: ScapReader, traceName: String, opts: Options) throws {
    let srcW = reader.header.width, srcH = reader.header.height
    let canvasW = opts.int("width", srcW) & ~1
    let canvasH = (srcH * canvasW / srcW) & ~1
    let pct = opts.int("scale", 100)
    let encW = max(64, canvasW * pct / 100) & ~1
    let encH = max(64, canvasH * pct / 100) & ~1
    let frames = opts.int("frames", 300)
    let skip = opts.int("skip", 0)
    let bitrate = opts.has("kbit") ? opts.int("kbit", 300) * 1_000 : opts.int("mbit", 3) * 1_000_000
    let submitIntervalUS: UInt64? = opts.has("submit-fps") ? UInt64(1_000_000 / opts.int("submit-fps", 60)) : nil
    let settleSteps = opts.int("settle", 0)
    let fromBlack = opts.has("from-black")
    let lowLatency = opts.has("low-latency")
    let ssimu2 = try SSIMULACRA2Scorer.make(setting: opts.string("ssimulacra2"))
    let ssimu2Every = opts.int("ssimulacra2-every", 5)

    let src = UnsafeMutableRawBufferPointer.allocate(byteCount: srcW * srcH * 4, alignment: 64)
    let canvas = UnsafeMutableRawBufferPointer.allocate(byteCount: canvasW * canvasH * 4, alignment: 64)
    let enc = UnsafeMutableRawBufferPointer.allocate(byteCount: encW * encH * 4, alignment: 64)
    let decoded = UnsafeMutableRawBufferPointer.allocate(byteCount: canvasW * canvasH * 4, alignment: 64)
    let shown = UnsafeMutableRawBufferPointer.allocate(byteCount: canvasW * canvasH * 4, alignment: 64)
    defer { [src, canvas, enc, decoded, shown].forEach { $0.deallocate() } }
    // The lowest-SSIM frame's pair, kept for SSIMULACRA2 (sampling may miss it).
    let worstRef = UnsafeMutableRawBufferPointer.allocate(byteCount: ssimu2 == nil ? 0 : canvas.count, alignment: 64)
    let worstShown = UnsafeMutableRawBufferPointer.allocate(byteCount: ssimu2 == nil ? 0 : canvas.count, alignment: 64)
    defer { worstRef.deallocate(); worstShown.deallocate() }

    let queue = DispatchQueue(label: "vquality.encoder")
    let encoder = VTHEVCRegionEncoder(callbackQueue: queue, lowLatency: lowLatency)
    if opts.has("max-qp") { encoder.maxFrameQP = opts.int("max-qp", 30) }
    if opts.has("cqf") { encoder.constantQualityFactor = Float(opts.int("cqf", 50)) / 100 }
    encoder.capWithVBV = opts.has("cqf-vbv")
    encoder.realTime = !opts.has("no-realtime")
    encoder.chroma444 = opts.has("chroma444")
    let submitW = encW, submitH = encH, outW = encW, outH = encH
    let delivered = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var lastData: [UInt8] = []
    nonisolated(unsafe) var lastSync = false
    nonisolated(unsafe) var config: [UInt8]?
    guard encoder.start(width: submitW, height: submitH, onFrame: { data, sync, cfg in
        lastData = data
        lastSync = sync
        if let cfg { config = cfg }
        delivered.signal()
    }) else { throw BenchError("VideoToolbox HEVC encoder failed to start at \(encW)×\(encH)") }
    defer { encoder.stop() }
    encoder.setBitrateCap(bitrate)
    let decoder = VTRegionDecoder()
    var decoderStarted = false

    print("vquality: \(traceName)")
    print("  canvas \(canvasW)×\(canvasH), encode \(encW)×\(encH) (\(pct)%), target \(bitrate / 1_000) kbit/s, "
          + "submit \(submitIntervalUS.map { "≤ \(1_000_000 / $0) fps" } ?? "every frame"), "
          + "low-latency \(lowLatency ? (encoder.lowLatencyActive ? "on" : "REFUSED (normal session)") : "off")"
          + ", max-qp \(encoder.maxFrameQP.map(String.init) ?? "none") \(encoder.maxFrameQPAccepted ? "accepted" : "REFUSED")"
          + (opts.has("cqf") ? ", cqf \(opts.int("cqf", 0)) \(encoder.constantQualityAccepted ? "accepted" : "REFUSED")"
             + (encoder.capWithVBV ? " (VBV cap)" : "") : "")
          + (opts.has("chroma444") ? ", chroma 4:4:4 \(encoder.chroma444Accepted ? "accepted" : "REFUSED")" : "")
          + (ssimu2.map { ", SSIMULACRA2 every \(ssimu2Every)th frame (\($0.binary.path))" } ?? ""))

    var rects: [DirtyRect] = []
    for _ in 0..<skip {
        guard try reader.readFrame(rects: &rects, into: src) != nil else { throw BenchError("trace too short for --skip") }
    }
    var ssims: [Double] = [], psnrs: [Double] = [], sizes: [Int] = [], latenciesUS: [UInt64] = []
    var decodeFailures = 0
    var ssimu2Frames: [Int] = [], ssimu2Worst: Int?, worstSSIM = Double.infinity
    var firstTraceUS: UInt64?, traceUS: UInt64 = 0, nextSubmitUS: UInt64 = 0, submitted = 0
    /// Encode `enc` stamped `timeUS`, decode it into `shown`; nil when the
    /// encoder dropped it or the decode failed.
    func encodeAndScore(timeUS: UInt64, forceSync: Bool) throws -> (bytes: Int, ssim: Double, psnr: Double)? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        encoder.encode(bgra: UnsafeRawBufferPointer(enc), forceSync: forceSync, timeUS: timeUS)
        guard delivered.wait(timeout: .now() + 2) == .success else { throw BenchError("encoder stalled") }
        latenciesUS.append((DispatchTime.now().uptimeNanoseconds - t0) / 1000)
        let data = queue.sync { lastData }
        guard !data.isEmpty else { return nil } // dropped by the encoder: no frame to score
        if !decoderStarted {
            guard let cfg = queue.sync(execute: { config }),
                  decoder.start(codec: VideoCodec.hevc, config: cfg, width: outW, height: outH) else {
                throw BenchError("decoder failed to start")
            }
            decoderStarted = true
        }
        let ok = decoder.decode(data, sync: queue.sync { lastSync }) { pixels, rowBytes in
            for row in 0..<outH {
                decoded.baseAddress!.advanced(by: row * outW * 4)
                    .copyMemory(from: pixels.baseAddress!.advanced(by: row * rowBytes), byteCount: outW * 4)
            }
        }
        guard ok else { decodeFailures += 1; return nil }
        resample(decoded, outW, outH, into: shown, canvasW, canvasH)
        let (ssim, psnr) = lumaQuality(UnsafeRawBufferPointer(canvas), UnsafeRawBufferPointer(shown), canvasW, canvasH)
        return (data.count, ssim, psnr)
    }
    if fromBlack {
        // A blank first keyframe (not scored): everything after is inter.
        for i in stride(from: 0, to: enc.count, by: 4) {
            enc[i] = 0; enc[i + 1] = 0; enc[i + 2] = 0; enc[i + 3] = 0xFF
        }
        _ = try encodeAndScore(timeUS: 0, forceSync: true)
        submitted = 1
    }
    for _ in 0..<frames {
        guard let meta = try reader.readFrame(rects: &rects, into: src) else { break }
        let first = firstTraceUS ?? meta.timestampUS
        firstTraceUS = first
        traceUS = (meta.timestampUS &- first) + (fromBlack ? 16_667 : 0)
        // Newest-wins pacing: the first capture at or after the deadline goes.
        if submitIntervalUS != nil, submitted > 0, traceUS < nextSubmitUS { continue }
        nextSubmitUS = traceUS + (submitIntervalUS ?? 0)
        resample(src, srcW, srcH, into: canvas, canvasW, canvasH)
        resample(UnsafeMutableRawBufferPointer(canvas), canvasW, canvasH, into: enc, encW, encH)
        guard let scored = try encodeAndScore(timeUS: traceUS, forceSync: submitted == 0) else { submitted += 1; continue }
        submitted += 1
        if let ssimu2 {
            if ssims.count % ssimu2Every == 0 {
                ssimu2Frames.append(try ssimu2.add(reference: canvas, distorted: shown, width: canvasW, height: canvasH))
            }
            if scored.ssim < worstSSIM {
                worstSSIM = scored.ssim
                worstRef.copyMemory(from: UnsafeRawBufferPointer(canvas))
                worstShown.copyMemory(from: UnsafeRawBufferPointer(shown))
            }
        }
        sizes.append(scored.bytes)
        ssims.append(scored.ssim)
        psnrs.append(scored.psnr)
    }
    guard !ssims.isEmpty else { throw BenchError("no frames scored") }
    let lat = latenciesUS.sorted()
    var settleLine: String?, ssimu2Settle: [Int] = []
    if settleSteps > 0 {
        // Motion stopped: the same final frame again, 250 ms apart.
        var line = "  settle (final frame, every 250 ms\(opts.has("settle-sync") ? ", first a keyframe" : "")): SSIM"
        var bytes = 0
        for step in 1...settleSteps {
            if let s = try encodeAndScore(timeUS: traceUS + UInt64(step) * 250_000,
                                          forceSync: step == 1 && opts.has("settle-sync")) {
                bytes += s.bytes
                line += String(format: " %.3f", s.ssim)
                if let ssimu2 {
                    ssimu2Settle.append(try ssimu2.add(reference: canvas, distorted: shown, width: canvasW, height: canvasH))
                }
            } else {
                line += " –"
                ssimu2Settle.append(-1)
            }
        }
        settleLine = line + String(format: "   (%d KB total)", bytes / 1024)
    }
    if let ssimu2, worstSSIM.isFinite {
        ssimu2Worst = try ssimu2.add(reference: worstRef, distorted: worstShown, width: canvasW, height: canvasH)
    }
    let ssimu2Scores = try ssimu2?.scoreAll() ?? []

    let n = sizes.count
    let seconds = max(Double(traceUS) / 1_000_000, Double(n) / 60)
    let mbps = Double(sizes.reduce(0, +)) * 8 / seconds / 1_000_000
    let meanSize = Double(sizes.reduce(0, +)) / Double(n)
    let sd = (sizes.map { (Double($0) - meanSize) * (Double($0) - meanSize) }.reduce(0, +) / Double(n)).squareRoot()
    let sortedS = ssims.sorted(), sortedP = psnrs.filter { $0.isFinite }.sorted()
    func pctl<T>(_ a: [T], _ p: Int) -> T { a[min(a.count - 1, a.count * p / 100)] }
    print(String(format: "  frames %d  achieved %.2f Mbit/s  frame bytes mean %.0f sd %.0f max %d  decode failures %d",
                 n, mbps, meanSize, sd, sizes.max() ?? 0, decodeFailures))
    print(String(format: "  SSIM mean %.4f  p5 %.4f  min %.4f   PSNR mean %.2f dB  p5 %.2f dB",
                 ssims.reduce(0, +) / Double(ssims.count), pctl(sortedS, 5), sortedS.first ?? 0,
                 sortedP.isEmpty ? .infinity : sortedP.reduce(0, +) / Double(sortedP.count),
                 sortedP.isEmpty ? .infinity : pctl(sortedP, 5)))
    if !ssimu2Frames.isEmpty {
        let sampled = ssimu2Frames.map { ssimu2Scores[$0] }.sorted()
        print(String(format: "  SSIMULACRA2 mean %.2f  p5 %.2f  min %.2f   (%d of %d frames)",
                     sampled.reduce(0, +) / Double(sampled.count), pctl(sampled, 5), sampled[0],
                     sampled.count, n)
              + (ssimu2Worst.map { String(format: "   SSIM-worst frame %.2f", ssimu2Scores[$0]) } ?? ""))
    }
    print(String(format: "  encode latency p50 %.1f ms  p95 %.1f ms", Double(pctl(lat, 50)) / 1000, Double(pctl(lat, 95)) / 1000))
    if let settleLine {
        print(settleLine)
        if ssimu2 != nil {
            print("  settle SSIMULACRA2" + ssimu2Settle.map { $0 < 0 ? " –" : String(format: " %.1f", ssimu2Scores[$0]) }.joined())
        }
    }
}

/// High-quality resample (vImage Lanczos); a plain copy at equal size.
private func resample(_ from: UnsafeMutableRawBufferPointer, _ fw: Int, _ fh: Int,
                      into to: UnsafeMutableRawBufferPointer, _ tw: Int, _ th: Int) {
    if fw == tw && fh == th {
        to.baseAddress!.copyMemory(from: from.baseAddress!, byteCount: tw * th * 4)
        return
    }
    var s = vImage_Buffer(data: from.baseAddress!, height: vImagePixelCount(fh), width: vImagePixelCount(fw), rowBytes: fw * 4)
    var d = vImage_Buffer(data: to.baseAddress!, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw * 4)
    vImageScale_ARGB8888(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
}

/// Luma (BT.601) SSIM averaged over non-overlapping 8×8 blocks, and PSNR.
private func lumaQuality(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer, _ w: Int, _ h: Int) -> (Double, Double) {
    @inline(__always) func luma(_ p: UnsafeRawBufferPointer, _ i: Int) -> Double {
        // BGRA
        0.114 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.299 * Double(p[i + 2])
    }
    let c1: Double = (0.01 * 255) * (0.01 * 255), c2: Double = (0.03 * 255) * (0.03 * 255)
    var ssimSum = 0.0, blocks = 0, sqErr = 0.0
    for by in stride(from: 0, to: h - 7, by: 8) {
        for bx in stride(from: 0, to: w - 7, by: 8) {
            var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
            for y in by..<(by + 8) {
                for x in bx..<(bx + 8) {
                    let i = (y * w + x) * 4
                    let la = luma(a, i), lb = luma(b, i)
                    sa += la; sb += lb; saa += la * la; sbb += lb * lb; sab += la * lb
                    sqErr += (la - lb) * (la - lb)
                }
            }
            let n = 64.0
            let ma = sa / n, mb = sb / n
            let va = saa / n - ma * ma, vb = sbb / n - mb * mb, cov = sab / n - ma * mb
            ssimSum += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
            blocks += 1
        }
    }
    let mse = sqErr / Double(blocks * 64)
    return (ssimSum / Double(blocks), mse == 0 ? .infinity : 10 * log10(255 * 255 / mse))
}
