import GlassActSession
import Testing

/// `HeldInput`: what a Viewer holds on the Host, so that it can let go when it loses the keyboard
/// (⌘-Tab away used to leave ⌘ held on the Host: every remote click a ⌘-click).
struct HeldInputTests {
    @Test func aCommandTabAwayReleasesTheCommandKey() {
        var held = HeldInput()
        held.sent(kind: 5, x: 55, y: 0, b: 0)  // ⌘ down (flagsChanged)
        // (the Tab and the ⌘'s release go to the app switcher)
        #expect(held.keys == [55])
        #expect(held.releaseAll() == [HeldInput.Event(kind: 6, x: 55, y: 0, a: 0, b: 0)])
        #expect(held.keys.isEmpty && held.releaseAll().isEmpty)
    }

    @Test func releasedKeysAndButtonsAreNotReleasedAgain() {
        var held = HeldInput()
        held.sent(kind: 5, x: 56, y: 0, b: 0)
        held.sent(kind: 5, x: 0, y: 0, b: 0)
        held.sent(kind: 6, x: 0, y: 0, b: 0)
        held.sent(kind: 2, x: 10, y: 20, b: 0)
        held.sent(kind: 3, x: 11, y: 21, b: 0)
        #expect(held.releaseAll() == [HeldInput.Event(kind: 6, x: 56, y: 0, a: 0, b: 0)])
    }

    @Test func aHeldButtonIsReleasedWhereThePointerLastWas() {
        var held = HeldInput()
        held.sent(kind: 2, x: 100, y: 200, b: 1)
        held.sent(kind: 1, x: 140, y: 230, b: 0)  // dragged
        held.sent(kind: 5, x: 58, y: 0, b: 0)     // ⌥
        #expect(held.position?.x == 140 && held.position?.y == 230)
        #expect(held.releaseAll() == [HeldInput.Event(kind: 6, x: 58, y: 0, a: 0, b: 0),
                                      HeldInput.Event(kind: 3, x: 140, y: 230, a: 1, b: 1)])
        #expect(held.buttons == 0)
    }
}
