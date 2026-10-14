import Testing
import GlassActCore

/// SCK dirty rects arrive in source backing pixels (measured live). The
/// host doubled them as if they were points.
@Suite struct DirtyRectMappingTests {
    typealias M = DirtyRectMapping

    @Test func sourcePixelsMapOneToOneWhenTheCaptureIsNative() {
        // Probe: 1440×810 pt @2x, captured at 2880×1620 — the right-edge
        // clock at (2832,2 48×4) must stay there, not double off the frame.
        let r = M.map(raw: [(2832, 2, 48, 4), (1054, 958, 670, 40)],
                      frameWidth: 2880, frameHeight: 1620, sourcePixelWidth: 1440 * 2)
        #expect(r == .rects([DirtyRect(x: 2832, y: 2, width: 48, height: 4),
                             DirtyRect(x: 1054, y: 958, width: 670, height: 40)]))
    }

    @Test func aScaledCaptureScalesTheRects() {
        // 2560×1440 pt @2x (5120 px source) captured at 2880×1620: ×0.5625.
        let r = M.map(raw: [(5072, 2, 48, 54)], frameWidth: 2880, frameHeight: 1620,
                      sourcePixelWidth: 2560 * 2)
        guard case let .rects(rects) = r, let d = rects.first else { Issue.record("\(r)"); return }
        #expect(d.x == 2853 && d.x + d.width == 2880, "\(d)")
        #expect(d.y == 1 && d.y + d.height >= 31, "\(d)")
    }

    @Test func outOfFrameMeansTheUnitIsWrongScanEverything() {
        // What the old doubling produced: a rect far past the frame.
        #expect(M.map(raw: [(5664, 4, 96, 8)], frameWidth: 2880, frameHeight: 1620,
                      sourcePixelWidth: 2880) == .unknown)
    }

    @Test func zeroRectAndEmptyList() {
        #expect(M.map(raw: [(0, 0, 0, 0)], frameWidth: 100, frameHeight: 100, sourcePixelWidth: 100) == .unknown)
        #expect(M.map(raw: [], frameWidth: 100, frameHeight: 100, sourcePixelWidth: 100) == .empty)
        #expect(M.map(raw: [(1, 1, 5, 5)], frameWidth: 100, frameHeight: 100, sourcePixelWidth: 0) == .unknown)
    }
}
