import AV1Core
import Foundation
import GlassActAV1
import GlassActAV1Decode
import GlassActCore
import GlassActTestSupport
import GlassActWire
import Metal
import Testing

/// `OwnAV1RegionDecoder`, Glass Act's own AV1 decoder as a Viewer's region decoder, on the hybrid
/// encoder's output: every frame shown is the encoder's picture (compared in Y, U, V before the
/// conversion), the BGRA is the conversion the stream's header asks for, damage and inter frames
/// after it fail until the next key frame, and the region's size caps the stream.
struct OwnAV1RegionDecoderTests {
    static let av1C: [UInt8] = [0x81, 0x00, 0x0C, 0x00]

    @Test func startTakesAV1AtARegionsSizeOnly() {
        let d = OwnAV1RegionDecoder(threads: 2)
        #expect(!d.start(codec: VideoCodec.hevc, config: Self.av1C, width: 64, height: 64))
        #expect(!d.start(codec: VideoCodec.av1, config: [0x12], width: 64, height: 64))
        #expect(!d.start(codec: VideoCodec.av1, config: Self.av1C, width: 0, height: 64))
        #expect(!d.start(codec: VideoCodec.av1, config: Self.av1C, width: 64, height: 8193))
        #expect(d.start(codec: VideoCodec.av1, config: Self.av1C, width: 64, height: 64))
        #expect(d.start(codec: VideoCodec.av1, config: Self.av1C, width: 128, height: 64), "a second start")
        #expect(d.size == (128, 64))
        // nothing decodes from nothing, or from bytes that aren't a temporal unit
        #expect(!d.decode([], sync: true) { _, _ in })
        #expect(!d.decode([0x12, 0x00], sync: true) { _, _ in })
        #expect(!d.decode(Array(repeating: 0xA5, count: 300), sync: true) { _, _ in })
        d.stop()
        #expect(!d.decode([0x12, 0x00], sync: true) { _, _ in }, "after stop")
        d.stop()
    }

    // MARK: - On the hybrid's frames

    /// Pictures that copy, scroll and change: rows of a few values, shifted and edited, with
    /// chroma that varies.
    @available(macOS 27, *)
    static func pictures(_ n: Int, width: Int, height: Int, seed: UInt64) -> [AV1HybridEncoder.Picture] {
        var rng = SplitMix64(seed: seed)
        let (cw, ch) = ((width + 1) / 2, (height + 1) / 2)
        var y = [UInt8](repeating: 0, count: width * height)
        var u = [UInt8](repeating: 128, count: cw * ch), v = u
        for k in y.indices { y[k] = UInt8(truncatingIfNeeded: (k / width) * 7 + (k % 61 < 30 ? 40 : 200)) }
        for k in u.indices {
            let (x, r) = (k % cw, k / cw)
            u[k] = (x / 24 + r / 16) % 3 == 0 ? 90 : 128
            v[k] = (x / 40) % 2 == 0 ? 170 : 128
        }
        return (0..<n).map { i in
            var (py, pu, pv) = (y, u, v)
            let shift = (i % 3) * 64
            for k in py.indices { py[k] = y[(k + shift * width) % y.count] }
            for k in pu.indices { pu[k] = u[(k + shift / 2 * cw) % u.count]; pv[k] = v[(k + shift / 2 * cw) % v.count] }
            for _ in 0..<(i % 4 == 3 ? width * height / 3 : 200) { py[rng.int(0..<py.count)] = UInt8(rng.int(0..<256)) }
            return AV1HybridEncoder.Picture(y: py, u: pu, v: pv, width: width, height: height)
        }
    }

    /// A 4:4:4 picture: a title bar, coloured glyphs sample by sample, one-sample colour stripes,
    /// a gradient whose chroma follows luma.
    @available(macOS 27, *)
    static func picture444(width: Int, height: Int, seed: UInt64) -> AV1HybridEncoder.Picture {
        var rng = SplitMix64(seed: seed)
        let n = width * height
        var y = [UInt8](repeating: 236, count: n), u = [UInt8](repeating: 128, count: n), v = u
        for r in 0..<min(12, height) { for c in 0..<width { (y[r * width + c], u[r * width + c], v[r * width + c]) = (210, 120, 134) } }
        for r in min(12, height - 1)..<min(height, 60) {
            for c in 0..<min(width, 200) where rng.int(0..<3) == 0 {
                let k = r * width + c
                (y[k], u[k], v[k]) = (UInt8(rng.int(20..<90)), UInt8(rng.int(40..<216)), UInt8(rng.int(40..<216)))
            }
        }
        for r in 0..<height { for c in (width * 3 / 4)..<width { u[r * width + c] = c % 2 == 0 ? 70 : 190; v[r * width + c] = r % 2 == 0 ? 60 : 200 } }
        for r in (height - min(40, height / 3))..<height {
            for c in 0..<width {
                let k = r * width + c, l = c / 4 + r / 3 + rng.int(0..<10)
                y[k] = UInt8(clamping: l)
                u[k] = UInt8(clamping: 128 + (l - 128) / 2)
                v[k] = UInt8(clamping: 128 - (l - 128) / 3)
            }
        }
        return AV1HybridEncoder.Picture(y: y, u: u, v: v, width: width, height: height, chroma444: true)
    }

    @available(macOS 27, *)
    static func encoder(interFrames: Bool) throws -> AV1HybridEncoder {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let e = try AV1HybridEncoder(device: device)
        e.tiling = (1, 0)
        e.interFrames = interFrames
        return e
    }

    @available(macOS 27, *)
    static func frames(_ e: AV1HybridEncoder, _ pictures: [AV1HybridEncoder.Picture], qindex: Int) throws -> [AV1HybridEncoder.Frame] {
        var out: [AV1HybridEncoder.Frame] = []
        try e.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { _, f in out.append(f) })
        return out
    }

    @available(macOS 27, *)
    static func isKey(_ f: AV1HybridEncoder.Frame) -> Bool { f.params.frame_type != UInt8(AV1G_FRAME_INTER) }

    /// The shown picture's planes, cropped.
    static func shownPlanes(_ d: OwnAV1RegionDecoder) -> [[UInt8]]? {
        d.withShownPicture { p in
            let planes = [p.planes.0, p.planes.1, p.planes.2], strides = [p.stride.0, p.stride.1, p.stride.2]
            let ws = [p.plane_w.0, p.plane_w.1, p.plane_w.2], hs = [p.plane_h.0, p.plane_h.1, p.plane_h.2]
            return (0..<3).map { k in
                guard let base = planes[k] else { return [] }
                var out: [UInt8] = []
                for r in 0..<Int(hs[k]) { out.append(contentsOf: UnsafeBufferPointer(start: base + r * Int(strides[k]), count: Int(ws[k]))) }
                return out
            }
        }
    }

    /// Decodes `f` into `d`: whether it was shown, and its BGRA (tight rows).
    @available(macOS 27, *)
    @discardableResult
    static func decode(_ d: OwnAV1RegionDecoder, _ f: AV1HybridEncoder.Frame, width: Int, height: Int,
                       obu: [UInt8]? = nil) -> (Bool, [UInt8]) {
        var bgra: [UInt8] = []
        let ok = d.decode(obu ?? f.obu, sync: isKey(f)) { px, rowBytes in
            for r in 0..<height { bgra.append(contentsOf: px[(r * rowBytes)..<(r * rowBytes + width * 4)]) }
        }
        return (ok, bgra)
    }

    @available(macOS 27, *)
    @Test(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (the hybrid encoder)"),
          arguments: [(640, 360), (334, 202)])
    func keyAndInterFramesDecodeToTheEncodersPictures(width: Int, height: Int) throws {
        let e = try Self.encoder(interFrames: true)
        let frames = try Self.frames(e, Self.pictures(10, width: width, height: height, seed: 0xD3C0), qindex: 80)
        let d = OwnAV1RegionDecoder(threads: 4)
        try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
        for (i, f) in frames.enumerated() {
            let (ok, bgra) = Self.decode(d, f, width: width, height: height)
            #expect(ok, "frame \(i) (\(Self.isKey(f) ? "key" : "inter"))")
            #expect(bgra.count == width * height * 4)
            #expect(Self.shownPlanes(d) == f.planes, "frame \(i): not the encoder's picture")
        }
        #expect(frames.filter(Self.isKey).count == 1)
        #expect(d.stats.framesShown == frames.count && d.stats.keyFramesShown == 1 && d.stats.failures == 0)
    }

    @available(macOS 27, *)
    @Test(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (the hybrid encoder)"))
    func damageFailsUntilTheNextKeyFrame() throws {
        let (width, height) = (448, 256)
        let e = try Self.encoder(interFrames: true)
        let pictures = Self.pictures(12, width: width, height: height, seed: 0xBAD)
        let first = try Self.frames(e, Array(pictures[0..<6]), qindex: 80)
        let second = try Self.frames(e, Array(pictures[6...]), qindex: 80)  // a new stream: a key frame
        try #require(Self.isKey(second[0]) && !Self.isKey(second[1]))
        let d = OwnAV1RegionDecoder(threads: 2)
        try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
        for f in first[0..<3] { #expect(Self.decode(d, f, width: width, height: height).0) }
        // an inter frame cut short, then whole inter frames that need what it would have made
        let cut = Array(first[3].obu.prefix(first[3].obu.count / 3))
        #expect(!Self.decode(d, first[3], width: width, height: height, obu: cut).0, "a truncated inter frame")
        #expect(Self.shownPlanes(d) == nil)
        for (i, f) in first[4...].enumerated() {
            #expect(!Self.decode(d, f, width: width, height: height).0, "inter frame \(i) after the damage")
        }
        // the next key frame, and the inter frames after it, are the encoder's pictures
        for (i, f) in second.enumerated() {
            #expect(Self.decode(d, f, width: width, height: height).0, "frame \(i) of the next stream")
            #expect(Self.shownPlanes(d) == f.planes, "frame \(i) of the next stream: not the encoder's picture")
        }
        // damage in the middle of a frame (tile data overwritten); a damaged key frame; random bytes
        var flipped = second[3].obu
        for k in stride(from: flipped.count / 2, to: flipped.count, by: 7) { flipped[k] ^= 0x5A }
        let r = Self.decode(d, second[3], width: width, height: height, obu: flipped)
        #expect(!r.0 || Self.shownPlanes(d) != nil, "a frame shown without its picture")
        let cutKey = Array(second[0].obu.prefix(second[0].obu.count - 5))
        #expect(!Self.decode(d, second[0], width: width, height: height, obu: cutKey).0, "a truncated key frame")
        #expect(!Self.decode(d, second[1], width: width, height: height).0, "an inter frame after a damaged key frame")
        var rng = SplitMix64(seed: 7)
        #expect(!d.decode(rng.bytes(500), sync: true) { _, _ in })
        #expect(Self.decode(d, second[0], width: width, height: height).0, "the key frame again")
        #expect(Self.shownPlanes(d) == second[0].planes)
        // after a stop and a start, a key frame first
        d.stop()
        try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
        #expect(!Self.decode(d, second[1], width: width, height: height).0, "an inter frame first")
        #expect(Self.decode(d, second[0], width: width, height: height).0)
        #expect(Self.decode(d, second[1], width: width, height: height).0)
        #expect(Self.shownPlanes(d) == second[1].planes)
        #expect(d.stats.failures >= 4)
    }

    @available(macOS 27, *)
    @Test(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (the hybrid encoder)"))
    func aStreamLargerThanTheRegionIsRefused() throws {
        let e = try Self.encoder(interFrames: true)
        let frames = try Self.frames(e, Self.pictures(3, width: 640, height: 360, seed: 3), qindex: 80)
        for (w, h) in [(320, 180), (638, 360), (640, 358)] {
            let d = OwnAV1RegionDecoder(threads: 2)
            try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: w, height: h))
            for (i, f) in frames.enumerated() {
                #expect(!Self.decode(d, f, width: w, height: h).0, "\(w)×\(h) region, frame \(i)")
            }
        }
        // and a region larger than the stream isn't shown a picture of another size
        let d = OwnAV1RegionDecoder(threads: 2)
        try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: 704, height: 360))
        #expect(!Self.decode(d, frames[0], width: 704, height: 360).0)
    }

    @available(macOS 27, *)
    @Test(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (the hybrid encoder)"),
          arguments: [(640, 360), (333, 201), (96, 64), (17, 9)])
    func chroma444KeyFramesDecodeExactly(width: Int, height: Int) throws {
        let e = try Self.encoder(interFrames: false)
        e.tiling = (-1, -1)
        for (k, q) in [8, 60, 140].enumerated() {
            let f = try e.encode(Self.picture444(width: width, height: height, seed: UInt64(k + 1)), qindex: q)
            try #require(f.planes.count == 3 && f.planes[1].count == width * height, "not a 4:4:4 picture")
            let d = OwnAV1RegionDecoder(threads: 2)
            try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
            let (ok, bgra) = Self.decode(d, f, width: width, height: height)
            #expect(ok, "\(width)×\(height) q\(q)")
            #expect(Self.shownPlanes(d) == f.planes, "\(width)×\(height) q\(q): not the encoder's picture")
            #expect(d.withShownPicture { $0.chroma_format } == UInt8(AV1G_CHROMA_444))
            if ok { try Self.checkConversion(d, bgra, width: width, height: height) }
        }
    }

    /// A 4:4:4 stream (the hybrid's 4:4:4 inter frames): every key and inter frame (copies at odd
    /// shifts, coded changes, one-sample colour stripes) is the encoder's picture, shown in the
    /// colours the stream signals; damage fails until the next stream's key frame.
    @available(macOS 27, *)
    @Test(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (the hybrid encoder)"),
          arguments: [(640, 360), (333, 201)])
    func chroma444InterFramesDecodeExactly(width: Int, height: Int) throws {
        let e = try Self.encoder(interFrames: true)
        let base = Self.picture444(width: width, height: height, seed: 0x444)
        var rng = SplitMix64(seed: 0x1E7)
        let pictures = (0..<10).map { i -> AV1HybridEncoder.Picture in
            var p = base
            let dy = (i * 3) % height  // (odd shifts: copies 4:2:0 couldn't make)
            for k in 0..<(width * height) {
                let from = (k + dy * width) % (width * height)
                (p.y[k], p.u[k], p.v[k]) = (base.y[from], base.u[from], base.v[from])
            }
            for _ in 0..<(i % 4 == 3 ? width * height / 4 : 100) {
                let k = rng.int(0..<(width * height))
                (p.y[k], p.u[k], p.v[k]) = (UInt8(rng.int(0..<256)), UInt8(rng.int(0..<256)), UInt8(rng.int(0..<256)))
            }
            return p
        }
        let first = try Self.frames(e, Array(pictures[0..<7]), qindex: 60)
        let second = try Self.frames(e, Array(pictures[7...]), qindex: 60)  // (a new stream: a key frame)
        try #require(first.filter(Self.isKey).count == 1 && Self.isKey(second[0]))
        let d = OwnAV1RegionDecoder(threads: 3)
        try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
        for (i, f) in first[0..<4].enumerated() {
            let (ok, bgra) = Self.decode(d, f, width: width, height: height)
            #expect(ok, "frame \(i) (\(Self.isKey(f) ? "key" : "inter"))")
            #expect(d.withShownPicture { $0.chroma_format } == UInt8(AV1G_CHROMA_444))
            #expect(Self.shownPlanes(d) == f.planes, "frame \(i): not the encoder's picture")
            if ok { try Self.checkConversion(d, bgra, width: width, height: height) }
        }
        // an inter frame cut short: it and the inter frames after it fail, until the next key frame
        #expect(!Self.decode(d, first[4], width: width, height: height, obu: Array(first[4].obu.prefix(first[4].obu.count / 2))).0)
        for f in first[5...] { #expect(!Self.decode(d, f, width: width, height: height).0, "an inter frame after the damage") }
        for (i, f) in second.enumerated() {
            #expect(Self.decode(d, f, width: width, height: height).0, "frame \(i) of the next stream")
            #expect(Self.shownPlanes(d) == f.planes, "frame \(i) of the next stream: not the encoder's picture")
        }
        #expect(d.stats.framesShown == 4 + second.count && d.stats.failures >= 1, "\(d.stats)")
    }

    /// The BGRA against the decoded Y, U, V converted by the matrix and range the picture signals,
    /// sample by sample (4:2:0: where the 3x3 chroma around a sample is flat, so the chroma
    /// upsampling doesn't matter); alpha opaque.
    static func checkConversion(_ d: OwnAV1RegionDecoder, _ bgra: [UInt8], width: Int, height: Int) throws -> Void {
        let planes = try #require(shownPlanes(d))
        let (mc, full, c444) = try #require(d.withShownPicture {
            ($0.matrix_coefficients, $0.color_range != 0, $0.chroma_format == UInt8(AV1G_CHROMA_444))
        })
        let (kr, kb): (Double, Double) = mc == 6 || mc == 5 ? (0.299, 0.114) : (0.2126, 0.0722)
        let kg = 1 - kr - kb
        let cw = c444 ? width : (width + 1) / 2, chh = c444 ? height : (height + 1) / 2
        var compared = 0, worst = 0
        for r in 0..<height {
            for c in 0..<width {
                let (cx, cy) = c444 ? (c, r) : (c / 2, r / 2)
                if !c444 {
                    var flat = true
                    for dy in -1...1 { for dx in -1...1 {
                        let (x, y) = (min(max(cx + dx, 0), cw - 1), min(max(cy + dy, 0), chh - 1))
                        if planes[1][y * cw + x] != planes[1][cy * cw + cx] || planes[2][y * cw + x] != planes[2][cy * cw + cx] { flat = false }
                    } }
                    if !flat { continue }
                }
                let yv = Double(planes[0][r * width + c]), cb = Double(planes[1][cy * cw + cx]), cr = Double(planes[2][cy * cw + cx])
                let yn = full ? yv / 255 : (yv - 16) / 219
                let (pb, pr) = full ? ((cb - 128) / 254, (cr - 128) / 254) : ((cb - 128) / 224, (cr - 128) / 224)
                let rgb = [yn + 2 * (1 - kr) * pr,
                           yn - 2 * kr * (1 - kr) / kg * pr - 2 * kb * (1 - kb) / kg * pb,
                           yn + 2 * (1 - kb) * pb].map { Int((min(max($0, 0), 1) * 255).rounded()) }
                let k = (r * width + c) * 4
                let got = [Int(bgra[k + 2]), Int(bgra[k + 1]), Int(bgra[k])]
                for j in 0..<3 { worst = max(worst, abs(got[j] - rgb[j])) }
                #expect(bgra[k + 3] == 255)
                compared += 1
            }
        }
        #expect(compared > width * height / 4, "\(compared) samples compared")
        #expect(worst <= 2, "matrix \(mc), \(full ? "full" : "video") range, \(c444 ? "4:4:4" : "4:2:0"): off by up to \(worst)")
    }

    @available(macOS 27, *)
    @Test(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (the hybrid encoder)"))
    func theConversionIsTheOneTheStreamSignals() throws {
        // a stream (BT.709, full range), 4:2:0 stills (BT.601), at an even and an odd size
        var matrices: Set<UInt32> = []
        for (width, height, inter) in [(640, 360, true), (334, 202, false), (333, 201, false)] {
            let e = try Self.encoder(interFrames: inter)
            let pictures = Self.pictures(inter ? 3 : 1, width: width, height: height, seed: 11)
            let frames = try inter ? Self.frames(e, pictures, qindex: 40) : [e.encode(pictures[0], qindex: 40)]
            let d = OwnAV1RegionDecoder(threads: 2)
            try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
            for f in frames {
                let (ok, bgra) = Self.decode(d, f, width: width, height: height)
                try #require(ok)
                #expect(Self.shownPlanes(d) == f.planes)
                try Self.checkConversion(d, bgra, width: width, height: height)
                matrices.insert(d.withShownPicture { $0.matrix_coefficients } ?? 0)
                #expect(d.withShownPicture { $0.color_range } == 1)
            }
        }
        #expect(matrices == [1, 6], "matrices \(matrices.sorted())")
    }

    /// Smooth content (periods of 40 to 100 samples of the region, so the half size loses little of
    /// it), sampled at the centres of a `width` × `height` picture of a `region`-sized one, as a
    /// scaled picture's samples sit: the same content at any size.
    @available(macOS 27, *)
    static func smooth(width: Int, height: Int, region: (Int, Int), frame: Int, chroma444: Bool = false) -> AV1HybridEncoder.Picture {
        func plane(_ w: Int, _ h: Int, _ f: (Double, Double) -> Double) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h)
            for r in 0..<h {
                for c in 0..<w {
                    let x = (Double(c) + 0.5) * Double(region.0) / Double(w) - 0.5
                    let y = (Double(r) + 0.5) * Double(region.1) / Double(h) - 0.5
                    out[r * w + c] = UInt8(clamping: Int(f(x, y).rounded()))
                }
            }
            return out
        }
        let t = Double(frame) * 3
        let (cw, ch) = chroma444 ? (width, height) : ((width + 1) / 2, (height + 1) / 2)
        let y = plane(width, height) { x, y in
            128 + 55 * sin(2 * .pi * (x + t) / 97) * cos(2 * .pi * y / 61) + 40 * sin(2 * .pi * (x - y) / 173)
        }
        let u = plane(cw, ch) { x, y in 128 + 50 * sin(2 * .pi * (x + y + t) / 131) }
        let v = plane(cw, ch) { x, y in 128 + 45 * cos(2 * .pi * (x - t) / 89) * sin(2 * .pi * y / 113) }
        return AV1HybridEncoder.Picture(y: y, u: u, v: v, width: width, height: height, chroma444: chroma444)
    }

    /// RGB PSNR between two BGRA pictures (alpha left out).
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var se = 0.0, n = 0
        for k in a.indices where k % 4 != 3 {
            let d = Double(Int(a[k]) - Int(b[k]))
            se += d * d
            n += 1
        }
        return se == 0 ? 99 : 10 * log10(255 * 255 * Double(n) / se)
    }

    /// Reduced frames are shown at the region's size by each way of scaling them up: at the Host's
    /// coded size (`HybridRegionEncoder.half`, max(2, (n / 2) & ~1): exactly half a side that's a
    /// multiple of 4, a little under half elsewhere), 4:2:0 and 4:4:4 (which the Host doesn't
    /// reduce, but the decoder takes). Their planes are the encoder's; what they show is close to
    /// what a full-size stream of the same content shows, at least as close as vImage's Lanczos
    /// makes it (4:2:0 planes much closer: they're converted as a full-size frame's are, where the
    /// BGRA paths scale up vImage's chroma upsampling at the coded size); Glass Act's BGRA path
    /// shows nearly vImage's picture; alpha is opaque.
    @available(macOS 27, *)
    @Test(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (the hybrid encoder)"),
          arguments: [(640, 360, false), (642, 362, false), (643, 361, false), (70, 41, false), (642, 361, true)])
    func reducedFramesAreScaledUpToTheRegion(width: Int, height: Int, chroma444: Bool) throws {
        let half = { (n: Int) in max(2, (n / 2) & ~1) }
        let (cw, ch) = (half(width), half(height))
        let frameCount = 3
        func encoder() throws -> AV1HybridEncoder {
            let e = try Self.encoder(interFrames: true)
            e.tiling = (0, 0)  // (one tile: the small sizes have no room for two)
            return e
        }
        // the same content at the region's size, and what it shows
        let fullStream = try Self.frames(encoder(),
                                         (0..<frameCount).map { Self.smooth(width: width, height: height, region: (width, height),
                                                                            frame: $0, chroma444: chroma444) }, qindex: 16)
        let full = OwnAV1RegionDecoder(threads: 2)
        try #require(full.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
        let shownFull = fullStream.map { Self.decode(full, $0, width: width, height: height) }
        let allShown = shownFull.allSatisfy { $0.0 }
        try #require(allShown)
        // reduced: coded at cw × ch, shown at the region's size
        let e = try encoder()
        e.streamSize = (width, height)
        let frames = try Self.frames(e, (0..<frameCount).map { Self.smooth(width: cw, height: ch, region: (width, height),
                                                                           frame: $0, chroma444: chroma444) }, qindex: 16)
        var shown: [OwnAV1RegionDecoder.Upscale: [[UInt8]]] = [:]
        for way in OwnAV1RegionDecoder.Upscale.allCases {
            let d = OwnAV1RegionDecoder(threads: 3)
            d.upscale = way
            try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
            for (i, f) in frames.enumerated() {
                let (ok, bgra) = Self.decode(d, f, width: width, height: height)
                #expect(ok, "\(way): reduced frame \(i)")
                guard ok else { continue }
                #expect(bgra.count == width * height * 4)
                #expect(Self.shownPlanes(d) == f.planes, "\(way): reduced frame \(i): not the encoder's picture")
                #expect(d.withShownPicture { (Int($0.width), Int($0.height), Int($0.render_width), Int($0.render_height)) }
                        ?? (0, 0, 0, 0) == (cw, ch, width, height))
                #expect(stride(from: 3, to: bgra.count, by: 4).allSatisfy { bgra[$0] == 255 }, "\(way): alpha")
                shown[way, default: []].append(bgra)
            }
            #expect(d.stats.framesShown == frameCount && d.stats.scaleNS > 0)
        }
        let ref = shownFull.map(\.1)
        func mean(_ way: OwnAV1RegionDecoder.Upscale) -> Double {
            let s = shown[way] ?? []
            return s.isEmpty ? 0 : zip(s, ref).map { Self.psnr($0, $1) }.reduce(0, +) / Double(s.count)
        }
        let (planes, bgra, vImage) = (mean(.planes), mean(.bgra), mean(.vImage))
        let what = "\(width)×\(height)\(chroma444 ? " 4:4:4" : ""): against the full-size stream planes \(planes), BGRA \(bgra), vImage \(vImage) dB"
        #expect(planes >= 40 && bgra >= 34, "\(what)")
        // (4:4:4: scaled before the conversion or after, 0.1–0.3 dB apart at 46 dB)
        #expect(planes >= vImage - 0.2 && bgra >= vImage - 0.1, "\(what)")
        // the same pipeline as vImage's but the filter: a phase or channel slip would show here
        let paths = zip(shown[.bgra] ?? [], shown[.vImage] ?? []).map { Self.psnr($0, $1) }.min() ?? 0
        #expect(paths >= 45, "\(what); BGRA against vImage \(paths) dB")
    }

    /// One region's decoder through reduced streams of each chroma format in turn (a key frame may
    /// bring a new sequence header): the 4:4:4 one needs twice the 4:2:0 one's planes, and gets
    /// them (run under AddressSanitizer: an overrun would pass unseen otherwise).
    @available(macOS 27, *)
    @Test(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (the hybrid encoder)"))
    func reducedStreamsOfEitherChromaFormatInTurn() throws {
        let (width, height) = (642, 361)
        let (cw, ch) = (max(2, (width / 2) & ~1), max(2, (height / 2) & ~1))
        func stream(_ c444: Bool, from frame: Int) throws -> [AV1HybridEncoder.Frame] {
            let e = try Self.encoder(interFrames: true)
            e.tiling = (0, 0)
            e.streamSize = (width, height)
            return try Self.frames(e, (0..<2).map { Self.smooth(width: cw, height: ch, region: (width, height), frame: frame + $0,
                                                                 chroma444: c444) }, qindex: 30)
        }
        let d = OwnAV1RegionDecoder(threads: 2)
        try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
        for (k, c444) in [false, true, false].enumerated() {
            for (i, f) in try stream(c444, from: 2 * k).enumerated() {
                let (ok, bgra) = Self.decode(d, f, width: width, height: height)
                #expect(ok, "stream \(k) (\(c444 ? "4:4:4" : "4:2:0")), frame \(i)")
                #expect(Self.shownPlanes(d) == f.planes, "stream \(k), frame \(i): not the encoder's picture")
                #expect(d.withShownPicture { $0.chroma_format } == UInt8(c444 ? AV1G_CHROMA_444 : AV1G_CHROMA_420))
                #expect(bgra.count == width * height * 4)
            }
        }
        #expect(d.stats.framesShown == 6 && d.stats.failures == 0)
    }

    /// A flat reduced frame comes out flat at the region's size, in its colour.
    @available(macOS 27, *)
    @Test(.enabled(if: AV1ShaderSource.hasCapableGPU, "needs an Apple-silicon GPU (the hybrid encoder)"),
          arguments: [(640, 360), (643, 361)])
    func aFlatReducedFrameStaysFlat(width: Int, height: Int) throws {
        let (cw, ch) = (max(2, (width / 2) & ~1), max(2, (height / 2) & ~1))
        let e = try Self.encoder(interFrames: true)
        e.streamSize = (width, height)
        let n = cw * ch, c = ((cw + 1) / 2) * ((ch + 1) / 2)
        let flat = AV1HybridEncoder.Picture(y: .init(repeating: 120, count: n), u: .init(repeating: 90, count: c),
                                            v: .init(repeating: 170, count: c), width: cw, height: ch)
        let f = try Self.frames(e, [flat], qindex: 20)[0]
        for way in OwnAV1RegionDecoder.Upscale.allCases {
            let d = OwnAV1RegionDecoder(threads: 2)
            d.upscale = way
            try #require(d.start(codec: VideoCodec.av1, config: Self.av1C, width: width, height: height))
            let (ok, bgra) = Self.decode(d, f, width: width, height: height)
            try #require(ok && bgra.count == width * height * 4)
            let first = Array(bgra[0..<4])
            var off = 0
            for k in stride(from: 0, to: bgra.count, by: 4) { for j in 0..<4 { off = max(off, abs(Int(bgra[k + j]) - Int(first[j]))) } }
            #expect(off <= (way == .vImage ? 2 : 0), "\(way): a flat picture scaled up varies by \(off)")
            #expect(first[3] == 255 && first[2] > first[0], "\(way): BGRA \(first): (120, 90, 170) is more red than blue")
        }
    }
}
