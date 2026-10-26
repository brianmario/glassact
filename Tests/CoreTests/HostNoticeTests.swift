import Foundation
import Testing
@testable import GlassActCore
import GlassActTestSupport
import GlassActWire

/// HOST_NOTICE (§3.5): the host tells the viewer what it should show its
/// user, such as the host's session being off the screen (another user has
/// it), instead of a picture that just freezes.
@Suite struct HostNoticeTests {
    private func notices(_ capture: CaptureTransport) -> [UInt8] {
        var d = ControlDeframer()
        for data in capture.sentControl { d.append(Array(data)) }
        var codes: [UInt8] = []
        while let event = d.next() {
            if case let .message(.hostNotice(code)) = event { codes.append(code) }
        }
        return codes
    }

    @Test func reachesTheViewerOnceForEachChange() {
        let h = Harness(width: 256, height: 192)
        var seen: [UInt8] = []
        h.viewer.onHostNotice = { seen.append($0) }
        h.host.setHostNotice(HostNotice.sessionOffScreen)
        h.host.setHostNotice(HostNotice.sessionOffScreen) // unchanged: nothing sent
        h.run(untilUS: h.now + 100_000)
        h.host.setHostNotice(HostNotice.none)
        h.run(untilUS: h.now + 100_000)
        #expect(seen == [HostNotice.sessionOffScreen, HostNotice.none])
    }

    /// A viewer that connects while a notice is in force hears it at the
    /// handshake; with none in force, nothing is sent.
    @Test func aViewerConnectingLaterHearsIt() {
        for (code, expected) in [(HostNotice.sessionOffScreen, [HostNotice.sessionOffScreen]), (HostNotice.none, [])] {
            let capture = CaptureTransport()
            let host = HostEngine(width: 256, height: 192, transport: capture)
            host.setHostNotice(code)
            host.start(nowUS: 0)
            #expect(notices(capture).isEmpty, "nothing before the handshake")
            let helloOK = ControlMessage.helloOK(ver: WireVersion.current, caps: 0, geoMode: 0,
                                                 geoWidth: 0, geoHeight: 0, geoScale: 0)
            host.handleControl(Data(helloOK.encoded()), nowUS: 1_000)
            #expect(notices(capture) == expected)
        }
    }
}
