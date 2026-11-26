import GlassActSession
import GlassActWire
import Testing

/// Display choice (§4.10), the Viewer's side: when the picker shows, what it lists, and that it
/// never moves ahead of the host's answers (`DisplayPicker`).
struct DisplayPickerTests {
    static func display(_ id: UInt32, _ name: String, x: Int32, _ w: UInt16 = 1600, _ h: UInt16 = 1000,
                        main: Bool = false, shown: Bool = false) -> WireDisplay {
        WireDisplay(displayID: id, name: name, x: x, y: 0, width: w, height: h, isMain: main, isShown: shown)
    }

    /// Two displays: the main one on the right, shown; the other on its left.
    static let two = [display(7, "Studio Display", x: 0, 5120 / 2, 2880 / 2, main: true, shown: true),
                      display(9, "LG UltraFine", x: -1920, 1920, 1080)]

    static func running(mode: UInt8, singleWindow: Bool = false) -> DisplayPicker {
        var p = DisplayPicker()
        _ = p.geometryRequested(mode: mode, singleWindow: singleWindow)
        p.sessionStarted(hostLists: true)
        p.received(two)
        return p
    }

    @Test func showsOnlyWherePicksTakeEffect() {
        #expect(Self.running(mode: GeometryMode.scale).isVisible)
        #expect(Self.running(mode: GeometryMode.native).isVisible)
        #expect(Self.running(mode: GeometryMode.none).isVisible, "no geometry asked: the host's own")
        // The host answers "not now" to these: a virtual display mirrors every display into
        // one, Client Resolution has switched the display's mode, a window isn't a display.
        #expect(!Self.running(mode: GeometryMode.virtualDisplay).isVisible)
        #expect(!Self.running(mode: GeometryMode.clientResolution).isVisible)
        #expect(!Self.running(mode: GeometryMode.scale, singleWindow: true).isVisible)
    }

    @Test func needsTheHostsCapsAndTwoDisplays() {
        var p = DisplayPicker()
        _ = p.geometryRequested(mode: GeometryMode.scale, singleWindow: false)
        let r1 = p.sessionStarted(hostLists: false)
        #expect(!r1, "an older host: never ask")
        p.received(Self.two)
        #expect(!p.isVisible)

        var one = DisplayPicker()
        _ = one.geometryRequested(mode: GeometryMode.scale, singleWindow: false)
        let r2 = one.sessionStarted(hostLists: true)
        #expect(r2)
        one.received([Self.two[0]])
        #expect(!one.isVisible, "one display: nothing to pick")
        one.received([])
        #expect(!one.isVisible, "a View Only key's empty list")
    }

    @Test func asksAgainOnlyWhenAGeometryChangeMakesPicksWork() {
        var p = DisplayPicker()
        _ = p.geometryRequested(mode: GeometryMode.virtualDisplay, singleWindow: false)
        let r3 = p.sessionStarted(hostLists: true)
        #expect(!r3, "virtual display: not worth asking")
        let r4 = p.geometryRequested(mode: GeometryMode.scale, singleWindow: false)
        #expect(r4, "now it is")
        let r5 = p.geometryRequested(mode: GeometryMode.native, singleWindow: false)
        #expect(!r5, "already wanted")
        let r6 = p.geometryRequested(mode: GeometryMode.clientResolution, singleWindow: false)
        #expect(!r6)
        let r7 = p.geometryRequested(mode: GeometryMode.scale, singleWindow: false)
        #expect(r7)
    }

    @Test func listsLeftToRightNumberingSharedNames() {
        var p = Self.running(mode: GeometryMode.scale)
        #expect(p.items.map(\.name) == ["LG UltraFine", "Studio Display"])
        #expect(p.items.map(\.detail) == ["1920 × 1080", "2560 × 1440 · Main"])
        #expect(p.items.map(\.isShown) == [false, true])
        p.received([Self.display(1, "DELL U2723QE", x: 0, main: true, shown: true),
                    Self.display(2, "DELL U2723QE", x: 1600), Self.display(3, "", x: 3200)])
        #expect(p.items.map(\.name) == ["DELL U2723QE 1", "DELL U2723QE 2", "Display"])
    }

    @Test func followsTheHostsAnswersNotThePick() {
        var p = Self.running(mode: GeometryMode.scale)
        let r8 = p.pick(7)
        #expect(!r8, "already shown")
        let r9 = p.pick(42)
        #expect(!r9, "not listed")
        let r10 = p.pick(9)
        #expect(r10)
        let r11 = p.pick(9)
        #expect(!r11, "already waiting")
        #expect(p.items.first { $0.id == 9 }?.isPending == true)
        #expect(p.shownID == 7, "still the host's until it answers")

        // refused: the shown display stays the one the host says it shares
        p.received(WireDisplaySelection(requestedID: 9, status: .notNow, displayID: 7))
        #expect(p.shownID == 7 && p.pendingID == nil)

        let r12 = p.pick(9)

        #expect(r12)
        p.received(WireDisplaySelection(requestedID: 9, status: .ok, displayID: 9))
        #expect(p.shownID == 9 && p.pendingID == nil)
        #expect(p.items.map(\.isShown) == [true, false])
    }

    @Test func aNewerPickWaitsBehindAnOlderAnswer() {
        var p = Self.running(mode: GeometryMode.scale)
        let r13 = p.pick(9)
        #expect(r13)
        let r14 = p.pick(7)
        #expect(r14, "back again, while 9 waits")
        p.received(WireDisplaySelection(requestedID: 9, status: .ok, displayID: 9))
        #expect(p.shownID == 9 && p.pendingID == 7, "7 still waiting")
        p.received(WireDisplaySelection(requestedID: 7, status: .ok, displayID: 7))
        #expect(p.shownID == 7 && p.pendingID == nil)
    }

    @Test func aLostConnectionClearsEverything() {
        var p = Self.running(mode: GeometryMode.scale)
        let r15 = p.pick(9)
        #expect(r15)
        p.received(WireDisplaySelection(requestedID: 9, status: .connectionLost, displayID: 0))
        #expect(p.shownID == 7 && p.pendingID == nil, "connection lost says nothing about what's shown")
        p.sessionEnded()
        #expect(!p.isVisible && p.items.isEmpty)
    }
}
