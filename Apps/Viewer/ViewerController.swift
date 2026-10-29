import AppKit
import CoreGraphics
import Foundation
import GlassActCore
import GlassActSession
import GlassActTransport
import GlassActWire
import os

/// The app's side of a viewer session: presenting telemetry, clipboard sync,
/// pausing while occluded, and log upload around a package `ViewerSession`
/// (transport → engine, tick, watchdog — shared with the headless agent).
/// The engine is confined to `queue` (the session's apply queue).
///
/// Concurrency (§8): queue-confined, not actor-isolated — state lives on
/// `queue` or the main thread as documented per property; hops are explicit
/// `DispatchQueue.async`. `@unchecked Sendable` so those hops compile under
/// Swift 6 strict concurrency without actors in the apply/present path.
final class ViewerController: @unchecked Sendable {
    static let log = Logger(subsystem: "app.glassact.viewer", category: "diag")
    /// Transport → engine, tick and watchdog (package; also drives agents).
    let session: ViewerSession
    var queue: DispatchQueue { session.queue }
    var engine: ViewerEngine { session.engine }
    var onStatus: (String) -> Void = { _ in }

    /// The host key this dial saw (for trust-on-first-use and for reporting
    /// a changed key). Any thread.
    var observedHostFingerprint: String? { session.observedHostFingerprint }

    /// Main thread: a pinned host presented a different key. The session is
    /// over; onConnectionFailed does NOT fire (redialing can't help).
    var onHostKeyChanged: ((_ expected: String, _ presented: String) -> Void)?

    /// Main thread, valid inside onConnectionFailed: why the dial ended, and
    /// whether it looked like a host waiting on its user to approve this
    /// viewer (it refuses the handshake until then).
    var lastFailureReason: String { session.lastFailureReason }
    var lastFailureAwaitsApproval: Bool { session.lastFailureAwaitsApproval }

    /// The short code both screens show for this host/viewer pair, once the
    /// host's key is known.
    func verificationCode() -> String? { session.verificationCode() }
    // Client quality policy (QUALITY)
    private(set) var qualityFloor = 0        // QualityFloor: 0 = automatic
    private(set) var qualityMotionPreference = 0 // ViewerSettings.motionPreference
    private var lastSentScalePct = -1
    func setQualityPrefs(floor: Int, motionPreference: Int) {
        qualityFloor = floor; qualityMotionPreference = motionPreference
        queue.async { [engine] in
            engine.initialQualityPolicy = (floor, motionPreference == 1, motionPreference == 2)
        }
    }
    /// Send the policy (presented scale + stored floor/preference). Throttled
    /// on scale so a resize storm doesn't flood the control stream.
    func updatePresentedScale(_ pct: Int) {
        guard pct != lastSentScalePct else { return }
        lastSentScalePct = pct
        queue.async { [weak self] in
            guard let self else { return }
            self.engine.sendQualityPolicy(presentedScalePct: pct,
                                          floor: self.qualityFloor,
                                          preferSharpness: self.qualityMotionPreference == 1,
                                          preferSmoothness: self.qualityMotionPreference == 2)
        }
    }
    // Clipboard sync (main thread)
    private var clipboardTimer: Timer?
    private var lastClipboardHash = 0
    private var clipboardChangeCount = -1
    // Session-scoped App Nap exemption: held only while a session is live —
    // the ACK/PONG cadence has millisecond deadlines then (App Nap throttling
    // a hidden viewer's timers runs SRTT up to seconds). Outside a session
    // the app naps normally. Deliberately no display/system-sleep
    // assertions.
    private var sessionActivity: NSObjectProtocol?
    // Occlusion-aware pausing. Hidden/occluded ≥ 3 s → ask the host to
    // pause content and release the activity assertion (App Nap becomes
    // safe: only keep-alives flow). Visible → resume + assertion,
    // immediately. --no-pause (demo flag) disables this: a hidden-but-live
    // viewer is the demo posture, not a real one.
    private var pauseEnabled = true
    private var occluded = false
    private var pausePending: DispatchWorkItem?
    private var pausedNow = false
    static let occlusionDebounceS = 3.0

    // Glass-to-glass (capture_ts → present) sliding window. Same-machine
    // loopback only — the timestamps are the host's monotonic clock (§10.1).
    private var g2gSamplesUS: [UInt64] = []
    // Session-log telemetry, main thread only.
    private let sessionTarget: String
    private let cursorMode: String
    private var telemetryTimer: Timer?
    private var stallProbe: Timer?
    private var telemetryLastUS: UInt64 = 0
    private var telemetryLastStallFire: UInt64 = 0
    private var telemetryStallMaxUS: UInt64 = 0
    private var telemetryStalls50 = 0
    private var telemetryStalls250 = 0
    private var telemetryG2G: [UInt64] = []
    private var telemetryBlits: [UInt64] = []
    private var telemetryFlipDelays: [UInt64] = []
    private var telemetryPrevStats: ViewerStats?
    private var g2gLock = NSLock()
    private var lastG2GPrint = Date()

    func setPauseEnabled(_ enabled: Bool) {
        queue.async { self.pauseEnabled = enabled }
    }

    /// Main thread (AppKit) → engine queue. Debounced on hide, instant on show.
    func windowVisibilityChanged(visible: Bool) {
        queue.async { [self] in
            let newOccluded = !visible
            guard pauseEnabled, occluded != newOccluded else { return }
            occluded = newOccluded
            pausePending?.cancel()
            pausePending = nil
            if visible {
                if pausedNow {
                    pausedNow = false
                    engine.setContentPaused(false)
                    if sessionActivity == nil {
                        sessionActivity = ProcessInfo.processInfo.beginActivity(
                            options: [.userInitiated, .latencyCritical],
                            reason: "glassact session active")
                    }
                    onStatus("visible — content resumed")
                }
            } else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.occluded, !self.pausedNow else { return }
                    self.pausedNow = true
                    self.engine.setContentPaused(true)
                    if let token = self.sessionActivity {
                        ProcessInfo.processInfo.endActivity(token)
                        self.sessionActivity = nil
                    }
                    self.onStatus("occluded — content paused (keep-alives only, App Nap allowed)")
                }
                pausePending = work
                queue.asyncAfter(deadline: .now() + Self.occlusionDebounceS, execute: work)
            }
        }
    }

    /// `identity`: this viewer's certificate, presented to the host (mutual
    /// TLS). The host admits only viewer fingerprints its user approved.
    /// `fingerprint` pins the host; empty = trust on first use.
    init(host: String, port: UInt16, fingerprint: String, identity: SecIdentity?,
         cursorMetadata: Bool = true, av1: Bool = false) {
        session = ViewerSession(host: host, port: port, fingerprint: fingerprint, identity: identity,
                                options: .init(cursorMetadata: cursorMetadata, video: true, av1: av1))
        sessionTarget = session.target
        cursorMode = cursorMetadata ? "metadata" : "burned"
        engine.onVideoCodecChanged = { [weak self] codec in
            let msg = codec.map { "video codec: \(VideoCodec.name($0))" }
                ?? "video off — lossless tiles"
            DispatchQueue.main.async { self?.onStatus(msg) }
        }
        engine.onHostNotice = { [weak self] code in
            DispatchQueue.main.async { self?.onHostNotice?(code) }
        }
    }

    /// Auto-reconnect hook (main thread): fired when the transport dies.
    var onConnectionFailed: (() -> Void)?
    /// The host's HOST_NOTICE changed (main thread).
    var onHostNotice: ((UInt8) -> Void)?

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
            guard hash != self.lastClipboardHash else { return }
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
        clipboardChangeCount = pb.changeCount
    }

    /// Remote input (main thread → engine queue, reliable). Also the person
    /// at this viewer touching the session — an attached agent yields.
    func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int) {
        agentDriver?.noteHumanInput()
        session.sendInput(kind: kind, x: x, y: y, a: a, b: b)
    }
    /// An agent using this session (Settings › Agents), if any. It sends
    /// through `session` directly, so its input never counts as the person's.
    var agentDriver: AgentDriver?

    /// Handshake geometry (main thread → engine queue, BEFORE HELLO lands).
    func setRequestedGeometry(mode: UInt8, widthPoints: Int, heightPoints: Int, scale: Int) {
        session.setRequestedGeometry(mode: mode, widthPoints: widthPoints, heightPoints: heightPoints, scale: scale)
    }

    /// RESIZE request (main thread → engine queue).
    func requestResize(mode: UInt8, widthPoints: Int, heightPoints: Int, scale: Int) {
        session.requestResize(mode: mode, widthPoints: widthPoints, heightPoints: heightPoints, scale: scale)
    }

    // MARK: - Single-window mode (main thread → engine queue)

    /// Fired when the host's pickable-window snapshot arrives.
    var onWindowList: (([WireWindow]) -> Void)?
    /// Main thread: the host ended the session on purpose (shared window
    /// closed) — show why, don't redial.
    var onHostEndedSession: ((String) -> Void)?
    /// Main thread: the host runs a different build; don't redial.
    var onIncompatibleHost: ((_ hostVersion: UInt8) -> Void)?
    /// Host advertised single-window support (has Screen Recording).
    /// Which host the upload ledger is kept for (the pinned or observed key).
    /// How `session_start` names this session's host in the log.
    var logTarget: String { sessionTarget }

    var uploadHostKey: String {
        String((observedHostFingerprint ?? session.pinnedHostFingerprint).prefix(16))
    }

    /// Upload log files to the host over the control stream, paced: 2 KB
    /// every 125 ms (~16 KB/s). The stream also carries ACKs and PINGs: at
    /// 8 KB / 100 ms (~640 kbit/s) a 2.7 MB upload on a phone tether queues
    /// them for seconds, which the host reads as a collapsing link (SRTT 44
    /// → 320 ms, tile and video rates to their floors, viewer g2g p50 3 s).
    /// `onFileSent` (main) fires per completed file; `onProgress` runs on
    /// main.
    func sendLogs(_ files: [URL], onFileSent: @escaping @Sendable (_ name: String, _ size: Int) -> Void = { _, _ in },
                  onProgress: @escaping @Sendable (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.engine.hostAcceptsLogs else {
                DispatchQueue.main.async { onProgress("this host can't receive logs (update the host)") }
                return
            }
            // One upload at a time: a second would interleave its chunks
            // with the first's on the same stream.
            guard self.logUpload == nil else {
                DispatchQueue.main.async { onProgress("already sending logs to the host") }
                return
            }
            var jobs: [LogUpload.Job] = []
            for url in files {
                guard let data = try? Data(contentsOf: url), data.count <= Int(ControlMessage.maxViewerLogTotal),
                      ControlMessage.isSafeLogName(url.lastPathComponent) else { continue }
                jobs.append(.init(name: url.lastPathComponent, bytes: [UInt8](data)))
            }
            self.logUpload = LogUpload(jobs: jobs, onFileSent: onFileSent, onProgress: onProgress)
            self.sendNextLogChunk()
        }
    }

    /// An upload in progress (`queue`-confined, like everything it touches).
    private struct LogUpload {
        struct Job { let name: String; let bytes: [UInt8] }
        let jobs: [Job]
        let totalBytes: Int
        let onFileSent: @Sendable (_ name: String, _ size: Int) -> Void
        let onProgress: @Sendable (String) -> Void
        var job = 0, offset = 0, sent = 0

        init(jobs: [Job], onFileSent: @escaping @Sendable (String, Int) -> Void,
             onProgress: @escaping @Sendable (String) -> Void) {
            self.jobs = jobs
            self.totalBytes = jobs.reduce(0) { $0 + $1.bytes.count }
            self.onFileSent = onFileSent
            self.onProgress = onProgress
        }
    }

    /// `queue`.
    private var logUpload: LogUpload?
    private static let logChunkBytes = 2 << 10
    private static let logChunkInterval = 0.125

    /// `queue`. Send the next chunk of `logUpload` and schedule the one after.
    private func sendNextLogChunk() {
        guard var upload = logUpload else { return }
        let report = upload.onProgress
        guard upload.job < upload.jobs.count else {
            let done = "sent \(upload.jobs.count) log(s), \(upload.totalBytes / 1024) KB, to the host"
            logUpload = nil
            DispatchQueue.main.async { report(done) }
            return
        }
        let current = upload.jobs[upload.job]
        let end = min(current.bytes.count, upload.offset + Self.logChunkBytes)
        guard engine.sendViewerLogChunk(name: current.name, offset: UInt32(upload.offset),
                                        total: UInt32(current.bytes.count),
                                        data: Array(current.bytes[upload.offset..<end])) else {
            logUpload = nil
            DispatchQueue.main.async { report("log upload stopped — session ended") }
            return
        }
        upload.sent += end - upload.offset
        upload.offset = end
        if upload.offset >= current.bytes.count {
            let fileSent = upload.onFileSent, size = current.bytes.count
            DispatchQueue.main.async { fileSent(current.name, size) }
            upload.job += 1
            upload.offset = 0
        }
        if upload.sent % (32 << 10) < Self.logChunkBytes || upload.job == upload.jobs.count {
            let pct = upload.totalBytes == 0 ? 100 : upload.sent * 100 / upload.totalBytes
            DispatchQueue.main.async { report("sending logs to the host… \(pct)%") }
        }
        logUpload = upload
        queue.asyncAfter(deadline: .now() + Self.logChunkInterval) { [weak self] in
            self?.sendNextLogChunk()
        }
    }

    func hostSupportsVirtualDisplay() -> Bool { session.hostSupportsVirtualDisplay() }

    func hostSupportsWindowList() -> Bool { session.hostSupportsWindowList() }
    /// Ask the host to enumerate + send its window list.
    func requestWindowList() { session.requestWindowList() }
    /// Pick a window (the host swaps its capture filter and re-HELLOs in
    /// place — see onGeometryChanged).
    func selectWindow(_ id: UInt32) { session.selectWindow(id) }
    /// A window-chrome action (fullscreen / resize / endSession).
    func windowControl(action: UInt8, width: Int = 0, height: Int = 0) {
        session.windowControl(action: action, width: width, height: height)
    }

    /// In-session geometry change (re-HELLO on the live connection): the canvas
    /// was reconfigured to new dims without a reconnect. Fired on the main
    /// thread; the app opens or rebuilds the present surfaces to the new grid.
    var onGeometryChanged: ((_ width: Int, _ height: Int) -> Void)?

    /// Cursor as metadata: cursor state for the present-time composite (main thread).
    var onCursorUpdate: (() -> Void)? // main thread
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var cursorVisible = false
    private(set) var cursorImage: CGImage?
    private(set) var cursorHotspot = CGPoint.zero // image pixels

    /// First-picture timing (see SessionMilestones): session start and
    /// transport-ready times (MonotonicClock µs), and whether the one-time
    /// `first_picture` line was taken (queue-confined).
    private var sessionStartUS: UInt64 = 0
    private var transportReadyUS: UInt64 = 0 // queue
    private var firstPictureTaken = false    // queue

    /// Queue only (the present path's blit hop). The engine's milestones the
    /// first time a blit carries content; nil afterwards.
    func takeFirstPicture() -> SessionMilestones? {
        guard !firstPictureTaken, engine.milestones.firstContentUS != 0 else { return nil }
        firstPictureTaken = true
        return engine.milestones
    }

    /// Main thread: that blit is on glass. One line per session, every time
    /// in ms after session_start ("-" = never happened).
    func logFirstPicture(_ m: SessionMilestones, presentedUS: UInt64) {
        let t0 = sessionStartUS
        func ms(_ us: UInt64) -> String { us == 0 || us < t0 ? "-" : String((us - t0) / 1000) }
        SessionLog.shared.write("first_picture",
            "presented_ms=\(ms(presentedUS)) ready_ms=\(ms(transportReadyUS)) hello_ms=\(ms(m.firstHelloUS))"
            + " hellos=\(m.hellos) configured_ms=\(ms(m.runningUS)) video_start_ms=\(ms(m.videoStartUS))"
            + " video_rx_ms=\(ms(m.firstVideoRxUS)) video_bytes=\(m.firstVideoBytes) video_sync=\(m.firstVideoSync ? 1 : 0)"
            + " video_decoded_ms=\(ms(m.firstVideoAppliedUS)) tile_ms=\(ms(m.firstTileUS)) keyframe_ms=\(ms(m.firstKeyframeUS))")
    }

    func start() {
        sessionStartUS = MonotonicClock.nowUS
        SessionLog.shared.write("session_start", "\(sessionTarget)"
            + " host_fp=\(session.pinnedHostFingerprint.isEmpty ? "tofu" : String(session.pinnedHostFingerprint.prefix(16)))"
            + " viewer_fp=\(session.viewerFingerprint.prefix(16))"
            + " cursor=\(cursorMode)")
        startTelemetry()
        session.onStatus = { [weak self] text in self?.onStatus(text) }
        session.onTransportReady = { [weak self] in // queue
            guard let self else { return }
            if self.transportReadyUS == 0 { self.transportReadyUS = MonotonicClock.nowUS }
            if self.sessionActivity == nil, !self.pausedNow {
                self.sessionActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical],
                    reason: "glassact session active")
            }
        }
        session.onTransportEnded = { [weak self] in // queue
            guard let self, let token = self.sessionActivity else { return }
            ProcessInfo.processInfo.endActivity(token)
            self.sessionActivity = nil
        }
        session.onCursorPos = { [weak self] x, y, visible in
            guard let self else { return }
            self.cursorX = x
            self.cursorY = y
            self.cursorVisible = visible
            self.onCursorUpdate?()
        }
        session.onCursorImage = { [weak self] image, hotspot in
            guard let self else { return }
            self.cursorImage = image
            self.cursorHotspot = hotspot
            self.onCursorUpdate?()
        }
        session.onClipboard = { [weak self] format, data in
            self?.agentDriver?.noteHostClipboard(format: format, data: data)
            self?.applyInboundClipboard(format, data)
        }
        session.onWindowList = { [weak self] windows in
            self?.agentDriver?.noteWindowList(windows)
            self?.onWindowList?(windows)
        }
        session.onHostEndedSession = { [weak self] reason in self?.onHostEndedSession?(reason) }
        session.onIncompatibleHost = { [weak self] version in self?.onIncompatibleHost?(version) }
        session.onGeometryChanged = { [weak self] w, h in self?.onGeometryChanged?(w, h) }
        session.onConnectionFailed = { [weak self] in self?.onConnectionFailed?() }
        session.onHostKeyChanged = { [weak self] expected, presented in self?.onHostKeyChanged?(expected, presented) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startClipboardSync { [weak self] fmt, data in
                self?.session.sendClipboard(format: fmt, data: data)
            }
        }
        session.start()
    }

    /// Main thread. Deliberate end of the session: no onConnectionFailed.
    /// `bye`: why, for the host (`ViewerBye`).
    func stop(bye: UInt8 = ViewerBye.disconnected) {
        stopTelemetry(reason: "stopped")
        clipboardTimer?.invalidate(); clipboardTimer = nil
        queue.async { [self] in
            if let token = sessionActivity {
                ProcessInfo.processInfo.endActivity(token)
                sessionActivity = nil
            }
        }
        session.stop(bye: bye)
    }

    /// Blocks (at most `timeout` s) until the connection has closed: lets a
    /// quitting Viewer's goodbye reach the host.
    func waitUntilClosed(timeout: Double) { session.waitUntilClosed(timeout: timeout) }

    /// Main thread: the configured canvas grid, synchronously — waits for
    /// the apply queue, so only for one-off events (a geometry change), never
    /// for polling (use the async form).
    func configuredGrid() -> TileGrid? { session.configuredGrid() }

    /// Main-thread poll: non-nil once the HELLO has configured the canvas.
    func configuredGrid(_ done: @escaping @MainActor (TileGrid?) -> Void) { session.configuredGrid(done) }

    /// Main-thread poll: true once the canvas has any content.
    func hasPicture(_ done: @escaping @MainActor (Bool) -> Void) { session.hasPicture(done) }

    /// Main-thread cache of the engine's PING-derived clock offset (the
    /// engine is queue-confined; the present path must not hop queues).
    private(set) var hostClockOffsetUS: Int64 = 0

    /// Called by the present path with capture→present latency samples.
    func recordGlassToGlass(_ samples: [UInt64]) {
        telemetryG2G.append(contentsOf: samples)
        g2gLock.lock()
        g2gSamplesUS.append(contentsOf: samples)
        if g2gSamplesUS.count > 5000 {
            g2gSamplesUS.removeFirst(g2gSamplesUS.count - 5000)
        }
        g2gLock.unlock()
        if Date().timeIntervalSince(lastG2GPrint) >= 2 {
            lastG2GPrint = Date()
            // Snapshot engine state on its queue: offset for the next g2g
            // window, stats for the diagnostic line.
            queue.async { [weak self] in
                guard let self else { return }
                let offset = self.engine.hostClockOffsetEstimateUS ?? 0
                let s = self.engine.stats
                DispatchQueue.main.async { self.hostClockOffsetUS = offset }
                let codec = self.engine.activeVideoCodec.map(VideoCodec.name) ?? "off"
                let diag = "applied \(s.recordsApplied) · stale \(s.recordsStale)"
                    + " · deltas \(s.deltasApplied)/\(s.deltaBaseMisses) miss"
                    + " · reasm-exp \(s.reasmExpired) · scrolls \(s.scrollsApplied)"
                    + " · video \(s.videoFramesApplied) [\(codec)] · kf \(s.keyframesApplied)"
                    + " · cache \(s.cacheRefsApplied)/\(s.cacheRefMisses) miss"
                print("glassact-viewer: \(diag)")
                Self.log.notice("\(diag, privacy: .public)")
            }
            if let summary = glassToGlassSummary() {
                print("glassact-viewer: \(summary)")
                Self.log.notice("\(summary, privacy: .public)")
            }
        }
    }

    // Title-bar bandwidth/framerate: rates between consecutive samples of
    // the engine's counters. State is only touched on `queue`.
    private var bwLastBytes = 0
    private var bwLastVideoFrames = 0
    private var bwLastSampleUS: UInt64 = 0

    /// Received bandwidth + video framerate, plus the active codec — e.g.
    /// "623 KB/s · 42 fps (HEVC)". Computed on the apply queue, delivered on
    /// main: a `queue.sync` from the 1 s title poll would block the main
    /// thread on apply work up to 33 % of the time.
    func bandwidthSummary(_ done: @escaping @MainActor (String?) -> Void) {
        queue.async { [self] in
            let line = bandwidthSummaryOnQueue()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(line) } }
        }
    }

    /// `queue` only.
    private func bandwidthSummaryOnQueue() -> String? {
        do {
            let now = MonotonicClock.nowUS
            let bytes = engine.stats.bytesIn
            let frames = engine.stats.videoFramesApplied
            defer { bwLastBytes = bytes; bwLastVideoFrames = frames; bwLastSampleUS = now }
            guard bwLastSampleUS > 0, now > bwLastSampleUS, bytes >= bwLastBytes else { return nil }
            let dt = Double(now - bwLastSampleUS) / 1_000_000
            let kbps = Double(bytes - bwLastBytes) * 8 / dt / 1000
            var line = kbps >= 1000
                ? String(format: "%.1f Mbps", kbps / 1000)
                : String(format: "%.0f Kbps", kbps)
            guard let codec = engine.activeVideoCodec else { return line }
            let fps = Double(frames - bwLastVideoFrames) / dt
            line += String(format: " · %.0f fps (%@)", fps.rounded(), VideoCodec.name(codec))
            return line
        }
    }

    /// Median glass-to-glass latency, once there are enough samples.
    func glassToGlassMedianMS() -> Double? {
        g2gLock.lock()
        let sorted = g2gSamplesUS.sorted()
        g2gLock.unlock()
        guard sorted.count >= 20 else { return nil }
        return Double(sorted[sorted.count / 2]) / 1000.0
    }

    func glassToGlassSummary() -> String? {
        g2gLock.lock()
        let sorted = g2gSamplesUS.sorted()
        g2gLock.unlock()
        guard sorted.count >= 20 else { return nil }
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        return String(format: "glass-to-glass p50 %.1f ms  p95 %.1f ms  (n=%d)",
                      Double(p50) / 1000.0, Double(p95) / 1000.0, sorted.count)
    }

    // MARK: - Session log telemetry (main thread)

    /// Main thread: a landed present — its blit cost and blit→flip delay.
    func recordPresent(blitUS: UInt64, flipDelayUS: UInt64) {
        telemetryBlits.append(blitUS)
        telemetryFlipDelays.append(flipDelayUS)
    }

    private func startTelemetry() {
        telemetryLastStallFire = SurfacePresenter.uptimeUS()
        // Stall probe: a 20 ms main-runloop timer can't fire while main is
        // blocked, so its lateness is main-thread unresponsiveness.
        stallProbe = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = SurfacePresenter.uptimeUS()
            let late = now > self.telemetryLastStallFire + 20_000 ? now - self.telemetryLastStallFire - 20_000 : 0
            self.telemetryLastStallFire = now
            self.telemetryStallMaxUS = max(self.telemetryStallMaxUS, late)
            if late > 50_000 { self.telemetryStalls50 += 1 }
            if late > 250_000 { self.telemetryStalls250 += 1 }
        }
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.writeTelemetryLine()
        }
        telemetryLastUS = SurfacePresenter.uptimeUS()
    }

    private func stopTelemetry(reason: String) {
        guard telemetryTimer != nil else { return }
        writeTelemetryLine()
        stallProbe?.invalidate(); stallProbe = nil
        telemetryTimer?.invalidate(); telemetryTimer = nil
        g2gLock.lock()
        let all = g2gSamplesUS
        g2gLock.unlock()
        let s = queue.sync { engine.stats } // once, at session end
        SessionLog.shared.write("session_end", "reason=\(reason)"
            + " rx_bytes=\(s.bytesIn) dgrams=\(s.datagramsReceived) records_applied=\(s.recordsApplied)"
            + " video_frames=\(s.videoFramesApplied) keyframes=\(s.keyframesApplied)"
            + " malformed=\(s.malformedDatagrams) records_nacked=\(s.recordsRejectedNacked)"
            + " " + (LatencySummary(all)?.fields("g2g_session") ?? "g2g_session_n=0"))
    }

    /// Main thread, every 5 s: engine deltas (snapshotted on the apply
    /// queue) + this interval's present / latency / stall numbers.
    private func writeTelemetryLine() {
        let now = SurfacePresenter.uptimeUS()
        let seconds = Double(now - telemetryLastUS) / 1_000_000
        telemetryLastUS = now
        let g2g = LatencySummary(telemetryG2G)?.fields("g2g") ?? "g2g_n=0"
        let blit = LatencySummary(telemetryBlits)?.fields("blit") ?? "blit_n=0"
        let flip = LatencySummary(telemetryFlipDelays)?.fields("blit_to_flip") ?? "blit_to_flip_n=0"
        let stall = String(format: "main_stall_max_ms=%.1f main_stalls_50ms=%d main_stalls_250ms=%d",
                           Double(telemetryStallMaxUS) / 1000, telemetryStalls50, telemetryStalls250)
        let presents = telemetryBlits.count
        telemetryG2G.removeAll(keepingCapacity: true)
        telemetryBlits.removeAll(keepingCapacity: true)
        telemetryFlipDelays.removeAll(keepingCapacity: true)
        telemetryStallMaxUS = 0; telemetryStalls50 = 0; telemetryStalls250 = 0
        let local = "presents=\(presents) \(g2g) \(blit) \(flip) \(stall)"
            + " occluded=\(occluded ? 1 : 0) paused=\(pausedNow ? 1 : 0) presented_scale_pct=\(lastSentScalePct)"
        let previous = telemetryPrevStats
        queue.async { [weak self] in
            guard let self else { return }
            let stats = self.engine.stats
            let offset = self.engine.hostClockOffsetEstimateUS.map { String(format: "%.1f", Double($0) / 1000) } ?? "na"
            let codec = self.engine.activeVideoCodec.map(VideoCodec.name) ?? "off"
            let grid = self.engine.grid.map { "\($0.width)x\($0.height)" } ?? "none"
            let engineFields = stats.intervalFields(since: previous ?? stats, seconds: seconds)
            DispatchQueue.main.async {
                self.telemetryPrevStats = stats
                SessionLog.shared.write("stats", String(format: "interval_s=%.1f", seconds)
                    + " \(engineFields) \(local) codec=\(codec) canvas=\(grid) host_offset_ms=\(offset)")
            }
        }
    }
}
