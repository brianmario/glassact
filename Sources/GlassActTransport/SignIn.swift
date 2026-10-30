public import Foundation
public import GlassActWire
import Network
#if os(macOS)
import OpenDirectory
#endif
public import Security
import Synchronization

// §13 — signing in with the host Mac's account. A viewer the host doesn't
// know is refused on the session ALPN during the TLS handshake (no prompt).
// It may then open a short sign-in connection (`glassact-signin`, same port)
// and send this Mac's user name and password. If they check out, the key it
// presented on that connection is approved, and its next dial is admitted.
// The sign-in connection can do nothing else: the server never builds a
// session on it (QUICServer classifies by ALPN once the handshake is done).

/// What the host does with a viewer key it hasn't approved.
public enum NewViewerPolicy: String, Sendable, CaseIterable {
    /// The viewer signs in with this Mac's account (no dialog here).
    case signIn
    /// This Mac's user is asked, with the verification code.
    case ask
    /// Refused, silently.
    case closed
}

// MARK: - Password check

public protocol PasswordVerifier: Sendable {
    /// Blocking. True iff `user`/`password` are an account allowed to sign in.
    func verify(user: String, password: String) -> Bool
}

#if os(macOS)
/// The account running this process — the one whose screen is shared — and
/// no other. `user` may be its short name or its full name (any case).
/// A name that doesn't match is refused without asking OpenDirectory, so it
/// never counts toward the account's failed-login tally; a wrong password
/// does (`failedLoginCount`), which is why SignInThrottle stays far below
/// any lockout policy.
public struct LocalAccountVerifier: PasswordVerifier {
    public init() {}

    public func verify(user: String, password: String) -> Bool {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty, !name.isEmpty,
              name.caseInsensitiveCompare(NSUserName()) == .orderedSame
                || name.caseInsensitiveCompare(NSFullUserName()) == .orderedSame else { return false }
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}
#endif

// MARK: - Throttle

/// Bounds password guessing. Per address, consecutive failures back off
/// (free, 5 s, 30 s, then 2 min); across all addresses, at most
/// `maxFailuresPerWindow` failures per `windowSeconds`, after which sign-in
/// waits for the window to roll. A success clears its address. Pure; time
/// is passed in.
public struct SignInThrottle: Sendable {
    public static let windowSeconds = 15.0 * 60
    public static let maxFailuresPerWindow = 5
    static let maxTrackedAddresses = 256

    private struct Address {
        var consecutiveFailures = 0
        var lastFailure = 0.0
    }
    private var addresses: [String: Address] = [:]
    private var recentFailures: [Double] = []

    public init() {}

    static func backoff(afterFailures n: Int) -> Double {
        switch n {
        case ..<2: 0
        case 2: 5
        case 3: 30
        default: 120
        }
    }

    /// Seconds until anyone may try again (the shared window is full); nil
    /// when the window has room.
    public mutating func globalRetryAfter(now: Double) -> Double? {
        recentFailures.removeAll { now - $0 >= Self.windowSeconds }
        guard recentFailures.count >= Self.maxFailuresPerWindow, let oldest = recentFailures.first else { return nil }
        let wait = oldest + Self.windowSeconds - now
        return wait > 0 ? wait : nil
    }

    /// Seconds until `address` may try again; nil when it may now.
    public mutating func retryAfter(address: String, now: Double) -> Double? {
        var wait = globalRetryAfter(now: now) ?? 0
        if let a = addresses[address] {
            wait = max(wait, a.lastFailure + Self.backoff(afterFailures: a.consecutiveFailures) - now)
        }
        return wait > 0 ? wait : nil
    }

    public mutating func noteFailure(address: String, now: Double) {
        recentFailures.append(now)
        if addresses[address] == nil, addresses.count >= Self.maxTrackedAddresses,
           let stalest = addresses.min(by: { $0.value.lastFailure < $1.value.lastFailure })?.key {
            addresses[stalest] = nil
        }
        addresses[address, default: Address()].consecutiveFailures += 1
        addresses[address]?.lastFailure = now
    }

    public mutating func noteSuccess(address: String) {
        addresses[address] = nil
    }
}

// MARK: - Host policy

/// The host's answer to each sign-in request. Requests are handled one at a
/// time on the gate's own serial queue (password checks block), so guesses
/// can't run in parallel. The app supplies the policy, what's approved, and
/// how to approve.
public final class SignInGate: @unchecked Sendable {
    public struct Approval: Sendable {
        public let fingerprint: String
        public let device: String
        public let address: String
    }

    public enum Event: Sendable {
        case signedIn(Approval)
        case wrongPassword(address: String)
        /// Sign-in is paused for everyone (too many failures in the window).
        case throttled(retryAfterSeconds: Int)
    }

    private let queue = DispatchQueue(label: "glassact.signin.gate", qos: .userInitiated)
    private let verifier: any PasswordVerifier
    private let policy: @Sendable () -> NewViewerPolicy
    private let isApproved: @Sendable (String) -> Bool
    private let approve: @Sendable (Approval) -> Bool
    private let onEvent: @Sendable (Event) -> Void
    private let now: @Sendable () -> Double
    /// Every wrong answer takes at least this long (slows guessing; hides
    /// whether the name or the password was wrong).
    private let failureDelaySeconds: Double
    private var throttle = SignInThrottle() // queue

    public init(verifier: any PasswordVerifier,
                policy: @escaping @Sendable () -> NewViewerPolicy,
                isApproved: @escaping @Sendable (String) -> Bool,
                approve: @escaping @Sendable (Approval) -> Bool,
                onEvent: @escaping @Sendable (Event) -> Void = { _ in },
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSinceReferenceDate },
                failureDelaySeconds: Double = 1) {
        self.verifier = verifier
        self.policy = policy
        self.isApproved = isApproved
        self.approve = approve
        self.onEvent = onEvent
        self.now = now
        self.failureDelaySeconds = failureDelaySeconds
    }

    /// Any thread; `reply` fires once, on the gate's queue.
    public func handle(_ request: SignInRequest, peer: QUICTransport.PeerCertificate, address: String,
                       reply: @escaping @Sendable (SignInResponse) -> Void) {
        queue.async { [self] in reply(decide(request, peer: peer, address: address)) }
    }

    /// Synchronous form for tests. Blocks on the gate's queue.
    public func answerNow(_ request: SignInRequest, peer: QUICTransport.PeerCertificate,
                       address: String) -> SignInResponse {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { decide(request, peer: peer, address: address) }
    }

    /// `queue` only.
    private func decide(_ request: SignInRequest, peer: QUICTransport.PeerCertificate,
                        address: String) -> SignInResponse {
        let policy = policy()
        // Agents never hold this Mac's password: their keys go to the prompt.
        if peer.isAgent { return SignInResponse(policy == .closed ? .closed : .askOnHost) }
        if isApproved(peer.fingerprint) { return SignInResponse(.approved) }
        switch policy {
        case .ask: return SignInResponse(.askOnHost)
        case .closed: return SignInResponse(.closed)
        case .signIn: break
        }
        guard request.op == .signIn else { return SignInResponse(.signInAvailable) }

        let started = now()
        if let wait = throttle.retryAfter(address: address, now: started) {
            return SignInResponse(.tooManyAttempts, retryAfterSeconds: Self.seconds(wait))
        }
        if verifier.verify(user: request.user, password: request.password) {
            throttle.noteSuccess(address: address)
            let approval = Approval(fingerprint: peer.fingerprint, device: request.device, address: address)
            guard approve(approval) else { return SignInResponse(.closed) }
            onEvent(.signedIn(approval))
            return SignInResponse(.approved)
        }
        throttle.noteFailure(address: address, now: started)
        onEvent(.wrongPassword(address: address))
        if let wait = throttle.globalRetryAfter(now: started) {
            onEvent(.throttled(retryAfterSeconds: Int(Self.seconds(wait))))
        }
        let elapsed = now() - started
        if elapsed < failureDelaySeconds { Thread.sleep(forTimeInterval: failureDelaySeconds - elapsed) }
        return SignInResponse(.wrongCredentials)
    }

    static func seconds(_ wait: Double) -> UInt16 {
        UInt16(min(Double(UInt16.max), max(1, wait.rounded(.up))))
    }
}

// MARK: - Viewer side

/// One sign-in exchange from the viewer: dial `glassact-signin`, check the
/// host's key exactly as a session dial would (pinned, or trust on first
/// use), send the request, read the answer, hang up.
public enum SignInClient {
    public struct Outcome: Sendable {
        /// Nil when no answer came back (unreachable, timed out, the host
        /// refused the key, or the host doesn't offer sign-in).
        public let response: SignInResponse?
        /// The key the host presented, if the handshake got that far.
        public let hostFingerprint: String?
        /// The pin was set and the host presented a different key: nothing
        /// was sent.
        public let hostKeyMismatch: Bool
        public let error: String?
    }

    public static let timeoutSeconds = 15.0

    /// `completion` fires exactly once, on `queue`.
    public static func send(
        _ request: SignInRequest, host: String, port: UInt16, pinnedFingerprint: String,
        identity: SecIdentity?, queue: DispatchQueue = DispatchQueue(label: "glassact.signin.client"),
        timeout: Double = timeoutSeconds, completion: @escaping @Sendable (Outcome) -> Void
    ) {
        Exchange(request: request, host: host, port: port, pin: QUICIdentity.normalize(pinnedFingerprint),
                 identity: identity, queue: queue, completion: completion).start(timeout: timeout)
    }

    private final class ObservedKey: Sendable {
        let value = Mutex<String?>(nil)
    }

    /// One exchange's state. Confined to `queue`; it keeps itself alive
    /// through the connection's handlers until `finish`.
    private final class Exchange: @unchecked Sendable {
        private let request: SignInRequest
        private let pin: String
        private let queue: DispatchQueue
        private let completion: @Sendable (Outcome) -> Void
        private let connection: NWConnection
        private let observed = ObservedKey()
        private var received: [UInt8] = []
        private var finished = false

        init(request: SignInRequest, host: String, port: UInt16, pin: String, identity: SecIdentity?,
             queue: DispatchQueue, completion: @escaping @Sendable (Outcome) -> Void) {
            self.request = request
            self.pin = pin
            self.queue = queue
            self.completion = completion
            let options = QUICTransport.signInOptions()
            let observed = observed
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trustRef, complete in
                let presented = QUICIdentity.leafFingerprint(of: trustRef)
                observed.value.withLock { $0 = presented }
                guard let presented else { return complete(false) }
                complete(pin.isEmpty || presented == pin) // empty pin: trust on first use
            }, queue)
            if let identity, let secIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
            }
            connection = NWConnection(
                to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 4433),
                using: NWParameters(quic: options))
        }

        func start(timeout: Double) {
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.send(content: Data(request.encoded()), contentContext: .finalMessage,
                                    isComplete: true, completion: .contentProcessed { _ in })
                    receive()
                case let .failed(error), let .waiting(error):
                    finish(nil, "\(error)")
                case .cancelled:
                    finish(nil, "cancelled")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(nil, "timed out") }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [self] data, _, isComplete, error in
                if let data { received.append(contentsOf: data) }
                if let response = SignInResponse.parse(received) { return finish(response, nil) }
                if received.count >= SignInResponse.encodedBytes || isComplete || error != nil {
                    return finish(nil, error.map { "\($0)" } ?? "the host's answer was malformed")
                }
                receive()
            }
        }

        private func finish(_ response: SignInResponse?, _ error: String?) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            let presented = observed.value.withLock { $0 }
            completion(Outcome(response: response, hostFingerprint: presented,
                               hostKeyMismatch: !pin.isEmpty && presented != nil && presented != pin,
                               error: error))
        }
    }
}
