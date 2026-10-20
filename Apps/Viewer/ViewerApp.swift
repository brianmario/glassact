import AppKit
import GlassActCore
import GlassActSession
import GlassActTransport
import GlassActWire
import SwiftUI
import os

/// Viewer app (§9): dial the host, render. Thin — engine logic is in the package.
///
/// One connect window does double duty: the form (nearby Macs, address,
/// what to show) and, while a connection is in progress, its live status —
/// connecting, waiting for the host's approval, reconnecting. The session
/// itself gets its own window, titled with the host's name.
@main
@MainActor
final class ViewerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    /// The bundle's version and build number, e.g. "1.0 (202610131845)" —
    /// release.sh stamps the build number with the archive's UTC time. The
    /// About panel shows the same two values by default.
    nonisolated static let buildStamp: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    /// Status paper trail. stdout only exists under Xcode/terminal; os_log
    /// makes `log show --predicate 'subsystem == "app.glassact.viewer"'` work
    /// for Finder-launched instances too.
    nonisolated static let log = Logger(subsystem: "app.glassact.viewer", category: "status")

    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal] = []

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0) // stream prints when stdout is a pipe
        print("glassact-viewer: build \(buildStamp)")
        log.notice("build \(buildStamp, privacy: .public)")
        let app = NSApplication.shared
        let delegate = ViewerAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // `kill` / Ctrl-C quit through NSApp, so the session log still gets
        // its end-of-session summary.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        app.run()
    }

    private let model = ConnectModel()
    /// MetricKit crash and hang reports, and the notice after one (§13).
    private var crashReporter: CrashReporter!
    /// Sparkle updates (§13).
    private var updater: AppUpdater!
    private let settings = ViewerSettings.shared
    private var connectWindow: NSWindow!
    private var settingsWindow: NSWindow?
    private var canvasWindow: NSWindow?
    private var controller: ViewerController?
    private var configurePoll: Timer?
    /// The scheduled automatic redial, cancellable from the connect window.
    private var pendingRedial: DispatchWorkItem?
    /// When this run of approval-wait redials began (nil when not waiting).
    private var approvalWaitStarted: Date?
    private static let approvalWaitLimit: TimeInterval = 180
    /// This viewer's TLS identity (in the keychain; a file in unsigned
    /// builds), presented to hosts; they admit it once their user approves
    /// its key.
    private var viewerIdentity: SecIdentity?
    private var viewerIdentitySource = ""
    private var viewerFingerprint = ""
    /// Remembered host keys (trust on first use, ~/Library/Application Support/Glass Act/known_host_keys).
    private let knownHosts = KnownHosts(
        url: AppPaths.dataDirectory.appendingPathComponent(IdentityFiles.knownHosts))
    private var dialHost = ""
    private var dialPort: UInt16 = 0
    /// The key this dial pinned ("" = trust on first use).
    private var dialPin = ""
    /// This Connect already asked the host how new viewers get in (§3.9);
    /// later redials don't ask again.
    private var askedHowToJoin = false
    /// Bumped by endSession: an answer for an abandoned attempt is dropped.
    private var signInGeneration = 0
    /// What the session window is called: the nearby Mac's name, else the address.
    private var sessionName = ""
    private var trustingOnFirstUse = false
    // Per-canvas-window session state, released in teardownCanvasWindow().
    private var titleTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?

    private var noPause = false
    private var cursorMetadata = true
    private var reconnect = ReconnectPolicy()
    // Single-window mode
    private var singleWindowMode = false
    private var selectedWindowID: UInt32 = 0
    private var selectedWindowTitle = ""
    private var windowPicker: WindowPicker?
    /// The app asked for the host's window list (the picker opens for those
    /// answers only — an agent's list_windows mustn't pop UI at the person).
    private var windowListRequested = false
    // Agents (Settings › Agents): the socket other programs on this Mac use
    // to drive this session, and whether one is driving right now.
    private let agentTarget = AgentTarget()
    private var agentServer: AgentSocketServer?
    private var agentActive = false
    private var agentIdleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let dir = AppPaths.dataDirectory
            let (identity, source) = try QUICIdentity.loadForApp(directory: dir, name: "viewer-identity",
                                                                 commonName: "glassact-viewer")
            viewerIdentity = identity
            viewerIdentitySource = source.description
            viewerFingerprint = try QUICIdentity.fingerprint(of: identity)
            print("glassact-viewer key: \(QUICIdentity.keyString(viewerFingerprint)) (\(source.description))")
        } catch {
            print("glassact-viewer: identity error: \(error)")
        }
        SessionLog.shared.writeHeader(arguments: CommandLine.arguments)
        SessionLog.shared.write("identity", "viewer_fp=\(viewerFingerprint) source=\(viewerIdentitySource)")
        print("glassact-viewer: session log \(SessionLog.shared.url.path)")
        crashReporter = CrashReporter(appName: "Glass Act Viewer", prefix: "viewer") { [weak self] text in
            self?.note(text)
        }
        crashReporter.onNotice = { [weak self] notice in self?.model.crashNotice = notice }
        model.onReportCrash = { [weak self] in self?.crashReporter.report() }
        model.onDismissCrash = { [weak self] in self?.crashReporter.dismiss() }
        crashReporter.start()
        updater = AppUpdater { [weak self] text in self?.note(text) }
        updater.start()
        model.restore()
        model.onConnect = { [weak self] in self?.connect() }
        model.onCancel = { [weak self] in self?.cancelConnecting() }
        model.onSignIn = { [weak self] in self?.signIn() }
        buildMainMenu()
        buildConnectWindow()
        NSApp.activate()
        NotificationCenter.default.addObserver(forName: ViewerSettings.allowAgentsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAgentSharing() }
        }
        updateAgentSharing()
        if viewerFingerprint.isEmpty {
            model.notice = .init(kind: .problem,
                                 text: "This viewer has no identity, so hosts will refuse it. See the session log.")
        }
        // Scriptable demos: --host H --port P --fingerprint F auto-connects.
        let args = CommandLine.arguments
        func value(of flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        noPause = args.contains("--no-pause")
        // Cursor as metadata (§5) is client policy: the metadata cursor
        // (default) wins on pointer latency; --burned-cursor keeps the host
        // drawing it into pixels
        // (exact transient shapes, e.g. drag badges, at frame latency).
        cursorMetadata = !args.contains("--burned-cursor")
        // Quality policy: floor + sharpness preference (presented-scale is
        // automatic). --quality-floor auto|high|medium|low ; --prefer-sharpness
        switch value(of: "--quality-floor") {
        case "auto": settings.qualityFloor = 0
        case "high": settings.qualityFloor = 1
        case "medium": settings.qualityFloor = 2
        case "low": settings.qualityFloor = 3
        default: break
        }
        if args.contains("--prefer-sharpness") { settings.preferSharpness = true }
        // Prefill from args, but only auto-dial when explicitly asked
        // (--auto-connect / --connect) — otherwise wait for the Connect button.
        if let host = value(of: "--host") { model.host = host }
        if let port = value(of: "--port") { model.port = port }
        if let fp = value(of: "--fingerprint") { model.hostKey = fp }
        if args.contains("--auto-connect") || args.contains("--connect") {
            connect()
        }
    }

    /// Clicking the Dock icon with nothing on screen brings back the connect window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showConnectWindow() }
        return true
    }

    /// A status line: the session log and the console, not the UI — the
    /// UI shows phases (ConnectModel), not the protocol's narration.
    private func note(_ text: String) {
        print("glassact-viewer: \(text)")
        SessionLog.shared.text("status", text)
    }

    @objc private func showSessionLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([SessionLog.shared.url])
    }

    @objc private func showCrashReports() {
        crashReporter.revealReports()
    }

    @objc private func openCurrentLog() {
        SessionLog.shared.flush()
        NSWorkspace.shared.open(SessionLog.shared.url)
    }

    /// Help › Send Logs to Host: this launch's log, the crash and hang
    /// reports (§13), and other logs from the last 24 h, over the live
    /// session.
    @objc private func sendLogsToHost() {
        guard let controller else {
            model.notice = .init(kind: .info, text: "Connect to a host first, then send it your logs.")
            showConnectWindow()
            return
        }
        SessionLog.shared.flush()
        let dir = SessionLog.shared.url.deletingLastPathComponent()
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("viewer-") && $0.pathExtension == "log" }
            .compactMap { url -> (URL, Date, Int)? in
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let date = v?.contentModificationDate, date >= cutoff else { return nil }
                return (url, date, v?.fileSize ?? 0)
            }
            .sorted { $0.1 > $1.1 }
        // Crash and hang reports first (newest first, any age: there are at
        // most 20). Their bare names (`viewer-crash-….json`) are valid
        // upload names, so they land beside the logs in the Host's
        // from-viewer folder.
        let reports = crashReporter.store.reports().map { url in
            (url, Date.distantPast, (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        let candidates = reports + files
        // Only what this host doesn't have yet: a file goes again only if it
        // grew since it was sent (the current log always has). Re-sending the
        // whole day each time would cost ~2.7 MB on a tether.
        let hostKey = controller.uploadHostKey
        let sentSizes = Self.uploadedLogs(for: hostKey)
        // ≤ 512 KB per upload, newest first (~30 s at the paced 16 KB/s);
        // anything older still unsent goes on a later upload.
        var picked: [URL] = [], budget = 512 << 10, skipped = 0
        for (url, _, size) in candidates where size <= budget {
            if sentSizes[url.lastPathComponent] == size { skipped += 1; continue }
            picked.append(url)
            budget -= size
        }
        if !picked.contains(SessionLog.shared.url) { picked.insert(SessionLog.shared.url, at: 0) }
        SessionLog.shared.write("log_upload", "files=\(picked.count) already_sent=\(skipped)")
        controller.sendLogs(picked, onFileSent: { name, size in
            MainActor.assumeIsolated { Self.noteUploadedLog(name, size: size, for: hostKey) }
        }) { [weak self] text in
            MainActor.assumeIsolated { self?.note(text) } // delivered on main
        }
    }

    /// Per-host ledger of uploaded logs: file name → size when sent.
    private static let uploadedLogsKey = "glassact.viewer.uploadedLogs"
    private static func uploadedLogs(for host: String) -> [String: Int] {
        let all = UserDefaults.standard.dictionary(forKey: uploadedLogsKey) as? [String: [String: Int]] ?? [:]
        return all[host] ?? [:]
    }
    private static func noteUploadedLog(_ name: String, size: Int, for host: String) {
        var all = UserDefaults.standard.dictionary(forKey: uploadedLogsKey) as? [String: [String: Int]] ?? [:]
        var mine = all[host] ?? [:]
        mine[name] = size
        // Bounded: names older than the 24 h window never match again anyway.
        if mine.count > 200 {
            for key in mine.keys.sorted().prefix(mine.count - 200) { mine[key] = nil }
        }
        all[host] = mine
        UserDefaults.standard.set(all, forKey: uploadedLogsKey)
    }

    @objc private func showConnectWindow() {
        connectWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, viewerFingerprint: viewerFingerprint, knownHosts: knownHosts,
                                    nearby: model.nearby)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func showAbout() {
        AboutPanel.show(tagline: "Shows and controls another Mac’s screen — pixel-exact, over a lossy network.")
    }

    /// The standard menus. Key equivalents are safe while a session has
    /// focus: CanvasView claims every key equivalent first
    /// (performKeyEquivalent) and forwards it to the host, so ⌘C, ⌘Q… act on
    /// the remote Mac; these menus are for the mouse and the other windows.
    private func buildMainMenu() {
        let main = NSMenu()
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = modifiers
            i.target = target
            return i
        }
        let services = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        submenu("Glass Act Viewer", [
            item("About Glass Act Viewer", #selector(showAbout), target: self),
        ] + (updater.isEnabled ? [updater.menuItem()] : []) + [
            .separator(),
            item("Settings…", #selector(showSettings), ",", target: self),
            .separator(),
            servicesItem,
            .separator(),
            item("Hide Glass Act Viewer", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option],
                 target: NSApp),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item("Quit Glass Act Viewer", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
        submenu("Connection", [
            item("Connect…", #selector(showConnectWindow), "k", target: self),
            item("Disconnect", #selector(disconnect), "d", [.command, .shift], target: self),
            item("Stop Agent", #selector(stopAgent), "", target: self),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("View", [
            // Mouse-driven while a session has focus: every key equivalent
            // goes to the host (CanvasView.performKeyEquivalent).
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp),
        ])
        NSApp.windowsMenu = window
        let help = submenu("Help", [
            item("Send Logs to Host", #selector(sendLogsToHost), target: self),
            .separator(),
            item("Open Current Log", #selector(openCurrentLog), target: self),
            item("Show Logs in Finder", #selector(showSessionLogs), target: self),
            item("Show Crash Reports in Finder", #selector(showCrashReports), target: self),
            .separator(),
            item("Copy Viewer ID", #selector(copyViewerFingerprint), target: self),
        ])
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(disconnect), #selector(sendLogsToHost):
            return controller != nil
        case #selector(stopAgent):
            return agentActive
        case #selector(copyViewerFingerprint):
            return !viewerFingerprint.isEmpty
        default:
            return true
        }
    }

    @objc private func copyViewerFingerprint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewerFingerprint, forType: .string)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildConnectWindow() {
        let hosting = NSHostingController(rootView: ConnectView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Connect" // Window menu
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false // ARC owns it; avoid AppKit double-release on close
        window.setContentSize(hosting.view.fittingSize) // its real size, so centering is centered
        window.center()
        window.makeKeyAndOrderFront(nil)
        connectWindow = window
    }

    @objc private func connect() {
        guard controller == nil else { return }
        pendingRedial?.cancel()
        pendingRedial = nil
        let host = model.trimmedHost
        guard !host.isEmpty else { return }
        guard let port = UInt16(model.port.trimmingCharacters(in: .whitespaces)), port > 0 else {
            model.notice = .init(kind: .problem, text: "Enter a port number from 1 to 65535.")
            model.showAdvanced = true
            return
        }
        let typed = model.hostKey.trimmingCharacters(in: .whitespaces)
        // Pin: what the user typed, else the key remembered for this
        // host:port, else trust on first use (remembered once a session
        // actually comes up — see rememberHostKeyIfNew).
        let fingerprint = typed.isEmpty ? (knownHosts.fingerprint(host: host, port: port) ?? "") : typed
        trustingOnFirstUse = fingerprint.isEmpty
        dialHost = host
        dialPort = port
        dialPin = fingerprint
        sessionName = model.displayName
        model.save()
        model.notice = nil
        if model.phase == .idle { model.phase = .connecting }
        note(trustingOnFirstUse ? "connecting to a new host (trust on first use)…" : "connecting…")
        let controller = ViewerController(host: host, port: port, fingerprint: fingerprint,
                                          identity: viewerIdentity, cursorMetadata: cursorMetadata)
        controller.onStatus = { text in
            print("glassact-viewer: \(text)")
            SessionLog.shared.text("status", text)
            Self.log.notice("\(text, privacy: .public)")
        }
        // Identity-checked: a late failure from a controller we already
        // replaced must not tear down the new session.
        controller.onConnectionFailed = { [weak self, weak controller] in
            guard let self, let controller, self.controller === controller else { return }
            self.handleConnectionFailure()
        }
        controller.onHostKeyChanged = { [weak self, weak controller] expected, presented in
            guard let self, let controller, self.controller === controller else { return }
            self.handleHostKeyChanged(expected: expected, presented: presented)
        }
        controller.onWindowList = { [weak self] windows in
            guard let self, self.windowListRequested else { return }
            self.windowListRequested = false
            self.showWindowPicker(windows)
        }
        controller.onHostEndedSession = { [weak self, weak controller] reason in
            guard let self, let controller, self.controller === controller else { return }
            self.handleHostEndedSession(reason)
        }
        controller.onIncompatibleHost = { [weak self, weak controller] version in
            guard let self, let controller, self.controller === controller else { return }
            self.handleIncompatibleHost(version)
        }
        controller.onGeometryChanged = { [weak self] w, h in self?.handleGeometryChanged(w, h) }
        singleWindowMode = model.shareMode == .window
        controller.setQualityPrefs(floor: settings.qualityFloor, preferSharpness: settings.preferSharpness)
        self.controller = controller
        updateAgentSharing() // a new dial gets a new driver; agents keep their socket
        if noPause {
            controller.setPauseEnabled(false)
            print("glassact-viewer: --no-pause — pausing while occluded disabled (demo mode)")
        }
        controller.start()

        // Handshake geometry (set BEFORE start): the request rides HELLO_OK,
        // the host holds pixels until settled — no data at a rejected size.
        // Single-window mode skips this: the canvas is the window's own pixels,
        // so there's no display resolution to negotiate.
        if !singleWindowMode, let screen = NSScreen.main {
            let mode = model.resolution.rawValue + 1 // 1=ClientRes 2=Scale 3=Native 4=Virtual
            let scale = Int(screen.backingScaleFactor)
            // frame, not visibleFrame: display MODES are full-screen sizes.
            var pts = screen.frame.size
            if mode == Int(GeometryMode.virtualDisplay) {
                // A virtual display the size of the session window (it then
                // follows the window — see requestVirtualDisplaySize): the
                // last windowed size on this screen, else most of the screen.
                pts = Self.largestWindowContentSize(on: screen)
            }
            let name = ["", "Client Resolution", "Scale", "Native", "Virtual Display"][mode]
            print("glassact-viewer: geometry request: \(name) \(Int(pts.width))×\(Int(pts.height)) @\(scale)x")
            controller.setRequestedGeometry(mode: UInt8(mode),
                                            widthPoints: Int(pts.width),
                                            heightPoints: Int(pts.height), scale: scale)
        }
        // Main-runloop timers fire on the main thread; the bodies are
        // main-actor methods (assumeIsolated also checks that at runtime).
        configurePoll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurePollFired() }
        }
    }

    private func configurePollFired() {
        guard !configurePollInFlight, let controller else { return }
        configurePollInFlight = true
        controller.configuredGrid { [weak self] grid in
            guard let self else { return }
            self.configurePollInFlight = false
            // A stale answer from a session that has since been replaced.
            guard let grid, self.controller === controller, self.configurePoll != nil else { return }
            self.configured(grid: grid)
        }
    }

    private var configurePollInFlight = false

    private func configured(grid: TileGrid) {
        configurePoll?.invalidate()
        configurePoll = nil
        approvalWaitStarted = nil
        rememberHostKeyIfNew()
        if singleWindowMode && selectedWindowID == 0 {
            // Connected, but no window chosen yet: ask the host for its
            // window list and wait for the picker instead of presenting the
            // (full-display) canvas.
            if controller?.hostSupportsWindowList() == true {
                note("loading window list…")
                model.phase = .choosingWindow
                windowListRequested = true
                controller?.requestWindowList()
            } else {
                note("host can't share a single window (needs Screen Recording) — showing full display")
                singleWindowMode = false
                openCanvasWindow(grid: grid, sharedWindow: false)
            }
        } else {
            // Full display, or reconnecting after a pick → present the window.
            openCanvasWindow(grid: grid, sharedWindow: singleWindowMode)
        }
    }

    /// Trust on first use: the first session with an unpinned host proved
    /// out (both TLS directions + the HELLO), so remember the key it used.
    private func rememberHostKeyIfNew() {
        guard trustingOnFirstUse, let presented = controller?.observedHostFingerprint else { return }
        trustingOnFirstUse = false
        do {
            try knownHosts.remember(host: dialHost, port: dialPort, fingerprint: presented)
            let code = controller?.verificationCode().map { " · code \($0)" } ?? ""
            note("trusted new host key \(presented) for \(dialHost):\(dialPort)\(code)")
        } catch {
            note("couldn't remember the host key: \(error.localizedDescription)")
        }
    }

    /// The host ended the session on purpose (single-window mode: the shared
    /// window closed or its app quit). Back to the connect window — no
    /// redial: there's nothing to reconnect to.
    private func handleHostEndedSession(_ reason: String) {
        SessionLog.shared.write("ended_by_host", "reason=\"\(reason)\"")
        endSession()
        model.notice = .init(kind: .info, text: "“\(sessionName)” ended the session: \(reason).")
    }

    /// The host runs a different build (another wire version): the two
    /// ends must match (until 1.0 the protocol changes between builds), so
    /// redialing can't help. Say which side is behind, and offer to update.
    private func handleIncompatibleHost(_ hostVersion: UInt8) {
        SessionLog.shared.write("incompatible_host", "host_wire=\(hostVersion) viewer_wire=\(WireVersion.current)")
        endSession()
        let hostNewer = hostVersion > WireVersion.current
        let which = hostNewer ? "this Viewer" : "Glass Act Host on “\(sessionName)”"
        model.notice = .init(kind: .problem,
                             text: "Didn’t connect: “\(sessionName)” runs a \(hostNewer ? "newer" : "older") "
                                 + "version of Glass Act. Update \(which).",
                             detail: "host protocol \(hostVersion), this Viewer \(WireVersion.current)")
        let alert = NSAlert()
        alert.messageText = "“\(sessionName)” runs a different version of Glass Act"
        alert.informativeText = "Glass Act Host and Viewer must be the same version. "
            + (hostNewer ? "The Host is newer: update this Viewer."
                         : "This Viewer is newer: update Glass Act Host on “\(sessionName)” (its menu › Check for Updates…).")
        if hostNewer && updater.isEnabled {
            alert.addButton(withTitle: "Check for Updates…")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn { updater.checkForUpdates(nil) }
        } else {
            alert.runModal()
        }
    }

    /// A pinned host presented a different key: never redial into it. Like
    /// SSH, re-trusting is a deliberate act (forget, then connect again).
    private func handleHostKeyChanged(expected: String, presented: String) {
        endSession()
        let remembered = knownHosts.fingerprint(host: dialHost, port: dialPort) == expected
        model.notice = .init(kind: .problem, text: "Didn’t connect: “\(sessionName)” presented a different key.",
                             detail: "expected \(expected), presented \(presented)")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = remembered ? "“\(sessionName)” has a new identity"
                                       : "The host key doesn’t match"
        let source = remembered ? "the one remembered from earlier connections" : "the host key you entered"
        alert.informativeText = """
            \(dialHost) presented a different key than \(source).

            Expected:  \(SettingsView.abbreviated(expected))
            Presented: \(SettingsView.abbreviated(presented))

            This happens when the host’s identity was reset — and it’s also exactly \
            what someone listening in between would look like. Only continue if you \
            know why it changed.
            """
        alert.addButton(withTitle: "Cancel")
        if remembered {
            let forget = alert.addButton(withTitle: "Forget Saved Key")
            forget.hasDestructiveAction = true
        }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        try? knownHosts.forget(host: dialHost, port: dialPort)
        model.notice = .init(kind: .info,
                             text: "Forgot the saved key. Connect again to trust the host’s new key — "
                                + "then check the code it shows matches.")
    }

    /// The user cancelled from the connect window (connecting, waiting for
    /// approval, reconnecting, or choosing a window).
    private func cancelConnecting() {
        note("cancelled")
        endSession()
    }

    /// Connection › Disconnect, or the session window closed.
    @objc private func disconnect() {
        guard controller != nil else { return }
        note("disconnected by the user")
        let name = sessionName
        endSession()
        model.notice = .init(kind: .info, text: "Disconnected from “\(name)”.")
    }

    /// Drop the session (whatever stage it reached) and return to the
    /// connect window, ready for the next Connect.
    private func endSession() {
        pendingRedial?.cancel(); pendingRedial = nil
        configurePoll?.invalidate(); configurePoll = nil
        windowPicker?.close(); windowPicker = nil
        teardownCanvasWindow()
        controller?.agentDriver?.endAgentSession()
        controller?.stop(); controller = nil
        updateAgentSharing()
        reconnect.reset()
        approvalWaitStarted = nil
        askedHowToJoin = false
        signInGeneration += 1
        model.signInPassword = ""
        model.signInError = nil
        model.signInBusy = false
        model.signInHostKey = nil
        model.connectHint = nil
        selectedWindowID = 0 // the next Connect re-picks a window
        singleWindowMode = false
        model.phase = .idle
        showConnectWindow()
    }

    /// The host sent its shareable-window list → show the picker. On pick, tell
    /// the host to swap its capture to that window: the host reconfigures in
    /// place (no reconnect) and re-HELLOs at the window's dimensions, which
    /// arrives as onGeometryChanged and opens the presentation window.
    private func showWindowPicker(_ windows: [WireWindow]) {
        let picker = WindowPicker()
        windowPicker = picker
        picker.show(windows: windows, hostName: sessionName, onPick: { [weak self] id in
            guard let self else { return }
            self.windowPicker = nil
            self.selectedWindowID = id
            self.selectedWindowTitle = windows.first { $0.windowID == id }.map {
                [$0.appName, $0.title].filter { !$0.isEmpty }.joined(separator: " — ")
            } ?? "Shared window"
            self.note("sharing \(self.selectedWindowTitle)…")
            self.model.phase = .connecting
            self.controller?.selectWindow(id)
        }, onCancel: { [weak self] in
            guard let self else { return }
            self.windowPicker = nil
            self.cancelConnecting()
        })
    }

    /// In-session geometry change (§4.10; window pick / resize / fullscreen /
    /// revert): the canvas was reconfigured on the live connection. Open the
    /// presentation window the first time (after a pick, when the picker was
    /// showing and no canvas is up yet); otherwise rebuild its present surfaces
    /// to the new grid in place — no reconnect, no window recreation.
    private func handleGeometryChanged(_ width: Int, _ height: Int) {
        guard let grid = controller?.configuredGrid() else { return }
        note("geometry \(width)×\(height)")
        if canvasWindow == nil {
            openCanvasWindow(grid: grid, sharedWindow: singleWindowMode)
            if singleWindowMode { maybeRequestHostFit(grid: grid) }
        } else {
            rebuildCanvasContent(grid: grid)
        }
    }

    /// If the shared window's native size is larger than the viewer's screen,
    /// ask the host to resize the real window down to fit (preserving
    /// aspect). The host resizes + re-HELLOs, and the content settles crisp at
    /// native pixels instead of pan-scrolling or minifying. Sent once per open;
    /// a window that already fits is left at native (crispest).
    private func maybeRequestHostFit(grid: TileGrid) {
        guard let visible = NSScreen.main?.visibleFrame.size else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let naturalW = CGFloat(grid.width) / scale
        let naturalH = CGFloat(grid.height) / scale
        let maxW = visible.width * 0.9, maxH = visible.height * 0.9
        guard naturalW > maxW || naturalH > maxH else { return } // already fits → keep native
        let fit = min(maxW / naturalW, maxH / naturalH)
        let tw = Int((naturalW * fit).rounded())
        let th = Int((naturalH * fit).rounded())
        note("fitting window to screen (\(tw)×\(th))…")
        controller?.windowControl(action: WindowAction.resize, width: tw, height: th)
    }

    /// Reconfigure the presentation to a new grid IN PLACE, keeping the same
    /// window (and its user-chosen size) and the same CanvasView — the new-dim
    /// canvas fit-scales into it, crisp once the host's native pixels match.
    /// Swapping the contentView here would crash AppKit's window-transform
    /// animation, so we reconfigure the existing view instead.
    private func rebuildCanvasContent(grid: TileGrid) {
        (canvasWindow?.contentView as? CanvasView)?.reconfigure(grid: grid)
    }

    /// A flaky radio should cost seconds, not a manual re-dial: tear the
    /// session down and redial with the same parameters, bounded.
    private func handleConnectionFailure() {
        guard let failed = controller else { return }
        let wasInSession = canvasWindow != nil
        // A host that hasn't approved this viewer refuses the handshake until
        // its user answers; keep redialing (outside the retry budget) while
        // both screens show the code, up to a limit.
        let awaitingApproval = failed.lastFailureAwaitsApproval && !wasInSession
        let code = awaitingApproval ? failed.verificationCode() : nil
        let presentedKey = failed.observedHostFingerprint
        let reason = failed.lastFailureReason
        configurePoll?.invalidate()
        configurePoll = nil
        windowPicker?.close()
        windowPicker = nil
        teardownCanvasWindow()
        failed.stop()
        controller = nil
        // A first dial that never reached a session may be the host refusing
        // a key it hasn't approved — under TLS 1.3 that can look like any
        // dropped connection from here. Ask it (once per Connect) how new
        // viewers get in: a sign-in with its Mac's account, its user's
        // approval, or not at all.
        if !wasInSession, !askedHowToJoin, model.phase == .connecting {
            askedHowToJoin = true
            askHowToJoin(code: code, presentedKey: presentedKey, reason: reason)
            return
        }
        continueAfterFailure(code: code, wasInSession: wasInSession, reason: reason)
    }

    /// Redial (or give up) after a failed dial or a lost session. `code`:
    /// the host's user is deciding whether to approve this viewer.
    private func continueAfterFailure(code: String?, wasInSession: Bool, reason: String) {
        if let code {
            let started = approvalWaitStarted ?? Date()
            approvalWaitStarted = started
            if Date().timeIntervalSince(started) > Self.approvalWaitLimit {
                SessionLog.shared.write("gave_up", "reason=approval_timeout")
                endSession()
                model.notice = .init(kind: .problem,
                                     text: "“\(sessionName)” didn’t approve this viewer. Connect again, "
                                        + "then click Allow on the host.")
                return
            }
            reconnect.reset()
            model.phase = .awaitingApproval(code: code)
        }
        guard let attempt = reconnect.nextAttempt() else {
            SessionLog.shared.write("gave_up", "attempts=\(ReconnectPolicy.maxAttempts)")
            endSession()
            model.notice = .init(kind: .problem,
                                 text: model.nearby.isBlocked
                                    ? "Couldn’t reach “\(sessionName)”. Glass Act Viewer isn’t allowed on the local "
                                        + "network — turn on Local Network for it in Privacy & Security."
                                    : "Couldn’t reach “\(sessionName)”. Check that Glass Act Host is running "
                                        + "there and that both Macs are on the same network.",
                                 detail: reason.isEmpty ? nil : reason)
            return
        }
        print("glassact-viewer: reconnecting (attempt \(attempt)/\(ReconnectPolicy.maxAttempts))…")
        SessionLog.shared.write("reconnect", "attempt=\(attempt) of=\(ReconnectPolicy.maxAttempts)")
        if code == nil, wasInSession || model.phase != .connecting {
            model.phase = .reconnecting(attempt: attempt)
        } else if code == nil, trustingOnFirstUse {
            // A host that hasn't approved this viewer can also just hold the
            // handshake while its user decides.
            model.connectHint = "If this is your first time connecting, “\(sessionName)” may be asking "
                + "its user to allow this viewer."
        }
        showConnectWindow()
        let redial = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
        pendingRedial = redial
        DispatchQueue.main.asyncAfter(deadline: .now() + ReconnectPolicy.delaySeconds, execute: redial)
    }

    // MARK: - Signing in to a host (§3.9)

    /// Ask the host how new viewers get in: sign in (show the form), ask its
    /// user (the code), or not at all. No answer (unreachable, or a host
    /// without sign-in) carries on with the usual redial.
    private func askHowToJoin(code: String?, presentedKey: String?, reason: String) {
        let generation = signInGeneration
        // Pin what this dial pinned; on a first connection, the key the host
        // just presented — so the form talks to the same machine.
        let pin = dialPin.isEmpty ? (presentedKey ?? "") : dialPin
        note("asking how new viewers join…")
        SignInClient.send(SignInRequest(op: .query, device: ViewerSession.computerName),
                          host: dialHost, port: dialPort, pinnedFingerprint: pin,
                          identity: viewerIdentity, timeout: 5) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.signInGeneration == generation, self.controller == nil else { return }
                    self.handleHowToJoin(outcome, code: code, pin: pin, reason: reason)
                }
            }
        }
    }

    private func handleHowToJoin(_ outcome: SignInClient.Outcome, code: String?, pin: String, reason: String) {
        note("join: \(outcome.response.map { "\($0.status)" } ?? "no answer (\(outcome.error ?? "?"))")")
        if outcome.hostKeyMismatch, let presented = outcome.hostFingerprint {
            return handleHostKeyChanged(expected: pin, presented: presented)
        }
        switch outcome.response?.status {
        case .signInAvailable?:
            model.signInHostKey = trustingOnFirstUse ? (outcome.hostFingerprint ?? pin) : nil
            if model.signInUser.isEmpty { model.signInUser = NSUserName() }
            model.signInPassword = ""
            model.signInError = nil
            model.phase = .signingIn
            showConnectWindow()
        case .approved?: // this key is approved: the failure was something else
            continueAfterFailure(code: nil, wasInSession: false, reason: reason)
        case .closed?:
            hostIsClosed()
        case .askOnHost?: // its user decides; both screens show the code
            let hostKey = outcome.hostFingerprint ?? presentedOrPin(pin)
            let askCode = code ?? hostKey.map {
                QUICIdentity.verificationCode(hostFingerprint: $0, viewerFingerprint: viewerFingerprint)
            }
            continueAfterFailure(code: askCode, wasInSession: false, reason: reason)
        default: // no answer: unreachable, or a host without sign-in
            continueAfterFailure(code: code, wasInSession: false, reason: reason)
        }
    }

    private func presentedOrPin(_ pin: String) -> String? { pin.isEmpty ? nil : pin }

    private func signIn() {
        guard model.canSignIn else { return }
        let generation = signInGeneration
        let pin = dialPin.isEmpty ? (model.signInHostKey ?? "") : dialPin
        let request = SignInRequest(op: .signIn, user: model.signInUser.trimmingCharacters(in: .whitespaces),
                                    password: model.signInPassword, device: ViewerSession.computerName)
        model.signInPassword = ""
        model.signInBusy = true
        model.signInError = nil
        note("signing in…")
        SignInClient.send(request, host: dialHost, port: dialPort, pinnedFingerprint: pin,
                          identity: viewerIdentity) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.signInGeneration == generation, self.model.phase == .signingIn else { return }
                    self.handleSignIn(outcome, pin: pin)
                }
            }
        }
    }

    private func handleSignIn(_ outcome: SignInClient.Outcome, pin: String) {
        model.signInBusy = false
        note("sign in: \(outcome.response.map { "\($0.status)" } ?? "no answer (\(outcome.error ?? "?"))")")
        if outcome.hostKeyMismatch, let presented = outcome.hostFingerprint {
            return handleHostKeyChanged(expected: pin, presented: presented)
        }
        switch outcome.response?.status {
        case .approved?:
            // The key the password went to is this host's: remember it now
            // (a first connection would otherwise wait for the session).
            if trustingOnFirstUse, let key = outcome.hostFingerprint {
                try? knownHosts.remember(host: dialHost, port: dialPort, fingerprint: key)
            }
            model.signInHostKey = nil
            model.signInError = nil
            model.phase = .connecting
            reconnect.reset()
            connect()
        case .wrongCredentials?:
            model.signInError = "The name or password is incorrect."
        case .tooManyAttempts?:
            let minutes = max(1, (Int(outcome.response?.retryAfterSeconds ?? 60) + 59) / 60)
            model.signInError = minutes == 1 ? "Too many attempts. Try again in a minute."
                                             : "Too many attempts. Try again in \(minutes) minutes."
        case .closed?:
            hostIsClosed()
        case .askOnHost?:
            // Its user changed the setting meanwhile: dial, and they'll be asked.
            model.phase = .connecting
            connect()
        default:
            model.signInError = "Couldn’t reach “\(sessionName)”. Check that it’s still on the network and try again."
        }
    }

    private func hostIsClosed() {
        endSession()
        model.notice = .init(kind: .problem,
                             text: "“\(sessionName)” isn’t accepting new viewers. On that Mac, choose who can "
                                + "connect in Glass Act Host › Options › New Viewers.")
    }

    /// Drop the presentation window and everything scoped to it (otherwise
    /// the title timer and occlusion observer would pile up across
    /// reconnects and keep polling the old session).
    private func teardownCanvasWindow() {
        titleTimer?.invalidate()
        titleTimer = nil
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        (canvasWindow?.contentView as? CanvasView)?.stopPresenting()
        canvasWindow?.orderOut(nil)
        canvasWindow = nil
    }

    // MARK: - Agents (Settings › Agents)

    /// The driver agents reach through the socket (swapped per dial).
    private final class AgentTarget: @unchecked Sendable {
        private let lock = NSLock()
        private var current: AgentDriver?
        var driver: AgentDriver? { lock.withLock { current } }
        func set(_ driver: AgentDriver?) { lock.withLock { current = driver } }
    }

    /// Serve `viewer.sock` while agents are allowed, pointed at the current
    /// session's driver (none between sessions).
    private func updateAgentSharing() {
        let allowed = settings.allowAgents
        if let controller {
            if allowed, controller.agentDriver == nil {
                agentActiveChanged(false) // a new session starts with no agent driving
                let driver = AgentDriver(session: controller.session, label: "agent")
                let host = sessionName
                driver.statusExtras = { ["host": host, "via": "Glass Act Viewer"] }
                driver.onActiveChanged = { [weak self] active in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.agentActiveChanged(active) } }
                }
                controller.agentDriver = driver
            } else if !allowed, let driver = controller.agentDriver {
                driver.endAgentSession()
                controller.agentDriver = nil
            }
        }
        agentTarget.set(allowed ? controller?.agentDriver : nil)
        if !allowed || controller == nil { agentActiveChanged(false) }
        if allowed, agentServer == nil {
            let target = agentTarget
            let server = AgentSocketServer(path: AgentPaths.viewerSocket) { op, args in
                guard let driver = target.driver else {
                    if op == "status" { return ["connected": false, "via": "Glass Act Viewer", "error": "Glass Act Viewer isn't connected to a host"] }
                    throw AgentDriver.Failure("Glass Act Viewer isn't connected to a host")
                }
                return try driver.perform(op, args)
            }
            do {
                try server.start()
                agentServer = server
                note("agents can use this session (\(AgentPaths.viewerSocket.path))")
            } catch {
                note("agents: \(error)")
            }
            // CLI agents connect per command: an agent quiet for 30 s is done.
            agentIdleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.agentActive, let driver = self.agentTarget.driver,
                          driver.idleUS > 30_000_000 else { return }
                    driver.endAgentSession()
                }
            }
        } else if !allowed, let server = agentServer {
            server.stop()
            agentServer = nil
            agentIdleTimer?.invalidate()
            agentIdleTimer = nil
        }
    }

    private func agentActiveChanged(_ active: Bool) {
        guard agentActive != active else { return }
        agentActive = active
        note(active ? "an agent is using this session" : "the agent stopped")
        if let window = canvasWindow {
            let current = window.subtitle
            window.subtitle = active ? "Agent active · " + current : current.replacingOccurrences(of: "Agent active · ", with: "")
        }
    }

    /// Connection › Stop Agent: end the agent's turn and drop its connections.
    @objc private func stopAgent() {
        agentTarget.driver?.endAgentSession()
        agentServer?.stop()
        agentServer = nil
        agentIdleTimer?.invalidate()
        agentIdleTimer = nil
        agentActiveChanged(false)
        updateAgentSharing()
    }

    /// Quit closes the session cleanly (the host otherwise waits out its
    /// liveness timeout before accepting the next viewer).
    func applicationWillTerminate(_ notification: Notification) {
        controller?.agentDriver?.endAgentSession()
        agentServer?.stop()
        controller?.stop()
        SessionLog.shared.write("quit")
        SessionLog.shared.flush() // the session_end summary must reach disk
    }

    private func openCanvasWindow(grid: TileGrid, sharedWindow: Bool = false) {
        guard let controller else { return }
        teardownCanvasWindow() // never stack a second window's timers/observers
        reconnect.sessionEstablished() // a configured session resets the retry budget
        print("glassact-viewer: HELLO applied — canvas \(grid.width)×\(grid.height), presenting"
              + (sharedWindow ? " (single window)" : ""))
        SessionLog.shared.write("presenting", "canvas=\(grid.width)x\(grid.height) single_window=\(sharedWindow ? 1 : 0)")
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let natural = NSSize(width: CGFloat(grid.width) / scale, height: CGFloat(grid.height) / scale)
        // Native mode = the canvas doesn't fit this screen at 1:1 → pan
        // viewport (1:1, edge-scroll). Otherwise fit-scale the whole canvas.
        let visible = NSScreen.main?.visibleFrame.size ?? natural
        // Windowed mode always fit-scales into the viewer's screen — never pan
        // (pan is for a full display that exceeds the screen at 1:1). We also
        // ask the host to shrink the real window to fit (see maybeRequestHostFit),
        // so the fit-scale is transient and it settles crisp at native pixels.
        var panMode = natural.width > visible.width || natural.height > visible.height
        // Virtual Display: the canvas IS the window's size (1:1), never a
        // pan viewport; the window's size drives the host display's.
        virtualMode = !sharedWindow && model.resolution.rawValue + 1 == Int(GeometryMode.virtualDisplay)
            && controller.hostSupportsVirtualDisplay()
        lastVirtualRequest = virtualMode ? (Int(natural.width.rounded()), Int(natural.height.rounded())) : nil
        if sharedWindow || virtualMode { panMode = false }
        var size = natural
        if virtualMode {
            size = natural // requested to fit this screen; exactly the host display, 1:1
        } else if panMode {
            // Open as a free-aspect viewport filling most of the screen; the
            // pointer pans into the full-resolution pixels near the edges.
            size = NSSize(width: floor(visible.width * 0.9), height: floor(visible.height * 0.9))
        } else if let vis = NSScreen.main?.visibleFrame {
            let fit = min(1, min((vis.width - 40) / natural.width, (vis.height - 40) / natural.height))
            size = NSSize(width: floor(natural.width * fit), height: floor(natural.height * fit))
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; avoid AppKit double-release on close
        if sharedWindow {
            // Present the remote window as a native-feeling local window: its
            // own title, and the traffic-light buttons drive the host window
            // (green → host fullscreen, red → end session, yellow → local
            // minimize + auto-pause). We deliberately do NOT make the viewer
            // window itself fullscreen/zoom — a local window-transform
            // animation over the live present layer crashes AppKit's animation
            // machinery. The host fullscreens; our window fit-scales the result.
            window.title = selectedWindowTitle.isEmpty ? "Shared Window" : selectedWindowTitle
            window.subtitle = sessionName
            window.delegate = self
        } else {
            window.title = sessionName
            window.subtitle = Self.sizeSubtitle(grid, panMode: panMode)
            // Full screen takes over the whole screen (aspect-fit on black;
            // edge to edge with Virtual Display). Pushing the pointer to the
            // very top reveals the menu bar and window controls as usual.
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.delegate = self
        }
        if sharedWindow {
            // Free resize: dragging the frame fit-scales locally, and the
            // committed size drives a host window resize (windowDidEndLiveResize
            // → WINDOW_CONTROL resize) so the host re-captures at native pixels.
            // No aspect/max lock — the host is authoritative over the real size.
            window.contentMinSize = NSSize(width: 160, height: 120)
        } else if virtualMode {
            // Free resize: the committed size becomes the host display's.
            window.contentMinSize = NSSize(width: 320, height: 200)
        } else if panMode {
            window.contentMaxSize = NSSize(width: natural.width, height: natural.height)
        } else {
            window.contentAspectRatio = natural
            window.contentMaxSize = natural // never upscale past 1:1
        }
        window.center()
        let canvas = CanvasView(controller: controller, grid: grid, panMode: panMode)
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.autoresizingMask = [.width, .height]
        if virtualMode {
            canvas.onSizeSettled = { [weak self] _ in self?.scheduleVirtualDisplayResize() }
        }
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas) // keyboard/mouse capture
        window.acceptsMouseMovedEvents = true
        canvas.startPresenting()
        canvasWindow = window
        model.phase = .inSession
        model.noteConnected()
        // Content pauses while the window can't be seen (minimized, hidden,
        // fully covered).
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window,
            queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                self?.controller?.windowVisibilityChanged(
                    visible: window.occlusionState.contains(.visible))
            }
        }
        connectWindow.orderOut(nil)
        // Live subtitle: bandwidth (+ codec) for every session; g2g appended
        // on full-display sessions. The title stays the host's (or the shared
        // window's) name.
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSubtitle(grid: grid, sharedWindow: sharedWindow) }
        }
    }

    private static func sizeSubtitle(_ grid: TileGrid, panMode: Bool) -> String {
        "\(grid.width) × \(grid.height)" + (panMode ? " · move to an edge to pan" : "")
    }

    private func refreshSubtitle(grid: TileGrid, sharedWindow: Bool) {
        guard let window = canvasWindow else { return }
        let base = (agentActive ? "Agent active · " : "") + (sharedWindow ? sessionName : "\(grid.width) × \(grid.height)")
        let g2g = sharedWindow ? nil : controller?.glassToGlassMedianMS().map { String(format: "%.0f ms latency", $0) }
        controller?.bandwidthSummary { [weak window] bw in
            window?.subtitle = ([base] + [bw, g2g].compactMap { $0 }).joined(separator: " · ")
        }
    }

    // MARK: - Window-chrome control (single-window sessions)

    /// Green → drive the HOST window fullscreen and REFUSE the local zoom
    /// (return false). The host reconfigures in-session and re-HELLOs at
    /// fullscreen dims, which fit-scale crisp into our window — no local
    /// window-transform animation (that path crashes AppKit).
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        guard window == canvasWindow, selectedWindowID != 0 else { return true }
        controller?.windowControl(action: WindowAction.fullscreen)
        note("full-screen requested on host…")
        return false
    }

    // MARK: - Full screen (full-display sessions)

    /// The full-screen transition animates the window; presenting into it
    /// mid-animation crashes AppKit (see windowShouldZoom), so presents
    /// pause across the transition. The windowed size limits (≤ 1:1, canvas
    /// aspect) are lifted while full screen — the canvas aspect-fits on
    /// black.
    private var windowedLimits: (max: NSSize, aspect: NSSize)?

    /// Full screen means "I'm using the other Mac": a pointer sweep into a
    /// corner is aimed at the remote screen, so this Mac's hot corners stay
    /// quiet (macOS 27; full screen's auto-hidden Dock satisfies its
    /// precondition).
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = [])
        -> NSApplication.PresentationOptions {
        guard window == canvasWindow else { return proposedOptions }
        var options = proposedOptions
        // Hot corners stay live in full screen before macOS 27, which has no option for them.
        if #available(macOS 27, *) { options.formUnion(.disableScreenCornerInteractions) }
        // AppKit raises on hideDock + autoHideDock together; add one only if neither is set.
        if options.isDisjoint(with: [.hideDock, .autoHideDock]) { options.insert(.autoHideDock) }
        return options
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == canvasWindow else { return }
        inFullScreenTransition = true
        (window.contentView as? CanvasView)?.stopPresenting()
        windowedLimits = (window.contentMaxSize, window.contentAspectRatio)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.resizeIncrements = NSSize(width: 1, height: 1) // clears the aspect lock
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == canvasWindow else { return }
        inFullScreenTransition = false
        (window.contentView as? CanvasView)?.startPresenting()
        SessionLog.shared.write("full_screen", "on=1 size=\(Int(window.frame.width))x\(Int(window.frame.height))")
        scheduleVirtualDisplayResize()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == canvasWindow else { return }
        inFullScreenTransition = true
        (window.contentView as? CanvasView)?.stopPresenting()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == canvasWindow else { return }
        if let limits = windowedLimits {
            window.contentMaxSize = limits.max
            if limits.aspect.width > 0 { window.contentAspectRatio = limits.aspect }
            windowedLimits = nil
        }
        inFullScreenTransition = false
        (window.contentView as? CanvasView)?.startPresenting()
        SessionLog.shared.write("full_screen", "on=0")
        scheduleVirtualDisplayResize()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard window == canvasWindow else { return }
        inFullScreenTransition = false
        (window.contentView as? CanvasView)?.startPresenting()
    }

    // MARK: - Virtual Display follows the window

    /// The session uses a host virtual display sized to this window.
    private var virtualMode = false
    /// The last size (points) asked of the host.
    private var lastVirtualRequest: (Int, Int)?
    private var virtualResizeWork: DispatchWorkItem?
    private var inFullScreenTransition = false

    /// Once the window's size has settled (end of a drag, full screen in or
    /// out), ask the host for a virtual display that size. Until it arrives
    /// the old picture fit-scales; then it's 1:1 again.
    private func scheduleVirtualDisplayResize() {
        guard virtualMode else { return }
        virtualResizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.requestVirtualDisplaySize() }
        }
        virtualResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func requestVirtualDisplaySize() {
        guard virtualMode, !inFullScreenTransition, let window = canvasWindow,
              let size = window.contentView?.bounds.size, let screen = window.screen else { return }
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let fullScreen = window.styleMask.contains(.fullScreen)
        if let last = lastVirtualRequest, last == (w, h) { return }
        lastVirtualRequest = (w, h)
        let scale = Int(screen.backingScaleFactor)
        let f = window.frame, v = screen.visibleFrame
        SessionLog.shared.write("virtual_resize", "size=\(w)x\(h) scale=\(scale) full_screen=\(fullScreen ? 1 : 0)"
            + " window=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))"
            + " visible=\(Int(v.minX)),\(Int(v.minY)),\(Int(v.width))x\(Int(v.height))")
        controller?.requestResize(mode: GeometryMode.virtualDisplay, widthPoints: w, heightPoints: h, scale: scale)
    }

    /// Like Client Resolution's window: the largest session window that
    /// fits this screen's usable area under its title bar (a small margin
    /// all round, as the Client Resolution window has).
    static func largestWindowContentSize(on screen: NSScreen) -> NSSize {
        let vis = screen.visibleFrame
        let frame = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable])
        let chromeH = frame.height - 100
        return NSSize(width: (vis.width - 20).rounded(.down), height: (vis.height - chromeH - 20).rounded(.down))
    }

    /// Closing the session window ends the session and returns to the
    /// connect window (whose own close quits the app).
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == canvasWindow else { return }
        disconnect()
    }

    /// Red → tell the host to stop single-window capture (revert to display),
    /// then let the window close (which ends the session).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == canvasWindow, selectedWindowID != 0 {
            controller?.windowControl(action: WindowAction.endSession)
        }
        return true
    }

    /// Resize-drag ended → commit the host window to the new size (points).
    /// During the drag the canvas just fit-scales locally (instant); on release
    /// the host re-captures at native pixels and re-HELLOs, and the content
    /// snaps crisp — one round-trip per drag, not per mouse-move.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == canvasWindow else { return }
        guard selectedWindowID != 0 else { return }
        let size = window.contentView?.frame.size ?? window.frame.size
        controller?.windowControl(action: WindowAction.resize,
                                  width: Int(size.width.rounded()),
                                  height: Int(size.height.rounded()))
    }
}
