import CoreGraphics
import Testing
import GlassActCore
import GlassActShare

@Suite struct CaptureGeometryTests {
    @Test func aCaptureWithinTheWireLimitIsUnchanged() {
        let c = CaptureGeometry.clamp(5120, 2880)
        #expect(c.w == 5120 && c.h == 2880 && c.factor == 1)
    }

    /// Past TileGrid.maxDimension the capture shrinks to fit, keeping its
    /// aspect with even dimensions.
    @Test func anOversizeCaptureIsScaledToTheLimit() {
        let m = TileGrid.maxDimension
        let c = CaptureGeometry.clamp(m * 2 + 2, m)
        #expect(c.w <= m && c.h <= m)
        #expect(c.w % 2 == 0 && c.h % 2 == 0)
        #expect(abs(CGFloat(c.w) / CGFloat(c.h) - CGFloat(m * 2 + 2) / CGFloat(m)) < 0.01)
        #expect(c.factor < 0.5 + 0.001)
    }

    /// Scale mode: a 1512×982 pt display into a 1200×800 pt @2x window.
    @Test func scaleFitsTheViewersWindow() {
        let s = CaptureGeometry.scaledSize(of: CGSize(width: 1512, height: 982),
                                           toFit: (1200, 800, 2), maxPixelsPerPoint: 2)
        #expect(s.w == 2400 && s.h == 1558)
    }

    /// A window bigger than the display gets the display's own pixels, not
    /// an upscaled picture.
    @Test func scaleNeverUpscalesPastTheDisplay() {
        let s = CaptureGeometry.scaledSize(of: CGSize(width: 1512, height: 982),
                                           toFit: (3000, 2000, 2), maxPixelsPerPoint: 2)
        #expect(s.w == 3024 && s.h == 1964)
    }

    @Test func aTinyRequestStillMakesACapture() {
        let s = CaptureGeometry.scaledSize(of: CGSize(width: 1512, height: 982),
                                           toFit: (1, 1, 1), maxPixelsPerPoint: 2)
        #expect(s.w == 64 && s.h == 64)
    }
}
