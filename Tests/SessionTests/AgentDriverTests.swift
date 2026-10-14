import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import GlassActCore
import GlassActSession
import GlassActTestSupport
import GlassActTransport
import GlassActWire

/// An agent driving a real session: QUICServer + HostEngine (synthetic
/// frames) ← QUIC → ViewerSession + AgentDriver. What an agent sees must be
/// exactly the host's pixels once settled, and what it does must reach the
/// host as agent-flagged input, in the order a keyboard and mouse produce.
@Suite(.serialized, .tags(.quic), .notInFastLane) struct AgentDriverTests {
    static let width = 640, height = 400

    /// What the host engine received.
    final class HostLog: Sendable {
        let inputs = Mutex<[(kind: Int, x: Int, y: Int, a: Int, b: Int)]>([])
        let texts = Mutex<[String]>([])
        let agentStates = Mutex<[(Bool, String)]>([])
        let treeRequests = Mutex<[(UInt32, UInt32, Int)]>([])
        let viewerNames = Mutex<[String]>([])
    }

    /// Builds the whole loop; nil if QUIC loopback didn't come up.
    static func makeRig() throws -> (server: QUICServer, serverQueue: DispatchQueue, hostBox: HostBox,
                                     session: ViewerSession, driver: AgentDriver, frame: [UInt8], stop: () -> Void)? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glassact-agent-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostID = try QUICIdentity.loadOrCreate(directory: dir, name: "host", commonName: "host")
        let hostFP = try QUICIdentity.fingerprint(of: hostID)
        let agentID = try QUICIdentity.loadOrCreate(directory: dir, name: "agent", commonName: "glassact-agent")

        var rng = SplitMix64(seed: 7)
        var frame = [UInt8](repeating: 0xFF, count: width * height * 4)
        for i in stride(from: 0, to: frame.count, by: 4) {
            let v = rng.next()
            frame[i] = UInt8(truncatingIfNeeded: v)
            frame[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
            frame[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
        }

        let serverQueue = DispatchQueue(label: "test.agent.host")
        let server = try QUICServer(port: 0, identity: hostID, queue: serverQueue, authorizeViewer: { _ in true })
        let listening = DispatchSemaphore(value: 0)
        server.onReady = { listening.signal() }
        let box = HostBox()
        server.onTransport = { transport in
            let engine = HostEngine(width: width, height: height, transport: transport, clock: { MonotonicClock.nowUS })
            engine.extraHelloCaps = WireCaps.agentControl
            engine.onInput = { kind, x, y, a, b in box.log.inputs.withLock { $0.append((kind, x, y, a, b)) } }
            engine.onTextInput = { text in box.log.texts.withLock { $0.append(text) } }
            engine.onAgentState = { active, label in box.log.agentStates.withLock { $0.append((active, label)) } }
            engine.onUITreeRequest = { id, window, maxNodes in box.log.treeRequests.withLock { $0.append((id, window, maxNodes)) } }
            engine.onViewerInfo = { name in box.log.viewerNames.withLock { $0.append(name) } }
            transport.onControl = { engine.handleControl($0, nowUS: MonotonicClock.nowUS) }
            box.engine = engine
            transport.start()
            engine.start(nowUS: MonotonicClock.nowUS)
        }
        server.start()
        guard listening.wait(timeout: .now() + 5) == .success, let port = server.port,
              let datagramPort = server.datagramPort else { return nil }

        // Host loop: the same frame every 16 ms (a static screen).
        let timer = DispatchSource.makeTimerSource(queue: serverQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        let frameCopy = frame
        timer.setEventHandler {
            guard let engine = box.engine else { return }
            let now = MonotonicClock.nowUS
            if engine.state == .running {
                frameCopy.withUnsafeBytes { raw in
                    engine.encodeTick(frame: raw, bytesPerRow: width * 4, dirtyRects: nil, captureTimestampUS: now, nowUS: now)
                }
            }
            engine.tick(nowUS: now)
        }
        timer.resume()

        let session = ViewerSession(host: "127.0.0.1", port: port, fingerprint: hostFP, identity: agentID,
                                    datagramPort: datagramPort,
                                    options: .init(cursorMetadata: false, video: false, deviceName: "Test’s MacBook Air"))
        let driver = AgentDriver(session: session, label: "test-agent")
        driver.maxEdge = 4096 // agent space = canvas pixels unless a test changes it
        session.start()
        let stop = {
            timer.cancel()
            session.stop()
            server.cancel()
        }
        return (server, serverQueue, box, session, driver, frame, stop)
    }

    final class HostBox: @unchecked Sendable {
        var engine: HostEngine? // serverQueue
        let log = HostLog()
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    static func decodePNG(_ base64: String) -> (Int, Int, [UInt8])? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, out) : nil
    }

    @Test func agentSeesExactPixelsAndDrivesTheHost() throws {
        guard let rig = try Self.makeRig() else {
            Issue.record("QUIC loopback didn't come up")
            return
        }
        defer { rig.stop() }
        let log = rig.hostBox.log

        // Connected, with the host's agent support visible.
        #expect(Self.waitUntil(15) { ((try? rig.driver.perform("status", [:]))?["connected"] as? Bool) == true })
        let status = try rig.driver.perform("status", [:])
        // The viewer told the host what computer it's on, once.
        #expect(Self.waitUntil(5) { log.viewerNames.withLock { $0 } == ["Test’s MacBook Air"] })
        #expect(status["agent_support"] as? Bool == true)

        // A settled screenshot is the host's frame, byte for byte.
        let shot = try rig.driver.perform("screenshot", ["timeout": 10])
        #expect(shot["settled"] as? Bool == true)
        let png = try #require(shot["png_base64"] as? String)
        let decoded = try #require(Self.decodePNG(png))
        #expect(decoded.0 == Self.width && decoded.1 == Self.height)
        var mismatches = 0
        for i in stride(from: 0, to: rig.frame.count, by: 4)
        where decoded.2[i] != rig.frame[i] || decoded.2[i + 1] != rig.frame[i + 1] || decoded.2[i + 2] != rig.frame[i + 2] {
            mismatches += 1
        }
        #expect(mismatches == 0, "settled screenshot differs from the host frame in \(mismatches) pixels")

        // Double-click: move, then down/up with click counts 1 and 2 — all flagged as agent input.
        _ = try rig.driver.perform("click", ["x": 10, "y": 20, "count": 2])
        #expect(Self.waitUntil(5) { log.inputs.withLock { $0.count } >= 5 })
        let clicks = log.inputs.withLock { $0 }
        #expect(clicks.allSatisfy { UInt8($0.kind) & InputFlags.agent != 0 })
        #expect(clicks.map { UInt8($0.kind) & InputFlags.kindMask } == [1, 2, 3, 2, 3])
        #expect(clicks.map(\.a) == [0, 1, 1, 2, 2])
        #expect(clicks.allSatisfy { $0.x == 10 && $0.y == 20 })

        // Text goes as text.
        _ = try rig.driver.perform("type", ["text": "héllo 👋"])
        #expect(Self.waitUntil(5) { log.texts.withLock { $0 } == ["héllo 👋"] })

        // A shortcut presses modifiers like a keyboard: shift, cmd, t, then releases in reverse.
        log.inputs.withLock { $0.removeAll() }
        _ = try rig.driver.perform("key", ["key": "cmd+shift+t"])
        #expect(Self.waitUntil(5) { log.inputs.withLock { $0.count } >= 6 })
        let keys = log.inputs.withLock { $0 }
        #expect(keys.map { UInt8($0.kind) & InputFlags.kindMask } == [5, 5, 5, 6, 6, 6])
        #expect(keys.map(\.x) == [56, 55, 17, 17, 55, 56])
        let shiftCmd = Int(Int32(bitPattern: 0x0012_0000))
        #expect(keys[2].a == shiftCmd && keys[3].a == shiftCmd)

        // The host heard that an agent is driving.
        #expect(Self.waitUntil(5) { log.agentStates.withLock { $0.first?.0 == true && $0.first?.1 == "test-agent" } })

        // Agent coordinates scale to canvas pixels.
        rig.driver.maxEdge = Self.width / 2
        log.inputs.withLock { $0.removeAll() }
        _ = try rig.driver.perform("move", ["x": 100, "y": 50])
        #expect(Self.waitUntil(5) { log.inputs.withLock { $0.last.map { $0.x == 200 && $0.y == 100 } ?? false } })

        // The accessibility tree comes back in agent coordinates.
        let (hostQueue, hostBox) = (rig.serverQueue, rig.hostBox)
        let answer = DispatchWorkItem {
            _ = Self.waitUntil(5) { log.treeRequests.withLock { !$0.isEmpty } }
            let req = log.treeRequests.withLock { $0[0] }
            let json = #"{"app":"Test","nodes":[{"i":0,"p":-1,"role":"AXButton","title":"OK","frame":[100,200,40,20]}]}"#
            hostQueue.async {
                hostBox.engine?.sendUITree(requestID: req.0, status: UITreeStatus.ok, json: Array(json.utf8))
            }
        }
        DispatchQueue.global().async(execute: answer)
        let ui = try rig.driver.perform("ui_tree", ["max_nodes": 50])
        let node = try #require((ui["nodes"] as? [[String: Any]])?.first)
        #expect(node["role"] as? String == "AXButton")
        #expect(node["frame"] as? [Int] == [50, 100, 20, 10])
        #expect(log.treeRequests.withLock { $0.first?.2 } == 50)

        // When the host says no, input fails with its reason.
        rig.serverQueue.sync { rig.hostBox.engine?.sendAgentScope(control: false, reason: "view-only approval") }
        #expect(Self.waitUntil(5) {
            ((try? rig.driver.perform("status", [:]))?["control"] as? Bool) == false
        })
        #expect(throws: AgentDriver.Failure.self) { _ = try rig.driver.perform("click", ["x": 1, "y": 1]) }

        // The person at the viewer wins too.
        rig.serverQueue.sync { rig.hostBox.engine?.sendAgentScope(control: true, reason: "") }
        #expect(Self.waitUntil(5) { ((try? rig.driver.perform("status", [:]))?["control"] as? Bool) == true })
        rig.driver.noteHumanInput()
        #expect(throws: AgentDriver.Failure.self) { _ = try rig.driver.perform("move", ["x": 1, "y": 1]) }
    }
}
