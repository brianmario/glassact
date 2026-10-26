import GlassActWire

/// One message of every type, as released builds encode them; the shared
/// input of WireCompatTests.
enum WireCompatSamples {
    static let control: [ControlMessage] = [
        .hello(ver: 4, width: 2940, height: 1912, tileSize: 64, pixfmt: 1, caps: 0x0E71),
        .helloOK(ver: 4, caps: 0x0011, geoMode: 4, geoWidth: 1470, geoHeight: 956, geoScale: 2),
        .ack(frameSeq: 1234, dgramCnt: 10, bitmap: [0xFF, 0x03]),
        .ping(nonce: 0x0102_0304_0506_0708, tUS: 1_000_000),
        .pong(nonce: 0x0102_0304_0506_0708, tUS: 1_000_000, recvTUS: 1_000_250),
        .scroll(frameSeq: 77, x: 0, y: 128, width: 2940, height: 1600, dx: 0, dy: -192),
        .scrollAck(frameSeq: 77, skipped: [3, 900], digest: 0xDEAD_BEEF_F00D_CAFE),
        .pauseHint(paused: true),
        .keyframeAck(seq: 42),
        .deltaNack(frameSeq: 99, tiles: [1, 2, 3]),
        .cursorPos(x: 640, y: 400, visible: true),
        .cursorImage(width: 2, height: 1, hotspotX: 0, hotspotY: 0, scale: 2, bgra: [1, 2, 3, 4, 5, 6, 7, 8]),
        .resize(mode: 1, width: 1470, height: 956, scale: 2),
        .clipboard(format: 1, data: Array("hello".utf8)),
        .quality(presentedScalePct: 100, floor: 1, preferSharpness: 1),
        .input(kind: 5, x: 124, y: 0, a: 0x0018_0000, b: 0),
        .windowList(windows: [WireWindow(windowID: 7, appName: "Notes", title: "Groceries",
                                         thumbFormat: 1, thumbWidth: 2, thumbHeight: 2, thumb: [9, 9])]),
        .windowSelect(windowID: 7),
        .windowControl(action: 2, width: 800, height: 600),
        .viewerLog(name: "viewer.log", offset: 0, total: 3, data: [65, 66, 67]),
        .textInput(text: "héllo"),
        .agentState(active: true, label: "Claude"),
        .uiTreeRequest(requestID: 5, windowID: 7, maxNodes: 200),
        .uiTree(requestID: 5, status: 0, json: Array("{}".utf8)),
        .agentScope(control: false, reason: "paused"),
        .viewerInfo(name: "MacBook Air"),
        .syncRequest(region: 1, generation: 9),
        .received(bytes: 1_000_000, tUS: 2_000_000),
        .hostNotice(code: HostNotice.sessionOffScreen),
    ]

    static let video: [VideoMessage] = [
        .start(region: 1, generation: 2, x: 0, y: 0, width: 1280, height: 720, codec: 1, config: [1, 2, 3]),
        .frame(region: 1, generation: 2, seq: 3, sync: true, captureUS: 123_456, data: [0, 0, 0, 1]),
        .stop(region: 1, generation: 2, reveal: [4, 5]),
        .keyframe(seq: 8, x: 0, y: 0, width: 64, height: 64, codec: 1, stripes: [[1, 2], [3]]),
        .reveal(region: 1, generation: 2, tiles: [6, 7]),
    ]

    static let signInRequest = SignInRequest(op: .signIn, user: "alex", password: "pw", device: "MacBook Air")
    static let signInResponse = SignInResponse(.approved)
}
