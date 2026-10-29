import Foundation
import Testing
import GlassActCore
import GlassActTestSupport
import GlassActWire

/// Input and the changes like it wait for the handshake (§13): the Host app
/// loads a session's policy (View Only, agent access) as it comes up, so
/// anything acted on before then would run under no policy at all. A viewer
/// sends none of these before its HELLO_OK; a modified one that does is
/// ignored until the handshake completes.
@Suite struct HandshakeGateTests {
    /// Every callback the gate covers, counted.
    private final class Calls {
        var inputs: [Int] = []
        var clipboard = 0, text = 0, windowSelect = 0, windowControl: [UInt8] = [], uiTree = 0, agentState = 0, resize = 0
    }

    private func wire(_ host: HostEngine) -> Calls {
        let calls = Calls()
        host.onInput = { kind, _, _, _, _ in calls.inputs.append(kind) }
        host.onClipboard = { _, _ in calls.clipboard += 1 }
        host.onTextInput = { _ in calls.text += 1 }
        host.onWindowSelect = { _ in calls.windowSelect += 1 }
        host.onWindowControl = { action, _, _ in calls.windowControl.append(action) }
        host.onUITreeRequest = { _, _, _ in calls.uiTree += 1 }
        host.onAgentState = { _, _ in calls.agentState += 1 }
        host.onResizeRequested = { _, _, _, _ in calls.resize += 1 }
        return calls
    }

    private func sendAll(_ host: HostEngine, nowUS: UInt64) {
        let messages: [ControlMessage] = [
            .input(kind: 2, x: 10, y: 10, a: 1, b: 0), // mouse down
            .input(kind: 3, x: 10, y: 10, a: 1, b: 0), // mouse up
            .input(kind: 5, x: 55, y: 0, a: 0, b: 0),  // key down (⌘)
            .input(kind: 6, x: 55, y: 0, a: 0, b: 0),  // key up
            .clipboard(format: 1, data: Array("secret".utf8)),
            .textInput(text: "hello"),
            .windowSelect(windowID: 7),
            .windowControl(action: 1, width: 0, height: 0),
            .windowControl(action: WindowAction.endSession, width: 0, height: 0),
            .uiTreeRequest(requestID: 1, windowID: 0, maxNodes: 100),
            .agentState(active: true, label: "x"),
            .resize(mode: GeometryMode.virtualDisplay, width: 800, height: 600, scale: 2),
        ]
        for message in messages { host.handleControl(Data(message.encoded()), nowUS: nowUS) }
    }

    @Test func nothingActsBeforeHelloOK() {
        let host = HostEngine(width: 128, height: 128, transport: CaptureTransport())
        let calls = wire(host)
        host.start(nowUS: 0)
        sendAll(host, nowUS: 500)
        #expect(calls.inputs == [3, 6], "only releases pass before the handshake")
        #expect(calls.windowControl == [WindowAction.endSession], "ending the session always passes")
        #expect(calls.clipboard == 0 && calls.text == 0 && calls.windowSelect == 0)
        #expect(calls.uiTree == 0 && calls.agentState == 0 && calls.resize == 0)
        #expect(!host.sessionOpen)

        let helloOK = ControlMessage.helloOK(ver: WireVersion.current, caps: 0, geoMode: 0,
                                             geoWidth: 0, geoHeight: 0, geoScale: 0)
        host.handleControl(Data(helloOK.encoded()), nowUS: 1_000)
        #expect(host.sessionOpen)
        sendAll(host, nowUS: 2_000)
        #expect(calls.inputs == [3, 6, 2, 3, 5, 6])
        #expect(calls.windowControl == [WindowAction.endSession, 1, WindowAction.endSession])
        #expect(calls.clipboard == 1 && calls.text == 1 && calls.windowSelect == 1)
        #expect(calls.uiTree == 1 && calls.agentState == 1 && calls.resize == 1)
    }

    /// A geometry request in HELLO_OK holds the engine out of `.running`
    /// until the re-offered HELLO: still closed.
    @Test func aGeometryHandshakeStaysClosed() {
        let host = HostEngine(width: 128, height: 128, transport: CaptureTransport())
        let calls = wire(host)
        host.start(nowUS: 0)
        let helloOK = ControlMessage.helloOK(ver: WireVersion.current, caps: 0, geoMode: GeometryMode.native,
                                             geoWidth: 0, geoHeight: 0, geoScale: 0)
        host.handleControl(Data(helloOK.encoded()), nowUS: 1_000)
        #expect(calls.resize == 1, "the handshake's own geometry request is answered")
        sendAll(host, nowUS: 2_000)
        #expect(calls.inputs == [3, 6] && calls.clipboard == 0 && calls.resize == 1)
    }

    /// An in-session rebuild (§4.10) carries the open session over, so input
    /// keeps flowing while the viewer answers the re-offered HELLO.
    @Test func anInSessionRebuildStaysOpen() {
        let (old, _) = makeRunningHost(width: 128, height: 128)
        let rebuilt = HostEngine(width: 256, height: 128, transport: CaptureTransport())
        rebuilt.sessionOpen = old.sessionOpen
        let calls = wire(rebuilt)
        rebuilt.start(nowUS: 0)
        sendAll(rebuilt, nowUS: 500)
        #expect(calls.inputs == [2, 3, 5, 6] && calls.clipboard == 1)
    }
}
