import Foundation
import GlassActCore
import GlassActHybridVideo
import Testing

/// The hybrid's frames carry the engine's change map (per 64×64 of the BGRA frame) as their
/// pictures' (`AV1HybridEncoder.Picture.changed`): a 64×64 unchanged in BGRA must convert to the
/// same samples in every plane, so the conversions must be local (each sample from its own pixel,
/// 4:2:0's chroma from its own 2×2), with nothing carried across the picture (dither, error
/// diffusion).
@Suite struct ConversionLocalityTests {
    static func random(_ n: Int, seed: UInt64) -> [UInt8] {
        var s = seed
        return (0..<n).map { _ in
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return UInt8(truncatingIfNeeded: s)
        }
    }

    /// Converts `before` and `after` (which differ inside `rect`) and checks every plane's samples
    /// outside the 64×64s that `rect` overlaps.
    static func check(width w: Int, height h: Int, rect: (x: Int, y: Int, w: Int, h: Int), seed: UInt64,
                      chromaSide: Int, convert: ([UInt8]) -> [[UInt8]]) -> [String] {
        let before = random(w * h * 4, seed: seed)
        var after = before
        let fresh = random(rect.w * rect.h * 4, seed: seed &+ 1)
        for y in 0..<rect.h {
            for x in 0..<rect.w * 4 { after[((rect.y + y) * w + rect.x) * 4 + x] = fresh[y * rect.w * 4 + x] }
        }
        let (a, b) = (convert(before), convert(after))
        let (sx0, sy0, sx1, sy1) = (rect.x / 64, rect.y / 64, (rect.x + rect.w - 1) / 64, (rect.y + rect.h - 1) / 64)
        var wrong: [String] = []
        for p in 0..<3 {
            let side = p == 0 ? 64 : chromaSide, pw = p == 0 ? w : w * chromaSide / 64
            for i in a[p].indices where a[p][i] != b[p][i] {
                let (sx, sy) = (i % pw / side, i / pw / side)
                if !(sx0...sx1).contains(sx) || !(sy0...sy1).contains(sy) {
                    wrong.append("plane \(p) sample (\(i % pw), \(i / pw)) in 64×64 (\(sx), \(sy))")
                }
            }
        }
        return wrong
    }

    @Test(arguments: I420Converter.Colour.allCases)
    func i420IsLocal(_ colour: I420Converter.Colour) throws {
        let c = try #require(I420Converter(colour))
        let (w, h) = (330, 194)
        for (k, rect) in [(x: 64, y: 0, w: 64, h: 64), (x: 1, y: 63, w: 3, h: 2), (x: 250, y: 129, w: 80, h: 65)].enumerated() {
            let wrong = Self.check(width: w, height: h, rect: rect, seed: UInt64(k + 1), chromaSide: 32) { bgra in
                var y = [UInt8](repeating: 0, count: w * h), u = [UInt8](repeating: 0, count: w * h / 4), v = u
                let ok = bgra.withUnsafeBytes { src in
                    y.withUnsafeMutableBytes { yp in u.withUnsafeMutableBytes { up in v.withUnsafeMutableBytes { vp in
                        c.convert(bgra: src, width: w, height: h, y: yp.baseAddress!, u: up.baseAddress!, v: vp.baseAddress!)
                    } } }
                }
                #expect(ok)
                return [y, u, v]
            }
            #expect(wrong.isEmpty, "\(colour) rect \(rect): \(wrong.prefix(4))")
        }
    }

    @Test func ycbcr444IsLocal() throws {
        let c = try #require(YCbCr444Converter())
        let (w, h) = (330, 194)
        for (k, rect) in [(x: 64, y: 0, w: 64, h: 64), (x: 1, y: 63, w: 3, h: 2), (x: 250, y: 129, w: 80, h: 65)].enumerated() {
            let wrong = Self.check(width: w, height: h, rect: rect, seed: UInt64(k + 11), chromaSide: 64) { bgra in
                var y = [UInt8](repeating: 0, count: w * h), u = y, v = y
                let ok = bgra.withUnsafeBytes { src in
                    y.withUnsafeMutableBytes { yp in u.withUnsafeMutableBytes { up in v.withUnsafeMutableBytes { vp in
                        c.convert(bgra: src, width: w, height: h, y: yp.baseAddress!, u: up.baseAddress!, v: vp.baseAddress!)
                    } } }
                }
                #expect(ok)
                return [y, u, v]
            }
            #expect(wrong.isEmpty, "rect \(rect): \(wrong.prefix(4))")
        }
    }
}
