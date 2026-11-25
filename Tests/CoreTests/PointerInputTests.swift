import Testing
import GlassActCore

/// Sharing a display, the remote pointer stays on it.
@Suite struct PointerInputTests {
    @Test func movesAndClicksStayOnThePicture() {
        for kind in 1...3 {
            #expect(PointerInput.onPicture(kind: kind, x: 6000, y: 4000, width: 5120, height: 2880) == (5119, 2879))
            #expect(PointerInput.onPicture(kind: kind, x: 100, y: 200, width: 5120, height: 2880) == (100, 200))
            #expect(PointerInput.onPicture(kind: kind, x: -5, y: -1, width: 5120, height: 2880) == (0, 0))
        }
    }

    /// A key's x is its key code and scrolls don't use x and y: they pass as sent.
    @Test func keysAndScrollsPassAsSent() {
        for kind in [4, 5, 6, 7] {
            #expect(PointerInput.onPicture(kind: kind, x: 6000, y: 4000, width: 5120, height: 2880) == (6000, 4000))
        }
        #expect(PointerInput.onPicture(kind: 1, x: 6000, y: 4000, width: 0, height: 0) == (6000, 4000), "no picture yet")
    }
}
