import Foundation
import Testing
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Real QUIC over loopback: TLS with a freshly generated self-signed identity,
/// fingerprint pinning, control stream + datagram flow, and the engines
/// converging end-to-end. Uses real time and real sockets — assertions are
/// deadline-based.
@Suite(.serialized, .tags(.quic), .notInFastLane) struct QUICLoopbackTests {
    // MARK: - Test identity (openssl ships with macOS; dev-only posture, §6)

    static func makeTestIdentity() throws -> (SecIdentity, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassact-quic-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let identity = try QUICIdentity.loadOrCreate(directory: dir, name: "id", commonName: "glassact-test")
        return (identity, try QUICIdentity.fingerprint(of: identity))
    }

    struct Session {
        let server: QUICServer
        let host: QUICTransport
        let client: QUICTransport
        let serverQueue: DispatchQueue
        let clientQueue: DispatchQueue
    }

    /// Brings up listener + client and waits for both transports to be ready.
    static func makeSession(
        fingerprint: String, identity: SecIdentity,
        clientIdentity: SecIdentity? = nil,
        authorizeViewer: (@Sendable (String) -> Bool)? = nil,
        configureHost: @escaping (QUICTransport) -> Void,
        configureClient: @escaping (QUICTransport) -> Void
    ) throws -> Session? {
        let serverQueue = DispatchQueue(label: "test.quic.server")
        let clientQueue = DispatchQueue(label: "test.quic.client")
        let server = try QUICServer(port: 0, identity: identity, queue: serverQueue,
                                    authorizeViewer: authorizeViewer)

        let listening = DispatchSemaphore(value: 0)
        var hostTransport: QUICTransport?
        let hostReady = DispatchSemaphore(value: 0)
        server.onReady = { listening.signal() }
        server.onTransport = { transport in
            hostTransport = transport
            configureHost(transport)
            let userState = transport.onState
            transport.onState = { state in
                userState(state)
                if state == .ready { hostReady.signal() }
            }
            transport.start()
        }
        server.start()
        guard listening.wait(timeout: .now() + 5) == .success,
              let port = server.port, let datagramPort = server.datagramPort else {
            return nil
        }

        let client = QUICTransport.connect(host: "127.0.0.1", port: port,
                                           fingerprint: fingerprint,
                                           datagramPort: datagramPort, identity: clientIdentity,
                                           queue: clientQueue)
        configureClient(client)
        let clientReady = DispatchSemaphore(value: 0)
        let userState = client.onState
        client.onState = { state in
            userState(state)
            if state == .ready { clientReady.signal() }
        }
        client.start()

        guard clientReady.wait(timeout: .now() + 10) == .success,
              hostReady.wait(timeout: .now() + 10) == .success,
              let host = hostTransport else { return nil }
        return Session(server: server, host: host, client: client,
                       serverQueue: serverQueue, clientQueue: clientQueue)
    }

    // MARK: - Tests

    /// Host speaks first on both paths — that is the protocol's shape (HELLO,
    /// then pixels) and the transport's contract: the viewer's control stream
    /// only materializes once the host's first bytes arrive.
    @Test func controlStreamAndDatagramsRoundTrip() throws {
        let (identity, fingerprint) = try Self.makeTestIdentity()
        let controlEchoed = DispatchSemaphore(value: 0)
        let datagramArrived = DispatchSemaphore(value: 0)
        var echoPayload = Data()
        var datagramPayload = Data()

        var hostRef: QUICTransport?
        var clientRef: QUICTransport?
        guard let session = try Self.makeSession(
            fingerprint: fingerprint, identity: identity,
            configureHost: { host in
                hostRef = host
                host.onControl = { data in // viewer's reply comes back here
                    echoPayload = data
                    controlEchoed.signal()
                }
            },
            configureClient: { client in
                clientRef = client
                client.onControl = { clientRef?.sendControl($0) } // echo host → viewer → host
                client.onDatagram = { data in
                    datagramPayload = data
                    datagramArrived.signal()
                }
            }
        ) else {
            Issue.record("QUIC loopback session failed to become ready")
            return
        }
        defer {
            session.client.cancel()
            session.host.cancel()
            session.server.cancel()
        }
        _ = hostRef

        #expect(session.client.maxDatagramSize > 0)
        #expect(session.host.maxDatagramSize > 0)

        session.host.sendControl(Data("glassact-hello".utf8))
        #expect(controlEchoed.wait(timeout: .now() + 5) == .success)
        #expect(echoPayload == Data("glassact-hello".utf8))

        // Datagrams are unreliable by contract; send a burst, require delivery.
        for i in 0..<20 {
            session.host.sendDatagram(Data([0xAB, UInt8(i)]))
        }
        #expect(datagramArrived.wait(timeout: .now() + 5) == .success)
        #expect(datagramPayload.first == 0xAB)
    }

    /// The video stream (§3.7): host-opened second stream in the control
    /// group, demuxed at the viewer by preamble. Control must keep flowing
    /// alongside it (HoL isolation is the whole point), ordering within the
    /// video channel must hold, and backlog accounting must drain to zero.
    @Test func videoStreamDeliversInOrderAlongsideControl() throws {
        let (identity, fingerprint) = try Self.makeTestIdentity()
        let allVideoArrived = DispatchSemaphore(value: 0)
        let controlArrived = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var videoBytes = Data()
        let expectedTotal = 300_000 + 40_000 + 8

        guard let session = try Self.makeSession(
            fingerprint: fingerprint, identity: identity,
            configureHost: { _ in },
            configureClient: { client in
                client.onVideo = { data in
                    lock.lock()
                    videoBytes.append(data)
                    let done = videoBytes.count >= expectedTotal
                    lock.unlock()
                    if done { allVideoArrived.signal() }
                }
                client.onControl = { _ in controlArrived.signal() }
            }
        ) else {
            Issue.record("QUIC loopback session failed to become ready")
            return
        }
        defer {
            session.client.cancel()
            session.host.cancel()
            session.server.cancel()
        }

        // A large frame, then a control message, then more video: the channels
        // must not block each other and video must arrive intact and ordered.
        var rng = SystemRandomNumberGenerator()
        let big = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let small = Data((0..<40_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        session.host.sendVideo(big)
        session.host.sendControl(Data("mid-video-control".utf8))
        session.host.sendVideo(small)
        session.host.sendVideo(Data([1, 2, 3, 4, 5, 6, 7, 8]))

        #expect(controlArrived.wait(timeout: .now() + 5) == .success)
        #expect(allVideoArrived.wait(timeout: .now() + 10) == .success)
        lock.lock()
        let received = videoBytes
        lock.unlock()
        #expect(received.count == expectedTotal)
        #expect(received.prefix(300_000) == big)
        #expect(received.dropFirst(300_000).prefix(40_000) == small)
        #expect(received.suffix(8) == Data([1, 2, 3, 4, 5, 6, 7, 8]))

        // Backlog drains once the network accepted everything.
        let deadline = Date().addingTimeInterval(5)
        while session.host.videoBacklogBytes > 0 && Date() < deadline {
            usleep(20_000)
        }
        #expect(session.host.videoBacklogBytes == 0)
    }

    @Test func wrongFingerprintIsRejected() throws {
        let (identity, _) = try Self.makeTestIdentity()
        let bogus = String(repeating: "ab", count: 32)
        let session = try Self.makeSession(fingerprint: bogus, identity: identity,
                                           configureHost: { _ in }, configureClient: { _ in })
        #expect(session == nil, "pinning must reject a mismatched certificate")
        // (listener cleanup happens via process teardown; makeSession owns no
        // reference we can cancel when setup fails partway)
    }

    /// The real thing: HostEngine → QUIC loopback → ViewerEngine, canvas
    /// byte-identical. Engines are confined to the transport queues.
    @Test func enginesConvergeOverRealQUIC() throws {
        let (identity, fingerprint) = try Self.makeTestIdentity()
        let width = 128, height = 128
        var host: HostEngine?
        var viewer: ViewerEngine?

        guard let session = try Self.makeSession(
            fingerprint: fingerprint, identity: identity,
            configureHost: { transport in
                let engine = HostEngine(width: width, height: height, transport: transport,
                                        clock: { MonotonicClock.nowUS })
                host = engine
                transport.onControl = { engine.handleControl($0, nowUS: MonotonicClock.nowUS) }
            },
            configureClient: { transport in
                let engine = ViewerEngine(transport: transport)
                viewer = engine
                transport.onControl = { engine.handleControl($0, nowUS: MonotonicClock.nowUS) }
                transport.onDatagram = { engine.handleDatagram($0, nowUS: MonotonicClock.nowUS) }
            }
        ) else {
            Issue.record("QUIC loopback session failed to become ready")
            return
        }
        defer {
            session.client.cancel()
            session.host.cancel()
            session.server.cancel()
        }
        guard let host, let viewer else {
            Issue.record("engines not created")
            return
        }

        var rngState: UInt64 = 90
        var frame = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<frame.count {
            rngState = rngState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            frame[i] = UInt8(truncatingIfNeeded: rngState >> 33)
        }

        session.serverQueue.sync { host.start(nowUS: MonotonicClock.nowUS) }

        let deadline = Date().addingTimeInterval(15)
        var matched = false
        while Date() < deadline && !matched {
            session.serverQueue.sync {
                let now = MonotonicClock.nowUS
                if host.state == .running {
                    frame.withUnsafeBytes { raw in
                        host.encodeTick(frame: raw, bytesPerRow: width * 4, dirtyRects: nil,
                                        captureTimestampUS: now, nowUS: now)
                    }
                }
                host.tick(nowUS: now)
            }
            session.clientQueue.sync { viewer.tick(nowUS: MonotonicClock.nowUS) }
            matched = session.clientQueue.sync {
                viewer.withCanvas { canvas in
                    frame.withUnsafeBytes { expected in
                        canvas.count == expected.count
                            && memcmp(canvas.baseAddress, expected.baseAddress, expected.count) == 0
                    }
                } ?? false
            }
            Thread.sleep(forTimeInterval: 0.016)
        }
        #expect(matched, "viewer canvas did not converge over real QUIC within 15 s")
    }
}
