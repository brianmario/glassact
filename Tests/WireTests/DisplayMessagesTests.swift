import Testing
import GlassActWire

/// DISPLAY_LIST, DISPLAY_SELECT and DISPLAY_SELECTED (§4.10 display choice, 0x60–0x62).
@Suite struct DisplayMessagesTests {
    static func roundTrips(_ messages: [ControlMessage]) -> Bool {
        var d = ControlDeframer()
        for m in messages { d.append(m.encoded()) }
        return messages.allSatisfy { d.next() == .message($0) }
    }

    @Test func messagesRoundTrip() {
        let list = ControlMessage.displayList(displays: [
            WireDisplay(displayID: 1, name: "Main", x: 0, y: 0, width: 1920, height: 1080,
                        pixelsPerPoint100: 200, isMain: true, isShown: true),
            WireDisplay(displayID: 3, name: "Portrait ✓", x: 1960, y: -420, width: 1080, height: 1920,
                        rotation: 90, isMain: false, isShown: false,
                        thumbFormat: 1, thumbWidth: 112, thumbHeight: 200, thumb: [1, 2, 3, 4]),
        ])
        let select = ControlMessage.displaySelect(displayID: 2, placePointer: true, pointerX: -1, pointerY: -400)
        let selected = ControlMessage.displaySelected(WireDisplaySelection(
            requestedID: 4, status: .ok, displayID: 4, x: 0, y: -1080, width: 1920, height: 1080,
            pictureWidth: 960, pictureHeight: 540, pointerPlaced: true, pointerX: 100, pointerY: -500))
        let refused = ControlMessage.displaySelected(WireDisplaySelection(requestedID: 9, status: .notOffered, displayID: 1))
        #expect(Self.roundTrips([list, select, selected, refused, .displayList(displays: [])]))
        #expect([list, select, selected].map(\.tlvType) == [0x60, 0x61, 0x62])
    }

    @Test func theTypesAreKnownAndTheBitIs31() {
        #expect((0x60...0x62).allSatisfy { ControlMessage.isKnownType(UInt8($0)) })
        #expect(!ControlMessage.isKnownType(0x5F) && !ControlMessage.isKnownType(0x63))
        #expect(WireCaps.displayList == 1 << 31)
    }

    /// A known type with a bad body fails the stream (§8, INV-6).
    @Test func badBodiesAreRefused() {
        func malformed(_ bytes: [UInt8]) -> Bool {
            var d = ControlDeframer()
            d.append(bytes)
            return d.next() == nil && d.isMalformed
        }
        let select = ControlMessage.displaySelect(displayID: 2, placePointer: true, pointerX: 1, pointerY: 2).encoded()
        var badPlace = select
        badPlace[2 + 4] = 2 // placePointer is 0 or 1
        #expect(malformed(badPlace))
        var selected = ControlMessage.displaySelected(WireDisplaySelection(requestedID: 1, status: .ok, displayID: 1)).encoded()
        selected[2 + 4] = 255 // connectionLost is the viewer's own, never on the wire
        #expect(malformed(selected))
        // a list claiming more displays than its body can hold
        #expect(malformed([0x60, 0x01, 0x05]))
        var thumbFormat = ControlMessage.displayList(displays: [
            WireDisplay(displayID: 1, name: "", x: 0, y: 0, width: 1, height: 1, isMain: true, isShown: true)]).encoded()
        thumbFormat[2 + 1 + 4 + 1 + 4 + 4 + 2 + 2 + 2 + 2 + 1] = 3 // thumbFormat is 0, 1 or 2
        #expect(malformed(thumbFormat))
    }
}
