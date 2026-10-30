// The local agent socket, the MCP server and the headless daemon are the
// Mac's: an iPad has no other processes to drive a session from.
#if os(macOS)
import Foundation
import GlassActCore
import GlassActTransport
import GlassActWire
import Security

/// A headless agent session: dial a host with the agent's own identity,
/// wait (redialing) while the host's user approves it, keep the connection
/// up, and serve the agent socket. One per `glassact connect`; runs on main.
///
/// The host learns it's an agent from the certificate's common name
/// ("glassact-agent") before it asks its user, and from AGENT_STATE after.
@MainActor
public final class HeadlessAgent {
    public struct Config: Sendable {
        public var host: String
        public var port: UInt16 = 4433
        /// Pinned host key; empty = the remembered one, else trust on first use.
        public var fingerprint = ""
        public var label = "agent"
        /// Ask the host for a virtual display of this many points (the
        /// agent's coordinates then equal the host's points). Nil = native.
        public var size: (width: Int, height: Int)?
        /// Longest edge of the agent's coordinate space when `size` is nil.
        public var maxEdge = 1568
        /// Give up waiting for the host's user to approve after this long.
        public var approvalTimeout: Double = 300

        public init(host: String) { self.host = host }
    }

    public enum Phase: Equatable, Sendable {
        case dialing
        case awaitingApproval(code: String)
        case connected
        case failed(String)
    }

    public let config: Config
    public private(set) var phase: Phase = .dialing
    /// Status lines (main).
    public var onStatus: (String) -> Void = { print($0) }
    /// The session ended for good (failed or stopped) — the daemon exits.
    public var onFinished: ((String) -> Void)?

    private let identity: SecIdentity
    private let knownHosts: KnownHosts
    private var session: ViewerSession?
    private var driver: AgentDriver?
    private var reconnect = ReconnectPolicy()
    private var approvalStarted: Date?
    private var pinned = ""
    private var stopped = false
    private var pollTimer: Timer?
    private let driverBox = DriverBox()

    public init(config: Config) throws {
        self.config = config
        identity = try QUICIdentity.loadOrCreate(directory: AgentPaths.dataDirectory,
                                                 name: AgentPaths.agentIdentityName,
                                                 commonName: AgentPaths.agentCommonName)
        knownHosts = KnownHosts(url: AgentPaths.dataDirectory.appendingPathComponent(IdentityFiles.knownHosts))
        pinned = config.fingerprint.isEmpty
            ? (knownHosts.fingerprint(host: config.host, port: config.port) ?? "")
            : QUICIdentity.normalize(config.fingerprint)
    }

    /// This agent's own key (what the host's user approves).
    public var agentFingerprint: String { (try? QUICIdentity.fingerprint(of: identity)) ?? "" }

    /// The socket handler: forwards to the live session's driver. Any thread.
    public nonisolated var handler: AgentSocketServer.Handler {
        let box = driverBox
        return { op, args in
            guard let driver = box.driver else {
                if op == "status" { return box.idleStatus() }
                throw AgentDriver.Failure("not connected — \(box.waitingFor())")
            }
            return try driver.perform(op, args)
        }
    }

    public func start() {
        dial()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop(_ reason: String = "stopped") {
        guard !stopped else { return }
        stopped = true
        pollTimer?.invalidate()
        driver?.endAgentSession()
        session?.stop()
        driverBox.set(nil, phase: .failed(reason))
        onFinished?(reason)
    }

    private func dial() {
        guard !stopped else { return }
        let session = ViewerSession(host: config.host, port: config.port, fingerprint: pinned, identity: identity,
                                    options: .init(cursorMetadata: false, video: false))
        let driver = AgentDriver(session: session, label: config.label)
        driver.maxEdge = config.size.map { max($0.width, $0.height) } ?? config.maxEdge
        let target = "\(config.host):\(config.port)"
        let fingerprint = agentFingerprint
        driver.statusExtras = { [box = driverBox] in
            var out: [String: Any] = ["host": target, "agent_key": QUICIdentity.keyString(fingerprint)]
            out.merge(box.phaseFields()) { $1 }
            return out
        }
        session.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.onStatus(text) }
        }
        session.onClipboard = { [weak driver] format, data in driver?.noteHostClipboard(format: format, data: data) }
        session.onWindowList = { [weak driver] windows in driver?.noteWindowList(windows) }
        session.onConnectionFailed = { [weak self] in self?.connectionFailed() }
        session.onHostKeyChanged = { [weak self] expected, presented in
            self?.onStatus("the host's key changed (expected \(expected.prefix(16))…, got \(presented.prefix(16))…) — "
                           + "refusing to connect. If that's expected, forget it: glassact forget \(target)")
            self?.stop("host key changed")
        }
        session.onIncompatibleHost = { [weak self] version in
            let hostNewer = version > WireVersion.current
            self?.onStatus("the host runs a different Glass Act version (protocol \(version), this glassact "
                           + "\(WireVersion.current)) — update \(hostNewer ? "glassact" : "Glass Act Host"); "
                           + "these versions are too far apart to work together")
            self?.stop("incompatible host version")
        }
        session.onHostEndedSession = { [weak self] reason in
            self?.onStatus("the host ended the session: \(reason)")
            self?.stop(reason)
        }
        if let size = config.size {
            session.setRequestedGeometry(mode: GeometryMode.virtualDisplay, widthPoints: size.width,
                                         heightPoints: size.height, scale: 2)
        }
        self.session = session
        self.driver = driver
        driverBox.set(nil, phase: phase)
        session.start()
    }

    private func poll() {
        guard !stopped, let session, let driver else { return }
        let running = session.queue.sync { session.engine.state == .running && session.engine.grid != nil }
        if running, phase != .connected {
            phase = .connected
            reconnect.sessionEstablished()
            approvalStarted = nil
            driverBox.set(driver, phase: phase)
            if pinned.isEmpty, let presented = session.observedHostFingerprint {
                try? knownHosts.remember(host: config.host, port: config.port, fingerprint: presented)
                pinned = QUICIdentity.normalize(presented)
                onStatus("remembered the host's key \(presented.prefix(16))…")
            }
            driver.activate()
            onStatus("connected to \(config.host) — agent ready")
        }
    }

    private func connectionFailed() {
        guard !stopped, let session else { return }
        driver?.endAgentSession()
        driverBox.set(nil, phase: phase)
        let awaiting = session.lastFailureAwaitsApproval
        if awaiting, let code = session.verificationCode() {
            if approvalStarted == nil {
                approvalStarted = Date()
                onStatus("waiting for approval on \(config.host): its user should see the code \(code)")
            }
            phase = .awaitingApproval(code: code)
            driverBox.set(nil, phase: phase)
            if Date().timeIntervalSince(approvalStarted!) > config.approvalTimeout {
                stop("not approved within \(Int(config.approvalTimeout)) s")
                return
            }
            redial(after: 2)
            return
        }
        if phase == .connected { reconnect.reset() }
        phase = .dialing
        driverBox.set(nil, phase: phase)
        guard let attempt = reconnect.nextAttempt() else {
            stop("couldn't reach \(config.host): \(session.lastFailureReason)")
            return
        }
        onStatus("reconnecting (attempt \(attempt))…")
        redial(after: ReconnectPolicy.delaySeconds)
    }

    private func redial(after seconds: Double) {
        session = nil
        driver = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.dial() }
        }
    }

    /// The live driver and dial phase, readable from socket threads.
    private final class DriverBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: AgentDriver?
        private var phase: Phase = .dialing

        var driver: AgentDriver? { lock.withLock { current } }

        func set(_ driver: AgentDriver?, phase: Phase) {
            lock.withLock { current = driver; self.phase = phase }
        }

        func phaseFields() -> [String: Any] {
            switch lock.withLock({ phase }) {
            case .dialing: ["phase": "dialing"]
            case let .awaitingApproval(code): ["phase": "awaiting_approval", "verification_code": code,
                                                "waiting_for": "approval on the host (code \(code))"]
            case .connected: ["phase": "connected"]
            case let .failed(reason): ["phase": "failed", "error": reason]
            }
        }

        func waitingFor() -> String {
            (phaseFields()["waiting_for"] as? String) ?? (phaseFields()["error"] as? String) ?? "dialing the host"
        }

        func idleStatus() -> [String: Any] {
            var out = phaseFields()
            out["connected"] = false
            return out
        }
    }
}
#endif
