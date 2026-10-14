public import CoreGraphics
public import Foundation
import ImageIO
public import GlassActCore
import UniformTypeIdentifiers

/// What the person at a viewer sees, as pixels: the exact canvas with any
/// live video overlay tiles laid over it (the same per-tile choice the
/// present path makes). BGRA, tightly packed.
public struct ScreenFrame: Sendable {
    public let width: Int
    public let height: Int
    public let bgra: [UInt8]

    /// `engine`'s queue only. Nil before the first HELLO configured a canvas.
    public static func capture(_ engine: ViewerEngine) -> ScreenFrame? {
        guard let grid = engine.grid else { return nil }
        let w = grid.width, h = grid.height, tile = TileGrid.tileSize
        let cols = (w + tile - 1) / tile
        return engine.withPresentSources { canvas, overlay, showsOverlay in
            var out = [UInt8](repeating: 0, count: w * h * 4)
            out.withUnsafeMutableBytes { dst in
                dst.baseAddress!.copyMemory(from: canvas.baseAddress!, byteCount: w * h * 4)
                guard let overlay else { return }
                let rows = (h + tile - 1) / tile
                for t in 0..<(cols * rows) where showsOverlay(t) {
                    let x0 = (t % cols) * tile, y0 = (t / cols) * tile
                    let tw = min(tile, w - x0), th = min(tile, h - y0)
                    for y in y0..<(y0 + th) {
                        let off = (y * w + x0) * 4
                        dst.baseAddress!.advanced(by: off)
                            .copyMemory(from: overlay.baseAddress!.advanced(by: off), byteCount: tw * 4)
                    }
                }
            }
            return ScreenFrame(width: w, height: h, bgra: out)
        }
    }

    /// The frame as a CGImage (opaque sRGB).
    public func image() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 64-bit digest of a rect's pixels (canvas pixels), to tell whether a
    /// region changed between two frames.
    public func digest(x: Int, y: Int, width rw: Int, height rh: Int) -> Int {
        let x0 = max(0, min(width, x)), y0 = max(0, min(height, y))
        let x1 = max(x0, min(width, x + rw)), y1 = max(y0, min(height, y + rh))
        var hasher = Hasher()
        bgra.withUnsafeBytes { buf in
            for row in y0..<y1 {
                hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: buf[((row * width + x0) * 4)..<((row * width + x1) * 4)]))
            }
        }
        return hasher.finalize()
    }
}

public enum ImageEncoding {
    /// Crop `image` to `rect` (its pixels; nil = whole), scale to
    /// `outWidth`×`outHeight` with high-quality filtering, encode as PNG.
    public static func png(_ image: CGImage, crop rect: CGRect? = nil, outWidth: Int, outHeight: Int) -> Data? {
        var source = image
        if let rect, let cropped = image.cropping(to: rect.integral) { source = cropped }
        let scaled: CGImage
        if source.width == outWidth && source.height == outHeight {
            scaled = source
        } else {
            guard let ctx = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
            guard let made = ctx.makeImage() else { return nil }
            scaled = made
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, scaled, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
