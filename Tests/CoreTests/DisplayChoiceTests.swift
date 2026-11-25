import Testing
import GlassActCore
import GlassActTestSupport
import GlassActWire

/// The display a viewer picks (§4.10 display choice).
@Suite struct DisplayChoiceTests {
    @Test func theViewersPickWhileOfferedElseTheFallback() {
        #expect(DisplayChoice.displayToShare(requested: nil, offered: [5, 3, 9], fallback: 3) == 3, "nothing picked")
        #expect(DisplayChoice.displayToShare(requested: 9, offered: [5, 3, 9], fallback: 3) == 9)
        #expect(DisplayChoice.displayToShare(requested: 7, offered: [5, 3, 9], fallback: 3) == 3, "not offered: never the first listed")
        #expect(DisplayChoice.displayToShare(requested: 0, offered: [5, 3, 9], fallback: 3) == 3)
    }

    /// The pointer lands inside the new display, one point in from its edges.
    @Test func thePointerLandsOnTheDisplay() {
        let left = DisplayChoice.Rect(x: -1680, y: 30, width: 1680, height: 1050)
        let pushed = DisplayChoice.pointerPlacement(asked: (x: 5, y: 500), on: left)
        #expect(pushed.x == -1 && pushed.y == 500, "a point past its right edge comes back on")
        let middle = DisplayChoice.pointerPlacement(asked: nil, on: left)
        #expect(middle.x == -840 && middle.y == 555)
        let low = DisplayChoice.pointerPlacement(asked: (x: -100, y: 5000), on: left)
        #expect(low.x == -100 && low.y == 1079)
        #expect(left.contains(pushed.x, pushed.y) && left.contains(low.x, low.y))
    }
}

/// The three messages between the engines.
@Suite struct DisplayChoiceEngineTests {
    @Test func aSelectReachesTheHostAndTheListAndAnswerReachTheViewer() {
        let h = Harness(width: 320, height: 240)
        var selects: [(UInt32, Bool, Int32, Int32)] = []
        h.host.onDisplaySelect = { selects.append(($0, $1, $2, $3)) }
        var lists: [[WireDisplay]] = []
        h.viewer.onDisplayList = { lists.append($0) }
        var answers: [WireDisplaySelection] = []
        h.viewer.onDisplaySelected = { answers.append($0) }

        h.viewer.sendDisplaySelect(displayID: 0)
        h.viewer.sendDisplaySelect(displayID: 7, placePointer: true, x: -12, y: 34)
        h.run(untilUS: h.now + 100_000)
        #expect(selects.count == 2)
        #expect(selects.first.map { $0.0 == 0 && !$0.1 } == true, "0 asks for the list")
        #expect(selects.last.map { $0.0 == 7 && $0.1 && $0.2 == -12 && $0.3 == 34 } == true)

        let display = WireDisplay(displayID: 7, name: "Left", x: -1920, y: 0, width: 1920, height: 1080,
                                  isMain: false, isShown: false)
        h.host.sendDisplayList([display])
        let answer = WireDisplaySelection(requestedID: 7, status: .ok, displayID: 7, x: -1920, y: 0,
                                          width: 1920, height: 1080, pictureWidth: 1920, pictureHeight: 1080)
        h.host.sendDisplaySelected(answer)
        h.run(untilUS: h.now + 100_000)
        #expect(lists == [[display]])
        #expect(answers == [answer])
    }
}
