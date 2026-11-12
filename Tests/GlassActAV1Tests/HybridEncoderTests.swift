import AV1Core
import Foundation
import GlassActAV1
import GlassActTestSupport
import Metal
import Synchronization
import Testing
import libaom

/// The hybrid encoder (GPU analysis, CPU closed loop on tile threads, GPU
/// filters, av1core's writer) is an encoder of the decoder's pictures: every
/// stream decodes in libaom to exactly the picture it reports, alone and in
/// an overlapped sequence, and a sequence gives the pictures alone would.
@Suite(.enabled(if: AV1ShaderSource.hasCapableGPU && glassact_aom_available() != 0,
                "needs an Apple-silicon GPU (not a VM's paravirtual one) and libaom (arm64)"))
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

extension HybridEncoderTests {
    /// Inter frames: a window scrolling over a page of glyphs, words typed elsewhere, a photo
    /// that drifts and brightens (never an exact copy, so motion search's), pictures that don't
    /// change; one stream that libaom decodes in order to exactly the pictures the encoder reports
    /// (each of which the next frame references), with scrolled 64×64s copied at their shift,
    /// unchanged ones copied as they are, and searched blocks predicted with a residual. With an
    /// `interPreset`, inter frames analyze fewer block shapes than the key frame.
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(1280, 720, 80, 2, nil), (333, 201, 120, -1, AV1MetalEncoder.Preset.turbo2)])
    func interStreamsDecodeToTheirPictures(width: Int, height: Int, qindex: Int, tilesLog2: Int,
                                           interPreset: AV1MetalEncoder.Preset?) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (tilesLog2, tilesLog2)
        encoder.interPreset = interPreset
        encoder.interFrames = true
        let base = PartitionTests.Picture(width: width, height: height)
        var rng = SplitMix64(seed: 0x5c01)
        let cw = (width + 1) / 2
        // the page: glyph-like luma, tinted chroma
        let (pw, ph) = (width / 2, height * 3)
        var page = [UInt8](repeating: 230, count: pw * ph), pageU = [UInt8](repeating: 120, count: (pw / 2) * (ph / 2))
        for k in page.indices where rng.int(0..<4) == 0 { page[k] = UInt8(rng.int(20..<90)) }
        for k in pageU.indices { pageU[k] = UInt8(100 + (k / 37) % 40) }
        let (wx, wy) = ((width / 4) & ~1, (height / 6) & ~1)
        let wh = min(ph - 2 * height, height - wy - 8) & ~1
        var pictures: [AV1HybridEncoder.Picture] = []
        var y = base.y, u = base.u
        var top = 0
        for i in 0..<12 {
            if i % 4 != 3 { top += 2 * rng.int(1..<12) }  // every fourth picture, no scroll
            for r in 0..<wh {
                for c in 0..<pw where wx + c < width { y[(wy + r) * width + wx + c] = page[(top + r) * pw + c] }
            }
            for r in 0..<wh / 2 {
                for c in 0..<pw / 2 where (wx / 2) + c < cw { u[(wy / 2 + r) * cw + wx / 2 + c] = pageU[(top / 2 + r) * (pw / 2) + c] }
            }
            // the photo: a smooth texture, moved (3, 1) and brightened by 2 a picture, bottom left
            let (px0, py0) = (8, height - min(120, height / 3))
            for r in py0..<min(height, py0 + 96) {
                for c in px0..<min(width / 3, px0 + 160) {
                    let (u0, v0) = (c - px0 + 3 * i, r - py0 + i)
                    y[r * width + c] = UInt8(clamping: 60 + 2 * i + (u0 * 7 + v0 * 3) % 50 + ((u0 / 9 + v0 / 7) % 3) * 20)
                }
            }
            if i % 3 == 1 {  // a word typed at the top left
                let x0 = rng.int(0..<max(1, wx - 24)), y0 = rng.int(0..<max(1, wy - 12))
                for r in y0..<min(height, y0 + 10) { for c in x0..<min(width, x0 + 20) where rng.int(0..<2) == 0 { y[r * width + c] = 40 } }
            }
            pictures.append(AV1HybridEncoder.Picture(y: y, u: u, v: base.v, width: width, height: height))
        }
        let label = "\(width)×\(height) q\(qindex) tiles \(tilesLog2) \(interPreset.map { "inter \($0.rawValue)" } ?? "")"
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var copied = 0.0, shifted = 0.0, searched = 0.0
        try encoder.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { i, f in
            copied += f.timing.copied
            shifted += f.timing.shifted
            searched += f.timing.searched
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, f.obu, f.obu.count, &frame) == 0, "\(label): libaom rejected frame \(i)")
            let sizes = [(width, height), ((width + 1) / 2, (height + 1) / 2), ((width + 1) / 2, (height + 1) / 2)]
            for p in 0..<3 {
                let (w, h) = sizes[p]
                let theirs = try #require(frame.planesTuple(p))
                let stride = Int(frame.stridesTuple(p))
                let rows = (0..<h).filter { r in (0..<w).contains { f.planes[p][r * w + $0] != theirs[r * stride + $0] } }
                #expect(rows.isEmpty, "\(label): frame \(i) plane \(p) differs from libaom on \(rows.count) rows")
            }
        })
        #expect(copied > 0 && shifted > 0, "\(label): copied \(copied), shifted \(shifted): the copies weren't exercised")
        #expect(searched > 0, "\(label): no block was motion-searched")
    }
}

extension HybridEncoderTests {
    /// GOLDEN_FRAME: two screens in turn (one with a word typed into it each time, the other
    /// scrolled), each picture mostly new against the one before. Every picture after the first
    /// two copies the one before that from GOLDEN_FRAME, and the stream decodes in libaom to
    /// exactly the pictures the encoder reports.
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(1280, 720, 80, 2), (333, 201, 120, -1)])
    func goldenFramesDecodeToTheirPictures(width: Int, height: Int, qindex: Int, tilesLog2: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (tilesLog2, tilesLog2)
        encoder.interFrames = true
        var rng = SplitMix64(seed: 0x601d)
        let base = PartitionTests.Picture(width: width, height: height)
        // screen A: glyph-like noise; screen B: a taller page, scrolled 2 rows a picture
        var a = base.y
        for k in a.indices where rng.int(0..<4) == 0 { a[k] = UInt8(rng.int(20..<90)) }
        var page = [UInt8](repeating: 200, count: width * (height + 64))
        for k in page.indices where rng.int(0..<3) == 0 { page[k] = UInt8(rng.int(100..<180)) }
        var pictures: [AV1HybridEncoder.Picture] = []
        for i in 0..<10 {
            if i % 2 == 0 {
                let x0 = rng.int(0..<max(1, width - 24)), y0 = rng.int(0..<max(1, height - 12))
                for r in y0..<min(height, y0 + 10) { for c in x0..<min(width, x0 + 20) where rng.int(0..<2) == 0 { a[r * width + c] = 40 } }
                pictures.append(AV1HybridEncoder.Picture(y: a, u: base.u, v: base.v, width: width, height: height))
            } else {
                let top = 2 * i
                let b = Array(page[(top * width)..<((top + height) * width)])
                pictures.append(AV1HybridEncoder.Picture(y: b, u: base.u, v: base.v, width: width, height: height))
            }
        }
        let label = "\(width)×\(height) q\(qindex) tiles \(tilesLog2)"
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var golden = 0.0
        // the writer's thread hands each frame on as soon as it's written (each write runs beside
        // the next closed loop): every one, in order, the bytes `output` gets later
        let written = Mutex<[(Int, [UInt8])]>([])
        var outputs: [[UInt8]] = []
        try encoder.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, written: { i, f in
            written.withLock { $0.append((i, f.obu)) }
        }, output: { i, f in
            outputs.append(f.obu)
            if i >= 2 { golden += f.timing.copiedGolden }
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, f.obu, f.obu.count, &frame) == 0, "\(label): libaom rejected frame \(i)")
            let sizes = [(width, height), ((width + 1) / 2, (height + 1) / 2), ((width + 1) / 2, (height + 1) / 2)]
            for p in 0..<3 {
                let (w, h) = sizes[p]
                let theirs = try #require(frame.planesTuple(p))
                let stride = Int(frame.stridesTuple(p))
                let rows = (0..<h).filter { r in (0..<w).contains { f.planes[p][r * w + $0] != theirs[r * stride + $0] } }
                #expect(rows.isEmpty, "\(label): frame \(i) plane \(p) differs from libaom on \(rows.count) rows")
            }
        })
        #expect(golden / 8 > 0.5, "\(label): \(golden / 8) of the 64×64s copied GOLDEN_FRAME on average")
        let handed = written.withLock { $0 }
        #expect(handed.map(\.0) == Array(pictures.indices), "\(label): frames handed on \(handed.map(\.0))")
        #expect(handed.map(\.1) == outputs, "\(label): a handed-on frame differs from its output")
    }
}

extension HybridEncoderTests {
    /// Long-term references: four screens (the key frame's and three more, each a different
    /// noise, with a word typed into it every time it's shown) in turn, one of them for two
    /// pictures each time. Every picture of a screen shown before copies most of itself from
    /// GOLDEN_FRAME (the screens share nothing, so only the long-term picture of its own screen
    /// can give it copies), and the stream decodes in libaom to exactly the pictures the encoder
    /// reports. With one long-term picture (GOLDEN_FRAME is the screen before the last one), a
    /// cycle of four copies almost nothing from it.
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(1280, 720, 80, 2, 4), (333, 201, 120, -1, 3), (1280, 720, 80, 2, 1)])
    func longTermReferencesDecodeToTheirPictures(width: Int, height: Int, qindex: Int, tilesLog2: Int, longTerm: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (tilesLog2, tilesLog2)
        encoder.interFrames = true
        encoder.longTermReferences = longTerm
        var rng = SplitMix64(seed: 0x10e7)
        let base = PartitionTests.Picture(width: width, height: height)
        var screens: [[UInt8]] = (0..<4).map { _ in base.y.map { _ in UInt8(rng.int(30..<220)) } }
        let schedule = [0, 1, 1, 2, 3, 0, 1, 1, 2, 3, 0, 1, 2, 3, 3, 0]
        var pictures: [AV1HybridEncoder.Picture] = []
        for s in schedule {
            let x0 = rng.int(0..<max(1, width - 24)), y0 = rng.int(0..<max(1, height - 12))
            for r in y0..<min(height, y0 + 10) { for c in x0..<min(width, x0 + 20) where rng.int(0..<2) == 0 { screens[s][r * width + c] = 16 } }
            pictures.append(AV1HybridEncoder.Picture(y: screens[s], u: base.u, v: base.v, width: width, height: height))
        }
        let label = "\(width)×\(height) q\(qindex) tiles \(tilesLog2), \(longTerm) long-term"
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        // the pictures of a screen shown before (not the one before them): where they copy GOLDEN_FRAME
        let returns = schedule.indices.filter { i in i > 0 && schedule[i] != schedule[i - 1] && schedule[..<i].contains(schedule[i]) }
        var golden: [Double] = []
        try encoder.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { i, f in
            if returns.contains(i) { golden.append(f.timing.copiedGolden) }
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, f.obu, f.obu.count, &frame) == 0, "\(label): libaom rejected frame \(i)")
            let sizes = [(width, height), ((width + 1) / 2, (height + 1) / 2), ((width + 1) / 2, (height + 1) / 2)]
            for p in 0..<3 {
                let (w, h) = sizes[p]
                let theirs = try #require(frame.planesTuple(p))
                let stride = Int(frame.stridesTuple(p))
                let rows = (0..<h).filter { r in (0..<w).contains { f.planes[p][r * w + $0] != theirs[r * stride + $0] } }
                #expect(rows.isEmpty, "\(label): frame \(i) plane \(p) differs from libaom on \(rows.count) rows")
            }
        })
        #expect(golden.count == returns.count, "\(label): \(golden.count) of \(returns.count) returns output")
        if longTerm >= 3 {
            #expect(golden.allSatisfy { $0 > 0.7 }, "\(label): the returns copied \(golden) of their 64×64s from GOLDEN_FRAME")
        } else {
            #expect(golden.reduce(0, +) / Double(max(1, golden.count)) < 0.2, "\(label): the returns copied \(golden) from GOLDEN_FRAME")
        }
    }
}

extension HybridEncoderTests {
    /// Intra block copy: pictures whose text repeats (at even and odd offsets) copy it, with no
    /// post-filters, and decode in libaom to exactly the pictures the encoder reports: as still
    /// pictures (the same one again, keeping its tiles; a photo after it, which doesn't copy and
    /// is filtered whole; then the text again, partly changed) and as a stream, whose inter frames
    /// reference the copying key frame.
    @available(macOS 27, *)
    @Test(.serialized, arguments: [false, true])
    func intraBlockCopyFramesDecodeToTheirPictures(stream: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (1, 0)
        encoder.intraBlockCopy = true
        encoder.interFrames = stream
        let (width, height) = (1280, 720)
        let cw = width / 2
        var rng = SplitMix64(seed: 0x1bc)
        let base = PartitionTests.Picture(width: width, height: height)
        // a block of glyphs, repeated down each half of the picture (a tile each; the right half's
        // copies come from its own first one)
        var text = base
        let (bw, bh) = (200, 48)
        for r in 0..<bh { for c in 0..<bw where rng.int(0..<3) == 0 { text.y[(8 + r) * width + 8 + c] = UInt8(rng.int(20..<90)) } }
        for half in [0, width / 2] {
            for k in 0..<8 {
                let (dx, dy) = (half + 8 + (k % 2) * 250 + k % 3, 70 + k * 80 + k % 2)
                guard dx + bw <= width, dy + bh <= height else { continue }
                for r in 0..<bh { for c in 0..<bw { text.y[(dy + r) * width + dx + c] = text.y[(8 + r) * width + 8 + c] } }
                for r in 0..<bh / 2 { for c in 0..<bw / 2 { text.u[(dy / 2 + r) * cw + dx / 2 + c] = text.u[(4 + r) * cw + 4 + c] } }
            }
        }
        var photo = base
        for k in photo.y.indices { photo.y[k] = UInt8(clamping: 90 + (k % 37) + rng.int(0..<40)) }
        var changed = text
        for r in 300..<340 { for c in 900..<1000 where rng.int(0..<2) == 0 { changed.y[r * width + c] = 30 } }
        let order = stream ? [text, changed, changed, text] : [text, text, photo, changed]
        let pictures = order.map { AV1HybridEncoder.Picture(y: $0.y, u: $0.u, v: $0.v, width: width, height: height) }
        let label = stream ? "stream" : "still pictures"
        var copying = 0
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        try encoder.encode(count: pictures.count, qindex: 80, picture: { pictures[$0] }, output: { i, f in
            if f.timing.intraCopied > 0 {
                copying += 1
                #expect(f.params.allow_intrabc == 1 && f.params.loop_filter_level == (0, 0, 0, 0), "\(label): frame \(i)")
            }
            // a still picture decodes alone (the decoder owns the planes until it's destroyed)
            let alone = stream ? nil : glassact_aom_dec_create(1)
            defer { if let alone { glassact_aom_dec_destroy(alone) } }
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(alone ?? decoder, f.obu, f.obu.count, &frame) == 0,
                         "\(label): libaom rejected frame \(i)")
            let sizes = [(width, height), (cw, height / 2), (cw, height / 2)]
            for p in 0..<3 {
                let (w, h) = sizes[p]
                let theirs = try #require(frame.planesTuple(p))
                let stride = Int(frame.stridesTuple(p))
                let rows = (0..<h).filter { r in (0..<w).contains { f.planes[p][r * w + $0] != theirs[r * stride + $0] } }
                #expect(rows.isEmpty, "\(label): frame \(i) plane \(p) differs from libaom on \(rows.count) rows")
            }
        })
        #expect(copying >= (stream ? 1 : 3), "\(label): \(copying) frames copied")
    }
}

    /// A picture's analysis waits on the GPU for the filters of the picture two before it, and is
    /// read on a thread of its own: a stream that stops early (here its fifth picture can't be
    /// had) must release the analyses already committed behind filters that won't come, and the
    /// next stream on the same encoder codes as it would on a fresh one.
    @available(macOS 27, *)
    @Test func aStreamThatStopsEarlyLeavesTheEncoderAsNew() throws {
        struct Stop: Error {}
        let device = try #require(MTLCreateSystemDefaultDevice())
        func make() throws -> AV1HybridEncoder {
            let e = try AV1HybridEncoder(device: device)
            e.tiling = (1, 1)
            e.interFrames = true
            return e
        }
        let (width, height) = (640, 360)
        var rng = SplitMix64(seed: 0x6a7e)
        // (the stream that stops codes other pictures: a key frame of the picture the last closed
        // loop coded keeps its tiles, and codes differently from a fresh encoder's)
        let all = (0..<12).map { _ -> AV1HybridEncoder.Picture in
            var p = PartitionTests.Picture(width: width, height: height)
            for k in p.y.indices where rng.int(0..<3) == 0 { p.y[k] = UInt8(rng.int(0..<256)) }  // all new each time
            return AV1HybridEncoder.Picture(y: p.y, u: p.u, v: p.v, width: width, height: height)
        }
        let (stopping, pictures) = (Array(all[6...]), Array(all[..<6]))
        let used = try make()
        // (the kernels compiled before the clock starts: an encoder's first pictures wait for
        // them, seconds beside other tests, and Metal keeps them for the next encoder)
        try make().encode(count: 3, qindex: 80, picture: { stopping[$0] }, output: { _, _ in })
        let started = ContinuousClock.now
        #expect(throws: Stop.self) {
            try used.encode(count: stopping.count, qindex: 80, picture: { i in
                if i == 4 { throw Stop() }
                return stopping[i]
            }, output: { _, _ in })
        }
        // (an analysis left waiting would hold the stream's end until the GPU gives up on it: seconds)
        #expect(ContinuousClock.now - started < .seconds(3), "the stream that stopped took \(ContinuousClock.now - started) to end")
        var again: [[UInt8]] = [], fresh: [[UInt8]] = []
        try used.encode(count: pictures.count, qindex: 80, picture: { pictures[$0] }, output: { _, f in again.append(f.obu) })
        try make().encode(count: pictures.count, qindex: 80, picture: { pictures[$0] }, output: { _, f in fresh.append(f.obu) })
        #expect(again.count == pictures.count)
        #expect(again == fresh, "a stream after one that stopped codes differently")
    }

extension HybridEncoderTests {
    /// Learned pruning (on in pictures of 2,000 superblocks and up) changes the
    /// analysis, and the streams stay the decoder's pictures; kept analysis is
    /// still the analysis (each cell's skips depend only on its own superblock).
    @available(macOS 27, *)
    @Test func learnedPruningKeepsStreamsExact() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (width, height) = (4096, 2048)  // 2,048 superblocks
        // lines of glyph-like text over most of the picture, a flat band, a noisy gradient
        var base = PartitionTests.Picture(width: width, height: height)
        var rng = SplitMix64(seed: 0x6d6c_7072)
        for row in 0..<1600 where row % 24 >= 6 && row % 24 < 20 {
            for col in 0..<width where (col / 7 + row / 24) % 9 != 0 && rng.next() % 3 == 0 { base.y[row * width + col] = 40 }
        }
        for row in 1800..<height { for col in 0..<width { base.y[row * width + col] = UInt8(truncatingIfNeeded: col / 16 + Int(rng.next() % 12)) } }
        var edited = base.y
        for row in 300..<420 { for col in 1000..<1500 { edited[row * width + col] = 236 } }  // a paragraph deleted
        let pictures = [base.y, edited].map { AV1HybridEncoder.Picture(y: $0, u: base.u, v: base.v, width: width, height: height) }

        let reusing = try AV1HybridEncoder(device: device), fresh = try AV1HybridEncoder(device: device)
        let unpruned = try AV1HybridEncoder(device: device)
        fresh.reusesAnalysis = false
        unpruned.learnedPrune = nil
        for e in [reusing, fresh, unpruned] { e.tiling = (2, 1) }
        try reusing.encode(count: pictures.count, qindex: 80, picture: { pictures[$0] }, output: { i, frame in
            let alone = try fresh.encode(pictures[i], qindex: 80)
            #expect(frame.obu == alone.obu, "picture \(i) codes differently with kept analysis")
            if i == 0 {
                #expect(try unpruned.encode(pictures[i], qindex: 80).obu != alone.obu, "learned pruning didn't change the analysis")
            }
            let decoder = try #require(glassact_aom_dec_create(4))
            defer { glassact_aom_dec_destroy(decoder) }
            var decoded = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, frame.obu, frame.obu.count, &decoded) == 0, "picture \(i): libaom")
            let theirs = try #require(decoded.planesTuple(0))
            let stride = Int(decoded.stridesTuple(0))
            let rows = (0..<height).filter { r in (0..<width).contains { frame.planes[0][r * width + $0] != theirs[r * stride + $0] } }
            #expect(rows.isEmpty, "picture \(i): luma differs from libaom on \(rows.count) rows")
        })
    }
}

extension HybridEncoderTests {
    /// A qindex per 64×64 (delta-q) keeps the streams the decoder's pictures,
    /// and kept analysis and kept tiles stay right when a superblock's qindex
    /// changes and its source doesn't: a reusing encoder codes what a fresh
    /// one does.
    @available(macOS 27, *)
    @Test func deltaQKeepsStreamsExact() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (width, height) = (1280, 720)
        let base = PartitionTests.Picture(width: width, height: height)
        let picture = AV1HybridEncoder.Picture(y: base.y, u: base.u, v: base.v, width: width, height: height)
        let sbs = ((width + 63) / 64) * ((height + 63) / 64)
        // the same picture three times: the first two with one map, the third with another
        let maps: [[UInt8]] = [0, 0, 1].map { seed in
            var rng = SplitMix64(seed: 0xd1_7a00 + UInt64(seed))
            return (0..<sbs).map { _ in UInt8(60 + Int(rng.next() % 41)) }
        }
        let reusing = try AV1HybridEncoder(device: device), fresh = try AV1HybridEncoder(device: device)
        fresh.reusesAnalysis = false
        for e in [reusing, fresh] { e.tiling = (2, 1) }
        // (the encoder asks for each picture's map once, in order, as it sets its analysis up)
        let calls = Mutex(0)
        reusing.sbQindex = { _, _ in calls.withLock { n in defer { n += 1 }; return maps[min(n, maps.count - 1)] } }
        try reusing.encode(count: maps.count, qindex: 80, picture: { _ in picture }, output: { i, frame in
            fresh.sbQindex = { _, _ in maps[i] }
            let alone = try fresh.encode(picture, qindex: 80)
            #expect(frame.obu == alone.obu, "picture \(i) codes differently with kept analysis and tiles")
            let decoder = try #require(glassact_aom_dec_create(1))
            defer { glassact_aom_dec_destroy(decoder) }
            var decoded = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, frame.obu, frame.obu.count, &decoded) == 0, "picture \(i): libaom")
            let theirs = try #require(decoded.planesTuple(0))
            let stride = Int(decoded.stridesTuple(0))
            let rows = (0..<height).filter { r in (0..<width).contains { frame.planes[0][r * width + $0] != theirs[r * stride + $0] } }
            #expect(rows.isEmpty, "picture \(i): luma differs from libaom on \(rows.count) rows")
        })
    }

    /// RDOQ in each form (contrast-gated, the default; every block; in the tx type trials) changes
    /// the levels, and libaom decodes what the encoder reconstructed.
    @available(macOS 27, *)
    @Test func rdoqKeepsStreamsExact() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (width, height) = (1280, 720)
        let base = PartitionTests.Picture(width: width, height: height)
        let picture = AV1HybridEncoder.Picture(y: base.y, u: base.u, v: base.v, width: width, height: height)
        let none = try AV1HybridEncoder(device: device)
        none.usesRDOQ = false
        let plain = try none.encode(picture, qindex: 80).obu
        var streams: [[UInt8]] = []
        for (range, trials, coeffs) in [(40, false, 0), (0, false, 0), (0, true, 0), (0, false, 17)] {
            let e = try AV1HybridEncoder(device: device)
            e.rdoqMinRange = range
            e.rdoqInTrials = trials
            e.rdoqMinCoefficients = coeffs
            let frame = try e.encode(picture, qindex: 80)
            streams.append(frame.obu)
            #expect(frame.obu != plain, "range \(range), trials \(trials), coefficients \(coeffs): RDOQ changed nothing")
            let decoder = try #require(glassact_aom_dec_create(1))
            defer { glassact_aom_dec_destroy(decoder) }
            var decoded = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, frame.obu, frame.obu.count, &decoded) == 0, "range \(range), trials \(trials), coefficients \(coeffs): libaom")
            let theirs = try #require(decoded.planesTuple(0))
            let stride = Int(decoded.stridesTuple(0))
            let rows = (0..<height).filter { r in (0..<width).contains { frame.planes[0][r * width + $0] != theirs[r * stride + $0] } }
            #expect(rows.isEmpty, "range \(range), trials \(trials), coefficients \(coeffs): luma differs from libaom on \(rows.count) rows")
        }
        // (the 4x4s left to the quantizer: another stream than every tx block's RDOQ)
        #expect(streams[3] != streams[1], "RDOQ from 17 coefficients changed nothing")
    }
}

extension HybridEncoderTests {
    /// `motionSkip`: a stream of a scene whose photo drifts, then of stripes (each picture new),
    /// then of the scene again, searches the scene's frames (quarter samples, blocks predicted at
    /// them), skips the search once two frames that searched found almost nothing (whole samples,
    /// no blocks predicted), two in a row and then searches one, two pictures late (the scene's
    /// return is seen at the third search after it), the search switched frame by frame; libaom
    /// decodes the stream in order to exactly the pictures the encoder reports.
    @available(macOS 27, *)
    @Test func motionSkipMixesSearchedAndSkippedFramesExactly() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (width, height) = (640, 384)
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (1, 1)
        encoder.interFrames = true
        encoder.motionSkip = (threshold: 0.2, recheckEvery: 3)
        let base = PartitionTests.Picture(width: width, height: height)
        var rng = SplitMix64(seed: 0x6e0_5ea7)
        let noise = 5..<13
        var pictures: [AV1HybridEncoder.Picture] = []
        for i in 0..<17 {
            var y = base.y
            if noise.contains(i) {
                // stripes of random levels, new each picture: intra predicts them, the last picture doesn't
                let levels = (0..<width).map { _ in UInt8(rng.int(0..<256)) }
                for k in y.indices { y[k] = levels[k % width] }
            } else {
                // the photo: a smooth texture, moved (3, 1) and brightened by 2 a picture
                for r in 100..<300 {
                    for c in 64..<448 {
                        let (u0, v0) = (c + 3 * i, r + i)
                        y[r * width + c] = UInt8(clamping: 60 + 2 * i + (u0 * 7 + v0 * 3) % 50 + ((u0 / 9 + v0 / 7) % 3) * 20)
                    }
                }
            }
            pictures.append(AV1HybridEncoder.Picture(y: y, u: base.u, v: base.v, width: width, height: height))
        }
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var skipped: [Int] = [], run = 0, longest = 0, found: [String] = []
        try encoder.encode(count: pictures.count, qindex: 100, picture: { pictures[$0] }, output: { i, f in
            if i > 0 {
                let t = f.timing
                found.append(t.searchedMotion ? String(format: "%.2f", t.motionFound) : "-")
                #expect(f.params.mv_precision == (t.searchedMotion ? 1 : 0), "frame \(i): mv_precision \(f.params.mv_precision)")
                if t.searchedMotion {
                    run = 0
                    if (1..<5).contains(i) || i == 16 { #expect(t.motionFound >= 0.5 && t.searched > 0, "frame \(i): found \(t.motionFound)") }
                } else {
                    skipped.append(i)
                    run += 1
                    longest = max(longest, run)
                    #expect(t.searched == 0 && t.motionFound < 0, "frame \(i): blocks predicted without a motion search")
                }
            }
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, f.obu, f.obu.count, &frame) == 0, "libaom rejected frame \(i)")
            let sizes = [(width, height), ((width + 1) / 2, (height + 1) / 2), ((width + 1) / 2, (height + 1) / 2)]
            for p in 0..<3 {
                let (w, h) = sizes[p]
                let theirs = try #require(frame.planesTuple(p))
                let stride = Int(frame.stridesTuple(p))
                let rows = (0..<h).filter { r in (0..<w).contains { f.planes[p][r * w + $0] != theirs[r * stride + $0] } }
                #expect(rows.isEmpty, "frame \(i) plane \(p) differs from libaom on \(rows.count) rows")
            }
        })
        // frames 5 and 6 (stripes) find nothing, so 8 and 9 skip, 10 searches; 11 and 12 skip, 13
        // (the scene against stripes) searches and finds nothing; 14 and 15 skip, 16 searches
        #expect(skipped == [8, 9, 11, 12, 14, 15], "skipped the motion search in frames \(skipped), found \(found)")
        #expect(longest <= 2, "skipped \(longest) frames in a row")
    }

    /// A stream coded without its pictures handed back (`returnsPlanes` off: the closed loop reads
    /// its reference where the filters left it, on the GPU) has the bytes of the same stream coded
    /// with them, which the tests above decode. At qindex 32 and under there's no CDEF, so the
    /// filters' output is the buffers the next picture is reconstructed into: the closed loop must
    /// not predict from what it has overwritten (a page scrolled down reads above itself; a key
    /// frame finer than its inter frames puts only the key frame there).
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(1280, 720, 24, 0), (1280, 720, 44, -16), (333, 201, 16, 0), (1280, 720, 80, 0)])
    func aStreamWithoutItsPicturesHasTheSameBytes(width: Int, height: Int, qindex: Int, keyDelta: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var rng = SplitMix64(seed: 0xa11a5)
        let base = PartitionTests.Picture(width: width, height: height)
        // two screens in turn, so pictures go to long-term slots and come back from GOLDEN_FRAME:
        // glyph-like noise with a word typed into it each time, and a page taller than the screen
        // scrolled down then up 64 rows (copies at a shift from above and below)
        var a = base.y
        for k in a.indices where rng.int(0..<4) == 0 { a[k] = UInt8(rng.int(20..<90)) }
        var page = [UInt8](repeating: 200, count: width * (height + 256))
        for k in page.indices where rng.int(0..<3) == 0 { page[k] = UInt8(rng.int(60..<180)) }
        var pictures: [AV1HybridEncoder.Picture] = []
        for (i, top) in [192, 192, 128, 64, 64, 0, 64, 128, 128, 192].enumerated() {
            if i % 3 == 1 {
                let x0 = rng.int(0..<max(1, width - 24)), y0 = rng.int(0..<max(1, height - 12))
                for r in y0..<min(height, y0 + 10) { for c in x0..<min(width, x0 + 20) where rng.int(0..<2) == 0 { a[r * width + c] = 40 } }
                pictures.append(AV1HybridEncoder.Picture(y: a, u: base.u, v: base.v, width: width, height: height))
            } else {
                let x0 = rng.int(0..<max(1, width - 24)), y0 = top + rng.int(0..<max(1, height - 12))
                for r in y0..<(y0 + 10) { for c in x0..<min(width, x0 + 20) where rng.int(0..<2) == 0 { page[r * width + c] = 16 } }
                pictures.append(AV1HybridEncoder.Picture(y: Array(page[(top * width)..<((top + height) * width)]), u: base.u, v: base.v,
                                                         width: width, height: height))
            }
        }
        func stream(planes: Bool) throws -> (bytes: [[UInt8]], shifted: Double, golden: Double) {
            let encoder = try AV1HybridEncoder(device: device)
            encoder.tiling = (width > 640 ? 1 : -1, width > 640 ? 1 : -1)
            encoder.interFrames = true
            encoder.keyFrameQindexDelta = keyDelta
            encoder.returnsPlanes = planes
            var bytes: [[UInt8]] = [], shifted = 0.0, golden = 0.0
            try encoder.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { _, f in
                bytes.append(f.obu)
                shifted += f.timing.shifted
                golden += f.timing.copiedGolden
            })
            return (bytes, shifted, golden)
        }
        let label = "\(width)×\(height) q\(qindex) key delta \(keyDelta)"
        let with = try stream(planes: true), without = try stream(planes: false)
        #expect(with.shifted > 0, "\(label): no picture copied at a shift")
        #expect(with.golden > 0, "\(label): no picture copied from GOLDEN_FRAME")
        #expect(with.bytes.count == pictures.count && without.bytes.count == pictures.count, "\(label)")
        for (i, (a, b)) in zip(with.bytes, without.bytes).enumerated() {
            #expect(a == b, "\(label): frame \(i) differs without its pictures (\(a.count) and \(b.count) bytes)")
        }
    }

    /// A key frame at another qindex than its inter frames (`keyFrameQindexDelta`): its header's
    /// base_q_idx is the given qindex plus the delta (clamped to 1…255), the inter frames' the
    /// given one, and the stream (a screen typed into, another screen, then the first again, which
    /// copies the key frame from GOLDEN_FRAME) decodes in libaom to exactly the pictures the
    /// encoder reports. Finer, the key frame comes out closer to its picture than at the given qindex.
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(1280, 720, 120, -40, 2), (333, 201, 20, -48, -1), (1280, 720, 80, 16, 1)])
    func keyFramesAtTheirOwnQindexDecodeToTheirPictures(width: Int, height: Int, qindex: Int, delta: Int, tilesLog2: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (tilesLog2, tilesLog2)
        encoder.interFrames = true
        encoder.newPictureEffort = nil  // (its mostly-new pictures would take a qindex of their own)
        var rng = SplitMix64(seed: 0x6e7)
        let base = PartitionTests.Picture(width: width, height: height)
        var screens: [[UInt8]] = (0..<2).map { _ in base.y.map { _ in UInt8(rng.int(30..<220)) } }
        let schedule = [0, 0, 0, 1, 1, 0, 0]
        var pictures: [AV1HybridEncoder.Picture] = []
        for s in schedule {
            let x0 = rng.int(0..<max(1, width - 24)), y0 = rng.int(0..<max(1, height - 12))
            for r in y0..<min(height, y0 + 10) { for c in x0..<min(width, x0 + 20) where rng.int(0..<2) == 0 { screens[s][r * width + c] = 16 } }
            pictures.append(AV1HybridEncoder.Picture(y: screens[s], u: base.u, v: base.v, width: width, height: height))
        }
        let label = "\(width)×\(height) q\(qindex) key delta \(delta) tiles \(tilesLog2)"
        func sse(_ f: AV1HybridEncoder.Frame, _ p: AV1HybridEncoder.Picture) -> Int {
            zip(f.planes[0], p.y).reduce(0) { $0 + (Int($1.0) - Int($1.1)) * (Int($1.0) - Int($1.1)) }
        }
        let plain = try encoder.encode(pictures[0], qindex: qindex)
        encoder.keyFrameQindexDelta = delta
        let keyQindex = min(255, max(1, qindex + delta))
        #expect(encoder.keyFrameQindex(qindex) == keyQindex, "\(label)")
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var keySSE = 0
        try encoder.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { i, f in
            #expect(Int(f.params.base_q_idx) == (i == 0 ? keyQindex : qindex), "\(label): frame \(i) at qindex \(f.params.base_q_idx)")
            if i == 0 { keySSE = sse(f, pictures[0]) }
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, f.obu, f.obu.count, &frame) == 0, "\(label): libaom rejected frame \(i)")
            let sizes = [(width, height), ((width + 1) / 2, (height + 1) / 2), ((width + 1) / 2, (height + 1) / 2)]
            for p in 0..<3 {
                let (w, h) = sizes[p]
                let theirs = try #require(frame.planesTuple(p))
                let stride = Int(frame.stridesTuple(p))
                let rows = (0..<h).filter { r in (0..<w).contains { f.planes[p][r * w + $0] != theirs[r * stride + $0] } }
                #expect(rows.isEmpty, "\(label): frame \(i) plane \(p) differs from libaom on \(rows.count) rows")
            }
        })
        if delta < 0 {
            #expect(keySSE < sse(plain, pictures[0]), "\(label): the key frame's SSE \(keySSE), at the given qindex \(sse(plain, pictures[0]))")
        }
        // a picture alone is a key frame too
        let alone = try encoder.encode(pictures[0], qindex: qindex)
        #expect(Int(alone.params.base_q_idx) == keyQindex, "\(label): a picture alone at qindex \(alone.params.base_q_idx)")
    }
}

extension HybridEncoderTests {
    /// `newPictureEffort`: a stream of a scene whose photo drifts, broken twice by three pictures
    /// of stripes (each new), takes the fast levers (no motion search, no tx type search, no RDOQ,
    /// no 4x4s, looser learned pruning, no CDEF, whole-sample motion) and a coarser qindex in the first two mostly-new pictures
    /// of each run (`runLimit`) and in no other, without the motion search in the first alone
    /// (`motionlessRun`), the levers switched frame by frame; libaom decodes
    /// the stream in order to exactly the pictures the encoder reports. An effort that changes
    /// nothing codes the stream without one, byte for byte.
    @available(macOS 27, *)
    @Test func newPictureEffortMixesFastAndNormalPicturesExactly() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (width, height) = (640, 384)
        let base = PartitionTests.Picture(width: width, height: height)
        var rng = SplitMix64(seed: 0xfa57_9e3)
        let stripes: Set = [5, 6, 7, 11, 12, 13]
        var pictures: [AV1HybridEncoder.Picture] = []
        for i in 0..<16 {
            var y = base.y
            if stripes.contains(i) {
                let levels = (0..<width).map { _ in UInt8(rng.int(0..<256)) }
                for k in y.indices { y[k] = levels[k % width] }
            } else {
                for r in 100..<300 {
                    for c in 64..<448 {
                        let (u0, v0) = (c + 3 * i, r + i)
                        y[r * width + c] = UInt8(clamping: 60 + 2 * i + (u0 * 7 + v0 * 3) % 50 + ((u0 / 9 + v0 / 7) % 3) * 20)
                    }
                }
            }
            pictures.append(AV1HybridEncoder.Picture(y: y, u: base.u, v: base.v, width: width, height: height))
        }
        func make(_ effort: AV1HybridEncoder.NewPictureEffort?) throws -> AV1HybridEncoder {
            let encoder = try AV1HybridEncoder(device: device)
            encoder.tiling = (1, 1)
            encoder.interFrames = true
            encoder.newPictureEffort = effort
            return encoder
        }
        let qindex = 100
        var effort = AV1HybridEncoder.NewPictureEffort(
            qindexDelta: 24, searchesMotion: false, searchesTxTypes: false, usesRDOQ: false,
            analysis: .init(shapeMask: 0x1248, eps: 0.1, modeEps: 0.1, subpel: false))
        effort.runLimit = 2
        effort.cdef = false
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var fast: [Int] = []
        try make(effort).encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { i, f in
            let t = f.timing
            if t.fast { fast.append(i) }
            if i > 0 {
                #expect(Int(f.params.base_q_idx) == (t.fast ? qindex + 24 : qindex), "frame \(i): qindex \(f.params.base_q_idx)")
                // (the motion search off in a run's first picture alone: `motionlessRun`)
                #expect(t.searchedMotion == ![5, 11].contains(i), "frame \(i): searched for motion: \(t.searchedMotion)")
                // (whole samples in the fast pictures that search: 6 and 12)
                #expect(f.params.mv_precision == (t.searchedMotion && !t.fast ? 1 : 0), "frame \(i): mv_precision \(f.params.mv_precision)")
            }
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, f.obu, f.obu.count, &frame) == 0, "libaom rejected frame \(i)")
            let sizes = [(width, height), ((width + 1) / 2, (height + 1) / 2), ((width + 1) / 2, (height + 1) / 2)]
            for p in 0..<3 {
                let (w, h) = sizes[p]
                let theirs = try #require(frame.planesTuple(p))
                let stride = Int(frame.stridesTuple(p))
                let rows = (0..<h).filter { r in (0..<w).contains { f.planes[p][r * w + $0] != theirs[r * stride + $0] } }
                #expect(rows.isEmpty, "frame \(i) plane \(p) differs from libaom on \(rows.count) rows")
            }
        })
        // each run of stripes: its first two pictures (the third is past `runLimit`)
        #expect(fast == [5, 6, 11, 12], "fast pictures \(fast)")
        var plain: [[UInt8]] = [], neutral: [[UInt8]] = []
        try make(nil).encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { _, f in plain.append(f.obu) })
        try make(AV1HybridEncoder.NewPictureEffort()).encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] },
                                                               output: { _, f in neutral.append(f.obu) })
        #expect(neutral == plain, "an effort that changes nothing changed the stream")
    }
}
