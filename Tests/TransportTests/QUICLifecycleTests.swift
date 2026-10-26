import Foundation
import Testing
import GlassActTestSupport
@testable import GlassActTransport

/// Transport lifecycle contract (real QUIC over loopback): one terminal
/// state per transport, however the session ends; a half-built dial never
/// wedges the listener; a lost video stream recovers in-session.
@Suite(.serialized, .tags(.quic), .notInFastLane) struct QUICLifecycleTests {
    final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [TransportState] = []
        func append(_ s: TransportState) { lock.lock(); states.append(s); lock.unlock() }
        var all: [TransportState] { lock.lock(); defer { lock.unlock() }; return states }
        var terminal: [TransportState] { all.filter { $0 == .failed || $0 == .cancelled } }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }

    /// cancel() must tear down before setting `finished`; otherwise the
    /// terminal state never fires and the viewer's connect-timeout redial
    /// hangs forever.
    @Test func localCancelEmitsExactlyOneTerminalState() throws {
        let (identity, fingerprint) = try QUICLoopbackTests.makeTestIdentity()
        let clientLog = StateLog()
        let hostLog = StateLog()
        guard let session = try QUICLoopbackTests.makeSession(
            fingerprint: fingerprint, identity: identity,
            configureHost: { $0.onState = { hostLog.append($0) } },
            configureClient: { $0.onState = { clientLog.append($0) } }
        ) else {
            Issue.record("session failed to become ready")
            return
        }
        defer { session.server.cancel() }
        session.client.cancel()
        session.client.cancel() // idempotent
        #expect(waitUntil(5) { clientLog.terminal.count == 1 }, "local cancel must report .cancelled")
        #expect(clientLog.terminal == [.cancelled])
        // The peer sees the close as a failure of an established session.
        #expect(waitUntil(10) { hostLog.terminal.count == 1 }, "the peer must observe the close")
        usleep(200_000)
        #expect(clientLog.terminal.count == 1 && hostLog.terminal.count == 1, "exactly one terminal state each")
    }

    /// close(after:) (the viewer's goodbye): the last message reaches the
    /// peer ahead of a clean end of the stream, and each side ends once.
    @Test func closeAfterDeliversTheLastMessage() throws {
        let (identity, fingerprint) = try QUICLoopbackTests.makeTestIdentity()
        let clientLog = StateLog(), hostLog = StateLog()
        let gotControl = DispatchSemaphore(value: 0)
        let received = NSMutableData()
        let lock = NSLock()
        guard let session = try QUICLoopbackTests.makeSession(
            fingerprint: fingerprint, identity: identity,
            configureHost: { host in
                host.onState = { hostLog.append($0) }
                host.onControl = { data in lock.lock(); received.append(data); lock.unlock() }
            },
            configureClient: { client in
                client.onState = { clientLog.append($0) }
                client.onControl = { _ in gotControl.signal() }
            }
        ) else {
            Issue.record("session failed to become ready")
            return
        }
        defer { session.server.cancel() }
        session.host.sendControl(Data("hello".utf8)) // materializes the viewer's control stream
        #expect(gotControl.wait(timeout: .now() + 5) == .success)
        session.client.close(after: Data("bye".utf8))
        session.client.sendControl(Data("late".utf8)) // after the end: dropped
        #expect(waitUntil(5) { hostLog.terminal.count == 1 }, "the peer must observe the close")
        lock.lock(); let bytes = received as Data; lock.unlock()
        #expect(bytes == Data("bye".utf8))
        #expect(session.host.peerClosedCleanly)
        #expect(waitUntil(5) { clientLog.terminal.count == 1 })
        usleep(1_200_000) // past the grace: still exactly one terminal state each
        #expect(clientLog.terminal.count == 1 && hostLog.terminal.count == 1)
    }

    /// Idle = zero bytes (INV-10) is safe only if QUIC's own keepalive holds
    /// both tunnels open: a session with no application traffic at all for
    /// longer than the idle timeout must still be alive and deliver on both
    /// channels. (This is why the host needs no app-level keepalive
    /// datagram.)
    @Test(.tags(.slow), .notInFastLane) func silentSessionOutlivesTheIdleTimeout() throws {
        let (identity, fingerprint) = try QUICLoopbackTests.makeTestIdentity()
        let hostLog = StateLog(), clientLog = StateLog()
        let gotControl = DispatchSemaphore(value: 0), gotDatagram = DispatchSemaphore(value: 0)
        guard let session = try QUICLoopbackTests.makeSession(
            fingerprint: fingerprint, identity: identity,
            configureHost: { $0.onState = { hostLog.append($0) } },
            configureClient: { client in
                client.onState = { clientLog.append($0) }
                client.onControl = { _ in gotControl.signal() }
                client.onDatagram = { _ in gotDatagram.signal() }
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
        session.host.sendControl(Data("hello".utf8)) // materializes the viewer's control stream
        #expect(gotControl.wait(timeout: .now() + 5) == .success)

        Thread.sleep(forTimeInterval: Double(QUICTransport.idleTimeoutMS) / 1000 + 5) // total silence

        #expect(hostLog.terminal.isEmpty && clientLog.terminal.isEmpty, "an idle session must not time out")
        session.host.sendControl(Data("still here".utf8))
        #expect(gotControl.wait(timeout: .now() + 5) == .success, "control must still deliver")
        for _ in 0..<5 { session.host.sendDatagram(Data([0xAB])) }
        #expect(gotDatagram.wait(timeout: .now() + 5) == .success, "datagrams must still deliver")
    }

    /// A dial whose datagram tunnel never arrives (port + 1 blocked) must
    /// fail by the establishment deadline on both sides, and must not wedge
    /// the listener's single session slot against the next, working dial.
    @Test func halfBuiltDialNeverWedgesTheListener() throws {
        let (identity, fingerprint) = try QUICLoopbackTests.makeTestIdentity()
        let serverQueue = DispatchQueue(label: "test.quic.server.lifecycle")
        let server = try QUICServer(port: 0, identity: identity, queue: serverQueue)
        defer { server.cancel() }
        let listening = DispatchSemaphore(value: 0)
        server.onReady = { listening.signal() }
        let hostLogs = StateLog() // every host transport, in order
        let hostReady = DispatchSemaphore(value: 0)
        server.onTransport = { transport in
            transport.onState = { state in
                hostLogs.append(state)
                if state == .ready { hostReady.signal() }
            }
            transport.start()
        }
        server.start()
        guard listening.wait(timeout: .now() + 5) == .success,
              let port = server.port, let datagramPort = server.datagramPort else {
            Issue.record("listener failed to come up")
            return
        }

        // Dial 1: correct control port, dead datagram port.
        let brokenLog = StateLog()
        let broken = QUICTransport.connect(host: "127.0.0.1", port: port, fingerprint: fingerprint,
                                           datagramPort: 9, queue: DispatchQueue(label: "test.broken"))
        broken.onState = { brokenLog.append($0) }
        broken.start()
        let limit = QUICTransport.establishTimeoutS + 5
        #expect(waitUntil(limit) { brokenLog.terminal.count == 1 }, "half-built dial must fail by the deadline")
        #expect(broken.lastFailReason.contains("not established"))
        #expect(waitUntil(limit) { hostLogs.terminal.count >= 1 }, "host side must give up too")

        // Dial 2: everything right — the listener must accept it.
        let goodLog = StateLog()
        let good = QUICTransport.connect(host: "127.0.0.1", port: port, fingerprint: fingerprint,
                                         datagramPort: datagramPort, queue: DispatchQueue(label: "test.good"))
        good.onState = { goodLog.append($0) }
        good.start()
        defer { good.cancel() }
        #expect(waitUntil(10) { goodLog.all.contains(.ready) }, "the listener must accept the next dial")
        #expect(hostReady.wait(timeout: .now() + 10) == .success)
    }

    /// A lost video stream degrades, not ends, the session: both sides are
    /// told (onVideoReset), and the next video rides a fresh stream the
    /// viewer adopts. Ignoring the replacement would leave video dead for the
    /// rest of the session.
    @Test func lostVideoStreamRecoversInSession() throws {
        let (identity, fingerprint) = try QUICLoopbackTests.makeTestIdentity()
        let lock = NSLock()
        var received = Data()
        var hostResets = 0
        var clientResets = 0
        var hostRef: QUICTransport?
        guard let session = try QUICLoopbackTests.makeSession(
            fingerprint: fingerprint, identity: identity,
            configureHost: { host in
                hostRef = host
                host.onVideoReset = { lock.lock(); hostResets += 1; lock.unlock() }
            },
            configureClient: { client in
                client.onVideo = { data in lock.lock(); received.append(data); lock.unlock() }
                client.onVideoReset = {
                    lock.lock(); clientResets += 1; received.removeAll(); lock.unlock()
                }
            }
        ) else {
            Issue.record("session failed to become ready")
            return
        }
        defer {
            session.client.cancel()
            session.host.cancel()
            session.server.cancel()
        }
        _ = hostRef
        session.host.sendVideo(Data(repeating: 0xA1, count: 1000))
        #expect(waitUntil(5) { lock.lock(); defer { lock.unlock() }; return received.count == 1000 })

        session.host.testKillVideoStream()
        #expect(waitUntil(5) { lock.lock(); defer { lock.unlock() }; return hostResets == 1 && clientResets >= 1 },
                "both sides must learn the video stream is gone")

        let second = Data(repeating: 0xB2, count: 5000)
        session.host.sendVideo(second)
        #expect(waitUntil(5) { lock.lock(); defer { lock.unlock() }; return received == second },
                "video must flow again on a fresh stream the viewer adopts")
    }
}
