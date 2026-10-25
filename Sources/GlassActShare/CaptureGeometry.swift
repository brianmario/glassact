public import CoreGraphics
import GlassActCore

/// Capture sizes (§3.1, §4.10).
public enum CaptureGeometry {
    /// The wire's largest canvas (TileGrid.maxDimension per side — the
    /// viewer rejects anything larger, and the engine refuses to build one).
    /// Scales an oversize capture down, preserving aspect with even dims;
    /// `factor` rescales the point→pixel mapping used for input and cursor.
    public static func clamp(_ w: Int, _ h: Int) -> (w: Int, h: Int, factor: CGFloat) {
        let m = TileGrid.maxDimension
        guard w > m || h > m else { return (w, h, 1) }
        let f = min(CGFloat(m) / CGFloat(w), CGFloat(m) / CGFloat(h))
        return (max(2, Int(CGFloat(w) * f)) & ~1, max(2, Int(CGFloat(h) * f)) & ~1, f)
    }

    /// "Scale": the capture size that aspect-fits a display of `size`
    /// points into the viewer's request, never past the display's own
    /// pixels (`maxPixelsPerPoint`): a viewer window bigger than this
    /// display gets its native picture, not an upscaled one. Even dims for
    /// 4:2:0 codecs; floored so a tiny (or hostile) request can't produce a
    /// zero-sized capture.
    public static func scaledSize(of size: CGSize,
                                  toFit request: (widthPoints: Int, heightPoints: Int, scale: Int),
                                  maxPixelsPerPoint: CGFloat) -> (w: Int, h: Int) {
        let f = min(maxPixelsPerPoint,
                    CGFloat(request.widthPoints * request.scale) / size.width,
                    CGFloat(request.heightPoints * request.scale) / size.height)
        return (max(64, Int(size.width * f)) & ~1, max(64, Int(size.height * f)) & ~1)
    }
}
