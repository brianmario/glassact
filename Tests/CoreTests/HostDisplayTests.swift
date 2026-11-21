import Foundation
import Testing
@testable import GlassActCore
import GlassActTestSupport
import GlassActWire

/// HOST_DISPLAY (§3.5): the host tells a viewer that asks (`WireCaps.hostDisplaySize`) the pixel
/// size of the display it shares, so the viewer can say "5120 × 2880 shown at 2896 × 1628" where
/// its picture is scaled (a tester read the picture's size as his Mac's and asked why it was wrong).
@Suite struct HostDisplayTests {
    private func sizes(_ capture: CaptureTransport) -> [[Int]] {
        var d = ControlDeframer()
        for data in capture.sentControl { d.append(Array(data)) }
        var out: [[Int]] = []
        while let event = d.next() {
            if case let .message(.hostDisplay(w, h)) = event { out.append([Int(w), Int(h)]) }
        }
        return out
    }

    private func handshake(_ host: HostEngine, viewerCaps: UInt32) {
        let helloOK = ControlMessage.helloOK(ver: WireVersion.current, caps: viewerCaps, geoMode: 0,
                                             geoWidth: 0, geoHeight: 0, geoScale: 0)
        host.handleControl(Data(helloOK.encoded()), nowUS: 1_000)
    }

    @Test func aViewerThatAsksHearsItAtTheHandshakeAndOnAChange() {
        let capture = CaptureTransport()
        let host = HostEngine(width: 256, height: 192, transport: capture)
        host.setHostDisplaySize(width: 5120, height: 2880)
        host.start(nowUS: 0)
        #expect(sizes(capture).isEmpty, "nothing before the handshake")
        handshake(host, viewerCaps: WireCaps.hostDisplaySize)
        #expect(sizes(capture) == [[5120, 2880]])
        host.setHostDisplaySize(width: 5120, height: 2880)  // unchanged: nothing
        host.setHostDisplaySize(width: 2560, height: 1440)
        #expect(sizes(capture) == [[5120, 2880], [2560, 1440]])
    }

    @Test func aViewerWithoutTheBitNeverGetsIt() {
        // (a released Viewer: it would fail on a type it doesn't know)
        let capture = CaptureTransport()
        let host = HostEngine(width: 256, height: 192, transport: capture)
        host.setHostDisplaySize(width: 5120, height: 2880)
        host.start(nowUS: 0)
        handshake(host, viewerCaps: 0)
        host.setHostDisplaySize(width: 2560, height: 1440)
        #expect(sizes(capture).isEmpty)
    }

    @Test func theViewerHearsItThroughTheEngine() {
        let h = Harness(width: 256, height: 192)
        var seen: [[Int]] = []
        h.viewer.onHostDisplay = { seen.append([$0, $1]) }
        h.host.setHostDisplaySize(width: 3840, height: 2160)
        h.run(untilUS: h.now + 100_000)
        #expect(seen.last == [3840, 2160])
    }
}
