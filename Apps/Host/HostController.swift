import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import ImageIO
import IOKit.pwr_mgt
import ScreenCaptureKit
import UniformTypeIdentifiers
import GlassActCore
import GlassActShare
import GlassActTransport
import GlassActWire
import os

/// Transfer box for framework objects (SCContentFilter, SCWindow, AXUIElement…)
/// that are immutable-in-practice but not marked Sendable, so explicit queue
/// hops compile under Swift 6 strict concurrency.
struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Wires capture (`ScreenCapture`) → HostEngine → QUICServer, plus the §7
/// recorder flag.
///
/// Concurrency (§8): queue-confined, not actor-isolated. State is confined to
/// the main thread or `encodeQueue` as documented per property; hops are explicit `DispatchQueue.async`. `@unchecked Sendable`
/// so those hops (and SCK/Network callbacks) compile under Swift 6 strict
/// concurrency without introducing actors into the pixel path.
final class HostController: NSObject, SCContentSharingPickerObserver,
                            @unchecked Sendable {
    static let controlPort: UInt16 = 4433

    /// Pinned full-screen video is simply how the host works.
    /// GLASSACT_TILE_ONLY=1 is a debug-only escape hatch for A/B measuring
    /// against the tile path — not a user-facing mode: no encoder factory,
    /// so no video caps are offered and the session is tiles only.
    static var videoEnabled: Bool {
        ProcessInfo.processInfo.environment["GLASSACT_TILE_ONLY"] == nil
    }

    var onStatus: (String) -> Void = { _ in }

    /// What the menu bar shows: a summary of the session, not the log.
    enum Phase: Equatable {
        case starting, needsScreenRecording, listening, viewerConnected, stopped
    }
    /// Main thread; fires on change only.
    var onPhase: (Phase) -> Void = { _ in }
    /// Main thread.
    private(set) var phase: Phase = .starting {
        didSet { if phase != oldValue { onPhase(phase) } }
    }
    /// Main thread: a permission this session needs is missing (input
    /// without Accessibility, capture revoked) — the app shows setup.
    var onPermissionProblem: () -> Void = {}
    /// Main thread: when the current viewer's transport came up.
    private(set) var viewerConnectedAt: Date?
    private(set) var fingerprint = ""
    private(set) var isRunning = false
    private(set) var isRecording = false

    private let encodeQueue = DispatchQueue(label: "glassact.host.encode", qos: .userInteractive)
    private let slot = LatestFrameSlot()
    /// Main thread. Capture and its recovery (§4.1); frames land in `slot`
    /// and are drained on `encodeQueue`.
    private lazy var capture: ScreenCapture<ScreenCaptureKitBackend> = {
        let capture = ScreenCapture(backend: ScreenCaptureKitBackend(), frames: slot, onFrame: { [weak self] in
            self?.encodeQueue.async { [weak self] in self?.drain() }
        })
        capture.onStatus = { [weak self] in self?.onStatus($0) }
        capture.onEvent = { [weak self] in self?.captureEvent($0) }
        capture.target = { [weak self] in
            guard let self else { return .display(CGMainDisplayID()) }
            return self.singleWindowID != 0 ? .window(self.singleWindowID)
                : .display(self.virtualDisplay?.displayID ?? self.physicalDisplay)
        }
        return capture
    }()
    private var identity: SecIdentity?
    // Session lifecycle (main-thread): the server, the active transport, and
    // its tick timer are created, replaced, and torn down only on main;
    // transport callbacks hop here and are identity-checked, so a late
    // callback from a superseded transport can't touch the live session.
    private var server: QUICServer?
    private var transport: QUICTransport?
    private var tickTimer: DispatchSourceTimer?
    private var engine: HostEngine? // encodeQueue-confined
    /// encodeQueue-confined mirror of the transport the engine talks to (for
    /// in-session engine rebuilds, which run on encodeQueue).
    private var sessionTransport: QUICTransport?
    /// encodeQueue: a server bootstrap hop is outstanding / done.
    private var serverRequested = false
    private var pixelScale: CGFloat = 1
    private var contentOrigin: CGPoint = .zero
    /// main-thread: the physical display a full-display capture shows, set
    /// when capture starts on it (0: not known yet). Geometry follows this
    /// display, not whichever one is main: someone at the Mac can make
    /// another display main mid-share.
    private var sharedDisplayID: CGDirectDisplayID = 0
    /// The viewer's last "Scale" request, to re-fit the capture when the
    /// display changes shape under it (main-thread).
    private var lastScaleRequest: (widthPoints: Int, heightPoints: Int, scale: Int)?
    private var displayReconcilePending = false
    // RESIZE support (§3.5): the viewer picks a
    // geometry policy — "Client Resolution" switches the HOST DISPLAY
    // (personal/unattended hosts), "Scale" downsamples the capture.
    private var lastFilter: SCContentFilter?
    private var captureWidth = 0
    private var captureHeight = 0
    private var originalDisplayMode: CGDisplayMode?
    /// The mode (points) the host switched the display to for a viewer, if
    /// any — checked before a HELLO claims the geometry is final.
    private var appliedDisplaySize: (width: Int, height: Int)?
    /// The mode behind `appliedDisplaySize`, for re-applying it (main-thread).
    private var appliedDisplayMode: CGDisplayMode?
    /// Re-applies of the viewer's mode after macOS moved the display off it
    /// (main-thread), rate-limited so the host never fights the system in a loop.
    private var displayReapplies: [Date] = []
    private var displayReapplyPending = false
    private var geometrySettled = false // one handshake geometry cycle per arm
    private var captureModified = false // display switched OR capture downscaled — restore on disconnect
    private var mouseButtonsDown = 0 // bitmask (bit 0 L, 1 R, 2 other) — drag vs move
    /// The held press's click count: a double-click-drag selects by word.
    private var heldClickState: Int64 = 1
    private var warnedNoAccessibility = false
    private var loggedFirstInject = false // one-time "input works" log line
    // Single-window mode (main-thread). The viewer drives the pick: it asks
    // for the list (windowSelect 0), the host enumerates via SCShareableContent
    // (needs Screen Recording), the viewer picks (windowSelect id), and the host
    // swaps its capture filter to that one window — the pinned-video path is
    // unchanged. `savedDisplayFilter` restores full-display on endSession.
    private var enumeratedWindows: [SCWindow] = []
    private var savedDisplayFilter: SCContentFilter?
    private var singleWindowID: UInt32 = 0 // 0 = full display
    // The shared window's AX element + its original frame, snapshotted at pick
    // BEFORE any resize, so we drive it reliably and restore it on disconnect
    // (like the display-resolution restore). Frame-matching a stale
    // SCWindow.frame after resizes would misfire, hence the cached element.
    private var sharedAXWindow: AXUIElement?
    private var originalWindowFrame: CGRect?
    // Clipboard sync
    private var clipboardTimer: Timer?
    private var lastClipboardHash = 0
    private var clipboardChangeCount = -1
    private var pendingDisplayRestore: DispatchWorkItem? // main-thread
    /// main-thread: the viewer asked for a virtual display at its size
    /// (geoMode 4); the physical displays mirror it while it exists.
    private var virtualDisplay: VirtualDisplay?
    /// main-thread: the physical display's capture filter, for teardown.
    private var physicalFilter: SCContentFilter?
    /// Lock-on-disconnect timer (main thread), and whether a viewer transport
    /// is up right now.
    private var pendingLock: DispatchWorkItem?
    private var viewerSessionLive = false
    /// main-thread: the screen was locked when the current run of viewer
    /// sessions began. Lock When Viewer Leaves only puts back a lock that
    /// was there: a Mac someone left unlocked stays unlocked. A reconnect
    /// within the lock grace keeps the first session's answer (the remote
    /// user has unlocked it since).
    private var lockedWhenViewerArrived = false
    // Auto-scale (airplane story, main-thread): sustained severe link
    // pressure halves the capture for the rest of the session; native
    // restores on disconnect (via the captureModified restore path) or on
    // stop — never mid-session.
    private var autoScaledDown = false
    private var recordingArmed = false // encodeQueue-confined
    // Video telemetry snapshot (encodeQueue-confined): transition lines fire
    // the moment a region forms or dissolves; rates ride the 2 s heartbeat.
    private var telePrevStats = HostStats()
    private var telePrevUS: UInt64 = 0
    /// The engine `telePrevStats` came from: a new session's engine starts
    /// its counters at 0, and diffing against the old one's would print
    /// negative rates (`bw -5675 Kbps · tiles -16974`).
    private var telePrevEngine: ObjectIdentifier?
    /// Where the screen changes (SCK dirty rects), per status interval —
    /// names what keeps an "idle" session sending. encodeQueue only.
    private var changeHotspots = ChangeHotspots()
    private var recorder: ScapWriter?
    private var recordName = ""
    private var recordTight: UnsafeMutableRawBufferPointer?
    private var frameCount = 0 // encodeQueue-confined
    // Static-screen drain (encodeQueue-confined): SCK stops delivering frames
    // the moment the host screen goes quiet, but governor-deferred tiles,
    // post-dissolve repaints, and open batches only make progress on encode
    // ticks — without them the viewer would sit on a mixed-generation
    // mosaic until the screen next changes. Keep the last frame and
    // self-tick from it while work remains.
    private var lastFrame: CMSampleBuffer?
    private var lastCaptureUS: UInt64 = 0
    private var lastSyntheticTickUS: UInt64 = 0
    // Cursor as metadata (encodeQueue-confined except where noted)
    private var lastCursorX = Int.min
    private var lastCursorY = Int.min
    private var lastCursorVisible = false
    private var cursorMetadataActive = false // showsCursor turned off + image timer running
    private var cursorImageTimer: Timer? // main-thread
    private var lastCursorImageHash = 0 // main-thread
    private var lastCursorImageSend = Date.distantPast // main-thread
    private var framesWithRects = 0 // encodeQueue-confined
    private var supersededFrames = 0 // encodeQueue-confined: slot drops whose rects were merged
    private var viewerConnectedUS: UInt64 = 0 // encodeQueue-confined: this connection's start
    private var frameWidth = 0 // encodeQueue: size of the latest captured frame
    private var frameHeight = 0

    // MARK: - Identity (self-signed, made on first run; §13)

    func loadIdentity() throws {
        let (loaded, source) = try QUICIdentity.loadForApp(directory: Self.dataDirectory, name: "identity",
                                                           commonName: "glassact-host")
        identity = loaded
        fingerprint = try QUICIdentity.fingerprint(of: loaded)
        print("glassact-host key: \(QUICIdentity.keyString(fingerprint))")
        onStatus("identity: \(source.description)")
        onStatus("ready (port \(Self.controlPort))")
    }

    /// ~/Library/Application Support/Glass Act (see AppPaths).
    static var dataDirectory: URL { AppPaths.dataDirectory }

    // MARK: - Viewer authorization (mutual TLS)

    /// Viewer certificate fingerprints the user approved. The listener
    /// requires a client certificate and admits only these — an unapproved
    /// viewer is refused during the TLS handshake, before it sees a pixel or
    /// can inject input.
    let authorizedViewers = AuthorizedViewers(
        url: HostController.dataDirectory.appendingPathComponent(IdentityFiles.approvedViewers))
    /// What agents may do here, and the record of what they did.
    let agentAccess = AgentAccess()
    let agentAudit = AgentAudit(directory: HostController.dataDirectory)
    /// Main: the approved-viewers list changed (its window follows).
    var onApprovalsChanged: (() -> Void)?

    private func approvalsChanged() {
        DispatchQueue.main.async { [weak self] in self?.onApprovalsChanged?() }
    }
    private var approvalsPending: Set<String> = [] // main-thread
    private var deniedThisRun: Set<String> = []   // main-thread

    /// Listener queue (TLS verify block): must answer immediately. Unknown
    /// keys are refused now. Under "Ask Me" (and always for agents, unless
    /// new viewers are closed) the user is asked, and approval takes effect
    /// on the viewer's automatic redial. Under "Sign In" a viewer is refused
    /// without a dialog: it signs in with this Mac's account instead (§13).
    private func authorize(peer: QUICTransport.PeerCertificate) -> Bool {
        if authorizedViewers.contains(peer.fingerprint) { return true }
        let policy = newViewerPolicy
        if policy == .ask || (peer.isAgent && policy != .closed) {
            DispatchQueue.main.async { [weak self] in self?.requestApproval(peer) }
        }
        return false
    }

    // MARK: - New viewers: sign in with this Mac's account

    static let newViewerPolicyKey = "glassact.host.newViewers"

    /// Any thread. What happens to a viewer key this Mac hasn't approved.
    var newViewerPolicy: NewViewerPolicy {
        get {
            UserDefaults.standard.string(forKey: Self.newViewerPolicyKey)
                .flatMap(NewViewerPolicy.init(rawValue:)) ?? .signIn
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.newViewerPolicyKey)
            onStatus("new viewers: \(newValue.rawValue)")
        }
    }

    /// Wrong passwords since launch, for the menu (main thread).
    private(set) var failedSignIns = 0
    private(set) var lastFailedSignInAddress = ""

    private lazy var signInGate = SignInGate(
        verifier: LocalAccountVerifier(),
        policy: { [weak self] in self?.newViewerPolicy ?? .closed },
        isApproved: { [weak self] fingerprint in self?.authorizedViewers.contains(fingerprint) ?? false },
        approve: { [weak self] approval in self?.approveSignedIn(approval) ?? false },
        onEvent: { [weak self] event in
            DispatchQueue.main.async { self?.signInEvent(event) }
        })

    /// The sign-in gate's queue. The key that signed in becomes an approved
    /// viewer with full control, like Allow in the dialog.
    private func approveSignedIn(_ approval: SignInGate.Approval) -> Bool {
        do {
            try authorizedViewers.add(approval.fingerprint, viewOnly: false, kind: .viewer)
            authorizedViewers.noteDevice(approval.fingerprint, device: approval.device)
            approvalsChanged()
            return true
        } catch {
            onStatus("couldn't save a signed-in viewer: \(error.localizedDescription)")
            return false
        }
    }

    /// Main thread.
    private func signInEvent(_ event: SignInGate.Event) {
        switch event {
        case let .signedIn(approval):
            let who = approval.device.isEmpty ? "A new viewer" : "“\(approval.device)”"
            onStatus("viewer \(QUICIdentity.abbreviatedKeyString(approval.fingerprint)) signed in from \(approval.address)")
            HostNotifications.post(title: "New viewer signed in",
                                   body: "\(who) can now connect to this Mac. Forget it in Approved Viewers if that wasn’t you.")
        case let .wrongPassword(address):
            failedSignIns += 1
            lastFailedSignInAddress = address
            onStatus("wrong password from \(address) (\(failedSignIns) since launch)")
        case let .throttled(seconds):
            onStatus("viewer sign-in paused for \(seconds / 60 + 1) min after repeated wrong passwords")
            HostNotifications.post(title: "Viewer sign-in paused",
                                   body: "Someone entered the wrong password \(SignInThrottle.maxFailuresPerWindow) times. "
                                       + "Sign-in resumes in \(seconds / 60 + 1) minutes.")
        }
    }


    /// Main thread.
    private func requestApproval(_ peer: QUICTransport.PeerCertificate) {
        let fingerprint = peer.fingerprint
        guard isRunning, !approvalsPending.contains(fingerprint),
              !deniedThisRun.contains(fingerprint), !authorizedViewers.contains(fingerprint) else { return }
        approvalsPending.insert(fingerprint)
        defer { approvalsPending.remove(fingerprint) }
        let code = QUICIdentity.verificationCode(hostFingerprint: self.fingerprint,
                                                 viewerFingerprint: fingerprint)
        let who = peer.isAgent ? "agent" : "viewer"
        onStatus("\(who) \(QUICIdentity.abbreviatedKeyString(fingerprint)) is asking to connect (code \(code))")
        let decision = MainActor.assumeIsolated {
            ApprovalAlert.run(code: code, viewerFingerprint: fingerprint, isAgent: peer.isAgent)
        }
        guard decision != .deny else {
            deniedThisRun.insert(fingerprint)
            onStatus("\(who) \(QUICIdentity.abbreviatedKeyString(fingerprint)) denied")
            if peer.isAgent { agentAudit.log("approval denied for agent key \(QUICIdentity.abbreviatedKeyString(fingerprint))") }
            return
        }
        do {
            try authorizedViewers.add(fingerprint, viewOnly: decision == .viewOnly,
                                      kind: peer.isAgent ? .agent : .viewer)
            onStatus("\(who) \(QUICIdentity.abbreviatedKeyString(fingerprint)) approved\(decision == .viewOnly ? " (view only)" : "") "
                     + "— connecting on its next retry")
            if peer.isAgent {
                agentAudit.log("approved agent key \(QUICIdentity.abbreviatedKeyString(fingerprint)) for \(decision == .viewOnly ? "viewing only" : "control")")
            }
            approvalsChanged()
        } catch {
            onStatus("couldn't save the approval: \(error.localizedDescription)")
        }
    }

    /// The key of the viewer connected right now, if any (main thread).
    var connectedViewerFingerprint: String? {
        viewerSessionLive ? transport?.peerCertificate?.fingerprint : nil
    }

    /// Main thread. Revokes one approval; if that key is connected now, its
    /// session ends (it would otherwise keep going until it next redials).
    func forgetViewer(_ fingerprint: String) {
        let entry = authorizedViewers.all.first { $0.fingerprint == fingerprint }
        do {
            guard try authorizedViewers.remove(fingerprint) else { return }
        } catch {
            onStatus("couldn't forget that viewer: \(error.localizedDescription)")
            return
        }
        deniedThisRun.remove(fingerprint)
        let what = entry?.kind == .agent ? "agent" : "viewer"
        if entry?.kind == .agent { agentAudit.log("forgot agent key \(QUICIdentity.abbreviatedKeyString(fingerprint))") }
        if connectedViewerFingerprint == fingerprint, transport != nil {
            endSession()
            server?.resetSession()
            onStatus("\(what) \(QUICIdentity.abbreviatedKeyString(fingerprint)) forgotten and disconnected")
        } else {
            onStatus("\(what) \(QUICIdentity.abbreviatedKeyString(fingerprint)) forgotten")
        }
        approvalsChanged()
    }

    /// Main thread. The user's own name for an approved key ("" = default).
    func renameViewer(_ fingerprint: String, to name: String) {
        do {
            try authorizedViewers.rename(fingerprint, to: name)
        } catch {
            onStatus("couldn't rename: \(error.localizedDescription)")
        }
        approvalsChanged()
    }

    /// Main thread. Switch an approved key between control and view only;
    /// a connected one changes at once (an agent hears AGENT_SCOPE).
    func setViewerViewOnly(_ fingerprint: String, _ viewOnly: Bool) {
        do {
            try authorizedViewers.setViewOnly(fingerprint, viewOnly)
        } catch {
            onStatus("couldn't change access: \(error.localizedDescription)")
            return
        }
        agentAudit.log("key \(QUICIdentity.abbreviatedKeyString(fingerprint)) set to \(viewOnly ? "view only" : "control") at this Mac")
        if connectedViewerFingerprint == fingerprint { agentAccess.setViewOnly(viewOnly) }
        approvalsChanged()
    }

    /// Main thread. Revokes every approval and drops the current session.
    func forgetApprovedViewers() {
        do {
            try authorizedViewers.removeAll()
        } catch {
            onStatus("couldn't clear approvals: \(error.localizedDescription)")
            return
        }
        deniedThisRun.removeAll()
        if transport != nil {
            endSession()
            server?.resetSession()
        }
        onStatus("approved viewers forgotten")
        approvalsChanged()
    }

    // MARK: - Capture lifecycle

    /// Viewer logs sent over the session (Session › Send Logs to Host).
    private let logInbox = ViewerLogInbox()

    private var displayWatchRegistered = false

    /// The physical display the Host shares: the one capture started on,
    /// or the main display before that (main-thread).
    private var physicalDisplay: CGDirectDisplayID {
        sharedDisplayID != 0 && CGDisplayIsOnline(sharedDisplayID) != 0 ? sharedDisplayID : CGMainDisplayID()
    }

    /// Log every display mode change with its new size — the host's own
    /// switches log just before theirs, so an unannounced one is external
    /// (e.g. macOS putting the display back to native between reconnects).
    private func watchDisplayReconfiguration() {
        guard !displayWatchRegistered else { return }
        displayWatchRegistered = true
        CGDisplayRegisterReconfigurationCallback({ display, flags, info in
            guard let info, !flags.contains(.beginConfigurationFlag) else { return }
            let controller = Unmanaged<HostController>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { controller.displayReconfigured(display, flags: flags) }
        }, Unmanaged.passUnretained(self).toOpaque())
        // Waking from display sleep isn't always a reconfiguration.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture.displayMayBeBack() }
        }
    }

    /// Main thread. One display's reconfiguration finished.
    private func displayReconfigured(_ display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        capture.displayMayBeBack()
        if flags.contains(.unMirrorFlag) || flags.contains(.mirrorFlag) {
            // A virtual display's mirroring can be undone by the system.
            reapplyViewerModeIfReverted()
        }
        if flags.contains(.setModeFlag), display == physicalDisplay {
            let b = CGDisplayBounds(display)
            onStatus("display mode changed → \(Int(b.width))×\(Int(b.height)) pt")
            reapplyViewerModeIfReverted()
        }
        // One reconcile per burst: a rearrangement reports every display,
        // and a mode switch reports itself and each display it moves.
        guard !displayReconcilePending else { return }
        displayReconcilePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.displayReconcilePending = false
            self.reconcileSharedDisplay()
        }
    }

    /// Main thread. Brings a full-display capture back in line with its
    /// display after a change the Host didn't make: someone at the Mac
    /// picks another resolution, rearranges displays or makes another one
    /// main. Left alone, input and the cursor map through the old origin
    /// and size, so clicks land in the wrong place. The Host's own switches
    /// rebuild the capture as they make them, so by the time this runs
    /// those already match and nothing happens. Client Resolution is
    /// `reapplyViewerModeIfReverted`'s, and a virtual display is the
    /// Host's own.
    private func reconcileSharedDisplay() {
        guard isRunning, singleWindowID == 0, virtualDisplay == nil, capture.isCapturing,
              pendingDisplayRestore == nil else { return }
        let display = physicalDisplay
        let bounds = CGDisplayBounds(display)
        guard bounds.width > 0 else { return }
        if bounds.origin != contentOrigin {
            contentOrigin = bounds.origin
            onStatus("shared display moved to \(Int(bounds.minX)),\(Int(bounds.minY)) — input follows it")
        }
        guard appliedDisplayMode == nil else { return }
        if captureModified {
            // Scale: re-fit the downscaled capture to the display's new shape.
            guard let request = lastScaleRequest else { return }
            let size = CaptureGeometry.scaledSize(of: bounds.size, toFit: request,
                                                  maxPixelsPerPoint: Self.pixelsPerPoint(display))
            let clamped = CaptureGeometry.clamp(size.w, size.h)
            guard clamped.w != captureWidth || clamped.h != captureHeight else { return }
            onStatus("display changed to \(Int(bounds.width))×\(Int(bounds.height)) — capture re-fit to \(size.w)×\(size.h) px")
            restartCapture(pixelWidth: size.w, pixelHeight: size.h, pointScale: CGFloat(size.w) / bounds.width,
                           origin: bounds.origin, inSession: true)
        } else {
            guard let mode = CGDisplayCopyDisplayMode(display) else { return }
            let clamped = CaptureGeometry.clamp(mode.pixelWidth, mode.pixelHeight)
            guard clamped.w != captureWidth || clamped.h != captureHeight else { return }
            onStatus("display changed to \(Int(bounds.width))×\(Int(bounds.height)) — capture follows "
                     + "(\(mode.pixelWidth)×\(mode.pixelHeight) px)")
            restartCapture(pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                           pointScale: CGFloat(mode.pixelWidth) / bounds.width,
                           origin: bounds.origin, inSession: true)
        }
    }

    /// Main thread. macOS can move the display off the viewer's Client
    /// Resolution mid-session (e.g. back to native 60 ms after a switch made
    /// on a connect right after display wake). Left alone, the viewer gets
    /// the whole native desktop scaled down for the session (the HELLO-time
    /// check only runs on a reconnect). Put it back after a short
    /// settle (0.15 s: every frame in the wrong mode is a full-screen change
    /// on a link still warming up); at most 3 times a minute, so a system
    /// that insists wins.
    private func reapplyViewerModeIfReverted() {
        if let vd = virtualDisplay {
            // Virtual display: what can be lost is the mirroring, or its 2×
            // mode (macOS picks the same-pixel 1× variant after a wake).
            guard vd.isOnline, !vd.isMirrored || !vd.isInMode, !displayReapplyPending else { return }
            displayReapplyPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.displayReapplyPending = false
                guard self.virtualDisplay === vd, vd.isOnline, !vd.isMirrored || !vd.isInMode else { return }
                let cutoff = Date().addingTimeInterval(-60)
                self.displayReapplies.removeAll { $0 < cutoff }
                guard self.displayReapplies.count < 3 else { return }
                self.displayReapplies.append(Date())
                if !vd.isInMode {
                    vd.selectMode()
                    self.onStatus("virtual display left \(vd.widthPoints)×\(vd.heightPoints) @\(vd.scale)x — restored")
                }
                if !vd.isMirrored {
                    self.onStatus(vd.mirror(true) ? "mirroring to the virtual display was lost — restored"
                                                  : "mirroring to the virtual display was lost — re-mirror refused")
                }
            }
            return
        }
        guard let applied = appliedDisplaySize, appliedDisplayMode != nil, !displayReapplyPending else { return }
        let now = CGDisplayBounds(physicalDisplay).size
        guard Int(now.width) != applied.width || Int(now.height) != applied.height else { return }
        displayReapplyPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.displayReapplyPending = false
            guard let applied = self.appliedDisplaySize, let mode = self.appliedDisplayMode else { return }
            let display = self.physicalDisplay
            let now = CGDisplayBounds(display).size
            guard Int(now.width) != applied.width || Int(now.height) != applied.height else { return }
            let cutoff = Date().addingTimeInterval(-60)
            self.displayReapplies.removeAll { $0 < cutoff }
            guard self.displayReapplies.count < 3 else {
                self.onStatus("display left \(applied.width)×\(applied.height) again — leaving it at "
                              + "\(Int(now.width))×\(Int(now.height)) (3 re-applies this minute)")
                return
            }
            self.displayReapplies.append(Date())
            let ok = self.setDisplayMode(mode, on: display)
            let after = CGDisplayBounds(display).size
            self.onStatus(ok && Int(after.width) == applied.width
                          ? "display reverted to \(Int(now.width))×\(Int(now.height)) — re-applied \(applied.width)×\(applied.height) for the viewer"
                          : "display reverted to \(Int(now.width))×\(Int(now.height)) — re-applying \(applied.width)×\(applied.height) refused")
        }
    }

    /// Auto-start capture on the main display — no picker step. Single-window
    /// mode already requires Screen Recording, so enumerating the display here
    /// via SCShareableContent is free, and it lets the host "just work" on
    /// launch. There is no multi-monitor selection yet; the picker menu item
    /// is the manual override for another display. Single-window mode ignores
    /// this entirely (the viewer's pick swaps the filter to a single window).
    func startDefaultDisplay() {
        watchDisplayReconfiguration()
        guard !isRunning, identity != nil else { return }
        // Preflight, not request: asking is the setup window's job (one
        // place, with context), not a bare system alert at launch.
        guard CGPreflightScreenCaptureAccess() else {
            onStatus("needs Screen Recording — grant Glass Act in System Settings › Privacy, then reopen")
            phase = .needsScreenRecording
            onPermissionProblem()
            return
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                        ?? content.displays.first else {
                    // Asleep (or locked): nothing to capture yet. Launch has
                    // no viewer to wake it and the listener only starts on
                    // the first frame — so without a retry a host launched
                    // while the display sleeps would stay unreachable.
                    // Wake it and try again.
                    self.retryDefaultDisplay(after: 2, reason: "no display available to capture")
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let displayID = display.displayID
                DispatchQueue.main.async { self.start(filter: filter, displayID: displayID) }
            } catch {
                self.retryDefaultDisplay(after: 5, reason: "display enumeration failed: \(error.localizedDescription)")
            }
        }
    }

    private var defaultDisplayRetries = 0

    /// Any thread. Declare user activity (wakes a sleeping display — the
    /// same as a key press) and retry `startDefaultDisplay` until it runs.
    private func retryDefaultDisplay(after seconds: Double, reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.defaultDisplayRetries += 1
            if self.defaultDisplayRetries == 1 || self.defaultDisplayRetries % 30 == 0 {
                self.onStatus("\(reason) — waking the display, retrying (attempt \(self.defaultDisplayRetries))")
            }
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Glass Act host starting" as CFString, kIOPMUserActiveLocal, &activity)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, !self.isRunning else { return }
                self.startDefaultDisplay()
            }
        }
    }

    func presentPicker() {
        guard !isRunning, identity != nil else { return }
        // Accessory (menu-bar) apps are never active; without this the system
        // picker panel can appear behind other windows. (Menu action: main.)
        MainActor.assumeIsolated { NSApp.activate() }
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay]
        picker.configuration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present(using: .display)
        onStatus("choose a display in the picker…")
    }

    // SCContentSharingPickerObserver (callbacks arrive off-main)

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return } // no live re-picking of a running stream
        let boxed = UnsafeSendableBox(filter)
        DispatchQueue.main.async { [self] in
            guard !isRunning else { return }
            start(filter: boxed.value)
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { [self] in
            if !isRunning {
                let picker = SCContentSharingPicker.shared
                picker.isActive = false
                picker.remove(self)
                onStatus("picker cancelled")
            }
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { [self] in
            onStatus("picker failed: \(error.localizedDescription)")
        }
    }

    /// `displayID`: the display `filter` shows, when the caller knows it
    /// (the picker's filter doesn't say; it's found from the filter's rect).
    private func start(filter: SCContentFilter, displayID: CGDirectDisplayID? = nil) {
        guard !isRunning, identity != nil else { return }
        isRunning = true
        phase = .starting
        let scale = CGFloat(filter.pointPixelScale)
        let size = CaptureGeometry.clamp(Int(filter.contentRect.width * scale),
                                         Int(filter.contentRect.height * scale))
        pixelScale = scale * size.factor
        let shared = displayID ?? Self.display(containing: filter.contentRect)
        sharedDisplayID = shared
        contentOrigin = shared != 0 ? CGDisplayBounds(shared).origin : filter.contentRect.origin
        lastFilter = filter
        capture.start(filter: filter, settings: CaptureSettings(width: size.w, height: size.h))
    }

    /// Main thread. What capture reports (`ScreenCapture.Event`).
    private func captureEvent(_ event: ScreenCapture<ScreenCaptureKitBackend>.Event) {
        switch event {
        case .started:
            break
        case let .startFailed(reason):
            isRunning = false
            phase = CGPreflightScreenCaptureAccess() ? .stopped : .needsScreenRecording
            onStatus("capture failed: \(reason)")
        case .stoppedFromMenuBar:
            stop()
        case .screenRecordingRevoked:
            phase = .needsScreenRecording
            onPermissionProblem()
        case let .recovered(_, filter, displayID):
            lastFilter = filter
            if virtualDisplay == nil, let displayID {
                // The shared display may have gone (unplugged): follow the
                // one capture fell back to.
                sharedDisplayID = displayID
                contentOrigin = CGDisplayBounds(displayID).origin
            }
            reconcileSharedDisplay()
        case .sharedWindowClosed:
            endSessionForClosedWindow()
        }
    }

    /// The display's current mode, pixels per point (2 for a Retina mode).
    private static func pixelsPerPoint(_ display: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    /// The display under the middle of `rect` (global points), or 0.
    private static func display(containing rect: CGRect) -> CGDirectDisplayID {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 1, &display, &count) == .success,
              count > 0 else { return 0 }
        return display
    }

    /// Main thread. The shared window closed, or its app quit: end the
    /// session. Falling back to the whole display would suddenly show the
    /// viewer the entire desktop.
    private func endSessionForClosedWindow() {
        guard isRunning, singleWindowID != 0 else { return }
        onStatus("shared window closed on the host — ending the session")
        let engineQueue = encodeQueue
        engineQueue.async { self.engine?.sendSharedWindowClosed() }
        // Back to the full display for whoever connects next (not
        // in-session: this session is over).
        singleWindowID = 0
        sharedAXWindow = nil
        originalWindowFrame = nil
        if let display = savedDisplayFilter {
            savedDisplayFilter = nil
            lastFilter = display
            let scale = CGFloat(display.pointPixelScale)
            let pw = max(2, Int(display.contentRect.width * scale)) & ~1
            let ph = max(2, Int(display.contentRect.height * scale)) & ~1
            restartCapture(pixelWidth: pw, pixelHeight: ph, pointScale: scale,
                           origin: display.contentRect.origin)
        }
        // Let the message reach the viewer, then close the connection.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.transport?.cancel()
        }
    }

    /// Main thread, 1 Hz (`ScreenCapture.checkHealth`).
    func checkCaptureHealth() {
        capture.checkHealth()
    }

    // MARK: - Display awake while a viewer watches

    private var displayAwakeAssertion: IOPMAssertionID = 0

    /// Main thread. A connected viewer needs a lit display (capture fails
    /// while it sleeps): wake it now and hold it awake until the viewer
    /// leaves — then idle sleep is the system's again.
    private func holdDisplayAwake(_ hold: Bool) {
        if hold {
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Glass Act viewer connected" as CFString, kIOPMUserActiveLocal, &activity)
            guard displayAwakeAssertion == 0 else { return }
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Glass Act viewer connected" as CFString, &displayAwakeAssertion)
        } else if displayAwakeAssertion != 0 {
            IOPMAssertionRelease(displayAwakeAssertion)
            displayAwakeAssertion = 0
        }
    }

    func stop() {
        isRunning = false
        phase = .stopped
        viewerConnectedAt = nil
        pendingLock?.cancel() // stopped locally: someone is at the Mac
        pendingLock = nil
        pendingDisplayRestore?.cancel() // a queued restore would restart capture
        pendingDisplayRestore = nil
        lastFilter = nil
        captureModified = false
        lastScaleRequest = nil
        autoScaledDown = false
        clipboardTimer?.invalidate(); clipboardTimer = nil
        cursorImageTimer?.invalidate(); cursorImageTimer = nil
        restoreSharedWindowFrame()
        singleWindowID = 0
        savedDisplayFilter = nil
        sharedAXWindow = nil
        originalWindowFrame = nil
        restoreDisplayMode()
        SCContentSharingPicker.shared.isActive = false
        SCContentSharingPicker.shared.remove(self)
        capture.stop()
        holdDisplayAwake(false)
        server?.cancel()
        server = nil
        let ending = transport
        transport = nil // before cancel: its .cancelled is then not "ours"
        ending?.cancel()
        tickTimer?.cancel()
        tickTimer = nil
        encodeQueue.async { [self] in
            engine = nil
            sessionTransport = nil
            serverRequested = false
            lastFrame = nil
            frameWidth = 0
            frameHeight = 0
            if recordingArmed || recorder != nil {
                recordingArmed = false
                DispatchQueue.main.async { self.isRecording = false }
                closeRecorder(status: recorder != nil ? "stopped — trace saved: \(recordName)" : "stopped")
            } else {
                onStatus("stopped")
            }
        }
    }

    // MARK: - Clipboard sync (main thread)

    private func startClipboardSync(_ send: @escaping @Sendable (UInt8, [UInt8]) -> Void) {
        clipboardChangeCount = NSPasteboard.general.changeCount
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pb = NSPasteboard.general
            guard pb.changeCount != self.clipboardChangeCount else { return }
            self.clipboardChangeCount = pb.changeCount
            guard let str = pb.string(forType: .string) else { return }
            let bytes = Array(str.utf8)
            var h = Hasher(); h.combine(bytes); let hash = h.finalize()
            guard hash != self.lastClipboardHash else { return } // echo of an inbound apply
            self.lastClipboardHash = hash
            send(1, bytes)
        }
    }

    private func applyInboundClipboard(_ format: UInt8, _ data: [UInt8]) {
        guard format == 1, let str = String(bytes: data, encoding: .utf8) else { return }
        var h = Hasher(); h.combine(data); let hash = h.finalize()
        guard hash != lastClipboardHash else { return }
        lastClipboardHash = hash
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: .string)
        clipboardChangeCount = pb.changeCount // our own apply must not re-send
    }

    /// Inject a remote input event (engineQueue → CGEvent). Canvas pixels map
    /// to a global display point via the same origin/scale the cursor uses.
    /// Requires Accessibility (TCC): CGEventPost is silently ignored without
    /// it, so we prompt once.
    /// Canvas pixels per display point, for input, cursor reports and dirty
    /// rects. Full-display capture: measured from the display's CURRENT
    /// size every time — the configured scale assumes a display-mode switch
    /// happened, and when macOS refuses one (at the lock screen) clicks
    /// would land 78 % off (2.0 used where the native display needs 1.125).
    /// Window capture: the stored scale (the window, not the display).
    private var mappingScale: CGFloat {
        guard singleWindowID == 0, captureWidth > 0 else { return pixelScale }
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        let probe = CGPoint(x: contentOrigin.x + 1, y: contentOrigin.y + 1)
        if CGGetDisplaysWithPoint(probe, 1, &display, &count) != .success || count == 0 {
            display = CGMainDisplayID()
        }
        let w = CGDisplayBounds(display).width
        return w > 0 ? CGFloat(captureWidth) / w : pixelScale
    }

    private func injectInput(kind rawKind: Int, canvasX: Int, canvasY: Int, a: Int, b: Int) {
        let raw = UInt8(truncatingIfNeeded: rawKind)
        let kind = Int(raw & InputFlags.kindMask)
        let agentInput = raw & InputFlags.agent != 0 || agentAccess.sessionIsAgent
        // Releases always go through (a denied mouse-up would leave a button
        // stuck down), except for a key that may only watch.
        let release = kind == 3 || kind == 6
        if let denial = agentAccess.admit(agentInput: agentInput && !release) {
            if kind != 1 { agentAudit.denied(Self.inputName(kind), denial.reason) }
            return
        }
        if agentInput, kind == 2 || kind == 4 || kind == 5 || kind == 7 {
            agentAudit.log("\(agentTag) \(Self.inputName(kind)) \(kind == 5 ? "key \(canvasX) flags \(String(UInt32(bitPattern: Int32(truncatingIfNeeded: a)), radix: 16))" : "at \(canvasX),\(canvasY)")"
                           + (kind == 2 ? " button \(b) count \(max(1, a))" : "") + (kind == 4 || kind == 7 ? " by \(a),\(b)" : ""))
        }
        guard ensureAccessibility() else { return }
        if !loggedFirstInject {
            loggedFirstInject = true
            onStatus("remote input active (first event kind \(kind))")
        }
        let scale = mappingScale
        let gx = contentOrigin.x + CGFloat(canvasX) / scale
        let gy = contentOrigin.y + CGFloat(canvasY) / scale
        let pt = CGPoint(x: gx, y: gy)
        switch kind {
        case 1: // move (or drag if a button is held)
            if mouseButtonsDown != 0 {
                let (type, button) = draggedTypeForHeldButton()
                post(mouse: type, at: pt, button: button, clickState: heldClickState)
            } else {
                post(mouse: .mouseMoved, at: pt, button: .left)
            }
        case 2, 3: // down / up
            let button: CGMouseButton = b == 1 ? .right : (b == 2 ? .center : .left)
            let bit = 1 << b
            if kind == 2 { mouseButtonsDown |= bit } else { mouseButtonsDown &= ~bit }
            let type: CGEventType
            switch (kind, button) {
            case (2, .left): type = .leftMouseDown
            case (3, .left): type = .leftMouseUp
            case (2, .right): type = .rightMouseDown
            case (3, .right): type = .rightMouseUp
            case (2, _): type = .otherMouseDown
            default: type = .otherMouseUp
            }
            // The viewer's click count (0 is read as 1): a double-click is
            // two downs/ups with click state 1 then 2 — stamped 1 every
            // time, apps would see only single clicks.
            let clickState = Int64(max(1, min(a, 32)))
            if kind == 2 { heldClickState = clickState }
            post(mouse: type, at: pt, button: button, clickState: clickState)
        case 4, 7: // scroll: 4 = lines (wheel mouse), 7 = points (trackpad)
            if let ev = CGEvent(scrollWheelEvent2Source: nil, units: kind == 7 ? .pixel : .line,
                                wheelCount: 2, wheel1: Int32(b), wheel2: Int32(a), wheel3: 0) {
                ev.post(tap: .cghidEventTap)
            }
        case 5, 6: // key down / up
            if let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(canvasX),
                                keyDown: kind == 5) {
                // Keep the flags a key carries itself (numeric pad and
                // function on arrows and the like), which an agent's flags
                // may leave out; replacing them made a ← unlike a real one.
                // Not for modifier keys (54–63): fn's own flag would keep fn
                // held through its key-up.
                let own = (54...63).contains(canvasX) ? []
                    : ev.flags.intersection([.maskNumericPad, .maskSecondaryFn])
                ev.flags = CGEventFlags(rawValue: UInt64(UInt32(bitPattern: Int32(a)))).union(own)
                ev.post(tap: .cghidEventTap)
            }
        default: break
        }
    }

    /// Main: agent policy changed (toggle, pause, time limit, session) —
    /// tell an active agent whether its input is accepted now.
    func agentPolicyChanged() {
        let snap = agentAccess.snapshot
        guard snap.agentActive else { return }
        let scope = agentAccess.scope()
        encodeQueue.async { [weak self] in self?.engine?.sendAgentScope(control: scope.control, reason: scope.reason) }
    }

    /// Main: the person here paused or resumed the agent from the menu.
    func pauseAgent() {
        agentAccess.pause("paused from the Glass Act Host menu")
        agentAudit.log("\(agentTag) paused by the person at this Mac")
    }

    func resumeAgent() {
        agentAccess.resume()
        agentAudit.log("\(agentTag) resumed by the person at this Mac")
    }

    static func inputName(_ kind: Int) -> String {
        switch kind {
        case 1: "move"
        case 2: "mouse down"
        case 3: "mouse up"
        case 4, 7: "scroll"
        case 5: "key down"
        case 6: "key up"
        default: "input \(kind)"
        }
    }

    /// "agent claude" — how the audit log names whoever is driving.
    var agentTag: String {
        let label = agentAccess.snapshot.label
        return label.isEmpty || label == "agent" ? "agent" : "agent \(label)"
    }

    var sessionPeerSummary: String {
        guard let peer = transport?.peerCertificate ?? sessionTransport?.peerCertificate else { return "viewer key unknown" }
        return "\(peer.isAgent ? "agent" : "viewer") key \(QUICIdentity.abbreviatedKeyString(peer.fingerprint))"
    }

    /// TEXT_INPUT → Unicode key events (20 UTF-16 units per event, the most
    /// apps take at once; never splitting a surrogate pair). Newlines and
    /// tabs press Return and Tab, so forms submit and fields advance the way
    /// typing does.
    private func injectText(_ text: String) {
        guard ensureAccessibility() else { return }
        func press(_ code: CGKeyCode) {
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
        func type(_ run: Substring) {
            let units = Array(run.utf16)
            var i = 0
            while i < units.count {
                var end = min(i + 20, units.count)
                if end < units.count, UTF16.isTrailSurrogate(units[end]) { end -= 1 }
                let chunk = Array(units[i..<end])
                for down in [true, false] {
                    guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    ev.flags = []
                    ev.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    ev.post(tap: .cghidEventTap)
                }
                i = end
            }
        }
        var run = text[...]
        while let idx = run.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" || $0 == "\t" }) {
            type(run[..<idx])
            press(run[idx] == "\t" ? 48 : 36)
            run = run[run.index(after: idx)...]
        }
        type(run)
    }

    private func draggedTypeForHeldButton() -> (CGEventType, CGMouseButton) {
        if mouseButtonsDown & 0b010 != 0 { return (.rightMouseDragged, .right) }
        if mouseButtonsDown & 0b100 != 0 { return (.otherMouseDragged, .center) }
        return (.leftMouseDragged, .left)
    }

    private func post(mouse type: CGEventType, at pt: CGPoint,
                      button: CGMouseButton, clickState: Int64 = 0) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: pt, mouseButton: button) else { return }
        if clickState > 0 { ev.setIntegerValueField(.mouseEventClickState, value: clickState) }
        ev.post(tap: .cghidEventTap)
    }

    /// Accessibility (TCC) is required for CGEventPost. Checked SILENTLY
    /// (AXIsProcessTrusted, never the prompting variant) so no system dialog
    /// pops on the first stray event — instead, once per session, log it and
    /// tell the app, which shows the setup window (asking happens there).
    /// Injection no-ops until granted, then works without a relaunch.
    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !warnedNoAccessibility {
            warnedNoAccessibility = true
            onStatus("remote input needs Device Control and Data Access — allow Glass Act Host in System Settings › Privacy & Security")
            DispatchQueue.main.async { [weak self] in self?.onPermissionProblem() }
        }
        return false
    }

    /// Main thread. Apply a viewer RESIZE request, then reset the session —
    /// the viewer's auto-reconnect lands on a fresh HELLO with new geometry.
    private func applyResize(mode: Int, widthPoints: Int, heightPoints: Int, scale: Int) {
        geometrySettled = true // whatever happens, the next HELLO is final
        if mode != Int(GeometryMode.scale) { lastScaleRequest = nil }
        guard isRunning else { onStatus("resize: ignored (not running)"); return }
        guard lastFilter != nil else { onStatus("resize: ignored (no capture filter)"); return }
        if mode == Int(GeometryMode.virtualDisplay) {
            applyVirtualDisplay(widthPoints: widthPoints, heightPoints: heightPoints, scale: scale)
            return
        }
        if virtualDisplay != nil {
            // Back to the physical display first; its mode list and bounds
            // settle a moment after the virtual display goes away.
            tearDownVirtualDisplay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.applyResize(mode: mode, widthPoints: widthPoints, heightPoints: heightPoints, scale: scale)
            }
            return
        }
        if mode == 3 {
            // Explicit native: undo any display switch / capture downscale.
            restoreDisplayMode()
            captureModified = false
            let display = physicalDisplay
            let bounds = CGDisplayBounds(display)
            onStatus("resize: restored to native")
            if let m = CGDisplayCopyDisplayMode(display) {
                restartCapture(pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                               pointScale: CGFloat(m.pixelWidth) / bounds.width,
                               inSession: true)
            } else {
                reofferGeometryFinal()
            }
            return
        }
        captureModified = true // a display switch or a capture downscale
        let display = physicalDisplay
        if mode == 1 {
            // "Client Resolution": switch the host display to the viewer's
            // logical size (prefer a HiDPI mode at its backing factor).
            guard let modes = CGDisplayCopyAllDisplayModes(
                display, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
                as? [CGDisplayMode] else {
                onStatus("resize: no display modes")
                reofferGeometryFinal()
                return
            }
            // The viewer's panel geometry (e.g. a MacBook's 3:2-ish 1470×956)
            // rarely exists in a monitor's mode list — pick the LARGEST host
            // mode fitting WITHIN the viewer's logical size (the viewer then
            // shows it near-1:1, letterboxed by the aspect difference),
            // preferring HiDPI at the viewer's backing factor.
            let fitting = modes.filter { $0.width <= widthPoints && $0.height <= heightPoints
                && $0.isUsableForDesktopGUI() }
            let pick = fitting.max { a, b in
                let areaA = a.width * a.height, areaB = b.width * b.height
                if areaA != areaB { return areaA < areaB }
                return a.pixelWidth < b.pixelWidth // prefer HiDPI at equal size
            }
            guard let target = pick else {
                onStatus("resize: no mode fits \(widthPoints)×\(heightPoints) — staying native")
                reofferGeometryFinal()
                return
            }
            // Requested mode is what we're already capturing (the loopback /
            // same-geometry case): no display switch, no capture rebuild —
            // just finalize the handshake on the live connection.
            // The DISPLAY must be in that mode too, not just the capture at
            // that size: if macOS reverted the display to native (as it can
            // between two quick reconnects), a 2880×1620 capture of the
            // native 5120 display would match here and skip the switch — the
            // viewer would get the whole host desktop scaled down, not
            // Client Resolution.
            let current = CGDisplayCopyDisplayMode(display)
            if target.pixelWidth == captureWidth && target.pixelHeight == captureHeight
                && current?.width == target.width && current?.height == target.height {
                // Still switched if this is a kept Client Resolution (a
                // reconnect behind the lock): restore must stay armed.
                captureModified = originalDisplayMode != nil
                onStatus("resize: already at \(target.width)×\(target.height) — re-offering final")
                reofferGeometryFinal()
                return
            }
            onStatus("resize: best fit \(target.width)×\(target.height) (\(target.pixelWidth)×\(target.pixelHeight) px)")
            if originalDisplayMode == nil {
                originalDisplayMode = CGDisplayCopyDisplayMode(display)
            }
            let switched = setDisplayMode(target, on: display)
            appliedDisplaySize = switched ? (target.width, target.height) : nil
            appliedDisplayMode = switched ? target : nil
            let pw = target.pixelWidth
            let ph = target.pixelHeight
            // Report what the display IS, not what was asked: macOS refuses
            // a mode change at the lock screen. (Input mapping measures the
            // live display either way — see mappingScale.)
            let now = CGDisplayBounds(display)
            if switched && Int(now.width) == target.width {
                onStatus("resize: host display → \(target.width)×\(target.height) (\(pw)×\(ph) px)")
            } else {
                onStatus("resize: display switch to \(target.width)×\(target.height) refused — display stays "
                         + "\(Int(now.width))×\(Int(now.height)), capture scaled to \(pw)×\(ph) px")
            }
            restartCapture(pixelWidth: pw, pixelHeight: ph,
                           pointScale: CGFloat(pw) / max(1, now.width),
                           inSession: true)
        } else {
            // "Scale": display stays native; capture downsamples to the
            // viewer's pixel size — ASPECT-FIT of the host content, not a
            // stretch (a 16:9 host into a 3:2 viewer request).
            let bounds = CGDisplayBounds(display)
            lastScaleRequest = (widthPoints, heightPoints, scale)
            let (pw, ph) = CaptureGeometry.scaledSize(of: bounds.size, toFit: (widthPoints, heightPoints, scale),
                                                      maxPixelsPerPoint: Self.pixelsPerPoint(display))
            if pw == captureWidth && ph == captureHeight {
                // Still downscaled vs the display (a reconnect within the
                // grace): restore must stay armed.
                captureModified = CGDisplayCopyDisplayMode(display).map { $0.pixelWidth != pw } ?? false
                onStatus("resize: capture already \(pw)×\(ph) — re-offering final")
                reofferGeometryFinal()
                return
            }
            onStatus("resize: capture scaled → \(pw)×\(ph) px (display native)")
            restartCapture(pixelWidth: pw, pixelHeight: ph,
                           pointScale: CGFloat(pw) / bounds.width,
                           inSession: true)
        }
    }

    /// Main thread. Rebuild the SCK stream at a new output size and reset
    /// the session so the next HELLO carries the new dimensions.
    private func restartCapture(pixelWidth: Int, pixelHeight: Int, pointScale: CGFloat,
                                origin: CGPoint? = nil, inSession: Bool = false) {
        guard isRunning, let filter = lastFilter else { return }
        let size = CaptureGeometry.clamp(pixelWidth, pixelHeight)
        let pixelWidth = size.w, pixelHeight = size.h
        pixelScale = pointScale * size.factor
        contentOrigin = origin ?? CGDisplayBounds(physicalDisplay).origin
        captureWidth = pixelWidth
        captureHeight = pixelHeight
        guard capture.restart(filter: filter, width: pixelWidth, height: pixelHeight) else { return }
        encodeQueue.async { [weak self] in
            guard let self else { return }
            self.lastFrame = nil
            if inSession {
                // In-session geometry change (§4.10): swap the engine on the
                // live connection — re-HELLO the viewer at the new size, no
                // QUIC reconnect. New-dim frames from the fresh SCStream feed
                // the new engine; old-dim stragglers are dropped by drain()'s
                // grid guard.
                self.reconfigureEngineInSession(width: pixelWidth, height: pixelHeight)
            } else {
                self.engine = nil
                DispatchQueue.main.async { self.server?.resetSession() }
            }
        }
    }

    /// A geometry request must always end with a re-offered HELLO — even a
    /// refused one — or the handshake wedges (the host is holding pixels).
    /// The re-offer carries geometryFinal on the SAME connection, so the
    /// viewer proceeds at the current dims with no reconnect blink.
    private func reofferGeometryFinal() {
        encodeQueue.async { [weak self] in
            self?.engine?.reofferHelloFinal(nowUS: MonotonicClock.nowUS)
        }
    }

    // MARK: - Single-window mode

    /// Viewer picked (main thread). id 0 = "show me the list"; a real id swaps
    /// the capture filter to that one window.
    private func handleWindowSelect(_ id: UInt32) {
        guard isRunning else { return }
        if id == 0 {
            enumerateAndSendWindows()
        } else if let window = enumeratedWindows.first(where: { $0.windowID == id }) {
            captureWindow(window)
        } else {
            onStatus("window \(id) not found — re-enumerating")
            enumerateAndSendWindows()
        }
    }

    /// Enumerate on-screen app windows (needs Screen Recording), grab a small
    /// thumbnail each, and push the list to the viewer's picker. Best-effort:
    /// a window whose thumbnail fails ships with no image, still pickable by
    /// name.
    private func enumerateAndSendWindows() {
        guard CGPreflightScreenCaptureAccess() else {
            // Not granted (and a grant takes effect on relaunch). Send an
            // empty list so the viewer's picker gives feedback instead of
            // hanging on "loading…", and show setup here.
            onStatus("single-window needs Screen Recording — grant Glass Act in System Settings › Privacy, then reconnect")
            onPermissionProblem()
            encodeQueue.async { [weak self] in self?.engine?.sendWindowList([]) }
            return
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: false)
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let candidates = content.windows.filter { w in
                    guard let app = w.owningApplication else { return false }
                    if app.processID == ownPID { return false } // never share ourselves
                    // Layer 0 = real app windows. Everything else is system
                    // chrome — Dock, menu bar, Control Center, overlays.
                    guard w.windowLayer == 0 else { return false }
                    guard w.frame.width >= 80 && w.frame.height >= 80 else { return false }
                    // Off-screen windows (hidden apps, minimized, other
                    // Spaces) are shareable too — but only titled ones;
                    // untitled off-screen windows are app plumbing.
                    return w.isOnScreen || !(w.title ?? "").isEmpty
                }.sorted {
                    if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen }
                    return $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height
                }
                let capped = Array(candidates.prefix(24)) // bounds the TLV under maxBodyLength
                self.enumeratedWindows = capped
                var wire: [WireWindow] = []
                wire.reserveCapacity(capped.count)
                for w in capped {
                    let thumb = (try? await self.thumbnail(for: w)) ?? nil
                    wire.append(WireWindow(
                        windowID: w.windowID,
                        appName: w.owningApplication?.applicationName ?? "",
                        title: w.title ?? "",
                        thumbFormat: thumb?.format ?? WindowThumbFormat.none,
                        thumbWidth: UInt16(clamping: thumb?.width ?? 0),
                        thumbHeight: UInt16(clamping: thumb?.height ?? 0),
                        thumb: thumb?.bytes ?? []))
                }
                self.encodeQueue.async { [wire] in self.engine?.sendWindowList(wire) }
                self.onStatus("sent \(wire.count) windows to viewer")
            } catch {
                self.onStatus("window enumeration failed: \(error.localizedDescription)")
            }
        }
    }

    /// A one-shot small thumbnail for a window, encoded as WebP (preferred) or
    /// AVIF — both decode via NSImage on the viewer. Format is advisory only.
    private func thumbnail(for window: SCWindow) async throws
        -> (format: UInt8, width: Int, height: Int, bytes: [UInt8])? {
        let fw = max(window.frame.width, 1), fh = max(window.frame.height, 1)
        let f = min(320.0 / fw, 200.0 / fh, 1.0)
        let tw = max(2, Int(fw * f)) & ~1
        let th = max(2, Int(fh * f)) & ~1
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = tw
        config.height = th
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let encoded = Self.encodeThumbnail(cg) else { return nil }
        return (encoded.format, cg.width, cg.height, encoded.bytes)
    }

    /// Encode a CGImage as a compact still. Tries WebP then AVIF (both natively
    /// decodable by NSImage on macOS); returns nil if neither is writable.
    private static func encodeThumbnail(_ image: CGImage) -> (format: UInt8, bytes: [UInt8])? {
        let attempts: [(UTType, UInt8)] = [(.webP, WindowThumbFormat.webpLossy),
                                           (UTType("public.avif") ?? .heic, WindowThumbFormat.avif)]
        for (type, format) in attempts {
            let data = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(
                data, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(dst), data.length > 0 else { continue }
            return (format, [UInt8](data as Data))
        }
        return nil
    }

    /// Swap the capture filter to a single window (main thread). Rebuilds the
    /// stream at the window's native pixel size and resets the session so the
    /// viewer re-HELLOs at the window dimensions and switches to its borderless
    /// presentation. `savedDisplayFilter` restores full-display on endSession.
    private func captureWindow(_ window: SCWindow) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        if savedDisplayFilter == nil { savedDisplayFilter = lastFilter }
        singleWindowID = window.windowID
        // A hidden/minimized pick must surface the real window first: input
        // maps through SCREEN coordinates, so an off-screen window would
        // stream pixels while routing clicks to whatever sits under its
        // stale frame. Unhide/activate before AX resolution so the element
        // lookup and frame snapshot see the live window.
        if !window.isOnScreen, let pid = window.owningApplication?.processID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.unhide()
            app.activate(options: [])
        }
        // Cache the AX element + snapshot the original frame ONCE, before any
        // resize (for restoring it on disconnect and for reliable later drives).
        sharedAXWindow = axWindow(for: window)
        if let ax = sharedAXWindow {
            if !window.isOnScreen {
                AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            }
            originalWindowFrame = axFrame(ax)
        }
        let scale = CGFloat(filter.pointPixelScale)
        let pw = max(2, Int(filter.contentRect.width * scale)) & ~1
        let ph = max(2, Int(filter.contentRect.height * scale)) & ~1
        lastFilter = filter
        // Input/cursor map through the window's SCREEN origin. A desktop-
        // independent window filter's contentRect.origin is content-relative
        // (~0,0), which would send clicks to the screen corner and keep the
        // cursor out of frame — use the AX (or SCWindow) screen frame instead.
        let origin = originalWindowFrame?.origin ?? window.frame.origin
        onStatus("sharing window: \(window.owningApplication?.applicationName ?? "?") — \(window.title ?? "")")
        restartCapture(pixelWidth: pw, pixelHeight: ph, pointScale: scale,
                       origin: origin, inSession: true)
    }

    /// Viewer window-chrome action (main thread). Fullscreen/resize drive the
    /// real host window via Accessibility; endSession reverts to full display.
    private func handleWindowControl(_ action: UInt8, width: Int, height: Int) {
        if action == WindowAction.endSession { revertToDisplay(); return }
        guard singleWindowID != 0,
              let window = enumeratedWindows.first(where: { $0.windowID == singleWindowID }) else { return }
        switch action {
        case WindowAction.fullscreen: toggleFullscreen(window)
        case WindowAction.resize: resizeHostWindow(window, toPoints: CGSize(width: width, height: height))
        default: break
        }
    }

    private func revertToDisplay() {
        guard let display = savedDisplayFilter else { return }
        restoreSharedWindowFrame() // put the host window back the way we found it
        singleWindowID = 0
        savedDisplayFilter = nil
        lastFilter = display
        let scale = CGFloat(display.pointPixelScale)
        let pw = max(2, Int(display.contentRect.width * scale)) & ~1
        let ph = max(2, Int(display.contentRect.height * scale)) & ~1
        onStatus("returned to full display")
        restartCapture(pixelWidth: pw, pixelHeight: ph, pointScale: scale,
                       origin: display.contentRect.origin, inSession: true)
    }

    /// Toggle the shared window's full-screen state via Accessibility, then
    /// re-capture at the settled geometry (fullscreen animates, so read the AX
    /// frame after a short delay). Best-effort — some windows have no
    /// AXFullScreen.
    private func toggleFullscreen(_ window: SCWindow) {
        guard ensureAccessibility(), let ax = sharedAX(for: window) else {
            onStatus("fullscreen: no accessible window"); return
        }
        var cur: AnyObject?
        let has = AXUIElementCopyAttributeValue(ax, "AXFullScreen" as CFString, &cur) == .success
        let target = !((cur as? Bool) ?? false)
        let r = AXUIElementSetAttributeValue(ax, "AXFullScreen" as CFString, target as CFTypeRef)
        onStatus(r == .success && has ? "window fullscreen → \(target)" : "window does not support fullscreen")
        let boxed = UnsafeSendableBox((window, ax))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.recaptureShared(boxed.value.0, ax: boxed.value.1)
        }
    }

    private func resizeHostWindow(_ window: SCWindow, toPoints size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        guard ensureAccessibility() else {
            onStatus("resize needs Device Control and Data Access — allow Glass Act Host in System Settings › Privacy & Security"); return
        }
        guard let ax = sharedAX(for: window) else {
            onStatus("resize: couldn't locate the window via Accessibility"); return
        }
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v)
        onStatus("window resize → \(Int(size.width))×\(Int(size.height)) pt")
        let boxed = UnsafeSendableBox((window, ax))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.recaptureShared(boxed.value.0, ax: boxed.value.1)
        }
    }

    /// Rebuild the window capture at the window's current AX geometry (after a
    /// fullscreen/resize) so the streamed pixels stay 1:1, not scaled into a
    /// stale output size.
    private func recaptureShared(_ window: SCWindow, ax: AXUIElement) {
        guard singleWindowID == window.windowID, let f = axFrame(ax) else { return }
        let scale = CGFloat(SCContentFilter(desktopIndependentWindow: window).pointPixelScale)
        let pw = max(2, Int(f.size.width * scale)) & ~1
        let ph = max(2, Int(f.size.height * scale)) & ~1
        guard pw != captureWidth || ph != captureHeight else { return }
        restartCapture(pixelWidth: pw, pixelHeight: ph, pointScale: scale, origin: f.origin, inSession: true)
    }

    /// Cached AX element for the shared window (re-matches once if we didn't
    /// have Accessibility at pick time). AXUIElement refs stay valid for the
    /// window's lifetime, so caching survives resizes that stale the frame.
    private func sharedAX(for window: SCWindow) -> AXUIElement? {
        if sharedAXWindow == nil {
            sharedAXWindow = axWindow(for: window)
            if originalWindowFrame == nil, let ax = sharedAXWindow { originalWindowFrame = axFrame(ax) }
        }
        return sharedAXWindow
    }

    /// Restore the shared window to the size/position it had before we
    /// resized it, on disconnect/endSession (mirrors the display-mode restore).
    private func restoreSharedWindowFrame() {
        guard let ax = sharedAXWindow, let frame = originalWindowFrame else { return }
        var pos = frame.origin
        var size = frame.size
        if let p = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, p)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, s)
        }
        onStatus("restored window to \(Int(size.width))×\(Int(size.height)) pt")
        sharedAXWindow = nil
        originalWindowFrame = nil
    }

    /// Best AX window match for an SCWindow: same owning app, frame closest to
    /// the SCWindow's (no private CGWindowID→AX bridge; frame match is stable
    /// enough for the chrome actions).
    private func axWindow(for window: SCWindow) -> AXUIElement? {
        guard let pid = window.owningApplication?.processID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return nil }
        let target = window.frame
        var best: AXUIElement?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for candidate in axWindows {
            guard let frame = axFrame(candidate) else { continue }
            let d = abs(frame.origin.x - target.origin.x) + abs(frame.origin.y - target.origin.y)
                  + abs(frame.size.width - target.size.width) + abs(frame.size.height - target.size.height)
            if d < bestDist { bestDist = d; best = candidate }
        }
        return best
    }

    private func axFrame(_ ax: AXUIElement) -> CGRect? {
        var posVal: AnyObject?
        var sizeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let pv = posVal, CFGetTypeID(pv) == AXValueGetTypeID(),
              let sv = sizeVal, CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// A switched display restores 10 s after the last viewer leaves — the
    /// grace covers geometry-negotiation and flaky-radio reconnect cycles
    /// (an eager restore would undo the switch mid-handshake). Restoring
    /// also re-opens geometry negotiation for the next session.
    /// Main thread. Puts the display (or the shared window) back the way it
    /// was: at once when the viewer left on purpose (`clean`), else after a
    /// grace in which a dropped connection can come back.
    private func scheduleDisplayRestore(clean: Bool) {
        let grace = clean ? 0 : 5
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Single-window mode: after the grace (a transient reconnect cancels
            // it), put the shared window back to its original frame and revert
            // capture to the full display for the next session.
            if self.singleWindowID != 0 || self.originalWindowFrame != nil {
                self.pendingDisplayRestore?.cancel()
                self.onStatus(grace == 0 ? "viewer gone — restoring window" : "viewer gone — restoring window in \(grace)s")
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.restoreSharedWindowFrame()
                    if let display = self.savedDisplayFilter {
                        self.singleWindowID = 0
                        self.savedDisplayFilter = nil
                        self.lastFilter = display
                        let scale = CGFloat(display.pointPixelScale)
                        let pw = max(2, Int(display.contentRect.width * scale)) & ~1
                        let ph = max(2, Int(display.contentRect.height * scale)) & ~1
                        self.restartCapture(pixelWidth: pw, pixelHeight: ph, pointScale: scale,
                                            origin: display.contentRect.origin)
                    }
                }
                self.pendingDisplayRestore = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(grace), execute: work)
                return
            }
            // Restore after ANY geometry change — a display switch (Client
            // Resolution) OR a capture downscale (Scale). The latter leaves no
            // originalDisplayMode but still needs the capture rebuilt at native
            // (otherwise a Scale session leaves the capture at, say, 2940×1652
            // for the next Native session to inherit).
            guard self.captureModified else { return }
            self.pendingDisplayRestore?.cancel()
            self.pendingDisplayRestore = nil
            if grace == 0 {
                self.restoreToNative(status: "viewer gone — display/capture restored to native")
                return
            }
            self.onStatus("viewer gone — restoring in \(grace)s (or on Stop Sharing)")
            let work = DispatchWorkItem { [weak self] in
                self?.restoreToNative(status: "display/capture restored to native")
            }
            self.pendingDisplayRestore = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(grace), execute: work)
        }
    }

    /// Main thread. Undo a display switch / capture downscale and rebuild
    /// the capture at the native display size.
    private func restoreToNative(status: String) {
        pendingDisplayRestore?.cancel()
        pendingDisplayRestore = nil
        guard isRunning, captureModified else { return }
        let hadVirtual = virtualDisplay != nil
        restoreDisplayMode()      // no-op if only the capture was scaled
        geometrySettled = false
        captureModified = false
        lastScaleRequest = nil
        autoScaledDown = false    // native rebuild clears the rung
        onStatus(status)
        // The physical display's mode and bounds settle a moment after a
        // virtual display goes away.
        if hadVirtual {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restartCaptureAtNativeSize()
            }
        } else {
            restartCaptureAtNativeSize()
        }
    }

    /// Main thread. Rebuild the capture at the shared display's current mode.
    private func restartCaptureAtNativeSize() {
        guard isRunning else { return }
        let display = physicalDisplay
        let bounds = CGDisplayBounds(display)
        guard let mode = CGDisplayCopyDisplayMode(display) else { return }
        restartCapture(pixelWidth: mode.pixelWidth,
                       pixelHeight: mode.pixelHeight,
                       pointScale: CGFloat(mode.pixelWidth) / bounds.width,
                       origin: bounds.origin)
    }

    // MARK: - Virtual display (viewer's "Virtual Display" connect option)

    /// Main thread. geoMode 4: share a display made at the viewer's size.
    private func applyVirtualDisplay(widthPoints: Int, heightPoints: Int, scale: Int) {
        let s = max(1, min(2, scale))
        // Points may be odd at 2× (pixels are even either way): rounding a
        // 1470×923 full screen down to 922 would leave a 1 pt gap.
        var w = max(320, min(widthPoints, TileGrid.maxDimension / s))
        var h = max(200, min(heightPoints, TileGrid.maxDimension / s))
        if s == 1 { w &= ~1; h &= ~1 }
        if let vd = virtualDisplay, vd.widthPoints == w, vd.heightPoints == h, vd.scale == s,
           vd.isMirrored, vd.isInMode, captureWidth == w * s, captureHeight == h * s {
            captureModified = true
            onStatus("resize: virtual display already \(w)×\(h) — re-offering final")
            reofferGeometryFinal()
            return
        }
        // The viewer's window changed size: resize in place — same display,
        // mirroring kept, no teardown blink.
        if let vd = virtualDisplay, vd.scale == s, vd.resize(widthPoints: w, heightPoints: h) {
            captureModified = true
            appliedDisplaySize = (w, h)
            // Mirroring set up for the old size keeps the physical display
            // at it, and the desktop with it: the Dock would stay laid out
            // for 1470×923 on a 1382×763 display — below its bottom edge.
            // Un-mirror now; sharing re-mirrors once the new mode is in.
            vd.mirror(false)
            onStatus("virtual display → \(w)×\(h)")
            shareVirtualDisplayWhenReady(vd, attempt: 0)
            return
        }
        // Start from the plain physical display: undo a Client Resolution
        // switch or an older virtual display.
        let hadVirtual = virtualDisplay != nil
        restoreDisplayMode()
        if hadVirtual {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.applyVirtualDisplay(widthPoints: widthPoints, heightPoints: heightPoints, scale: scale)
            }
            return
        }
        guard let vd = VirtualDisplay.make(widthPoints: w, heightPoints: h, scale: s) else {
            onStatus("virtual display unavailable — using Client Resolution")
            applyResize(mode: Int(GeometryMode.clientResolution), widthPoints: widthPoints,
                        heightPoints: heightPoints, scale: scale)
            return
        }
        if physicalFilter == nil { physicalFilter = lastFilter }
        virtualDisplay = vd
        captureModified = true
        appliedDisplaySize = (w, h)
        appliedDisplayMode = nil
        onStatus("virtual display \(w)×\(h) @\(s)x created (id \(vd.displayID))")
        shareVirtualDisplayWhenReady(vd, attempt: 0)
    }

    /// Main thread: once the display is online, mirror the physical
    /// displays to it and move the capture onto it.
    private func shareVirtualDisplayWhenReady(_ vd: VirtualDisplay, attempt: Int) {
        guard isRunning, virtualDisplay === vd else { return }
        let retry = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.shareVirtualDisplayWhenReady(vd, attempt: attempt + 1)
            }
        }
        guard attempt < 30 else { // ~3 s
            onStatus("virtual display never came up — using Client Resolution")
            tearDownVirtualDisplay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.applyResize(mode: Int(GeometryMode.clientResolution), widthPoints: vd.widthPoints,
                                  heightPoints: vd.heightPoints, scale: vd.scale)
            }
            return
        }
        guard vd.isOnline, vd.selectMode() else { retry(); return }
        if !vd.isMirrored { vd.mirror(true) }
        Task { @MainActor in
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard self.isRunning, self.virtualDisplay === vd else { return }
            guard let display = content?.displays.first(where: { $0.displayID == vd.displayID }) else {
                // ScreenCaptureKit lists a new display a beat later.
                try? await Task.sleep(for: .milliseconds(100))
                self.shareVirtualDisplayWhenReady(vd, attempt: attempt + 1)
                return
            }
            self.lastFilter = SCContentFilter(display: display, excludingWindows: [])
            let bounds = CGDisplayBounds(vd.displayID)
            self.onStatus("virtual display \(vd.widthPoints)×\(vd.heightPoints) online"
                          + (vd.isMirrored ? ", desktop mirrored to it" : " (mirroring refused)") + " — sharing it")
            self.restartCapture(pixelWidth: vd.widthPoints * vd.scale, pixelHeight: vd.heightPoints * vd.scale,
                                pointScale: CGFloat(vd.scale), origin: bounds.origin, inSession: true)
        }
    }

    /// Main thread. Unmirror, drop the display, point capture back at the
    /// physical display (the caller rebuilds the capture).
    private func tearDownVirtualDisplay() {
        guard let vd = virtualDisplay else { return }
        vd.mirror(false)
        virtualDisplay = nil // releasing it removes the display
        if let physicalFilter { lastFilter = physicalFilter }
        physicalFilter = nil
        appliedDisplaySize = nil
        onStatus("virtual display removed")
    }

    private func restoreDisplayMode() {
        tearDownVirtualDisplay()
        appliedDisplaySize = nil
        appliedDisplayMode = nil
        if let original = originalDisplayMode {
            setDisplayMode(original, on: physicalDisplay)
            originalDisplayMode = nil
        }
    }

    /// Reliable display-mode switch via a configuration transaction. Bare
    /// CGDisplaySetDisplayMode silently no-ops in some contexts (a
    /// down-switch can take while the delayed restore does not); the
    /// begin/configure/complete transaction applies deterministically.
    @discardableResult
    private func setDisplayMode(_ mode: CGDisplayMode, on display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        // .forAppOnly: the system reverts the mode when this process exits —
        // including a crash or force-quit. `.permanently` would leave the
        // user's monitor at the viewer's resolution across logout and
        // reboot whenever the graceful restore path didn't run.
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    /// Follow the viewer's pause/resume hint (called on encodeQueue via the
    /// engine hook): 1 fps while paused, 60 otherwise.
    private func applyCaptureRate(paused: Bool) {
        DispatchQueue.main.async { [weak self] in self?.capture.setFrameRate(paused ? 1 : 60) }
    }

    /// Clean-benchmark recording: arm after `delay` (menu closed, screen
    /// settled), auto-stop after `duration` — the recorder never captures
    /// its own UI being operated (the stop menu's vibrancy blur can be 71 %
    /// of a typing trace's changes).
    func timedRecording(delaySeconds: Double = 5, durationSeconds: Double = 30) {
        onStatus("timed recording: starts in \(Int(delaySeconds)) s, runs \(Int(durationSeconds)) s — hands off the menu bar")
        encodeQueue.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self else { return }
            self.recordingArmed = true
            DispatchQueue.main.async { self.isRecording = true }
            self.onStatus("⏺ timed recording started")
            self.encodeQueue.asyncAfter(deadline: .now() + durationSeconds) { [weak self] in
                guard let self, self.recordingArmed || self.recorder != nil else { return }
                self.recordingArmed = false
                DispatchQueue.main.async { self.isRecording = false }
                self.closeRecorder(status: self.recorder != nil
                    ? "⏹ timed recording done — trace saved: \(self.recordName)"
                    : "⏹ timed recording done (no frames)")
            }
        }
    }

    func toggleRecording() {
        let arming = !isRecording
        isRecording = arming
        let capturing = isRunning
        encodeQueue.async { [self] in
            recordingArmed = arming
            if arming {
                onStatus(capturing
                    ? "recording armed — waiting for frames (move the cursor)"
                    : "recording armed — share a display first, then move the cursor")
            } else {
                closeRecorder(status: recorder != nil ? "trace saved: \(recordName)" : "recording cancelled")
            }
        }
    }

    /// encodeQueue only.
    private func closeRecorder(status: String) {
        var finishError: Error?
        if let recorder {
            do {
                try recorder.finish()
            } catch {
                finishError = error
            }
        }
        recorder = nil
        recordTight?.deallocate()
        recordTight = nil
        if let finishError {
            onStatus("trace finish failed: \(finishError)")
        } else {
            onStatus(status)
        }
    }

    // MARK: - Frames (capture's latest slot → encodeQueue)

    private func drain() {
        guard let taken = slot.take() else { return }
        let sampleBuffer = taken.buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer) // padded — stride-aware everywhere
        let frame = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        var rects = dirtyRects(from: sampleBuffer, width: width, height: height)
        if taken.overflowed {
            rects = nil
        } else if rects != nil {
            for attachments in taken.superseded {
                guard let more = dirtyRects(attachments: attachments, width: width, height: height) else {
                    rects = nil
                    break
                }
                rects! += more
            }
        }
        supersededFrames += taken.superseded.count
        let nowUS = MonotonicClock.nowUS
        // capture_ts (§3.3): SCK's presentation timestamp rides the host-time
        // clock — the same monotonic domain as MonotonicClock — so loopback
        // glass-to-glass includes SCK-internal and latest-slot latency.
        let pts = sampleBuffer.presentationTimeStamp
        let captureUS = pts.isValid && pts.seconds > 0 ? UInt64(pts.seconds * 1_000_000) : nowUS

        // Heartbeat: makes "is capture alive?" and rect-hint health visible.
        frameCount += 1
        if rects != nil { framesWithRects += 1 }
        if frameCount == 1 || frameCount % 120 == 0 {
            let recording = recorder != nil ? ", recording \(recordName) (\(recorder!.frameCount) frames)" : ""
            onStatus("capturing \(width)×\(height) — \(frameCount) frames, rects on \(framesWithRects), "
                     + "superseded \(supersededFrames)\(recording)")
        }

        frameWidth = width
        frameHeight = height
        bootstrapServerIfNeeded(width: width, height: height)
        record(frame: frame, bytesPerRow: bytesPerRow, width: width, height: height,
               rects: rects ?? [], nowUS: captureUS)
        guard let engine, engine.grid.width == width, engine.grid.height == height else { return }
        changeHotspots.note(rects, verdict: lastRectsVerdict) // only while a session reports (bounded tally)
        engine.encodeTick(frame: frame, bytesPerRow: bytesPerRow, dirtyRects: rects,
                          captureTimestampUS: captureUS, nowUS: nowUS)
        reportTelemetry(engine, nowUS: nowUS)
        lastFrame = sampleBuffer
        lastCaptureUS = nowUS
    }

    /// encodeQueue only (10 ms cadence). Position rides the control tunnel —
    /// measured to stay snappy even with the datagram path saturated — so
    /// the composited pointer moves at control latency, ahead of frames.
    private func publishCursorState(_ engine: HostEngine) {
        guard engine.cursorNegotiated else { return }
        if !cursorMetadataActive {
            cursorMetadataActive = true
            DispatchQueue.main.async { [weak self] in self?.enableCursorMetadata() }
        }
        guard let loc = CGEvent(source: nil)?.location else { return }
        let scale = mappingScale
        let x = Int((loc.x - contentOrigin.x) * scale)
        let y = Int((loc.y - contentOrigin.y) * scale)
        let visible = x >= 0 && y >= 0
            && x < frameWidth && y < frameHeight
        if x != lastCursorX || y != lastCursorY || visible != lastCursorVisible {
            lastCursorX = x
            lastCursorY = y
            lastCursorVisible = visible
            engine.publishCursor(x: max(0, x), y: max(0, y), visible: visible)
        }
    }

    /// Main thread: stop burning the pointer into pixels and start following
    /// the system cursor image (4 Hz + dedupe — shape changes are rare).
    private func enableCursorMetadata() {
        // NSCursor.currentSystem is on its way out ("will always be nil in a
        // future version of macOS", SDK 27) with no replacement for reading
        // the system cursor's image. Without it, keep the cursor burned into
        // the pixels rather than stream positions with no shape.
        guard NSCursor.currentSystem != nil else {
            onStatus("system cursor image unavailable — cursor stays in the pixels")
            return
        }
        capture.setShowsCursor(false)
        onStatus("cursor-as-metadata active (showsCursor off)")
        // Fresh session: forget the last-sent shape so the initial publish
        // below actually ships (the hash dedupe is per-connection state).
        lastCursorImageHash = 0
        lastCursorImageSend = .distantPast
        // 30 Hz poll, send-on-change: frequency costs only a tiny hash check —
        // bytes ship solely when the shape changes, so shape latency drops to
        // ≤33 ms with ~zero steady-state bandwidth. The min-send interval is
        // the safety valve against a pathologically flapping shape.
        cursorImageTimer?.invalidate()
        cursorImageTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.publishCursorImageIfChanged()
        }
        publishCursorImageIfChanged()
    }

    /// Main thread. NSCursor.currentSystem tracks the system-wide pointer.
    private func publishCursorImageIfChanged() {
        // No fallback to NSCursor.current: that is THIS app's cursor, not
        // the one on screen.
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let rep = image.representations
            .compactMap({ $0 as? NSBitmapImageRep }).first
            ?? tiffRep(of: image) else { return }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w >= 1, h >= 1, w <= 512, h <= 512, image.size.width > 0 else { return }
        let scale = max(1, Int((CGFloat(w) / image.size.width).rounded()))
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bgra.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue),
                  let cg = rep.cgImage else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return }
        var hasher = Hasher()
        hasher.combine(bgra)
        let hash = hasher.finalize()
        guard hash != lastCursorImageHash,
              Date().timeIntervalSince(lastCursorImageSend) > 0.05 else { return }
        lastCursorImageHash = hash
        lastCursorImageSend = Date()
        let hx = Int(cursor.hotSpot.x * CGFloat(scale))
        let hy = Int(cursor.hotSpot.y * CGFloat(scale))
        encodeQueue.async { [weak self, bgra] in
            self?.engine?.publishCursorImage(width: w, height: h, hotspotX: hx, hotspotY: hy,
                                             scale: scale, bgra: bgra)
        }
    }

    private func tiffRep(of image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// encodeQueue only. Synthetic encode tick from the retained frame while
    /// captures are quiet but the engine still has deliverable work.
    private func drainPendingWhileStatic(nowUS: UInt64) {
        guard let engine, engine.state == .running,
              nowUS &- lastCaptureUS > 100_000,          // captures have gone quiet
              nowUS &- lastSyntheticTickUS > 33_000,     // ~30 Hz drain cadence
              engine.stats.lastTickQualifiedTiles > 0
                || engine.pendingRepaintTiles > 0
                || engine.openBatchCount > 0,
              let sampleBuffer = lastFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSyntheticTickUS = nowUS
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let frame = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        engine.encodeTick(frame: frame, bytesPerRow: bytesPerRow, dirtyRects: nil,
                          captureTimestampUS: nowUS, nowUS: nowUS)
        reportTelemetry(engine, nowUS: nowUS)
    }

    /// encodeQueue only. Instant lines on lifecycle transitions; rolling
    /// rates every ~2 s alongside the capture heartbeat.
    private func reportTelemetry(_ engine: HostEngine, nowUS: UInt64) {
        let s = engine.stats
        // New session's engine: its counters restart at 0. Identity alone
        // misses it when the new engine reuses the old one's address (a
        // `bw -143711 Kbps` line); counters going backwards can't lie.
        let p0 = telePrevStats
        if telePrevEngine != ObjectIdentifier(engine) || s.bytesOut < p0.bytesOut
            || s.tilesSent < p0.tilesSent || s.videoFramesSent < p0.videoFramesSent {
            telePrevEngine = ObjectIdentifier(engine)
            telePrevStats = HostStats()
            telePrevUS = nowUS
        }
        let p = telePrevStats
        if s.videoRegionsFormed != p.videoRegionsFormed {
            onStatus("▶ video region FORMED — codec \(VideoCodec.name(engine.activeVideoCodec))")
        }
        if s.videoRegionsDissolved != p.videoRegionsDissolved {
            onStatus("■ video region DISSOLVED — lossless repaint queued")
        }
        if s.videoRefreshes != p.videoRefreshes {
            // Soft text that never sharpens while this never shows = the
            // re-sharpen isn't triggering; soft right after it = the
            // keyframe itself is starved (vcap).
            let cap = engine.videoRate.bitrateCap.map { String(format: "%.2f Mbps", Double($0) / 1e6) } ?? "none"
            onStatus("◆ video RE-SHARPENED — keyframe after the screen settled (vcap \(cap))")
        }
        if telePrevUS == 0 { telePrevUS = nowUS }
        let dtUS = nowUS &- telePrevUS
        if dtUS >= 2_000_000 {
            let dt = Double(dtUS) / 1_000_000
            // Bitrate (not byterate): Kbps/Mbps, decimal kilo like every
            // network tool.
            let kbps = Double(s.bytesOut - p.bytesOut) * 8 / dt / 1000
            let videoKbps = Double(s.videoBytesSent - p.videoBytesSent) * 8 / dt / 1000
            let tiles = s.tilesSent - p.tilesSent
            let refs = s.cacheRefsSent - p.cacheRefsSent
            let scrolls = s.scrollsSent - p.scrollsSent
            let dropped = s.batchesDropped - p.batchesDropped
            var line = kbps >= 1000
                ? String(format: "bw %.1f Mbps", kbps / 1000)
                : String(format: "bw %.0f Kbps", kbps)
            if engine.activeVideoRegionCount > 0 {
                let fps = Double(s.videoFramesSent - p.videoFramesSent) / dt
                let video = videoKbps >= 1000
                    ? String(format: "%.1f Mbps", videoKbps / 1000)
                    : String(format: "%.0f Kbps", videoKbps)
                line += String(format: " (video %@, %.0f fps, %@)",
                               video, fps, VideoCodec.name(engine.activeVideoCodec))
            }
            line += " · tiles \(tiles)"
            if refs > 0 { line += " · cache-refs \(refs)" }
            if scrolls > 0 { line += " · scrolls \(scrolls)" }
            if dropped > 0 { line += " · capture-drops \(dropped)" }
            let qdown = s.qualityDowngrades - p.qualityDowngrades
            let qup = s.qualityUpgrades - p.qualityUpgrades
            if qdown > 0 { line += " · quality↓\(qdown)" }
            if qup > 0 { line += " · quality↑\(qup)" }
            let sharpOn = s.sharpCeilingOn - p.sharpCeilingOn
            let sharpOff = s.sharpCeilingOff - p.sharpCeilingOff
            if sharpOn > 0 { line += " · sharp on" }
            if sharpOff > 0 { line += " · sharp off (pressure)" }
            // Still region tiles handed back to exact pixels while video runs
            // (free reveals, lossless records) — soft text with neither
            // showing means the handoff isn't firing.
            let reveals = s.overlayHandoffReveals - p.overlayHandoffReveals
            let records = s.overlayHandoffRecords - p.overlayHandoffRecords
            if reveals > 0 || records > 0 { line += " · handoff reveal \(reveals) record \(records)" }
            let nacks = s.deltaNacksRepaired - p.deltaNacksRepaired
            let digests = s.scrollDigestRepairs - p.scrollDigestRepairs
            let deferred = s.governorDeferredTiles - p.governorDeferredTiles
            if nacks > 0 { line += " · nack-repairs \(nacks)" }
            if digests > 0 { line += " · digest-repairs \(digests)" }
            if deferred > 0 { line += " · gov-deferred \(deferred)" }
            line += String(format: " · srtt %.1f ms · path %.0f ms · pace %.0f MB/s · rate %.1f MB/s · encode %d%%",
                           Double(engine.srttUS) / 1000, Double(engine.ackDelayUS) / 1000,
                           Double(s.datagramPaceRate) / 1e6, Double(s.governorRate) / 1e6, s.encodeDutyPercent)
            if engine.activeVideoRegionCount > 0 {
                // Video send control (VideoRateController): link estimate,
                // encoder cap, network queue, frames skipped by the gate.
                let skips = s.videoBacklogSkips - p.videoBacklogSkips
                // vlink/vcap stay unmeasured until the video stream first
                // backs up — a link that keeps up is never capped.
                let link = engine.videoRate.rate == 0 ? "unmeasured"
                    : String(format: "%.2f Mbps", Double(engine.videoRate.rate * 8) / 1e6)
                let cap = engine.videoRate.bitrateCap.map { String(format: "%.2f Mbps", Double($0) / 1e6) } ?? "none"
                line += " · vlink \(link) · vcap \(cap)"
                line += String(format: " · netq %.0f ms · vskips %d",
                               Double(engine.videoNetworkQueueUS ?? 0) / 1000, skips)
                // The encoder's side: frames skipped because it was still
                // busy, and its mean submit → delivery time.
                let encoded = s.videoEncodeCount - p.videoEncodeCount
                let encodeMS = encoded > 0
                    ? Double(s.videoEncodeUSSum &- p.videoEncodeUSSum) / Double(encoded) / 1000 : 0
                line += String(format: " · vfull %d · venc %.1f ms",
                               s.videoEncoderFullSkips - p.videoEncoderFullSkips, encodeMS)
            }
            line += " · " + changeHotspots.summaryAndReset()
            onStatus(line)
            telePrevStats = s
            telePrevUS = nowUS
        } else {
            // Transition detection must not wait for the heartbeat window.
            telePrevStats.videoRegionsFormed = s.videoRegionsFormed
            telePrevStats.videoRegionsDissolved = s.videoRegionsDissolved
            telePrevStats.videoRefreshes = s.videoRefreshes
        }
    }

    /// Dirty rects are hints only (§4.3); on any parse doubt return nil (full
    /// scan — the hash gate keeps it correct either way).
    private func dirtyRects(from sampleBuffer: CMSampleBuffer, width: Int, height: Int) -> [DirtyRect]? {
        guard let attachments = FrameInfo.attachments(of: sampleBuffer) else {
            lastRectsVerdict = .noAttachments
            return nil
        }
        return dirtyRects(attachments: attachments, width: width, height: height)
    }

    private func dirtyRects(attachments: [SCStreamFrameInfo: Any], width: Int, height: Int) -> [DirtyRect]? {
        if frameCount < 3 {
            // One-shot shape dump: what does the attachment actually look like?
            let value = attachments[.dirtyRects]
            print("glassact-host: dirtyRects attachment type=\(value.map { String(describing: type(of: $0)) } ?? "ABSENT") "
                + "value=\(String(describing: value).prefix(400))")
        }
        let read = FrameInfo.dirtyRects(attachments, frameWidth: width, frameHeight: height)
        lastRectsVerdict = read.verdict
        return read.rects
    }

    private var lastRectsVerdict = FrameInfo.DirtyRectVerdict.ok

    // MARK: - Transport wiring

    /// encodeQueue (first captured frame). The server itself is main-thread
    /// state — creating it right here would race stop() (a queued drain
    /// after Stop Sharing would re-create the listener).
    private func bootstrapServerIfNeeded(width: Int, height: Int) {
        guard !serverRequested else { return }
        serverRequested = true
        DispatchQueue.main.async { [weak self] in self?.ensureServer(width: width, height: height) }
    }

    /// Main thread. Creates the listener if sharing and none exists; a
    /// listener failure (port in use, interface loss) retries every 2 s.
    private func ensureServer(width: Int, height: Int) {
        guard isRunning else {
            // A frame drained just after stop(): un-latch so the next share
            // bootstraps a listener again.
            encodeQueue.async { [weak self] in self?.serverRequested = false }
            return
        }
        if captureWidth == 0 { captureWidth = width; captureHeight = height }
        guard server == nil, let identity else { return }
        do {
            let gate = signInGate
            let srv = try QUICServer(port: Self.controlPort, identity: identity,
                                     authorizePeer: { [weak self] peer in
                                         self?.authorize(peer: peer) ?? false
                                     },
                                     signIn: { request, peer, address, reply in
                                         gate.handle(request, peer: peer, address: address, reply: reply)
                                     })
            srv.onTransport = { [weak self] transport in
                DispatchQueue.main.async { self?.adopt(transport) }
            }
            srv.onReady = { [weak self] in
                self?.onStatus("listening on \(Self.controlPort) (\(width)×\(height))")
                DispatchQueue.main.async {
                    guard let self, self.isRunning, !self.viewerSessionLive else { return }
                    self.phase = .listening
                }
            }
            srv.onFailed = { [weak self, weak srv] reason in
                DispatchQueue.main.async {
                    guard let self, let srv, self.server === srv else { return }
                    self.server = nil
                    self.onStatus("\(reason) — retrying in 2 s")
                    self.retryServer()
                }
            }
            srv.start()
            server = srv
        } catch {
            onStatus("listen failed: \(error) — retrying in 2 s")
            retryServer()
        }
    }

    private func retryServer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isRunning, self.server == nil else { return }
            self.ensureServer(width: self.captureWidth, height: self.captureHeight)
        }
    }

    // MARK: - Lock screen on disconnect

    static let lockOnDisconnectKey = "glassact.lockOnDisconnect"
    /// A viewer that isn't back within this long is gone, not a Wi-Fi blip
    /// (the viewer's reconnect policy retries within seconds).
    static let lockGraceSeconds = 30

    /// Main thread. Persisted; default on — a remote session must not leave
    /// the Mac unlocked and unattended when the viewer drops.
    var lockOnDisconnect: Bool {
        get { UserDefaults.standard.object(forKey: Self.lockOnDisconnectKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.lockOnDisconnectKey)
            if !newValue {
                pendingLock?.cancel(); pendingLock = nil
            }
            onStatus(newValue ? "lock on disconnect: on" : "lock on disconnect: off")
        }
    }

    /// Main thread: lock unless a viewer is back or sharing was stopped
    /// locally (someone is at the Mac). A viewer that left on purpose
    /// (`clean`) gets it a second later, once the display restore has
    /// settled (macOS refuses mode changes at the lock screen); a dropped
    /// connection gets `lockGraceSeconds` to come back.
    private func scheduleLockAfterDisconnect(clean: Bool) {
        guard lockOnDisconnect else { return }
        guard lockedWhenViewerArrived else {
            onStatus("viewer gone — leaving the screen unlocked, as it was when the viewer connected")
            return
        }
        pendingLock?.cancel()
        let delay = clean ? 1 : Self.lockGraceSeconds
        onStatus(clean ? "viewer left — locking the screen"
                       : "viewer gone — locking the screen in \(delay)s unless it reconnects")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.lockOnDisconnect, !self.viewerSessionLive else { return }
            self.pendingLock = nil
            MainActor.assumeIsolated { self.lockScreen { locked in
                if locked {
                    self.onStatus("screen locked (viewer disconnected)")
                } else {
                    self.onStatus("couldn't lock the screen — is ⌃⌘Q still the Lock Screen shortcut, "
                                  + "and does Glass Act Host have Device Control?")
                }
            } }
        }
        pendingLock = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay), execute: work)
    }

    /// Main thread. Locks the session with ⌃⌘Q, the system's own Lock
    /// Screen shortcut, posted as keystrokes: public API, using the
    /// Accessibility grant remote input already needs. `done` gets whether
    /// the screen actually locked, from the system's `screenIsLocked`
    /// notification within 2 s, so a remapped shortcut or a missing grant
    /// reports failure instead of a false "locked".
    @MainActor private func lockScreen(then done: @escaping @MainActor (Bool) -> Void) {
        if Self.screenIsLocked { done(true); return }
        let center = DistributedNotificationCenter.default()
        let state = LockAttempt()
        state.observer = center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { state.finish(true, done) }
        }
        let q: CGKeyCode = 12
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: q, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: q, keyDown: false) {
            down.flags = [.maskControl, .maskCommand]
            up.flags = [.maskControl, .maskCommand]
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { state.finish(Self.screenIsLocked, done) }
        }
    }

    /// One lock attempt: answers once, then stops listening (main thread).
    @MainActor private final class LockAttempt {
        var observer: (any NSObjectProtocol)?
        private var answered = false
        func finish(_ locked: Bool, _ done: @MainActor (Bool) -> Void) {
            guard !answered else { return }
            answered = true
            if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
            done(locked)
        }
    }

    /// The session's screen is locked (CGSessionCopyCurrentDictionary).
    static var screenIsLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    // MARK: - Bandwidth setting

    static let bandwidthDefaultsKey = "glassact.bandwidthLimitMbit"
    /// 0 = Auto (follow the link). Choices offered in the menu.
    static let bandwidthChoicesMbit = [0, 25, 50, 100]

    /// Main thread. Persisted; the default (nothing stored) is Auto.
    var bandwidthLimitMbit: Int {
        get { UserDefaults.standard.integer(forKey: Self.bandwidthDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.bandwidthDefaultsKey)
            let limit = Self.rateLimit(forMbit: newValue)
            encodeQueue.async { [weak self] in self?.engine?.rateLimit = limit } // live session too
            onStatus(newValue == 0 ? "bandwidth: auto (follows the link)" : "bandwidth: limited to \(newValue) Mbit/s")
        }
    }

    static func rateLimit(forMbit mbit: Int) -> RateLimit {
        mbit > 0 ? .megabits(mbit) : .auto
    }

    /// Build + wire a HostEngine (all engine.onX callbacks + caps). Shared by
    /// the initial session and in-session geometry rebuilds (§4.10). Transport
    /// handlers route through `self.engine`, so swapping `self.engine` to the
    /// engine returned here is all a rebuild needs.
    private func makeEngine(on transport: QUICTransport, width: Int, height: Int,
                            startFrameSeq: UInt32) -> HostEngine {
        let encodeQueue = self.encodeQueue
        // Video (§4.6): pinned full-screen hardware HEVC, or software AV1
        // when the Viewer opted in (it advertises AV1 only then). AV1 comes
        // first, so a Viewer that asks for it gets it; on Intel libaom isn't
        // compiled in and only HEVC is offered.
        let video = Self.videoEnabled
        let engine = HostEngine(
            width: width, height: height, transport: transport,
            videoEncoderFactory: video ? { codec in
                switch codec {
                case VideoCodec.hevc: VTHEVCRegionEncoder(callbackQueue: encodeQueue)
                case VideoCodec.av1: AOMRegionEncoder(callbackQueue: encodeQueue)
                default: nil
                }
            } : nil,
            videoCodecPreference: AOMRegionEncoder.isAvailable ? [VideoCodec.av1, VideoCodec.hevc] : [VideoCodec.hevc],
            startFrameSeq: startFrameSeq,
            clock: { MonotonicClock.nowUS })
        // Always advertise single-window support (Screen Recording is a
        // runtime gate handled at enumeration — gating the cap would deadlock).
        // A settled geometry is only final while the display is still in the
        // mode it settled on: if the display left it (macOS can revert it
        // between reconnects), let the viewer's request through.
        if geometrySettled, let applied = appliedDisplaySize {
            let now = CGDisplayBounds(physicalDisplay).size
            if Int(now.width) != applied.width || Int(now.height) != applied.height {
                onStatus("display is \(Int(now.width))×\(Int(now.height)), not the \(applied.width)×\(applied.height) "
                         + "set for the viewer — renegotiating geometry")
                geometrySettled = false
            }
        }
        engine.extraHelloCaps = (geometrySettled ? WireCaps.geometryFinal : 0) | WireCaps.windowList | WireCaps.logUpload
            | WireCaps.agentControl
            | (VirtualDisplay.isAvailable ? WireCaps.virtualDisplay : 0)
        engine.rateLimit = Self.rateLimit(forMbit: bandwidthLimitMbit)
        if !video {
            onStatus("GLASSACT_TILE_ONLY: video off — lossless tiles only")
        }
        // First-picture timing, host half (the viewer logs `first_picture`):
        // the first video frame's size and encode time, and how long after
        // the connection it left.
        engine.onFirstVideoFrame = { [weak self] bytes, sync, encodeUS in
            guard let self else { return }
            let sinceConnect = self.viewerConnectedUS == 0 ? "-"
                : String((MonotonicClock.nowUS &- self.viewerConnectedUS) / 1000)
            self.onStatus("first video frame: \(bytes / 1024) KB \(sync ? "keyframe" : "delta"), encode "
                          + "\(encodeUS / 1000) ms, handed \(sinceConnect) ms after connect")
        }
        engine.onVideoCodecChanged = { [weak self] codec in
            self?.onStatus(codec.map { "video codec: \(VideoCodec.name($0))" }
                           ?? "video off — lossless tiles")
        }
        // Cursor state is SESSION-scoped, but lives on the controller: without
        // this reset, only the first session after app launch would receive
        // the cursor image (the metadata latch stays set and the image
        // resends only on a shape-hash change): hover works, but no cursor
        // shows after a reconnect.
        cursorMetadataActive = false
        lastCursorX = Int.min
        lastCursorY = Int.min
        lastCursorVisible = false
        engine.onInput = { [weak self] kind, cx, cy, a, b in
            self?.injectInput(kind: kind, canvasX: cx, canvasY: cy, a: a, b: b)
        }
        engine.onClipboard = { [weak self] format, data in
            guard let self else { return }
            if let denial = self.agentAccess.admit(agentInput: self.agentAccess.sessionIsAgent) {
                self.agentAudit.denied("clipboard", denial.reason)
                return
            }
            if self.agentAccess.sessionIsAgent { self.agentAudit.log("\(self.agentTag) set the clipboard (\(data.count) bytes)") }
            DispatchQueue.main.async { self.applyInboundClipboard(format, data) }
        }
        engine.onTextInput = { [weak self] text in
            guard let self else { return }
            if let denial = self.agentAccess.admit(agentInput: true) {
                self.agentAudit.denied("typing", denial.reason)
                return
            }
            self.agentAudit.log("\(self.agentTag) typed \(text.count) characters")
            self.injectText(text)
        }
        engine.onAgentState = { [weak self, weak engine] active, label in
            guard let self else { return }
            // A headless agent's name goes on its approval (a person's viewer
            // keeps its own identity even while an agent borrows it).
            if let peer = self.sessionTransport?.peerCertificate, peer.isAgent {
                self.authorizedViewers.noteLabel(peer.fingerprint, label: label)
                self.approvalsChanged()
            }
            if self.agentAccess.agentState(active: active, label: label) {
                self.agentAudit.log(active ? "\(self.agentTag) started driving (\(self.sessionPeerSummary))"
                                           : "agent \(label) stopped driving")
                self.onStatus(active ? "an agent (\(label)) is driving this Mac" : "the agent stopped driving")
            }
            let scope = self.agentAccess.scope()
            engine?.sendAgentScope(control: scope.control, reason: scope.reason)
        }
        engine.onViewerInfo = { [weak self] name in
            guard let self, let peer = self.sessionTransport?.peerCertificate else { return }
            self.authorizedViewers.noteDevice(peer.fingerprint, device: name)
            self.approvalsChanged()
        }
        engine.onUITreeRequest = { [weak self] requestID, windowID, maxNodes in
            guard let self else { return }
            self.agentAudit.log("\(self.agentTag) read the UI tree\(windowID == 0 ? "" : " of window \(windowID)")")
            let scale = self.mappingScale, origin = self.contentOrigin
            let engineQueue = self.encodeQueue
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let answer = UITreeBuilder.build(windowID: windowID, maxNodes: maxNodes) { rect in
                    CGRect(x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale,
                           width: rect.width * scale, height: rect.height * scale)
                }
                // The live engine (an in-session geometry rebuild may have replaced it).
                engineQueue.async { [weak self] in
                    self?.engine?.sendUITree(requestID: requestID, status: answer.status, json: answer.json)
                }
            }
        }
        engine.onResizeRequested = { [weak self] mode, w, h, scale in
            guard let self else { return }
            self.onStatus("geometry requested: mode \(mode) \(w)×\(h) @\(scale)x")
            DispatchQueue.main.async {
                if mode == 3 && !self.captureModified {
                    self.onStatus("already native — proceeding")
                    self.encodeQueue.async { self.engine?.reofferHelloFinal(nowUS: MonotonicClock.nowUS) }
                } else {
                    self.applyResize(mode: mode, widthPoints: w, heightPoints: h, scale: scale)
                }
            }
        }
        engine.onPausedChanged = { [weak self] paused in
            self?.applyCaptureRate(paused: paused)
            self?.onStatus(paused ? "viewer occluded — content paused (keep-alives only)"
                                  : "viewer visible — capture at full rate")
        }
        engine.onWindowSelect = { [weak self] windowID in
            guard let self else { return }
            // Listing windows (id 0 when not sharing one) only reads; picking one
            // changes what's shared — not for a view-only key.
            if windowID != 0, let denial = self.agentAccess.admit(agentInput: self.agentAccess.sessionIsAgent) {
                self.agentAudit.denied("window select", denial.reason)
                return
            }
            DispatchQueue.main.async { self.handleWindowSelect(windowID) }
        }
        engine.onWindowControl = { [weak self] action, width, height in
            guard let self else { return }
            if action != WindowAction.endSession,
               let denial = self.agentAccess.admit(agentInput: self.agentAccess.sessionIsAgent) {
                self.agentAudit.denied("window control", denial.reason)
                return
            }
            DispatchQueue.main.async { self.handleWindowControl(action, width: Int(width), height: Int(height)) }
        }
        engine.onViewerLog = { [weak self] name, offset, total, data in
            self?.logInbox.receive(name: name, offset: Int(offset), total: Int(total), data: data) { [weak self] text in
                self?.onStatus(text)
            }
        }
        engine.onScalePressureConstrained = { [weak self] in
            DispatchQueue.main.async { self?.handleScalePressureConstrained() }
        }
        // Terminal engine failure: end the transport; its terminal state
        // (identity-checked on main) tears the session down.
        engine.onFailed = { [weak self, weak transport] reason in
            self?.onStatus("session failed — \(reason)")
            transport?.cancel()
        }
        return engine
    }

    /// Auto-scale (main thread): halve the capture under sustained severe
    /// link pressure — fewer pixels shrink video bitrate and settle size
    /// together. One rung, latched for the session: native
    /// restores on disconnect (the captureModified grace path), never
    /// mid-session. Uses the in-session renegotiation (re-HELLO, no
    /// reconnect). Full-display sessions only (window sessions are already
    /// small and host-authoritative over their geometry).
    private func handleScalePressureConstrained() {
        guard isRunning, singleWindowID == 0 else { return }
        guard !autoScaledDown else { return }          // already down a rung
        guard captureWidth >= 1920 else { return }     // too small to be worth halving
        autoScaledDown = true
        captureModified = true // disconnect grace restores to native
        let pw = (captureWidth / 2) & ~1
        let ph = (captureHeight / 2) & ~1
        onStatus("link constrained — auto-scaling capture to \(pw)×\(ph) (restores on disconnect)")
        restartCapture(pixelWidth: pw, pixelHeight: ph, pointScale: pixelScale / 2,
                       origin: contentOrigin, inSession: true)
    }

    /// In-session geometry change (§4.10): rebuild the engine at new
    /// dimensions on the SAME transport (no reconnect). Seeds nextFrameSeq
    /// from the outgoing engine so the LWW domain stays monotonic across the
    /// swap, then re-HELLOs the viewer with the new size (it reconfigures its
    /// canvas in place). encodeQueue only.
    private func reconfigureEngineInSession(width: Int, height: Int) {
        guard let transport = sessionTransport else { return }
        let seed = engine?.currentFrameSeq ?? 1
        let newEngine = makeEngine(on: transport, width: width, height: height, startFrameSeq: seed)
        engine = newEngine
        DispatchQueue.main.async { [weak self] in
            self?.captureWidth = width
            self?.captureHeight = height
        }
        newEngine.start(nowUS: MonotonicClock.nowUS) // HELLO at the new dims
        onStatus("in-session geometry → \(width)×\(height) (seq \(seed))")
    }

    /// Main thread. A new viewer session. Anything left of a previous one
    /// is torn down first — the server only hands us a new transport after
    /// the old one ended (or was superseded while still establishing), so
    /// this also cancels its tick timer, which would otherwise pile up (one
    /// more 10 ms timer per reconnect, all ticking the engine).
    private func adopt(_ transport: QUICTransport) {
        guard isRunning else {
            transport.cancel()
            return
        }
        endSession()
        self.transport = transport
        let fallback = (captureWidth, captureHeight)
        encodeQueue.async { [weak self] in
            guard let self else { return }
            // The engine must match the frames actually arriving.
            let width = self.frameWidth > 0 ? self.frameWidth : fallback.0
            let height = self.frameHeight > 0 ? self.frameHeight : fallback.1
            self.engine = self.makeEngine(on: transport, width: width, height: height, startFrameSeq: 1)
            self.sessionTransport = transport
        }
        // Clipboard sync is session-scoped (one timer), not per engine rebuild.
        startClipboardSync { [weak self] fmt, data in
            guard let self else { return }
            self.encodeQueue.async { self.engine?.sendClipboard(format: fmt, data: data) }
        }
        // Route control through self.engine (not a captured engine) so an
        // in-session geometry rebuild (§4.10) swaps the engine transparently.
        transport.onControl = { [weak self] data in
            guard let self else { return }
            // Stamp ARRIVAL, on the transport queue: read after the hop, a
            // message that lands during a slow encode tick (a cold start,
            // a keyframe) would be timed at the tick's end — ACK delay and
            // SRTT samples inflated by host CPU time, which the governor and
            // auto-scale read as a congested path.
            let arrivedUS = MonotonicClock.nowUS
            self.encodeQueue.async {
                guard let engine = self.engine else { return }
                let wasRunning = engine.state == .running
                engine.handleControl(data, nowUS: arrivedUS)
                if !wasRunning && engine.state == .running {
                    self.onStatus("handshake complete — streaming to viewer")
                }
            }
        }
        transport.onVideoReset = { [weak self] in
            guard let self else { return }
            self.encodeQueue.async { self.engine?.videoChannelReset() }
        }
        transport.onState = { [weak self, weak transport] state in
            DispatchQueue.main.async {
                guard let self, let transport, self.transport === transport else { return }
                self.transportStateChanged(state)
            }
        }
        transport.start()

        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        // Handshake deadline + PONG liveness (package logic, tested there);
        // timer handler only, i.e. encodeQueue.
        var watchdog = HostSessionWatchdog()
        timer.setEventHandler { [weak self] in
            guard let self, let engine = self.engine else { return }
            let now = MonotonicClock.nowUS
            engine.tick(nowUS: now)
            self.drainPendingWhileStatic(nowUS: now)
            self.publishCursorState(engine)
            if case let .reset(reason) = watchdog.check(engine, nowUS: now) {
                self.resetSessionFromTimer("\(reason) — session reset")
            }
        }
        timer.resume()
        tickTimer = timer
    }

    /// encodeQueue (tick timer). The transport's resulting terminal state
    /// runs the normal teardown on main.
    private func resetSessionFromTimer(_ status: String) {
        engine = nil
        DispatchQueue.main.async { [weak self] in
            self?.server?.resetSession()
            self?.onStatus(status)
        }
    }

    /// Main thread; identity-checked by the caller (the live transport).
    private func transportStateChanged(_ state: TransportState) {
        switch state {
        case .ready:
            if pendingLock == nil {
                lockedWhenViewerArrived = Self.screenIsLocked
            }
            pendingDisplayRestore?.cancel()
            pendingDisplayRestore = nil
            pendingLock?.cancel()
            pendingLock = nil
            viewerSessionLive = true
            holdDisplayAwake(true)
            // Capture died while nobody watched (display slept, screen
            // locked): the display is waking now — try again right away.
            if isRunning { capture.retryNow() }
            let connectedUS = MonotonicClock.nowUS
            encodeQueue.async { [weak self] in
                self?.viewerConnectedUS = connectedUS
                self?.engine?.start(nowUS: MonotonicClock.nowUS)
            }
            viewerConnectedAt = Date()
            phase = .viewerConnected
            let peer = transport?.peerCertificate
            agentAccess.beginSession(peer: peer, viewOnly: peer.map { authorizedViewers.isViewOnly($0.fingerprint) } ?? false)
            if let peer {
                authorizedViewers.noteSeen(peer.fingerprint, kind: peer.isAgent ? .agent : .viewer,
                                           address: transport?.remoteAddress ?? "")
                approvalsChanged()
            }
            if peer?.isAgent == true { agentAudit.log("agent connected (\(sessionPeerSummary))") }
            onStatus(peer?.isAgent == true ? "agent connected" : "viewer connected")
        case .failed, .cancelled:
            let reason = transport?.lastFailReason ?? ""
            let clean = transport?.peerClosedCleanly ?? false
            let hadSession = viewerSessionLive
            viewerSessionLive = false
            viewerConnectedAt = nil
            if agentAccess.snapshot.agentActive { agentAudit.log("\(agentTag) disconnected") }
            // A headless agent leaving isn't the person walking away: no lock.
            let agentLeft = agentAccess.sessionIsAgent
            agentAccess.endSession()
            if isRunning { phase = .listening }
            holdDisplayAwake(false)
            endSession()
            server?.resetSession()
            onStatus("viewer disconnected" + (reason.isEmpty ? "" : " — \(reason)"))
            if isRunning { scheduleDisplayRestore(clean: clean) }
            if isRunning && hadSession && !agentLeft { scheduleLockAfterDisconnect(clean: clean) }
        case .connecting:
            break
        }
    }

    /// Main thread. Drop the current session's transport, timer, and engine.
    private func endSession() {
        tickTimer?.cancel()
        tickTimer = nil
        let ending = transport
        transport = nil
        ending?.cancel() // no-op if it already ended
        encodeQueue.async { [weak self] in
            self?.engine = nil
            self?.sessionTransport = nil
        }
    }

    // MARK: - §7 recorder (host-side flag)

    private func record(frame: UnsafeRawBufferPointer, bytesPerRow: Int,
                        width: Int, height: Int, rects: [DirtyRect], nowUS: UInt64) {
        guard recordingArmed else { return }
        // The trace format has one geometry per file, and recordTight is
        // sized from the first frame: a geometry change mid-recording (RESIZE,
        // window pick, auto-scale, native restore) would write larger frames
        // past the buffer. Close this file and continue in a new one.
        if let current = recorder, current.header.width != width || current.header.height != height {
            closeRecorder(status: "geometry changed — trace saved: \(recordName); continuing in a new file")
        }
        if recorder == nil {
            // Application Support/Glass Act/traces avoids the Desktop/Documents folder-access TCC
            // prompts that silently eat writes from Xcode-launched builds.
            let dir = AppPaths.dataDirectory.appendingPathComponent("traces")
            let name = "glassact-\(Int(Date().timeIntervalSince1970)).scap"
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                recorder = try ScapWriter(url: dir.appendingPathComponent(name), width: width, height: height)
                recordTight = .allocate(byteCount: width * height * 4, alignment: 64)
                recordName = name
                onStatus("recording \(name)")
            } catch {
                disarmRecording(reason: "recording failed to start: \(error)")
                return
            }
        }
        guard let recorder, let tight = recordTight else { return }
        let srcBase = frame.baseAddress!
        let dstBase = tight.baseAddress!
        for row in 0..<height {
            dstBase.advanced(by: row * width * 4)
                .copyMemory(from: srcBase.advanced(by: row * bytesPerRow), byteCount: width * 4)
        }
        do {
            try recorder.appendFrame(timestampUS: nowUS, dirtyRects: rects,
                                     frame: UnsafeRawBufferPointer(tight))
        } catch {
            disarmRecording(reason: "recording failed mid-trace (frame \(recorder.frameCount)): \(error)")
        }
    }

    /// encodeQueue only.
    private func disarmRecording(reason: String) {
        recordingArmed = false
        recorder = nil
        recordTight?.deallocate()
        recordTight = nil
        DispatchQueue.main.async { self.isRecording = false }
        onStatus(reason)
    }
}

/// Where the screen changes: SCK dirty rects over a status interval,
/// tallied by tile-aligned box, so a status line can say "the 128×64 box at
/// (2752,40) changed 60 times" — a clock, a spinner, a blinking caret —
/// instead of leaving an idle session's traffic unexplained. Telemetry
/// only, off the pixel path (a few rects per frame). encodeQueue only.
struct ChangeHotspots {
    private var counts: [UInt64: Int] = [:]
    private var framesChanged = 0
    private var framesTotal = 0
    private var framesNoRects = 0
    private var verdicts: [String: Int] = [:]

    mutating func note(_ rects: [DirtyRect]?, verdict: FrameInfo.DirtyRectVerdict) {
        framesTotal += 1
        guard let rects else {
            framesNoRects += 1
            verdicts[verdict.rawValue, default: 0] += 1
            return
        }
        guard !rects.isEmpty else { return }
        framesChanged += 1
        for r in rects where r.width > 0 && r.height > 0 {
            let ts = TileGrid.tileSize
            let c0 = UInt64(max(0, r.x) / ts), r0 = UInt64(max(0, r.y) / ts)
            let c1 = UInt64(max(0, r.x + r.width - 1) / ts), r1 = UInt64(max(0, r.y + r.height - 1) / ts)
            counts[c0 | r0 << 16 | c1 << 32 | r1 << 48, default: 0] += 1
        }
    }

    /// "changes 57/120 frames: 60× 128×64@2752,40 · 12× 64×64@320,1600" — the
    /// three most frequent boxes (canvas px) — then clears the tally.
    mutating func summaryAndReset() -> String {
        defer {
            counts.removeAll(keepingCapacity: true)
            framesChanged = 0
            framesTotal = 0
            framesNoRects = 0
            verdicts.removeAll(keepingCapacity: true)
        }
        guard framesTotal > 0 else { return "changes: no frames" }
        let why = verdicts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        if framesNoRects == framesTotal { return "changes: no dirty rects (\(why))" }
        let noRects = framesNoRects > 0 ? " · no-rect frames: \(why)" : ""
        guard framesChanged > 0 else { return "changes: none" + noRects }
        let ts = TileGrid.tileSize
        let top = counts.sorted { $0.value > $1.value }.prefix(3).map { key, n -> String in
            let c0 = Int(key & 0xFFFF), r0 = Int(key >> 16 & 0xFFFF)
            let c1 = Int(key >> 32 & 0xFFFF), r1 = Int(key >> 48 & 0xFFFF)
            return "\(n)× \((c1 - c0 + 1) * ts)×\((r1 - r0 + 1) * ts)@\(c0 * ts),\(r0 * ts)"
        }
        return "changes \(framesChanged)/\(framesTotal) frames: " + top.joined(separator: " · ") + noRects
    }
}

/// Stores VIEWER_LOG uploads in ~/Library/Logs/Glass Act/from-viewer/<name>.
/// Chunks must arrive in order (the stream is reliable and ordered); a gap
/// or overrun drops the rest of that file. Names are already validated by
/// the parser (bare, safe characters). Own queue: file I/O stays off the
/// engine's.
final class ViewerLogInbox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "glassact.host.viewer-logs")
    private var written: [String: Int] = [:]
    private var handles: [String: FileHandle] = [:]
    let directory = AppPaths.logsDirectory.appendingPathComponent("from-viewer")

    func receive(name: String, offset: Int, total: Int, data: [UInt8], status: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            let url = directory.appendingPathComponent(name)
            if offset == 0 {
                try? handles[name]?.close()
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: url.path, contents: nil),
                      let h = try? FileHandle(forWritingTo: url) else {
                    status("viewer log \(name): can't write \(url.path)")
                    return
                }
                handles[name] = h
                written[name] = 0
            }
            guard let h = handles[name], written[name] == offset else {
                if handles[name] != nil { status("viewer log \(name): out-of-order chunk at \(offset) — dropped") }
                try? handles[name]?.close()
                handles[name] = nil
                written[name] = nil
                return
            }
            h.write(Data(data))
            let now = offset + data.count
            written[name] = now
            if now >= total {
                try? h.close()
                handles[name] = nil
                written[name] = nil
                status("received viewer log \(name) (\(total / 1024) KB) → \(url.path)")
            }
        }
    }
}
