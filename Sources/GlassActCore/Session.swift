/// Session lifecycle decisions, clock-driven and app-free so `swift test`
/// covers them (§9: apps are UI + wiring). The apps own the timers, queues
/// and UI; every "is this session dead / what happened / should we redial"
/// question is answered here. All types are plain values confined to the
/// caller's queue (engine queue for the watchdogs, main for the policy).

/// Host side: a viewer that connected but never finished the handshake
/// (vanished, or stuck in geometry negotiation) must not hold the single
/// session slot forever, and a running viewer that stops answering PINGs is
/// gone even if the transport hasn't noticed (measured live: a host
/// streamed video into a torn-down viewer for 30+ s).
public struct HostSessionWatchdog: Sendable {
    public enum Verdict: Equatable, Sendable {
        case ok
        case reset(reason: String)
    }

    public static let handshakeTimeoutUS: UInt64 = 15_000_000
    /// PINGs go out at 1 Hz once running; this much PONG silence is a dead peer.
    public static let pongTimeoutUS: UInt64 = 10_000_000

    private var watched: ObjectIdentifier?
    private var phaseStartUS: UInt64 = 0
    private var runningSinceUS: UInt64 = 0

    public init() {}

    /// Call on every engine tick. A different engine (new session, or an
    /// in-session geometry rebuild) restarts the phase clock.
    public mutating func check(_ engine: HostEngine, nowUS: UInt64) -> Verdict {
        if watched != ObjectIdentifier(engine) {
            watched = ObjectIdentifier(engine)
            phaseStartUS = nowUS
            runningSinceUS = 0
        }
        switch engine.state {
        case .running:
            if runningSinceUS == 0 { runningSinceUS = nowUS }
            let reference = max(engine.lastPongUS, runningSinceUS)
            if nowUS > reference && nowUS - reference > Self.pongTimeoutUS {
                return .reset(reason: "viewer unresponsive (no PONG for \(Self.pongTimeoutUS / 1_000_000) s)")
            }
        case .failed:
            break // the engine's onFailed already ended the session
        default:
            if nowUS > phaseStartUS && nowUS - phaseStartUS > Self.handshakeTimeoutUS {
                return .reset(reason: "viewer never completed the handshake")
            }
        }
        return .ok
    }
}

/// Viewer side: a dial to a host that isn't listening yet sits in
/// "connecting" indefinitely and won't recover even once the host comes up
/// (a fresh dial does); and once connected, a crashed or sleeping host
/// leaves the canvas frozen until QUIC's ~30 s idle timeout unless the
/// viewer notices the silence itself — the host PINGs at 1 Hz even when
/// paused, so any control byte proves life.
public struct ViewerSessionWatchdog: Sendable {
    public enum Verdict: Equatable, Sendable {
        case ok
        case connectTimedOut
        case hostUnresponsive
    }

    public static let connectTimeoutUS: UInt64 = 5_000_000
    public static let livenessTimeoutUS: UInt64 = 10_000_000

    private let dialStartUS: UInt64
    private var readyUS: UInt64 = 0
    private var fired = false

    public init(dialStartUS: UInt64) {
        self.dialStartUS = dialStartUS
    }

    /// The transport reached `.ready`.
    public mutating func transportReady(nowUS: UInt64) {
        readyUS = nowUS
    }

    /// Call on every engine tick; reports each failure once (the caller
    /// cancels the transport, whose terminal state ends the session).
    public mutating func check(_ engine: ViewerEngine, nowUS: UInt64) -> Verdict {
        guard !fired else { return .ok }
        if readyUS == 0 {
            guard nowUS > dialStartUS, nowUS - dialStartUS > Self.connectTimeoutUS else { return .ok }
            fired = true
            return .connectTimedOut
        }
        let reference = max(engine.lastControlRxUS, readyUS)
        guard nowUS > reference, nowUS - reference > Self.livenessTimeoutUS else { return .ok }
        fired = true
        return .hostUnresponsive
    }
}

/// How a viewer session ended, decided once at the transport's terminal
/// state. Only `.lost` should redial.
public enum ViewerSessionEnd: Equatable, Sendable {
    /// The user ended it (stop()): no report, no redial.
    case stopped
    /// A pinned host presented a different key: redialing can't help.
    case hostKeyChanged(expected: String, presented: String)
    /// Anything else — redial within the policy's budget. `hint` explains a
    /// refused first dial: a host that hasn't approved this viewer refuses
    /// the TLS handshake, which looks like any other failed dial.
    case lost(reason: String, hint: String?)

    public static func classify(stopped: Bool, everReady: Bool, pinnedHostFingerprint: String,
                                observedHostFingerprint: String?, failReason: String,
                                verificationCode: String?) -> ViewerSessionEnd {
        if stopped { return .stopped }
        if !everReady, !pinnedHostFingerprint.isEmpty,
           let presented = observedHostFingerprint, presented != pinnedHostFingerprint {
            return .hostKeyChanged(expected: pinnedHostFingerprint, presented: presented)
        }
        var hint: String?
        if !everReady, observedHostFingerprint != nil, let code = verificationCode {
            hint = "new viewer? Allow it on the host if it shows code \(code)"
        }
        return .lost(reason: failReason, hint: hint)
    }
}

/// Bounded automatic redial: a lost session is retried after `delay`, up to
/// `maxAttempts` in a row; a session that got as far as a configured canvas
/// resets the budget.
public struct ReconnectPolicy: Sendable {
    public static let maxAttempts = 20 // ~2 min of retrying (5 s connect timeout + delay)
    public static let delaySeconds = 1.0

    public private(set) var attempts = 0

    public init() {}

    /// Next redial number (1-based), or nil when the budget is spent.
    public mutating func nextAttempt() -> Int? {
        guard attempts < Self.maxAttempts else { return nil }
        attempts += 1
        return attempts
    }

    public mutating func sessionEstablished() { attempts = 0 }
    public mutating func reset() { attempts = 0 }
}
