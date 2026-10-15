/// ScreenCaptureKit dirty rects → canvas pixels (a hint only — §4.3; any
/// doubt returns nil and the engine scans every tile).
///
/// Unit, measured (rect probe): SCK reports dirty rects in the capture
/// SOURCE's backing pixels — a 2880×1620 frame of a 1440×810 pt @2x display
/// carries rects reaching x = 2880; a 5120×2880 frame of a 2560×1440 pt @2x
/// display, x = 5120. Treating them as points and doubling them would push
/// rects in the right/bottom half off the frame (a full scan, by luck) and
/// point the rest at the wrong tiles.
///
/// `sourcePixelWidth` = content width in points × SCK's scaleFactor. The
/// canvas may be scaled from it (Scale mode, oversize clamps), so rects are
/// scaled by frameWidth / sourcePixelWidth. A rect that still lands clearly
/// outside the frame means the unit assumption is wrong for this stream:
/// return nil (full scan) rather than trust it.
public enum DirtyRectMapping {
    /// How far past the frame edge a mapped rect may reach (rounding) before
    /// the whole frame's hints are distrusted.
    public static let slackPixels = 8

    public enum Result: Equatable, Sendable {
        case rects([DirtyRect])
        /// Hints unusable (zero rect, out of frame, bad source size): scan all.
        case unknown
        /// No rects at all.
        case empty
    }

    public static func map(raw: [(x: Double, y: Double, width: Double, height: Double)],
                           frameWidth: Int, frameHeight: Int,
                           sourcePixelWidth: Double) -> Result {
        guard !raw.isEmpty else { return .empty }
        guard sourcePixelWidth > 0, frameWidth > 0, frameHeight > 0 else { return .unknown }
        let k = Double(frameWidth) / sourcePixelWidth
        var out: [DirtyRect] = []
        out.reserveCapacity(raw.count)
        for r in raw {
            // SCK emits {0,0,0,0} on some frames (first frame of a stream):
            // unknown damage, not "nothing changed".
            guard r.width > 0, r.height > 0 else { return .unknown }
            let x0 = (r.x * k).rounded(.down), y0 = (r.y * k).rounded(.down)
            let x1 = ((r.x + r.width) * k).rounded(.up), y1 = ((r.y + r.height) * k).rounded(.up)
            guard x0 >= -Double(slackPixels), y0 >= -Double(slackPixels),
                  x1 <= Double(frameWidth + slackPixels), y1 <= Double(frameHeight + slackPixels) else {
                return .unknown
            }
            let x = max(0, Int(x0)), y = max(0, Int(y0))
            let w = min(frameWidth, Int(x1)) - x, h = min(frameHeight, Int(y1)) - y
            if w > 0 && h > 0 { out.append(DirtyRect(x: x, y: y, width: w, height: h)) }
        }
        return out.isEmpty ? .unknown : .rects(out)
    }
}
