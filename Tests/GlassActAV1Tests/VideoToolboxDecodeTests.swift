import AV1Core
import Foundation
import GlassActAV1
import GlassActCore
import GlassActTestSupport
import GlassActWire
import Metal
import Testing

/// The hybrid encoder's streams through the decoder the Viewer uses: VideoToolbox's
/// hardware AV1 (M3 and later), configured as VIDEO_START configures it, from the key
/// frame's sequence header. Skipped where there's none (Intel, M1–M2, the CI runner's VM).
/// `av1seq --vt-decode` also checks the output sample for sample (BENCHMARKS "the hybrid's
/// streams on VideoToolbox's AV1 decoder").
@Suite struct VideoToolboxDecodeTests {
    @available(macOS 27, *)
    @Test(.enabled(if: VTRegionDecoder.canDecodeAV1), arguments: [(1280, 720, 80), (5120, 2880, 80), (333, 201, 120)])
    func hybridStreamsDecodeOnVideoToolbox(width: Int, height: Int, qindex: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = width >= 2560 ? (2, 0) : (-1, -1)
        encoder.interFrames = true
        var rng = SplitMix64(seed: 0x7d0c)
        let base = PartitionTests.Picture(width: width, height: height)
        // two screens in turn, a word typed into the first each time: key frame, long-term
        // references, copies, new blocks
        var a = base.y
        for k in a.indices where rng.int(0..<4) == 0 { a[k] = UInt8(rng.int(20..<90)) }
        var b = base.y
        for k in b.indices where rng.int(0..<3) == 0 { b[k] = UInt8(rng.int(100..<200)) }
        var pictures: [AV1HybridEncoder.Picture] = []
        for i in 0..<8 {
            if i % 2 == 0 {
                let x0 = rng.int(0..<max(1, width - 24)), y0 = rng.int(0..<max(1, height - 12))
                for r in y0..<min(height, y0 + 10) { for c in x0..<min(width, x0 + 20) where rng.int(0..<2) == 0 { a[r * width + c] = 40 } }
            }
            pictures.append(AV1HybridEncoder.Picture(y: i % 2 == 0 ? a : b, u: base.u, v: base.v, width: width, height: height))
        }
        var frames: [AV1HybridEncoder.Frame] = []
        try encoder.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { _, f in frames.append(f) })
        let label = "\(width)×\(height) q\(qindex)"
        let header = try #require(AV1Config.sequenceHeaderOBU(inTemporalUnit: frames[0].obu), "\(label): no sequence header")
        let config = try #require(AV1Config.build(sequenceHeaderOBU: header), "\(label): av1C refused")
        let decoder = VTRegionDecoder()
        defer { decoder.stop() }
        try #require(decoder.start(codec: VideoCodec.av1, config: config, width: width, height: height),
                     "\(label): VideoToolbox's AV1 session wasn't created")
        for (i, f) in frames.enumerated() {
            var shown = false
            let ok = decoder.decode(f.obu, sync: i == 0) { pixels, bytesPerRow in
                shown = pixels.count >= bytesPerRow * (height - 1) + width * 4
            }
            #expect(ok && shown, "\(label): frame \(i) didn't decode")
        }
    }
}
