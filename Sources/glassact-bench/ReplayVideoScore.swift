// replay --mode loop with a real codec: what the video layer delivered. Each submitted frame's
// encode latency (real time, submit to delivery), its glass-to-glass in virtual time (submit to
// the Viewer's decode: link and queueing, not the encode, which the loop waits for), the rate
// against the target, and the quality of the frames the Viewer decoded against the pictures the
// Host submitted (BT.601 luma at half size: PSNR and SSIM on 8x8 blocks), every --score-every'th
// frame. The same for every codec: the encoder wrapper (BenchPipelinedEncoder) and the decoder
// wrapper (ScoringDecoder) meet on the frame's bytes.
import Foundation
import GlassActCore
import QuartzCore

final class ReplayVideoScore {
    /// Virtual now (the link's clock).
    var now: () -> UInt64 = { 0 }
    /// Score every nth submitted frame (0: none).
    var scoreEvery = 4
    private struct Submitted {
        var virtualUS: UInt64
        var luma: [UInt8]?
        var w = 0, h = 0
    }
    /// Frames delivered by the encoder and not yet decoded, by their bytes' hash.
    private var byHash: [UInt64: Submitted] = [:]
    private var order: [UInt64] = []
    /// The submit being delivered: its virtual time and luma (one at a time: the loop drains each).
    private var pendingSubmits: [Submitted] = []
    private var submits = 0
    private(set) var encodeLatencies: [Double] = []
    private(set) var g2g: [Double] = []
    private(set) var psnrs: [Double] = []
    private(set) var ssims: [Double] = []
    private(set) var decoderName = "-"
    /// Mean of the target (`AOMRegionEncoder.target`, the ladder under the link cap, before an AV1
    /// encoder's share) at each submit, bits/s.
    private var targetSum = 0.0, targetCount = 0
    var meanTarget: Double { targetCount == 0 ? 0 : targetSum / Double(targetCount) }
    /// The first and last submit (virtual).
    private(set) var firstSubmitUS: UInt64?, lastSubmitUS: UInt64 = 0

    func submitted(bgra: UnsafeRawBufferPointer, width: Int, height: Int, timeUS: UInt64, target: Int) {
        var s = Submitted(virtualUS: now())
        if scoreEvery > 0 && submits % scoreEvery == 0 {
            (s.luma, s.w, s.h) = (Self.halfLuma(bgra, width: width, height: height, bytesPerRow: width * 4), width / 2, height / 2)
        }
        submits += 1
        pendingSubmits.append(s)
        targetSum += Double(target)
        targetCount += 1
        if firstSubmitUS == nil { firstSubmitUS = s.virtualUS }
        lastSubmitUS = s.virtualUS
    }

    func delivered(_ data: [UInt8], latency: Double) {
        guard !pendingSubmits.isEmpty else { return }
        let s = pendingSubmits.removeFirst()
        guard !data.isEmpty else { return }
        encodeLatencies.append(latency)
        let h = Self.hash(data)
        byHash[h] = s
        order.append(h)
        if order.count > 240 { byHash[order.removeFirst()] = nil }
    }

    func dropped() {
        if !pendingSubmits.isEmpty { pendingSubmits.removeFirst() }
    }

    func decoded(_ data: [UInt8], pixels: UnsafeRawBufferPointer?, bytesPerRow: Int, decoder: String) {
        decoderName = decoder
        let h = Self.hash(data)
        guard let s = byHash.removeValue(forKey: h) else { return }
        g2g.append(Double(now() &- s.virtualUS) / 1000)
        guard let luma = s.luma, let pixels else { return }
        let got = Self.halfLuma(pixels, width: s.w * 2, height: s.h * 2, bytesPerRow: bytesPerRow)
        let (p, q) = Self.psnrSSIM(luma, got, width: s.w, height: s.h)
        psnrs.append(p)
        ssims.append(q)
    }

    static func hash(_ data: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBufferPointer { b in for x in b { h = (h ^ UInt64(x)) &* 0x100_0000_01b3 } }
        return h &+ UInt64(data.count)
    }

    /// BT.601 luma of 2x2 averages.
    static func halfLuma(_ bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        let w = width / 2, h = height / 2
        return [UInt8](unsafeUninitializedCapacity: w * h) { out, n in
            let src = bgra.bindMemory(to: UInt8.self)
            for y in 0..<h {
                let r0 = 2 * y * bytesPerRow, r1 = r0 + bytesPerRow
                for x in 0..<w {
                    @inline(__always) func luma(_ o: Int) -> Int {
                        25 * Int(src[o]) + 129 * Int(src[o + 1]) + 66 * Int(src[o + 2])
                    }
                    let acc = luma(r0 + 8 * x) + luma(r0 + 8 * x + 4) + luma(r1 + 8 * x) + luma(r1 + 8 * x + 4)
                    out[y * w + x] = UInt8(min(255, (acc / 4 + 128) >> 8 + 16))
                }
            }
            n = w * h
        }
    }

    /// PSNR and mean SSIM on 8x8 blocks.
    static func psnrSSIM(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> (Double, Double) {
        var sse = 0.0
        for i in a.indices { let d = Double(Int(a[i]) - Int(b[i])); sse += d * d }
        let mse = sse / Double(a.count)
        let psnr = mse == 0 ? 100 : 10 * log10(255 * 255 / mse)
        let c1 = 6.5025, c2 = 58.5225
        var total = 0.0, blocks = 0
        for by in stride(from: 0, to: height - 7, by: 8) {
            for bx in stride(from: 0, to: width - 7, by: 8) {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                for y in by..<(by + 8) {
                    for x in bx..<(bx + 8) {
                        let p = Double(a[y * width + x]), q = Double(b[y * width + x])
                        sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q
                    }
                }
                let n = 64.0
                let ma = sa / n, mb = sb / n
                let va = saa / n - ma * ma, vb = sbb / n - mb * mb, cov = sab / n - ma * mb
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                blocks += 1
            }
        }
        return (psnr, blocks == 0 ? 1 : total / Double(blocks))
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    func summary(videoBytes: Int) -> String {
        let span = Double(lastSubmitUS &- (firstSubmitUS ?? 0)) / 1e6
        let achieved = span > 0 ? Double(videoBytes) * 8 / span : 0
        let fin = psnrs.filter(\.isFinite)
        return String(format: "  video score: encode latency p50 %.1f ms p95 %.1f ms (n %d) · glass-to-glass (virtual, decode) p50 %.0f ms p95 %.0f ms (n %d) · rate %.2f Mbit/s over %.1f s against a target of %.2f (%.0f %%) · scored %d: PSNR %.2f dB · SSIM %.4f (min %.4f) · decoder %@",
                      Self.percentile(encodeLatencies, 0.5) * 1000, Self.percentile(encodeLatencies, 0.95) * 1000, encodeLatencies.count,
                      Self.percentile(g2g, 0.5), Self.percentile(g2g, 0.95), g2g.count,
                      achieved / 1e6, span, meanTarget / 1e6, meanTarget > 0 ? 100 * achieved / meanTarget : 0,
                      psnrs.count, fin.isEmpty ? .nan : fin.reduce(0, +) / Double(fin.count),
                      ssims.isEmpty ? .nan : ssims.reduce(0, +) / Double(ssims.count), ssims.min() ?? .nan, decoderName)
    }
}

/// The Viewer's decoder, reporting each frame it decodes to the score.
final class ScoringDecoder: VideoRegionDecoder {
    private let inner: any VideoRegionDecoder
    private let score: ReplayVideoScore

    init(_ inner: any VideoRegionDecoder, _ score: ReplayVideoScore) {
        self.inner = inner
        self.score = score
    }

    func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
        inner.start(codec: codec, config: config, width: width, height: height)
    }

    @discardableResult
    func decode(_ data: [UInt8], sync: Bool, onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
        var seen = false
        let name = String(describing: type(of: inner))
        let ok = inner.decode(data, sync: sync) { pixels, bytesPerRow in
            seen = true
            score.decoded(data, pixels: pixels, bytesPerRow: bytesPerRow, decoder: name)
            onPixels(pixels, bytesPerRow)
        }
        if ok && !seen { score.decoded(data, pixels: nil, bytesPerRow: 0, decoder: name) }
        return ok
    }

    func stop() { inner.stop() }
}
