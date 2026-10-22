import AppKit
import GlassActTransport
import ScreenCaptureKit
import SwiftUI
import os

/// Menu-bar host app (§9): auto-share the main display, listen, show the cert
/// fingerprint. Thin by design — all engine/wire logic lives in the package.
///
/// The host auto-captures the main display on launch (SCShareableContent) —
/// single-window mode already requires Screen Recording, so there's no reason
/// to make the user pick a display first. "Choose Display…" (SCContentSharing-
/// Picker) is the manual override for choosing a non-main display; there is
/// no multi-monitor selection yet.
///
/// The menu is the whole UI, so it leads with what a person needs: is this
/// Mac shareable right now, how a viewer finds it, and anything blocking it
/// (missing permissions) — with the log-level detail one submenu down.
@main
@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    /// Status paper trail. stdout only exists under Xcode/terminal; os_log
    /// makes `log show --predicate 'subsystem == "app.glassact.host"'` work for
    /// Finder-launched instances too.
    nonisolated static let log = Logger(subsystem: "app.glassact.host", category: "status")

    /// UTC wall clock with ms, the viewer session log's format — so a host
    /// log line can be matched to the viewer's `wall=` by eye or script.
    nonisolated(unsafe) static let wallFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated static func stamp() -> String { wallFormatter.string(from: Date()) }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0) // stream prints when stdout is a pipe
        print("\(stamp()) glassact-host: build \(BuildInfo.stamp)")
        log.notice("build \(BuildInfo.stamp, privacy: .public)")
        let app = NSApplication.shared
        let delegate = HostAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let controller = HostController()
    private let advertiser = NearbyAdvertiser()
    private let header = StatusHeaderView()
    private weak var chooseDisplayItem: NSMenuItem?
    private let permissions = HostPermissions()
    private var setupWindow: NSWindow?
    private var approvalsWindow: NSWindow?
    private var approvalsModel: ApprovedViewersModel?
    private var approvalsTimer: Timer?
    /// Last check's answer — a true → false edge means something got
    /// turned off while running, which reopens setup.
    private var requiredWereGranted = false
    private static let setupDoneKey = "glassact.host.setupDone"
    /// The latest raw status line (Developer submenu; the log has them all).
    private var statusLine = "starting"
    private var identityError: String?
    /// MetricKit crash and hang reports, and the notice after one (§13).
    private var crashReporter: CrashReporter!
    /// Sparkle updates (§13). An update waits while a viewer is connected.
    private var updater: AppUpdater!
    private var crashNoticeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        controller.onStatus = { [weak self] text in
            print("\(Self.stamp()) glassact-host: \(text)") // paper trail in the Xcode console
            Self.log.notice("\(text, privacy: .public)")
            DispatchQueue.main.async { self?.statusLine = text }
        }
        controller.onPhase = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.phaseChanged()
                if self?.controller.phase != .viewerConnected { self?.updater?.relaunchMayProceed() }
            }
        }
        controller.onPermissionProblem = { [weak self] in
            MainActor.assumeIsolated { self?.showSetup(recheck: true) }
        }
        header.onToggle = { [weak self] on in
            MainActor.assumeIsolated { on ? self?.startSharing() : self?.stopSharing() }
        }
        controller.agentAccess.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.controller.agentPolicyChanged()
                self?.phaseChanged()
            }
        }
        crashReporter = CrashReporter(appName: "Glass Act Host", prefix: "host") { [weak self] text in
            self?.controller.onStatus(text)
        }
        crashReporter.onNotice = { [weak self] notice in self?.crashNoticeChanged(notice) }
        crashReporter.start()
        updater = AppUpdater { [weak self] text in self?.controller.onStatus(text) }
        updater.mayRelaunch = { [weak self] in self?.controller.phase != .viewerConnected }
        updater.start()
        permissions.startLocalNetworkCheck()
        requiredWereGranted = permissions.requiredGranted
        // Cheap no-prompt checks; catches a permission switched off in
        // System Settings while the Host runs, instead of failing quietly.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissions() }
        }
        if let error = OpenAtLogin.applyDefault() { controller.onStatus(error) }
        if !UserDefaults.standard.bool(forKey: Self.setupDoneKey) || !permissions.requiredGranted {
            showSetup(recheck: UserDefaults.standard.bool(forKey: Self.setupDoneKey))
        }
        do {
            try controller.loadIdentity()
            controller.startDefaultDisplay() // auto-share the main display
        } catch {
            identityError = error.localizedDescription
            statusLine = "identity error: \(error)"
        }
        phaseChanged()
    }

    func applicationWillTerminate(_ notification: Notification) {
        advertiser.stop()
        controller.stop() // restores a switched display mode (RESIZE)
    }

    // MARK: - Permissions / setup

    private func checkPermissions() {
        controller.checkCaptureHealth()
        _ = controller.agentAccess.scope() // expires the agent time limit on time, not on the next input
        permissions.refresh()
        let capturing = controller.phase == .listening || controller.phase == .viewerConnected
        if capturing {
            permissions.captureNeedsRelaunch = false
        } else if permissions.screenRecording && controller.phase == .needsScreenRecording {
            permissions.captureNeedsRelaunch = true // granted, but only a fresh launch can use it
        }
        let granted = permissions.requiredGranted
        if requiredWereGranted && !granted { showSetup(recheck: true) }
        requiredWereGranted = granted
    }

    private func showSetup(recheck: Bool) {
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = SetupView(permissions: permissions, isRecheck: recheck) { [weak self] in self?.finishSetup() }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Glass Act Host Setup"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        setupWindow = window
    }

    private func finishSetup() {
        setupWindow?.close() // windowWillClose records completion
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === crashNoticeWindow {
            crashNoticeWindow = nil // closed unanswered: the menu keeps it, and so does the next launch
            return
        }
        if let window = notification.object as? NSWindow, window === approvalsWindow {
            approvalsTimer?.invalidate()
            approvalsTimer = nil
            controller.onApprovalsChanged = nil
            approvalsWindow = nil
            approvalsModel = nil
            return
        }
        guard let window = notification.object as? NSWindow, window === setupWindow else { return }
        if permissions.requiredGranted { UserDefaults.standard.set(true, forKey: Self.setupDoneKey) }
        setupWindow = nil
    }

    // MARK: - Crash notice

    /// A small window of its own, in front but without taking focus from
    /// whatever the person is doing; closing it leaves the report waiting
    /// (the menu's first rows offer it until it's answered).
    private func crashNoticeChanged(_ notice: CrashNotice?) {
        guard let notice else {
            crashNoticeWindow?.close()
            return
        }
        let view = CrashNoticeContent(notice: notice,
                                      onReport: { [weak self] in self?.crashReporter.report() },
                                      onDismiss: { [weak self] in self?.crashReporter.dismiss() })
            .padding(.horizontal, 20)
            .padding(.top, 30) // under the transparent title bar
            .padding(.bottom, 18)
            .frame(width: 400)
            .fixedSize(horizontal: false, vertical: true)
        if let window = crashNoticeWindow, let hosting = window.contentViewController as? NSHostingController<AnyView> {
            hosting.rootView = AnyView(view)
            return
        }
        let hosting = NSHostingController(rootView: AnyView(view))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Glass Act Host"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.orderFrontRegardless()
        crashNoticeWindow = window
    }

    @objc private func showCrashNotice() {
        if crashNoticeWindow == nil { crashNoticeChanged(crashReporter.notice) }
        crashNoticeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func showCrashReports() {
        crashReporter.revealReports()
    }

    @objc private func showSetupFromMenu() {
        showSetup(recheck: false)
    }

    /// "Screen recording is off" for the menu row that leads to setup.
    private var missingSummary: String {
        if !permissions.screenRecordingAvailable { return "Screen recording isn’t allowed on this Mac" }
        return switch (permissions.screenRecording || permissions.captureNeedsRelaunch, permissions.accessibility) {
        case (false, false): "Screen recording and device control are off"
        case (false, true): "Screen recording is off — viewers can’t see this screen"
        case (true, false): "Device control is off — viewers can watch but not control"
        case (true, true): "Restart Glass Act Host to start recording"
        }
    }

    // MARK: - State → icon, header, Bonjour

    private func phaseChanged() {
        updateStatusIcon()
        updateAdvertising()
        refreshHeader() // live, if the menu is open
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let (symbol, description): (String, String)
        switch (identityError != nil, controller.phase) {
        case (true, _):
            (symbol, description) = ("rectangle.on.rectangle.slash", "Glass Act Host can’t start")
        case (_, .viewerConnected) where controller.agentAccess.snapshot.agentActive:
            (symbol, description) = ("cursorarrow.rays", "Glass Act Host — an agent is using this Mac")
        case (_, .viewerConnected):
            (symbol, description) = ("rectangle.fill.on.rectangle.fill", "Glass Act Host — sharing this screen")
        case (_, .needsScreenRecording):
            (symbol, description) = ("rectangle.on.rectangle.slash", "Glass Act Host needs Screen Recording")
        case (_, .stopped):
            (symbol, description) = ("rectangle.on.rectangle.slash", "Glass Act Host — sharing is off")
        case (_, .starting), (_, .listening):
            (symbol, description) = ("rectangle.on.rectangle", "Glass Act Host — ready to share")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = controller.phase == .stopped || controller.phase == .starting
        button.toolTip = description
    }

    /// Announce only while a viewer could actually connect.
    private func updateAdvertising() {
        let reachable = controller.phase == .listening || controller.phase == .viewerConnected
        if HostPresence.visibleNearby && reachable {
            advertiser.start(port: HostController.controlPort)
        } else {
            advertiser.stop()
        }
    }

    private func refreshHeader() {
        let tint: NSColor, symbol: String, title: String, subtitle: String
        if let identityError {
            (tint, symbol, title, subtitle) = (.systemRed, "exclamationmark", "Can’t Start", identityError)
        } else {
            switch controller.phase {
            case .starting:
                (tint, symbol, title, subtitle) = (.systemGray, "ellipsis", "Starting…",
                                                   "Getting this screen ready to share")
            case .needsScreenRecording:
                (tint, symbol, title, subtitle) = (.systemOrange, "exclamationmark", "Screen Recording Is Off",
                                                   "Allow Glass Act Host in Privacy & Security")
            case .listening:
                let reach = HostPresence.visibleNearby ? "Viewers nearby can connect to “\(HostPresence.computerName)”"
                                                       : "Viewers can connect to \(HostPresence.localAddress)"
                (tint, symbol, title, subtitle) = (.controlAccentColor, "rectangle.on.rectangle", "Ready to Share", reach)
            case .viewerConnected where controller.agentAccess.snapshot.agentActive:
                let agent = controller.agentAccess.snapshot
                let name = agent.label.isEmpty || agent.label == "agent" ? "An agent" : "“\(agent.label)”"
                if agent.viewOnly {
                    (tint, symbol, title, subtitle) = (.systemPurple, "eye", "An Agent Is Watching",
                                                       "\(name) can see this screen but not control it")
                } else if agent.paused {
                    (tint, symbol, title, subtitle) = (.systemOrange, "pause.fill", "Agent Paused", agent.pauseReason)
                } else {
                    let since = agent.since.map { Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? "just now"
                    (tint, symbol, title, subtitle) = (.systemPurple, "cursorarrow.rays", "An Agent Is Using This Mac",
                                                       "\(name) started \(since) · your mouse and keyboard always win")
                }
            case .viewerConnected:
                let since = controller.viewerConnectedAt.map {
                    Self.relative.localizedString(for: $0, relativeTo: Date())
                } ?? "just now"
                (tint, symbol, title, subtitle) = (.systemGreen, "rectangle.fill.on.rectangle.fill",
                                                   "Sharing This Screen", "A viewer connected \(since)")
            case .stopped:
                (tint, symbol, title, subtitle) = (.systemGray, "pause.fill", "Sharing Is Off",
                                                   "Turn it on to let viewers connect")
            }
        }
        header.update(symbol: symbol, tint: tint, title: title, subtitle: subtitle,
                      sharing: controller.isRunning || controller.phase == .needsScreenRecording,
                      switchEnabled: identityError == nil)
        chooseDisplayItem?.isHidden = controller.isRunning
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshHeader()
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())

        if let notice = crashReporter.notice {
            let hang = notice.summary.kind == .hang
            menu.addItem(item(hang ? "Report Last Hang…" : "Report Last Crash…", symbol: "exclamationmark.bubble",
                              tint: .systemOrange, action: #selector(showCrashNotice), subtitle: notice.title))
            menu.addItem(.separator())
        }

        // Anything blocking sharing comes first, with the way to fix it.
        permissions.refresh()
        if !permissions.requiredGranted || controller.phase == .needsScreenRecording {
            menu.addItem(item("Finish Setting Up…", symbol: "exclamationmark.triangle.fill",
                              tint: .systemOrange, action: #selector(showSetupFromMenu),
                              subtitle: missingSummary))
            menu.addItem(.separator())
        }

        let agent = controller.agentAccess.snapshot
        if agent.agentActive && !agent.viewOnly {
            if agent.paused {
                menu.addItem(item("Resume Agent", symbol: "play.circle", action: #selector(resumeAgent),
                                  subtitle: "Let the agent use the mouse and keyboard again"))
            } else {
                menu.addItem(item("Pause Agent", symbol: "pause.circle", action: #selector(pauseAgent),
                                  subtitle: "It keeps watching; its input waits until you resume"))
            }
            menu.addItem(.separator())
        }

        if identityError == nil {
            menu.addItem(item("Copy Address", symbol: "doc.on.doc", action: #selector(copyAddress),
                              subtitle: HostPresence.localAddress))
            if !controller.fingerprint.isEmpty {
                menu.addItem(item("Copy Host Key", symbol: "key", action: #selector(copyFingerprint),
                                  subtitle: Self.abbreviated(controller.fingerprint)))
            }
            menu.addItem(.separator())
            // Sharing itself is the header's switch. While it's off, pick what
            // to share first (shown or hidden in place as the switch flips).
            let choose = item("Choose Display…", symbol: "display", action: #selector(chooseDisplay),
                              subtitle: "Pick a display, then share it")
            choose.isHidden = controller.isRunning
            chooseDisplayItem = choose
            menu.addItem(choose)
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: "Options"))
        menu.addItem(bandwidthItem())
        let lock = item("Lock Screen When Viewer Leaves", symbol: "lock",
                        action: #selector(toggleLockOnDisconnect))
        lock.state = controller.lockOnDisconnect ? .on : .off
        lock.toolTip = "Locks this Mac \(HostController.lockGraceSeconds) seconds after a viewer drops, "
            + "unless it reconnects"
        menu.addItem(lock)
        let visible = item("Visible to Nearby Viewers", symbol: "dot.radiowaves.left.and.right",
                           action: #selector(toggleVisibleNearby))
        visible.state = HostPresence.visibleNearby ? .on : .off
        visible.toolTip = "Viewers on this network list this Mac by name. "
            + "They still need this Mac’s password or your approval to connect."
        menu.addItem(visible)
        menu.addItem(newViewersItem())
        let login = item("Open at Login", symbol: "power", action: #selector(toggleOpenAtLogin),
                         subtitle: OpenAtLogin.needsApproval ? "Switched off in Login Items" : nil)
        login.state = OpenAtLogin.isEnabled ? .on : .off
        login.toolTip = "Starts Glass Act Host when you log in, so viewers can reach this Mac after a restart"
        menu.addItem(login)
        menu.addItem(agentsItem())
        menu.addItem(item("Permissions…", symbol: "lock.shield", action: #selector(showSetupFromMenu)))
        if controller.authorizedViewers.count > 0 {
            menu.addItem(approvedViewersItem())
        }
        menu.addItem(.separator())

        menu.addItem(developerItem())
        menu.addItem(.separator())
        menu.addItem(item("About Glass Act Host", symbol: nil, action: #selector(showAbout)))
        if updater?.isEnabled == true { menu.addItem(updater.menuItem()) }
        let quit = NSMenuItem(title: "Quit Glass Act Host", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, symbol: String?, tint: NSColor? = nil, action: Selector?,
                      subtitle: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol {
            var image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let tint {
                image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            }
            item.image = image
        }
        item.subtitle = subtitle
        return item
    }

    private func bandwidthItem() -> NSMenuItem {
        let current = controller.bandwidthLimitMbit
        let holder = item("Bandwidth", symbol: "speedometer", action: nil,
                          subtitle: current == 0 ? "Automatic" : "Up to \(current) Mbit/s")
        let sub = NSMenu()
        for mbit in HostController.bandwidthChoicesMbit {
            let choice = NSMenuItem(title: mbit == 0 ? "Automatic" : "Up to \(mbit) Mbit/s",
                                    action: #selector(setBandwidth(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = mbit
            choice.state = current == mbit ? .on : .off
            if mbit == 0 { choice.subtitle = "Follows what the network can carry" }
            sub.addItem(choice)
            if mbit == 0 { sub.addItem(.separator()) }
        }
        holder.submenu = sub
        return holder
    }

    /// Options › New Viewers: how a viewer this Mac hasn't approved gets in.
    private func newViewersItem() -> NSMenuItem {
        let policy = controller.newViewerPolicy
        let failures = controller.failedSignIns
        let summary: String = switch policy {
        case .signIn: failures == 0 ? "Sign in with this Mac’s password"
            : "\(failures) wrong password\(failures == 1 ? "" : "s") · last from \(controller.lastFailedSignInAddress)"
        case .ask: "Ask me each time"
        case .closed: "Not allowed"
        }
        let holder = item("New Viewers", symbol: failures > 0 && policy == .signIn ? "person.badge.shield.exclamationmark"
                                                                                  : "person.badge.plus",
                          action: nil, subtitle: summary)
        let sub = NSMenu()
        let choices: [(NewViewerPolicy, String, String)] = [
            (.signIn, "Sign In with This Mac’s Password",
             "A new viewer enters this Mac’s user name and password. Nothing appears here."),
            (.ask, "Ask Me Each Time", "This Mac shows a dialog with a code to compare."),
            (.closed, "Don’t Allow", "Only viewers you’ve already approved can connect."),
        ]
        for (value, title, explanation) in choices {
            let choice = NSMenuItem(title: title, action: #selector(setNewViewerPolicy(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = value.rawValue
            choice.state = policy == value ? .on : .off
            choice.subtitle = explanation
            sub.addItem(choice)
        }
        sub.addItem(.separator())
        let note = NSMenuItem(title: "Agents always ask, and never get this Mac’s password.", action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
        holder.submenu = sub
        return holder
    }

    @objc private func setNewViewerPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let policy = NewViewerPolicy(rawValue: raw) else { return }
        controller.newViewerPolicy = policy
    }

    /// Options › Approved Viewers…: opens the window that lists them.
    private func approvedViewersItem() -> NSMenuItem {
        let entries = controller.authorizedViewers.all
        let agents = entries.filter { $0.kind == .agent }.count
        let viewers = entries.count - agents
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        let summary = [viewers == 0 ? nil : count(viewers, "viewer", "viewers"),
                       agents == 0 ? nil : count(agents, "agent", "agents")].compactMap { $0 }
        return item("Approved Viewers…", symbol: "person.2", action: #selector(showApprovedViewers),
                    subtitle: summary.joined(separator: " · "))
    }

    @objc private func showApprovedViewers() {
        if let approvalsWindow {
            approvalsModel?.reload()
            approvalsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let model = ApprovedViewersModel(controller: controller)
        let view = ApprovedViewersView(model: model) { [weak self] in self?.approvalsWindow?.close() }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Approved Viewers"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        approvalsWindow = window
        approvalsModel = model
        controller.onApprovalsChanged = { [weak model] in model?.reload() }
        // "Connected now" and the relative times stay current while it's open.
        approvalsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak model] _ in
            MainActor.assumeIsolated { model?.reload() }
        }
    }

    /// Options › Agents: whether agents may take control, for how long, and
    /// the record of what they did.
    private func agentsItem() -> NSMenuItem {
        let access = controller.agentAccess
        let holder = item("Agents", symbol: "cursorarrow.rays", action: nil,
                          subtitle: access.allowControl ? nil : "Watch only")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let allow = item("Allow Agents to Control This Mac", symbol: nil, action: #selector(toggleAgentControl))
        allow.state = access.allowControl ? .on : .off
        allow.toolTip = "Off: approved agents can still see the screen, but their mouse and keyboard input is ignored"
        sub.addItem(allow)
        sub.addItem(.sectionHeader(title: "Time Limit"))
        for minutes in AgentAccess.timeLimitChoices {
            let choice = NSMenuItem(title: minutes == 0 ? "No Limit" : minutes < 60 ? "\(minutes) Minutes"
                                        : minutes == 60 ? "1 Hour" : "\(minutes / 60) Hours",
                                    action: #selector(setAgentTimeLimit(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = minutes
            choice.state = access.timeLimitMinutes == minutes ? .on : .off
            sub.addItem(choice)
        }
        sub.addItem(.separator())
        sub.addItem(item("Show Agent Activity", symbol: "list.bullet.rectangle", action: #selector(showAgentAudit)))
        holder.submenu = sub
        return holder
    }

    /// Traces, recordings and the raw status line: for whoever is tuning
    /// the codec, out of everyone else's way.
    private func developerItem() -> NSMenuItem {
        let holder = item("Developer", symbol: "hammer", action: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        let record = item(controller.isRecording ? "Stop Recording Trace" : "Record Trace",
                          symbol: controller.isRecording ? "stop.circle.fill" : "record.circle",
                          tint: controller.isRecording ? .systemRed : nil, action: #selector(toggleRecording))
        sub.addItem(record)
        sub.addItem(item("Record 30 Seconds", symbol: "timer", action: #selector(timedRecording),
                         subtitle: "Starts in 5 seconds"))
        sub.addItem(item("Show Traces in Finder", symbol: "folder", action: #selector(showTraces)))
        sub.addItem(item("Show Crash Reports in Finder", symbol: "doc.text.magnifyingglass",
                         action: #selector(showCrashReports)))
        sub.addItem(.separator())
        let latest = NSMenuItem(title: String(statusLine.prefix(64)) + (statusLine.count > 64 ? "…" : ""),
                                action: nil, keyEquivalent: "")
        latest.isEnabled = false
        latest.toolTip = statusLine
        sub.addItem(.sectionHeader(title: "Latest Event"))
        sub.addItem(latest)
        holder.submenu = sub
        return holder
    }

    /// "ga1qz8fw3k5… …0d2yhqw4".
    nonisolated static func abbreviated(_ fp: String) -> String {
        QUICIdentity.abbreviatedKeyString(fp)
    }

    // MARK: - Actions

    @objc private func startSharing() {
        // Screen Recording off: sharing can't start — say how to fix it.
        permissions.refresh()
        guard permissions.screenRecording || CGPreflightScreenCaptureAccess() else {
            phaseChanged()
            showSetup(recheck: false)
            return
        }
        controller.startDefaultDisplay()
        phaseChanged()
    }

    @objc private func chooseDisplay() {
        controller.presentPicker()
    }

    @objc private func stopSharing() {
        controller.stop()
        phaseChanged()
    }

    @objc private func toggleRecording() {
        controller.toggleRecording()
    }

    @objc private func timedRecording() {
        controller.timedRecording()
    }

    @objc private func showTraces() {
        let dir = HostController.dataDirectory.appendingPathComponent("traces")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func pauseAgent() {
        controller.pauseAgent()
    }

    @objc private func resumeAgent() {
        controller.resumeAgent()
    }

    @objc private func toggleAgentControl() {
        controller.agentAccess.allowControl.toggle()
        controller.agentAudit.log("agent control switched \(controller.agentAccess.allowControl ? "on" : "off") at this Mac")
    }

    @objc private func setAgentTimeLimit(_ sender: NSMenuItem) {
        controller.agentAccess.timeLimitMinutes = sender.tag
    }

    @objc private func showAgentAudit() {
        let url = controller.agentAudit.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLockOnDisconnect() {
        controller.lockOnDisconnect.toggle()
    }

    @objc private func toggleVisibleNearby() {
        HostPresence.visibleNearby.toggle()
        updateAdvertising()
    }

    @objc private func toggleOpenAtLogin() {
        // Switched off in System Settings: only the user can turn it back on there.
        if OpenAtLogin.needsApproval {
            OpenAtLogin.openLoginItemsSettings()
        } else if let error = OpenAtLogin.set(!OpenAtLogin.isEnabled) {
            controller.onStatus(error)
        } else if OpenAtLogin.needsApproval {
            OpenAtLogin.openLoginItemsSettings()
        }
    }

    @objc private func setBandwidth(_ sender: NSMenuItem) {
        controller.bandwidthLimitMbit = sender.tag
    }

    @objc private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HostPresence.localAddress, forType: .string)
    }

    @objc private func copyFingerprint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(QUICIdentity.keyString(controller.fingerprint), forType: .string)
    }

    @objc private func showAbout() {
        NSApp.activate()
        AboutPanel.show(tagline: "Shares this Mac’s screen with Glass Act Viewer — pixel-exact, over a lossy network.")
    }
}

/// The menu's first row: what the Host is doing, and the switch that turns
/// sharing on and off — the way Wi-Fi and Bluetooth put theirs. The menu
/// stays open while it flips; the row updates in place.
final class StatusHeaderView: NSView {
    private let badge = NSView()
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    /// The person flipped the switch (on = share).
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 62))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 15
        glyph.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        glyph.contentTintColor = .white
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = 182
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(flipped)
        toggle.setAccessibilityLabel("Share This Screen")
        for v in [badge, glyph, titleLabel, subtitleLabel, toggle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(badge)
        badge.addSubview(glyph)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
            glyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.widthAnchor.constraint(equalToConstant: 182),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(symbol: String, tint: NSColor, title: String, subtitle: String,
                sharing: Bool, switchEnabled: Bool) {
        badge.layer?.backgroundColor = tint.cgColor
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.toolTip = subtitle
        toggle.state = sharing ? .on : .off
        toggle.isEnabled = switchEnabled
        toggle.setAccessibilityValueDescription(sharing ? "on" : "off")
        toggle.toolTip = sharing ? "Stop sharing — anyone connected is disconnected" : "Share this screen with viewers"
    }

    @objc private func flipped() {
        onToggle?(toggle.state == .on)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
