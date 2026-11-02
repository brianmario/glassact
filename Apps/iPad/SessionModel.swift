import GlassActCore
import GlassActSession
import GlassActTransport
import GlassActWire
import Observation
import Security
import UIKit
import os

/// The iPad Viewer's state: what the connect screen edits, and the session
/// it starts. The connect flow is the Mac Viewer's (§3.9, §13): pin the
/// host's key or trust it on first use; a host that hasn't approved this
/// iPad is asked how new viewers join (sign in with the Mac's account, or
/// its user allows it while both screens show a code); a lost session
/// redials, bounded. Main thread.
@MainActor @Observable
final class SessionModel {
    /// How the host's screen meets this one. Raw values are persisted.
    enum Resolution: Int, CaseIterable, Identifiable {
        case fitToIPad = 0, scaleDown = 1, native = 2
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .fitToIPad: "Fit to iPad"
            case .scaleDown: "Scale Down"
            case .native: "Native"
            }
        }

        var symbol: String {
            switch self {
            case .fitToIPad: "ipad.landscape"
            case .scaleDown: "arrow.down.right.and.arrow.up.left"
            case .native: "1.magnifyingglass"
            }
        }

        var explanation: String {
            switch self {
            case .fitToIPad: "The Mac adds a display shaped like this iPad, so everything is sharp and sized to fit."
            case .scaleDown: "The Mac’s display stays as it is, scaled down to fit this screen."
            case .native: "Every pixel of the Mac’s display. Pinch to zoom in."
            }
        }

        var geometryMode: UInt8 {
            switch self {
            case .fitToIPad: GeometryMode.virtualDisplay
            case .scaleDown: GeometryMode.scale
            case .native: GeometryMode.native
            }
        }
    }

    enum MotionPreference: Int, CaseIterable, Identifiable {
        case balanced = 0, sharpness = 1, smoothness = 2
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .balanced: "Balanced"
            case .sharpness: "Sharp Text"
            case .smoothness: "Smooth Motion"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case connecting
        /// The host is asking its user; both screens show `code`.
        case awaitingApproval(code: String)
        /// The host takes new viewers that sign in with its Mac's account.
        case signingIn
        case reconnecting(attempt: Int)
        /// Connected; the picture shows once it has arrived.
        case loadingPicture
        case inSession

        var isBusy: Bool { self != .idle && self != .inSession }

        var approvalCode: String? {
            if case let .awaitingApproval(code) = self { code } else { nil }
        }
    }

    struct Notice: Equatable {
        enum Kind { case info, problem }
        var kind: Kind
        var title: String
        var text: String
        /// The host's key changed: offer to forget the saved one.
        var offersForgetKey = false
    }

    // MARK: Connect screen

    var host = ""
    var port = "4433"
    var hostKey = ""
    var resolution: Resolution = .fitToIPad { didSet { save() } }
    var motion: MotionPreference = .balanced { didSet { save() } }
    var av1 = false { didSet { save() } }
    var phase: Phase = .idle
    var notice: Notice?
    var connectHint: String?
    private(set) var recents: [String] = []
    let nearby = NearbyHosts()
    /// What the session is called: the nearby Mac's name, else the address.
    private(set) var sessionName = ""

    var signInUser = ""
    var signInPassword = ""
    var signInError: String?
    var signInBusy = false
    var canSignIn: Bool {
        !signInBusy && !signInUser.trimmingCharacters(in: .whitespaces).isEmpty && !signInPassword.isEmpty
    }

    // MARK: Session

    private(set) var controller: ViewerController?
    /// The canvas, once the first picture has arrived.
    private(set) var grid: TileGrid?
    /// Bumped when the canvas is reconfigured in session (a new grid).
    private(set) var gridGeneration = 0
    /// What the host says is wrong with its screen (HOST_NOTICE), if anything.
    private(set) var hostNotice: String?
    /// "4.2 Mbps · 60 fps (HEVC)", refreshed while the session runs.
    private(set) var throughput: String?
    /// The picture's area, in points, and the screen's scale: the geometry
    /// the host is asked for.
    var viewport = CGSize(width: 1180, height: 820)
    var screenScale: CGFloat = 2

    static let log = Logger(subsystem: "app.glassact.viewer", category: "ipad")
    private var identity: SecIdentity?
    private(set) var viewerFingerprint = ""
    private let knownHosts = KnownHosts(url: AppPaths.dataDirectory.appendingPathComponent(IdentityFiles.knownHosts))
    private var dialHost = ""
    private var dialPort: UInt16 = 0
    private var dialPin = ""
    private var trustingOnFirstUse = false
    private var askedHowToJoin = false
    private var signInGeneration = 0
    private var reconnect = ReconnectPolicy()
    private var approvalWaitStarted: Date?
    private static let approvalWaitLimit: TimeInterval = 180
    private var pendingRedial: DispatchWorkItem?
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var throughputTimer: Timer?
    private var requestedGeometry: (mode: UInt8, w: Int, h: Int, scale: Int)?
    /// The app went to the background mid-session and the session ended
    /// there: dial again on the way back.
    private var resumeOnForeground = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static var deviceName: String { UIDevice.current.name }

    init() {
        restore()
        do {
            let (identity, source) = try QUICIdentity.loadForApp(directory: AppPaths.dataDirectory,
                                                                 name: "viewer-identity", commonName: "glassact-viewer")
            self.identity = identity
            viewerFingerprint = try QUICIdentity.fingerprint(of: identity)
            note("viewer key \(QUICIdentity.keyString(viewerFingerprint)) (\(source.description))")
        } catch {
            note("identity error: \(error)")
            notice = .init(kind: .problem, title: "This iPad has no identity",
                           text: "Macs will refuse it. Restart Glass Act and try again.")
        }
        nearby.start()
    }

    /// One log for the app: its header names the first window's size.
    private static var headerWritten = false

    /// The window's first size: the log's header names it as this
    /// device's display.
    func noteScreen(size: CGSize, scale: CGFloat) {
        viewport = size
        screenScale = scale
        guard !Self.headerWritten else { return }
        Self.headerWritten = true
        SessionLog.shared.writeHeader(arguments: CommandLine.arguments,
                                      displays: ["\(Int(size.width))x\(Int(size.height))@\(Int(scale))x"])
        SessionLog.shared.write("identity", "viewer_fp=\(viewerFingerprint)")
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var displayName: String {
        nearby.hosts.first { $0.host == trimmedHost }?.name ?? trimmedHost
    }

    private func note(_ text: String) {
        Self.log.notice("\(text, privacy: .public)")
        SessionLog.shared.text("status", text)
    }

    /// Scriptable runs (the Simulator, demos): `--host H [--port P]
    /// [--fingerprint F] [--resolution fit|scale|native] --connect`.
    func applyLaunchArguments(_ args: [String]) {
        guard !Self.launchArgumentsApplied else { return } // the first window only
        Self.launchArgumentsApplied = true
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let h = value("--host") { host = h }
        if let p = value("--port") { port = p }
        if let f = value("--fingerprint") { hostKey = f }
        switch value("--resolution") {
        case "fit": resolution = .fitToIPad
        case "scale": resolution = .scaleDown
        case "native": resolution = .native
        default: break
        }
        if args.contains("--connect"), phase == .idle { connect() }
    }

    private static var launchArgumentsApplied = false

    // MARK: - Persistence

    private static let defaultsKey = "glassact.ipad.connect"

    private func restore() {
        let d = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:]
        host = d["host"] as? String ?? ""
        port = d["port"] as? String ?? "4433"
        recents = d["recents"] as? [String] ?? []
        resolution = Resolution(rawValue: d["resolution"] as? Int ?? 0) ?? .fitToIPad
        motion = MotionPreference(rawValue: d["motion"] as? Int ?? 0) ?? .balanced
        av1 = d["av1"] as? Bool ?? false
    }

    private func save() {
        UserDefaults.standard.set([
            "host": host, "port": port, "recents": recents,
            "resolution": resolution.rawValue, "motion": motion.rawValue, "av1": av1,
        ], forKey: Self.defaultsKey)
    }

    private func remember(_ address: String) {
        // Other windows may have added theirs since this one loaded.
        if let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey)?["recents"] as? [String] {
            recents = stored
        }
        recents.removeAll { $0 == address }
        recents.insert(address, at: 0)
        if recents.count > 6 { recents.removeLast(recents.count - 6) }
    }

    func forgetRecent(_ address: String) {
        recents.removeAll { $0 == address }
        save()
    }

    func choose(_ nearbyHost: NearbyHost) {
        host = nearbyHost.host
        port = String(nearbyHost.port)
        hostKey = ""
        connect()
    }

    func choose(recent address: String) {
        let parts = address.split(separator: ":", maxSplits: 1)
        host = String(parts.first ?? "")
        port = parts.count > 1 ? String(parts[1]) : "4433"
        hostKey = ""
        connect()
    }

    // MARK: - Connecting

    func connect() {
        guard controller == nil else { return }
        pendingRedial?.cancel()
        pendingRedial = nil
        let host = trimmedHost
        guard !host.isEmpty else { return }
        guard let port = UInt16(port.trimmingCharacters(in: .whitespaces)), port > 0 else {
            notice = .init(kind: .problem, title: "Check the port", text: "Enter a port number from 1 to 65535.")
            return
        }
        let typed = hostKey.trimmingCharacters(in: .whitespaces)
        let fingerprint = typed.isEmpty ? (knownHosts.fingerprint(host: host, port: port) ?? "") : typed
        trustingOnFirstUse = fingerprint.isEmpty
        dialHost = host
        dialPort = port
        dialPin = fingerprint
        sessionName = displayName
        remember(port == 4433 ? host : "\(host):\(port)")
        save()
        notice = nil
        if phase == .idle { phase = .connecting }
        note(trustingOnFirstUse ? "connecting to a new host (trust on first use)…" : "connecting…")

        let controller = ViewerController(host: host, port: port, fingerprint: fingerprint, identity: identity,
                                          av1: av1, deviceName: Self.deviceName)
        controller.pasteboard = IPadPasteboard()
        controller.onStatus = { text in
            Self.log.notice("\(text, privacy: .public)")
            SessionLog.shared.text("status", text)
        }
        controller.onConnectionFailed = { [weak self, weak controller] in
            guard let self, let controller, self.controller === controller else { return }
            self.handleConnectionFailure()
        }
        controller.onHostKeyChanged = { [weak self, weak controller] expected, presented in
            guard let self, let controller, self.controller === controller else { return }
            self.handleHostKeyChanged(expected: expected, presented: presented)
        }
        controller.onHostEndedSession = { [weak self, weak controller] reason in
            guard let self, let controller, self.controller === controller else { return }
            SessionLog.shared.write("ended_by_host", "reason=\"\(reason)\"")
            let name = self.sessionName
            self.endSession()
            self.notice = .init(kind: .info, title: "Session ended", text: "“\(name)” ended the session: \(reason).")
        }
        controller.onIncompatibleHost = { [weak self, weak controller] version in
            guard let self, let controller, self.controller === controller else { return }
            self.handleIncompatibleHost(version)
        }
        controller.onHostNotice = { [weak self, weak controller] code in
            guard let self, let controller, self.controller === controller else { return }
            switch code {
            case HostNotice.sessionOffScreen:
                self.hostNotice = "This Mac switched to another user, so its screen can’t be shared right now."
            case HostNotice.none:
                self.hostNotice = nil
            default:
                break
            }
        }
        controller.onGeometryChanged = { [weak self, weak controller] _, _ in
            guard let self, let controller, self.controller === controller,
                  let grid = controller.configuredGrid() else { return }
            self.grid = grid
            self.gridGeneration += 1
        }
        controller.setQualityPrefs(floor: 0, motionPreference: motion.rawValue)
        self.controller = controller
        controller.start()

        // Handshake geometry: rides HELLO_OK, before any pixels.
        let g = geometryRequest(for: viewport)
        controller.setRequestedGeometry(mode: g.mode, widthPoints: g.w, heightPoints: g.h, scale: g.scale)
        requestedGeometry = g
        startPolling { [weak self] in self?.configurePollFired() }
    }

    private func geometryRequest(for size: CGSize) -> (mode: UInt8, w: Int, h: Int, scale: Int) {
        (resolution.geometryMode, Int(size.width.rounded()), Int(size.height.rounded()), Int(screenScale.rounded()))
    }

    private func startPolling(_ fire: @escaping @MainActor () -> Void) {
        pollTimer?.invalidate()
        pollInFlight = false
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { fire() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInFlight = false
    }

    private func configurePollFired() {
        guard !pollInFlight, let controller else { return }
        pollInFlight = true
        controller.configuredGrid { [weak self] grid in
            guard let self else { return }
            self.pollInFlight = false
            guard grid != nil, self.controller === controller, self.pollTimer != nil else { return }
            self.configured()
        }
    }

    /// The handshake finished: wait for a picture before showing it, so the
    /// screen never sits black.
    private func configured() {
        approvalWaitStarted = nil
        reconnect.sessionEstablished()
        rememberHostKeyIfNew()
        phase = .loadingPicture
        startPolling { [weak self] in self?.picturePollFired() }
    }

    private func picturePollFired() {
        guard !pollInFlight, let controller else { return }
        pollInFlight = true
        controller.hasPicture { [weak self] ready in
            guard let self else { return }
            self.pollInFlight = false
            guard ready, self.controller === controller, self.pollTimer != nil,
                  let grid = controller.configuredGrid() else { return }
            self.stopPolling()
            self.grid = grid
            self.gridGeneration += 1
            self.phase = .inSession
            self.connectHint = nil
            self.holdsAwake = true
            SessionLog.shared.write("presenting", "canvas=\(grid.width)x\(grid.height)")
            self.startThroughput()
        }
    }

    private func startThroughput() {
        throughputTimer?.invalidate()
        throughputTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let controller = self.controller else { return }
                controller.bandwidthSummary { [weak self] line in self?.throughput = line }
            }
        }
    }

    private func rememberHostKeyIfNew() {
        guard trustingOnFirstUse, let presented = controller?.observedHostFingerprint else { return }
        trustingOnFirstUse = false
        do {
            try knownHosts.remember(host: dialHost, port: dialPort, fingerprint: presented)
            note("trusted new host key \(presented) for \(dialHost):\(dialPort)")
        } catch {
            note("couldn't remember the host key: \(error.localizedDescription)")
        }
    }

    /// The picture area settled at a new size (rotation, Split View, Stage
    /// Manager): Fit to iPad and Scale Down follow it.
    func viewportSettled(_ size: CGSize) {
        viewport = size
        guard phase == .inSession, let controller, resolution != .native else { return }
        let g = geometryRequest(for: size)
        if let r = requestedGeometry, r == g { return }
        requestedGeometry = g
        note("resize request: \(g.w)×\(g.h) @\(g.scale)x")
        SessionLog.shared.write("virtual_resize", "size=\(g.w)x\(g.h) scale=\(g.scale)")
        controller.requestResize(mode: g.mode, widthPoints: g.w, heightPoints: g.h, scale: g.scale)
    }

    // MARK: - Ending

    func cancel() {
        note("cancelled")
        endSession()
    }

    func disconnect() {
        guard controller != nil else { return }
        note("disconnected by the user")
        endSession()
    }

    private func endSession() {
        pendingRedial?.cancel(); pendingRedial = nil
        stopPolling()
        throughputTimer?.invalidate(); throughputTimer = nil
        controller?.stop()
        controller = nil
        grid = nil
        hostNotice = nil
        throughput = nil
        reconnect.reset()
        approvalWaitStarted = nil
        askedHowToJoin = false
        signInGeneration += 1
        signInPassword = ""
        signInError = nil
        signInBusy = false
        connectHint = nil
        requestedGeometry = nil
        phase = .idle
        holdsAwake = false
    }

    /// The window went away (closed in the app switcher): so does its session.
    func windowClosed() {
        endBackgroundTask()
        guard controller != nil || phase != .idle else { return }
        note("window closed")
        endSession()
    }

    /// Windows in a session keep the screen awake; the last one out lets it
    /// sleep again.
    private static var awakeHolders = 0
    @ObservationIgnored private var holdsAwake = false {
        didSet {
            guard holdsAwake != oldValue else { return }
            Self.awakeHolders += holdsAwake ? 1 : -1
            UIApplication.shared.isIdleTimerDisabled = Self.awakeHolders > 0
        }
    }

    // MARK: - Failures

    private func handleConnectionFailure() {
        guard let failed = controller else { return }
        let wasInSession = phase == .inSession
        let awaitingApproval = failed.lastFailureAwaitsApproval && !wasInSession
        // A redial can fail before the host's key is seen, without a code;
        // while its user is still deciding, the code is the one shown.
        let code = awaitingApproval ? failed.verificationCode() : phase.approvalCode
        let presentedKey = failed.observedHostFingerprint
        let reason = failed.lastFailureReason
        stopPolling()
        throughputTimer?.invalidate(); throughputTimer = nil
        failed.stop()
        controller = nil
        if !wasInSession, !askedHowToJoin, phase == .connecting {
            askedHowToJoin = true
            askHowToJoin(code: code, presentedKey: presentedKey, reason: reason)
            return
        }
        continueAfterFailure(code: code, wasInSession: wasInSession, reason: reason)
    }

    private func continueAfterFailure(code: String?, wasInSession: Bool, reason: String) {
        if let code {
            let started = approvalWaitStarted ?? Date()
            approvalWaitStarted = started
            if Date().timeIntervalSince(started) > Self.approvalWaitLimit {
                SessionLog.shared.write("gave_up", "reason=approval_timeout")
                let name = sessionName
                endSession()
                notice = .init(kind: .problem, title: "Not allowed yet",
                               text: "“\(name)” didn’t allow this iPad. Connect again, then click Allow on the Mac.")
                return
            }
            reconnect.reset()
            phase = .awaitingApproval(code: code)
        }
        guard let attempt = reconnect.nextAttempt() else {
            SessionLog.shared.write("gave_up", "attempts=\(ReconnectPolicy.maxAttempts)")
            let name = sessionName
            let blocked = nearby.isBlocked
            endSession()
            notice = .init(kind: .problem, title: "Couldn’t reach “\(name)”",
                           text: blocked
                               ? "Glass Act isn’t allowed on the local network. Turn on Local Network for it in Settings › Privacy & Security."
                               : "Check that Glass Act Host is running on that Mac and that both are on the same network.")
            return
        }
        SessionLog.shared.write("reconnect", "attempt=\(attempt) of=\(ReconnectPolicy.maxAttempts)")
        grid = nil
        if code == nil, wasInSession || phase != .connecting {
            phase = .reconnecting(attempt: attempt)
        } else if code == nil, trustingOnFirstUse {
            connectHint = "If this is your first time connecting, “\(sessionName)” may be asking its user to allow this iPad."
        }
        let redial = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
        pendingRedial = redial
        DispatchQueue.main.asyncAfter(deadline: .now() + ReconnectPolicy.delaySeconds, execute: redial)
    }

    private func handleHostKeyChanged(expected: String, presented: String) {
        let remembered = knownHosts.fingerprint(host: dialHost, port: dialPort) == expected
        let name = sessionName
        endSession()
        notice = .init(kind: .problem,
                       title: remembered ? "“\(name)” has a new identity" : "The host key doesn’t match",
                       text: "It presented a different key than \(remembered ? "the one saved from earlier connections" : "the one you entered"). "
                           + "That happens when a Mac’s identity is reset, and it’s also exactly what someone listening in "
                           + "between would look like. Only continue if you know why it changed.",
                       offersForgetKey: remembered)
    }

    func forgetSavedKey() {
        guard let port = UInt16(port.trimmingCharacters(in: .whitespaces)) else { return }
        try? knownHosts.forget(host: trimmedHost, port: port)
        notice = .init(kind: .info, title: "Saved key forgotten",
                       text: "Connect again to trust the Mac’s new key, then check the code it shows matches.")
    }

    private func handleIncompatibleHost(_ hostVersion: UInt8) {
        SessionLog.shared.write("incompatible_host", "host_wire=\(hostVersion) viewer_wire=\(WireVersion.current)")
        let name = sessionName
        endSession()
        let hostNewer = hostVersion > WireVersion.current
        notice = .init(kind: .problem, title: "Different versions",
                       text: hostNewer ? "“\(name)” runs a newer Glass Act. Update this app."
                                       : "“\(name)” runs an older Glass Act Host. Update it from its menu › Check for Updates….")
    }

    // MARK: - Signing in (§3.9)

    private func askHowToJoin(code: String?, presentedKey: String?, reason: String) {
        let generation = signInGeneration
        let pin = dialPin.isEmpty ? (presentedKey ?? "") : dialPin
        note("asking how new viewers join…")
        SignInClient.send(SignInRequest(op: .query, device: Self.deviceName),
                          host: dialHost, port: dialPort, pinnedFingerprint: pin,
                          identity: identity, timeout: 5) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.signInGeneration == generation, self.controller == nil else { return }
                    self.handleHowToJoin(outcome, code: code, pin: pin, reason: reason)
                }
            }
        }
    }

    private var signInPin = ""

    private func handleHowToJoin(_ outcome: SignInClient.Outcome, code: String?, pin: String, reason: String) {
        note("join: \(outcome.response.map { "\($0.status)" } ?? "no answer (\(outcome.error ?? "?"))")")
        if outcome.hostKeyMismatch, let presented = outcome.hostFingerprint {
            return handleHostKeyChanged(expected: pin, presented: presented)
        }
        switch outcome.response?.status {
        case .signInAvailable?:
            signInPin = dialPin.isEmpty ? (outcome.hostFingerprint ?? pin) : dialPin
            signInPassword = ""
            signInError = nil
            phase = .signingIn
        case .approved?:
            continueAfterFailure(code: nil, wasInSession: false, reason: reason)
        case .closed?:
            hostIsClosed()
        case .askOnHost?:
            let hostKey = outcome.hostFingerprint ?? (pin.isEmpty ? nil : pin)
            let askCode = code ?? hostKey.map {
                QUICIdentity.verificationCode(hostFingerprint: $0, viewerFingerprint: viewerFingerprint)
            }
            continueAfterFailure(code: askCode, wasInSession: false, reason: reason)
        default:
            continueAfterFailure(code: code, wasInSession: false, reason: reason)
        }
    }

    func signIn() {
        guard canSignIn else { return }
        let generation = signInGeneration
        let pin = signInPin
        let request = SignInRequest(op: .signIn, user: signInUser.trimmingCharacters(in: .whitespaces),
                                    password: signInPassword, device: Self.deviceName)
        signInPassword = ""
        signInBusy = true
        signInError = nil
        note("signing in…")
        SignInClient.send(request, host: dialHost, port: dialPort, pinnedFingerprint: pin,
                          identity: identity) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.signInGeneration == generation, self.phase == .signingIn else { return }
                    self.handleSignIn(outcome, pin: pin)
                }
            }
        }
    }

    private func handleSignIn(_ outcome: SignInClient.Outcome, pin: String) {
        signInBusy = false
        note("sign in: \(outcome.response.map { "\($0.status)" } ?? "no answer (\(outcome.error ?? "?"))")")
        if outcome.hostKeyMismatch, let presented = outcome.hostFingerprint {
            return handleHostKeyChanged(expected: pin, presented: presented)
        }
        switch outcome.response?.status {
        case .approved?:
            if trustingOnFirstUse, let key = outcome.hostFingerprint {
                try? knownHosts.remember(host: dialHost, port: dialPort, fingerprint: key)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            phase = .connecting
            reconnect.reset()
            connect()
        case .wrongCredentials?:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            signInError = "The name or password is incorrect."
        case .tooManyAttempts?:
            let minutes = max(1, (Int(outcome.response?.retryAfterSeconds ?? 60) + 59) / 60)
            signInError = minutes == 1 ? "Too many attempts. Try again in a minute."
                                       : "Too many attempts. Try again in \(minutes) minutes."
        case .closed?:
            hostIsClosed()
        case .askOnHost?:
            phase = .connecting
            connect()
        default:
            signInError = "Couldn’t reach “\(sessionName)”. Check that it’s still on the network and try again."
        }
    }

    private func hostIsClosed() {
        let name = sessionName
        endSession()
        notice = .init(kind: .problem, title: "Not accepting new viewers",
                       text: "On “\(name)”, choose who can connect in Glass Act Host › Options › New Viewers.")
    }

    // MARK: - App lifecycle

    /// Backgrounded: pause the picture (the Mac stops sending it) and keep
    /// the session for as long as iPadOS lets the app run; past that, leave
    /// cleanly and dial again on return.
    func didEnterBackground() {
        guard let controller else { return }
        controller.windowVisibilityChanged(visible: false)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Glass Act session") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.controller != nil {
                    self.note("background time is up: leaving the session")
                    self.resumeOnForeground = true
                    self.endSession()
                }
                self.endBackgroundTask()
            }
        }
    }

    func willEnterForeground() {
        endBackgroundTask()
        if let controller {
            controller.windowVisibilityChanged(visible: true)
        } else if resumeOnForeground {
            resumeOnForeground = false
            phase = .reconnecting(attempt: 1)
            connect()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Paste to Mac: this iPad's clipboard text becomes the Mac's, ready for ⌘V.
    func sendClipboard(_ text: String) {
        controller?.session.sendClipboard(format: 1, data: Array(text.utf8))
    }

    var verificationCode: String? { controller?.verificationCode() }
}
