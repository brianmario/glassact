import AV1Core
import Foundation
import GlassActAV1
import GlassActTestSupport
import Metal
import Testing
import libaom

/// The hybrid encoder (GPU analysis, CPU closed loop on tile threads, GPU
/// filters, av1core's writer) is an encoder of the decoder's pictures: every
/// stream decodes in libaom to exactly the picture it reports, alone and in
/// an overlapped sequence, and a sequence gives the pictures alone would.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil && glassact_aom_available() != 0,
                "needs a Metal device and libaom (arm64)"))
struct HybridEncoderTests {
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(333, 201, 40, -1), (1280, 720, 120, 2), (1280, 720, 200, 1)])
    func streamsDecodeToTheirPictures(width: Int, height: Int, qindex: Int, tilesLog2: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (tilesLog2, tilesLog2)
        let pictures = (0..<3).map { i -> AV1HybridEncoder.Picture in
            var p = PartitionTests.Picture(width: width, height: height)
            for k in stride(from: i * 7, to: p.y.count, by: 997) { p.y[k] = UInt8(truncatingIfNeeded: k) }  // three different pictures
            return AV1HybridEncoder.Picture(y: p.y, u: p.u, v: p.v, width: width, height: height)
        }
        var sequence: [AV1HybridEncoder.Frame] = []
        try encoder.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { _, f in sequence.append(f) })
        let label = "\(width)×\(height) q\(qindex) tiles \(tilesLog2)"
        for (i, picture) in pictures.enumerated() {
            let alone = try encoder.encode(picture, qindex: qindex)
            #expect(alone.obu == sequence[i].obu, "\(label): picture \(i) codes differently in a sequence")
            let decoder = try #require(glassact_aom_dec_create(1))
            defer { glassact_aom_dec_destroy(decoder) }
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, alone.obu, alone.obu.count, &frame) == 0, "\(label): libaom")
            let sizes = [(width, height), ((width + 1) / 2, (height + 1) / 2), ((width + 1) / 2, (height + 1) / 2)]
            for p in 0..<3 {
                let (w, h) = sizes[p]
                let theirs = try #require(frame.planesTuple(p))
                let stride = Int(frame.stridesTuple(p))
                let rows = (0..<h).filter { r in (0..<w).contains { alone.planes[p][r * w + $0] != theirs[r * stride + $0] } }
                #expect(rows.isEmpty, "\(label): picture \(i) plane \(p) differs from libaom on \(rows.count) rows")
            }
        }
    }
}

extension HybridEncoderTests {
    /// Filtering only around changes stays the decoder's picture over a long
    /// sequence of small edits, including pictures whose CDEF presets change
    /// (every 64×64's preset is redone then, and CDEF reruns where a strength
    /// changed, on a deblocked frame that must be exact everywhere: an early
    /// version re-filtered samples next to the changed area twice, which only
    /// showed when a later picture's new presets reran CDEF there).
    @available(macOS 27, *)
    @Test func regionFilteringStaysExactAcrossPresetChanges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (width, height) = (1280, 720)
        let reusing = try AV1HybridEncoder(device: device), fresh = try AV1HybridEncoder(device: device)
        fresh.reusesAnalysis = false
        for e in [reusing, fresh] { e.tiling = (2, 2) }
        let base = PartitionTests.Picture(width: width, height: height)
        var rng = SplitMix64(seed: 0xcdef_1234)
        var pictures: [AV1HybridEncoder.Picture] = []
        var y = base.y
        for _ in 0..<40 {
            // a word typed, a patch repainted: soft or grainy, so CDEF's best strengths move
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let w = Int.random(in: 8...320, using: &rng), h = Int.random(in: 8...160, using: &rng)
                let x0 = Int.random(in: 0..<width - w, using: &rng), y0 = Int.random(in: 0..<height - h, using: &rng)
                let grain = Int.random(in: 0...48, using: &rng), level = Int.random(in: 40...200, using: &rng)
                for r in y0..<y0 + h {
                    for c in x0..<x0 + w {
                        let v = level + (r - y0) / 2 + ((c / 3 + r / 5) % 7 == 0 ? 60 : 0) + Int.random(in: -grain...grain, using: &rng)
                        y[r * width + c] = UInt8(clamping: v)
                    }
                }
            }
            pictures.append(AV1HybridEncoder.Picture(y: y, u: base.u, v: base.v, width: width, height: height))
        }
        var presetChanges = 0
        var last: av1g_frame_params?
        try reusing.encode(count: pictures.count, qindex: 80, picture: { pictures[$0] }, output: { i, frame in
            let alone = try fresh.encode(pictures[i], qindex: 80)
            #expect(frame.obu == alone.obu, "picture \(i) codes differently with kept analysis")
            #expect(frame.planes == alone.planes, "picture \(i) filters differently around changes")
            func presets(_ p: av1g_frame_params) -> [UInt8] {
                [p.cdef_bits] + withUnsafeBytes(of: p.cdef_y_pri) { Array($0) } + withUnsafeBytes(of: p.cdef_y_sec) { Array($0) }
                    + withUnsafeBytes(of: p.cdef_uv_pri) { Array($0) } + withUnsafeBytes(of: p.cdef_uv_sec) { Array($0) }
            }
            if let last, presets(last) != presets(frame.params) {
                presetChanges += 1
            }
            last = frame.params
        })
        #expect(presetChanges > 0, "no picture changed the CDEF presets, so the case wasn't exercised")
    }

    /// Kept analysis is the analysis: a sequence where only a little moves
    /// (a caret blinking, a word typed, a region scrolled) codes every picture
    /// exactly as an encoder that analyzes everything does.
    @available(macOS 27, *)
    @Test(arguments: [(1280, 720, 2), (333, 201, -1)])
    func reusedAnalysisCodesAsFreshAnalysis(width: Int, height: Int, tilesLog2: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let reusing = try AV1HybridEncoder(device: device), fresh = try AV1HybridEncoder(device: device)
        fresh.reusesAnalysis = false
        for e in [reusing, fresh] { e.tiling = (tilesLog2, tilesLog2) }
        let base = PartitionTests.Picture(width: width, height: height)
        let edits: [(x: Int, y: Int, w: Int, h: Int)] = [(0, 0, 0, 0), (40, 40, 3, 12), (40, 40, 3, 12), (100, 60, 60, 8),
                                                        (0, 150, width, 20), (width - 5, height - 5, 5, 5)]
        var pictures: [AV1HybridEncoder.Picture] = []
        var y = base.y
        for (i, e) in edits.enumerated() {
            for r in e.y..<min(height, e.y + e.h) { for c in e.x..<min(width, e.x + e.w) { y[r * width + c] = UInt8(truncatingIfNeeded: 37 * i + r + c) } }
            pictures.append(AV1HybridEncoder.Picture(y: y, u: base.u, v: base.v, width: width, height: height))
        }
        var kept = 0.0
        try reusing.encode(count: pictures.count, qindex: 120, picture: { pictures[$0] }, output: { i, frame in
            kept += frame.timing.kept
            let alone = try fresh.encode(pictures[i], qindex: 120)
            #expect(frame.obu == alone.obu, "\(width)×\(height): picture \(i) codes differently with kept analysis")
            // and the picture it reports, filtered only around what changed, is the decoder's
            #expect(frame.planes == alone.planes, "\(width)×\(height): picture \(i) filters differently around changes")
            let decoder = try #require(glassact_aom_dec_create(1))
            defer { glassact_aom_dec_destroy(decoder) }
            var decoded = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, frame.obu, frame.obu.count, &decoded) == 0)
            let theirs = try #require(decoded.planesTuple(0))
            let stride = Int(decoded.stridesTuple(0))
            let rows = (0..<height).filter { r in (0..<width).contains { frame.planes[0][r * width + $0] != theirs[r * stride + $0] } }
            #expect(rows.isEmpty, "\(width)×\(height): picture \(i) differs from libaom on \(rows.count) rows")
        })
        #expect(kept > 0.5, "\(width)×\(height): almost nothing was kept (\(kept) pictures' worth)")
    }
}
