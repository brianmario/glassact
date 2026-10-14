import Foundation
import Security
import Synchronization
import Testing
import GlassActWire
import GlassActTestSupport
@testable import GlassActTransport

/// §13 — signing in with the host Mac's account instead of a host-side
/// prompt: the throttle, the host's policy, and the real exchange over QUIC.
@Suite struct SignInThrottleTests {
    @Test func backsOffPerAddressAndClearsOnSuccess() {
        var t = SignInThrottle()
        #expect(t.retryAfter(address: "a", now: 0) == nil)
        t.noteFailure(address: "a", now: 0)
        #expect(t.retryAfter(address: "a", now: 0) == nil, "the first failure is free")
        t.noteFailure(address: "a", now: 0)
        #expect(t.retryAfter(address: "a", now: 1) == 4)
        #expect(t.retryAfter(address: "b", now: 1) == nil, "another address isn't held back")
        #expect(t.retryAfter(address: "a", now: 5) == nil)
        t.noteFailure(address: "a", now: 5)
        #expect(t.retryAfter(address: "a", now: 5) == 30)
        t.noteSuccess(address: "a")
        #expect(t.retryAfter(address: "a", now: 6) == nil)
    }

    @Test func capsFailuresAcrossAllAddresses() {
        var t = SignInThrottle()
        for i in 0..<SignInThrottle.maxFailuresPerWindow {
            #expect(t.retryAfter(address: "addr\(i)", now: Double(i)) == nil)
            t.noteFailure(address: "addr\(i)", now: Double(i))
        }
        // Full window: everyone waits until the oldest failure ages out.
        #expect(t.globalRetryAfter(now: 10) == SignInThrottle.windowSeconds - 10)
        #expect(t.retryAfter(address: "fresh", now: 10) == SignInThrottle.windowSeconds - 10)
        #expect(t.retryAfter(address: "fresh", now: SignInThrottle.windowSeconds) == nil)
    }

    @Test func trackedAddressesAreBounded() {
        var t = SignInThrottle()
        for i in 0..<(SignInThrottle.maxTrackedAddresses * 4) {
            t.noteFailure(address: "addr\(i)", now: Double(i) * 10_000) // never fills the window
        }
        // Bounded memory; the most recent addresses are still tracked.
        let last = "addr\(SignInThrottle.maxTrackedAddresses * 4 - 1)"
        t.noteFailure(address: last, now: 1e9)
        #expect(t.retryAfter(address: last, now: 1e9) != nil)
    }
}

@Suite struct SignInGateTests {
    struct FixedPassword: PasswordVerifier {
        func verify(user: String, password: String) -> Bool { user == "alex" && password == "right" }
    }

    final class World: @unchecked Sendable {
        let lock = NSLock()
        var policy = NewViewerPolicy.signIn
        var approved: [String: String] = [:] // fingerprint → device
        var events: [SignInGate.Event] = []
        var clock = 0.0
        var verifications = 0

        func gate() -> SignInGate {
            SignInGate(
                verifier: Counting(world: self),
                policy: { [self] in lock.withLock { policy } },
                isApproved: { [self] fp in lock.withLock { approved[fp] != nil } },
                approve: { [self] a in lock.withLock { approved[a.fingerprint] = a.device }; return true },
                onEvent: { [self] e in lock.withLock { events.append(e) } },
                now: { [self] in lock.withLock { clock } },
                failureDelaySeconds: 0)
        }

        struct Counting: PasswordVerifier {
            let world: World
            func verify(user: String, password: String) -> Bool {
                world.lock.withLock { world.verifications += 1 }
                return FixedPassword().verify(user: user, password: password)
            }
        }
    }

    let viewer = QUICTransport.PeerCertificate(fingerprint: "aa11", commonName: "glassact-viewer")
    let agent = QUICTransport.PeerCertificate(fingerprint: "bb22", commonName: "glassact-agent")

    @Test func rightPasswordApprovesThisKey() {
        let world = World()
        let gate = world.gate()
        #expect(gate.answerNow(SignInRequest(op: .query), peer: viewer, address: "1.2.3.4").status == .signInAvailable)
        let response = gate.answerNow(SignInRequest(op: .signIn, user: "alex", password: "right", device: "Air"),
                                      peer: viewer, address: "1.2.3.4")
        #expect(response.status == .approved)
        #expect(world.approved == ["aa11": "Air"])
        // Approved now: a query says so, and no password is checked again.
        #expect(gate.answerNow(SignInRequest(op: .query), peer: viewer, address: "1.2.3.4").status == .approved)
        #expect(gate.answerNow(SignInRequest(op: .signIn, user: "x", password: "y"), peer: viewer,
                               address: "1.2.3.4").status == .approved)
        #expect(world.verifications == 1)
    }

    @Test func wrongPasswordApprovesNothingAndIsThrottled() {
        let world = World()
        let gate = world.gate()
        let wrong = SignInRequest(op: .signIn, user: "alex", password: "wrong")
        #expect(gate.answerNow(wrong, peer: viewer, address: "5.6.7.8").status == .wrongCredentials)
        #expect(gate.answerNow(wrong, peer: viewer, address: "5.6.7.8").status == .wrongCredentials)
        let held = gate.answerNow(SignInRequest(op: .signIn, user: "alex", password: "right"), peer: viewer,
                                  address: "5.6.7.8")
        #expect(held.status == .tooManyAttempts && held.retryAfterSeconds == 5,
                "even the right password waits out the backoff")
        #expect(world.verifications == 2, "a throttled attempt never reaches the password check")
        #expect(world.approved.isEmpty)
    }

    @Test func policyDecidesWhatANewKeyHears() {
        let world = World()
        let gate = world.gate()
        let signIn = SignInRequest(op: .signIn, user: "alex", password: "right")
        world.policy = .ask
        #expect(gate.answerNow(SignInRequest(op: .query), peer: viewer, address: "a").status == .askOnHost)
        #expect(gate.answerNow(signIn, peer: viewer, address: "a").status == .askOnHost)
        world.policy = .closed
        #expect(gate.answerNow(SignInRequest(op: .query), peer: viewer, address: "a").status == .closed)
        #expect(gate.answerNow(signIn, peer: viewer, address: "a").status == .closed)
        #expect(world.verifications == 0 && world.approved.isEmpty)
    }

    /// Agents never get this Mac's password: their keys go to the prompt.
    @Test func agentsCannotSignIn() {
        let world = World()
        let gate = world.gate()
        let signIn = SignInRequest(op: .signIn, user: "alex", password: "right")
        #expect(gate.answerNow(signIn, peer: agent, address: "a").status == .askOnHost)
        world.policy = .closed
        #expect(gate.answerNow(signIn, peer: agent, address: "a").status == .closed)
        #expect(world.verifications == 0 && world.approved.isEmpty)
    }

    @Test func fullWindowReportsThrottledOnce() {
        let world = World()
        let gate = world.gate()
        for i in 0..<SignInThrottle.maxFailuresPerWindow {
            _ = gate.answerNow(SignInRequest(op: .signIn, user: "alex", password: "no"), peer: viewer,
                               address: "host\(i)")
        }
        let throttled = world.events.filter { if case .throttled = $0 { true } else { false } }
        #expect(throttled.count == 1)
        #expect(gate.answerNow(SignInRequest(op: .signIn, user: "alex", password: "right"), peer: viewer,
                               address: "new").status == .tooManyAttempts)
    }
}

/// The real exchange over loopback QUIC: an unapproved key is refused on the
/// session ALPN, signs in on the sign-in ALPN, and is then admitted.
@Suite(.serialized, .tags(.quic), .notInFastLane) struct SignInQUICTests {
    final class Approvals: Sendable {
        let keys = Mutex<Set<String>>([])
    }

    struct Harness {
        let server: QUICServer
        let port: UInt16
        let datagramPort: UInt16
        let hostFingerprint: String
        let approvals: Approvals
    }

    final class Counter: Sendable {
        let value = Atomic<Int>(0)
        /// Signalled when a host-side session transport becomes ready — the
        /// proof of admission (a refused viewer still sees its own TLS 1.3
        /// handshake finish before the host's refusal lands).
        let hostReady = DispatchSemaphore(value: 0)
    }

    func makeServer(policy: NewViewerPolicy = .signIn, signIn: Bool = true,
                    counter: Counter = Counter()) throws -> (Harness, Counter) {
        let (hostID, hostFP) = try QUICLoopbackTests.makeTestIdentity()
        let approvals = Approvals()
        let gate = SignInGate(verifier: SignInGateTests.FixedPassword(), policy: { policy },
                              isApproved: { fp in approvals.keys.withLock { $0.contains(fp) } },
                              approve: { a in approvals.keys.withLock { _ = $0.insert(a.fingerprint) }; return true },
                              failureDelaySeconds: 0)
        let handler: QUICServer.SignInHandler = { request, peer, address, reply in
            gate.handle(request, peer: peer, address: address, reply: reply)
        }
        let server = try QUICServer(
            port: 0, identity: hostID, queue: DispatchQueue(label: "test.signin.server"),
            authorizeViewer: { fp in approvals.keys.withLock { $0.contains(fp) } },
            signIn: signIn ? handler : nil)
        let listening = DispatchSemaphore(value: 0)
        server.onReady = { listening.signal() }
        server.onTransport = { (transport: QUICTransport) in
            counter.value.add(1, ordering: .relaxed)
            transport.onState = { if $0 == .ready { counter.hostReady.signal() } }
            transport.start()
        }
        server.start()
        #expect(listening.wait(timeout: .now() + 5) == .success)
        return (Harness(server: server, port: server.port ?? 0, datagramPort: server.datagramPort ?? 0,
                        hostFingerprint: hostFP, approvals: approvals), counter)
    }

    func exchange(_ request: SignInRequest, _ h: Harness, identity: SecIdentity?,
                  pin: String? = nil) -> SignInClient.Outcome? {
        let done = DispatchSemaphore(value: 0)
        let box = Mutex<SignInClient.Outcome?>(nil)
        SignInClient.send(request, host: "127.0.0.1", port: h.port, pinnedFingerprint: pin ?? h.hostFingerprint,
                          identity: identity, timeout: 8) { outcome in
            box.withLock { $0 = outcome }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return box.withLock { $0 }
    }

    /// Whether the host admitted a session from this key.
    func dialSession(_ h: Harness, _ counter: Counter, identity: SecIdentity) -> Bool {
        let client = QUICTransport.connect(host: "127.0.0.1", port: h.port, fingerprint: h.hostFingerprint,
                                           datagramPort: h.datagramPort, identity: identity)
        client.start()
        defer { client.cancel() }
        return counter.hostReady.wait(timeout: .now() + 4) == .success
    }

    @Test func unapprovedViewerSignsInThenConnects() throws {
        let (h, transports) = try makeServer()
        defer { h.server.cancel() }
        let (viewerID, viewerFP) = try QUICLoopbackTests.makeTestIdentity()

        #expect(!dialSession(h, transports, identity: viewerID), "an unknown key is refused on the session ALPN")
        let query = exchange(SignInRequest(op: .query, device: "Air"), h, identity: viewerID)
        #expect(query?.response?.status == .signInAvailable)
        #expect(query?.hostFingerprint == h.hostFingerprint)

        let wrong = exchange(SignInRequest(op: .signIn, user: "alex", password: "nope"), h, identity: viewerID)
        #expect(wrong?.response?.status == .wrongCredentials)
        #expect(!h.approvals.keys.withLock { $0.contains(viewerFP) })

        let right = exchange(SignInRequest(op: .signIn, user: "alex", password: "right", device: "Air"),
                             h, identity: viewerID)
        #expect(right?.response?.status == .approved)
        #expect(h.approvals.keys.withLock { $0.contains(viewerFP) }, "the key on the sign-in connection is approved")
        #expect(dialSession(h, transports, identity: viewerID), "the approved key now connects")
        #expect(transports.value.load(ordering: .relaxed) == 1,
                "sign-in connections never become session transports")
    }

    /// The password goes only to the key the viewer expects: a pinned key
    /// that doesn't match stops the exchange before anything is sent.
    @Test func wrongHostKeyIsRefusedBeforeSending() throws {
        let (h, _) = try makeServer()
        defer { h.server.cancel() }
        let (viewerID, viewerFP) = try QUICLoopbackTests.makeTestIdentity()
        let (_, otherFP) = try QUICLoopbackTests.makeTestIdentity()
        let outcome = exchange(SignInRequest(op: .signIn, user: "alex", password: "right"), h,
                               identity: viewerID, pin: otherFP)
        #expect(outcome?.response == nil)
        #expect(outcome?.hostKeyMismatch == true)
        #expect(!h.approvals.keys.withLock { $0.contains(viewerFP) })
    }

    @Test func hostWithoutSignInRefusesTheALPN() throws {
        let (h, _) = try makeServer(signIn: false)
        defer { h.server.cancel() }
        let (viewerID, _) = try QUICLoopbackTests.makeTestIdentity()
        let outcome = exchange(SignInRequest(op: .query), h, identity: viewerID)
        #expect(outcome?.response == nil, "an older or locked-down host has no sign-in channel")
    }

    @Test func noClientCertificateNoSignIn() throws {
        let (h, _) = try makeServer()
        defer { h.server.cancel() }
        let outcome = exchange(SignInRequest(op: .query), h, identity: nil)
        #expect(outcome?.response == nil, "there must be a key to approve")
    }
}
