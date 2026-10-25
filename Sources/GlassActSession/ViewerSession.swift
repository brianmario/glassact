public import CoreGraphics
import Foundation
import SystemConfiguration
public import GlassActCore
import GlassActTransport
public import Security
public import GlassActWire

/// One viewer's connection to a host: QUICTransport → ViewerEngine, the 4 ms
/// tick, the connect/liveness watchdog, and how the session ended. Shared by
/// the Viewer app (which adds presenting, telemetry and clipboard sync) and
/// the headless `glassact` agent daemon (which adds nothing visible at all).
///
/// Concurrency (§8): queue-confined, not actor-isolated. The engine lives on
/// `queue` (the transport callback queue doubles as the §5 applyQueue);
/// callbacks documented "main" hop there explicitly. `@unchecked Sendable`
/// so those hops compile under Swift 6 without actors in the apply path.
public final class ViewerSession: @unchecked Sendable {
    public struct Options: Sendable {
        /// Advertise WireCaps.cursor: the host sends the pointer as metadata
        /// instead of burning it into pixels.
        public var cursorMetadata: Bool
        /// Advertise hardware HEVC video regions. Off, the host sends only
        /// lossless tiles — every settled pixel is exact (what an agent wants).
        public var video: Bool
        /// Also advertise AV1 (when this Mac decodes it in hardware): the
        /// Viewer's opt-in. The Host prefers it whenever it's offered.
        public var av1: Bool
        /// Sent to the host (VIEWER_INFO) so its approved-viewers list can
        /// name this computer. Empty = say nothing.
        public var deviceName: String

        public init(cursorMetadata: Bool = true, video: Bool = true, av1: Bool = false,
                    deviceName: String = ViewerSession.computerName) {
            self.cursorMetadata = cursorMetadata
            self.video = video
            self.av1 = av1
            self.deviceName = deviceName
        }
    }

    /// "Alex’s MacBook Air" — this Mac's name from Sharing settings.
    public static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? ""
    }

    public let queue = DispatchQueue(label: "glassact.viewer.apply", qos: .userInteractive)
    public let engine: ViewerEngine

    /// Status lines for logs and UI. Called on `queue` or main.
    public var onStatus: @Sendable (String) -> Void = { _ in }
    /// `queue`: the transport came up (each dial).
    public var onTransportReady: (() -> Void)?
    /// `queue`: the transport ended (failed, cancelled, or stopped).
    public var onTransportEnded: (() -> Void)?
    /// Main: the dial or session was lost — the owner decides whether to redial.
    public var onConnectionFailed: (() -> Void)?
    /// Main: a pinned host presented a different key. The session is over;
    /// onConnectionFailed does NOT fire (redialing can't help).
    public var onHostKeyChanged: ((_ expected: String, _ presented: String) -> Void)?
    /// Main: the host's pickable-window snapshot.
    public var onWindowList: (([WireWindow]) -> Void)?
    /// Main: the host ended the session on purpose — show why, don't redial.
    public var onHostEndedSession: ((String) -> Void)?
    /// Main thread: the host runs a different build (its wire version);
    /// redialing can't help until one side updates.
    public var onIncompatibleHost: ((_ hostVersion: UInt8) -> Void)?
    /// Main: in-session geometry change (the canvas was reconfigured).
    public var onGeometryChanged: ((_ width: Int, _ height: Int) -> Void)?
    /// Main: pointer position (canvas pixels) and visibility, metadata mode.
    public var onCursorPos: ((_ x: Int, _ y: Int, _ visible: Bool) -> Void)?
    /// Main: pointer image and hotspot (image pixels), metadata mode.
    public var onCursorImage: ((_ image: CGImage, _ hotspot: CGPoint) -> Void)?
    /// Main: the host's clipboard changed (format 1 = UTF-8 text).
    public var onClipboard: ((_ format: UInt8, _ data: [UInt8]) -> Void)?

    /// Main, valid inside onConnectionFailed: why the dial ended, and whether
    /// it looked like a host waiting on its user to approve this viewer.
    public private(set) var lastFailureReason = ""
    public private(set) var lastFailureAwaitsApproval = false

    /// The host key this dial saw (trust on first use, changed-key reports).
    public var observedHostFingerprint: String? { transport.observedHostFingerprint }
    public let pinnedHostFingerprint: String
    public let viewerFingerprint: String
    public let target: String

    private let transport: QUICTransport
    private var tickTimer: (any DispatchSourceTimer)?
    /// Connect deadline + host liveness. `queue`.
    private var watchdog = ViewerSessionWatchdog(dialStartUS: MonotonicClock.nowUS)
    // `queue`. `stopped` is set by a deliberate stop(), ahead of the
    // transport's own teardown block, so its `.cancelled` isn't mistaken for
    // a lost connection; `failureReported` makes onConnectionFailed fire once.
    private var stopped = false
    private var failureReported = false
    private var everReady = false

    /// `identity`: this viewer's certificate (mutual TLS) — the host admits
    /// only fingerprints its user approved. `fingerprint` pins the host;
    /// empty = trust on first use.
    /// `datagramPort`: the host's datagram listener when it isn't `port + 1`
    /// (tests bind both to random ports).
    public init(host: String, port: UInt16, fingerprint: String, identity: SecIdentity?,
                datagramPort: UInt16? = nil, options: Options = Options()) {
        pinnedHostFingerprint = QUICIdentity.normalize(fingerprint)
        viewerFingerprint = identity.flatMap { try? QUICIdentity.fingerprint(of: $0) } ?? ""
        target = "host=\(host) port=\(port)"
        transport = QUICTransport.connect(host: host, port: port, fingerprint: fingerprint,
                                          datagramPort: datagramPort, identity: identity, queue: queue)
        engine = ViewerEngine(transport: transport,
                              videoDecoderFactory: options.video ? { VTRegionDecoder() } : nil,
                              supportedVideoCodecs: options.video ? VTRegionDecoder.supportedCodecs(av1: options.av1) : [],
                              advertiseCursor: options.cursorMetadata)
        engine.deviceName = options.deviceName
    }

    /// The short code both screens show for this host/viewer pair, once the
    /// host's key is known.
    public func verificationCode() -> String? {
        let host = observedHostFingerprint ?? (pinnedHostFingerprint.isEmpty ? nil : pinnedHostFingerprint)
        guard let host, !viewerFingerprint.isEmpty else { return nil }
        return QUICIdentity.verificationCode(hostFingerprint: host, viewerFingerprint: viewerFingerprint)
    }

    public func transportFailReason() -> String { transport.lastFailReason }

    public func start() {
        let engine = self.engine
        engine.onFailed = { [weak self] reason in
            // Terminal engine failure (engine queue): tear the transport
            // down; its terminal state drives the owner's reconnect.
            self?.onStatus("session failed — \(reason)")
            self?.transport.cancel()
        }
        engine.onCursorPos = { [weak self] x, y, visible in
            DispatchQueue.main.async { self?.onCursorPos?(x, y, visible) }
        }
        engine.onCursorImage = { [weak self] w, h, hx, hy, _, bgra in
            var bytes = bgra
            let image: CGImage? = bytes.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return nil }
                return ctx.makeImage()
            }
            guard let image else { return }
            let box = UnsafeSendable(image)
            DispatchQueue.main.async { self?.onCursorImage?(box.value, CGPoint(x: hx, y: hy)) }
        }
        engine.onClipboard = { [weak self] format, data in
            DispatchQueue.main.async { self?.onClipboard?(format, data) }
        }
        engine.onWindowList = { [weak self] windows in
            DispatchQueue.main.async { self?.onWindowList?(windows) }
        }
        engine.onHostEndedSession = { [weak self] reason in
            DispatchQueue.main.async { self?.onHostEndedSession?(reason) }
        }
        engine.onIncompatibleHost = { [weak self] version in
            DispatchQueue.main.async { self?.onIncompatibleHost?(version) }
        }
        engine.onGeometryChanged = { [weak self] w, h in
            DispatchQueue.main.async { self?.onGeometryChanged?(w, h) }
        }
        // Weak: the engine holds the transport, so strong captures here would
        // form an engine ↔ transport cycle that leaks a whole session (canvas,
        // cache, VT session) per reconnect. (The transport also drops its
        // callbacks at teardown.)
        transport.onControl = { [weak engine] data in
            engine?.handleControl(data, nowUS: MonotonicClock.nowUS)
        }
        transport.onDatagram = { [weak engine] data in
            engine?.handleDatagram(data, nowUS: MonotonicClock.nowUS)
        }
        transport.onVideo = { [weak engine] data in
            engine?.handleVideo(data, nowUS: MonotonicClock.nowUS)
        }
        transport.onVideoReset = { [weak engine] in
            engine?.resetVideoStream()
        }
        // All transport callbacks fire on `queue`.
        transport.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connecting:
                self.onStatus("connecting…")
            case .ready:
                self.watchdog.transportReady(nowUS: MonotonicClock.nowUS)
                self.everReady = true
                self.onTransportReady?()
                self.onStatus("connected — waiting for HELLO")
            case .failed, .cancelled:
                self.tickTimer?.cancel()
                self.tickTimer = nil
                self.onTransportEnded?()
                guard !self.failureReported else { return }
                self.failureReported = true
                switch ViewerSessionEnd.classify(
                    stopped: self.stopped, everReady: self.everReady,
                    pinnedHostFingerprint: self.pinnedHostFingerprint,
                    observedHostFingerprint: self.observedHostFingerprint,
                    failReason: self.transportFailReason(), verificationCode: self.verificationCode()) {
                case .stopped:
                    break
                case let .hostKeyChanged(expected, presented):
                    self.onStatus("host key changed — expected \(expected.prefix(12))…, got \(presented.prefix(12))…")
                    DispatchQueue.main.async { self.onHostKeyChanged?(expected, presented) }
                case let .lost(reason, hint):
                    self.onStatus("connection failed" + (reason.isEmpty ? "" : " — \(reason)")
                                  + (hint.map { " — \($0)" } ?? ""))
                    DispatchQueue.main.async {
                        self.lastFailureReason = reason
                        self.lastFailureAwaitsApproval = hint != nil
                        self.onConnectionFailed?()
                    }
                }
            }
        }
        transport.start()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4)) // ACK cadence resolution (§3.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = MonotonicClock.nowUS
            self.engine.tick(nowUS: now)
            // Each ends the dial/session via cancel → .cancelled → redial.
            switch self.watchdog.check(self.engine, nowUS: now) {
            case .ok:
                break
            case .connectTimedOut:
                self.onStatus("connect timed out — retrying")
                self.transport.cancel()
            case .hostUnresponsive:
                self.onStatus("host unresponsive (nothing for "
                              + "\(ViewerSessionWatchdog.livenessTimeoutUS / 1_000_000) s) — reconnecting")
                self.transport.cancel()
            }
        }
        timer.resume()
        tickTimer = timer
    }

    /// Deliberate end of the session: no onConnectionFailed. Any thread.
    public func stop() {
        queue.async { [self] in
            // Ordered ahead of the transport's teardown block (same queue),
            // so its .cancelled sees `stopped`.
            stopped = true
            tickTimer?.cancel()
            tickTimer = nil
        }
        transport.cancel()
    }

    // MARK: - Viewer → host (any thread → engine queue)

    /// Remote input, canvas pixels (see ControlMessage.input).
    public func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int) {
        queue.async { [weak self] in
            self?.engine.sendInput(kind: kind, x: x, y: y, a: a, b: b)
        }
    }

    /// Handshake geometry — set BEFORE the HELLO lands.
    public func setRequestedGeometry(mode: UInt8, widthPoints: Int, heightPoints: Int, scale: Int) {
        queue.async { [weak self] in
            self?.engine.requestedGeometry = (mode, widthPoints, heightPoints, scale)
        }
    }

    /// In-session RESIZE request.
    public func requestResize(mode: UInt8, widthPoints: Int, heightPoints: Int, scale: Int) {
        queue.async { [weak self] in
            self?.engine.requestResize(mode: mode, widthPoints: widthPoints,
                                       heightPoints: heightPoints, scale: scale)
        }
    }

    public func sendClipboard(format: UInt8, data: [UInt8]) {
        queue.async { [weak self] in self?.engine.sendClipboard(format: format, data: data) }
    }

    /// Ask the host to enumerate and send its window list.
    public func requestWindowList() {
        queue.async { [weak self] in self?.engine.sendWindowSelect(windowID: 0) }
    }

    /// Share one window (0 = back to the whole display).
    public func selectWindow(_ id: UInt32) {
        queue.async { [weak self] in self?.engine.sendWindowSelect(windowID: id) }
    }

    /// A window-chrome action (fullscreen / resize / endSession).
    public func windowControl(action: UInt8, width: Int = 0, height: Int = 0) {
        queue.async { [weak self] in
            self?.engine.sendWindowControl(action: action,
                                           width: UInt16(clamping: width),
                                           height: UInt16(clamping: height))
        }
    }

    // MARK: - Reads

    public func hostSupportsVirtualDisplay() -> Bool {
        queue.sync { engine.hostCaps & WireCaps.virtualDisplay != 0 }
    }

    public func hostSupportsWindowList() -> Bool {
        queue.sync { engine.hostCaps & WireCaps.windowList != 0 }
    }

    /// The configured canvas grid, synchronously — waits for the apply
    /// queue, so only for one-off events, never for polling.
    public func configuredGrid() -> TileGrid? {
        queue.sync { engine.grid }
    }

    /// Main-thread poll: non-nil once the HELLO has configured the canvas.
    /// Read on the apply queue, delivered on main.
    public func configuredGrid(_ done: @escaping @MainActor (TileGrid?) -> Void) {
        queue.async { [engine] in
            let grid = engine.grid
            DispatchQueue.main.async { MainActor.assumeIsolated { done(grid) } }
        }
    }
}

/// Carries a non-Sendable value across a queue hop the code has proven safe
/// (immutable after the hop, single consumer).
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
