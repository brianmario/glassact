public import Foundation
public import GlassActWire
import GlassActCodec
public import GlassActTransport
import os

/// Connect-to-first-picture milestones for one session (engine-queue µs in
/// the transport's `nowUS` domain; 0 = not yet). The app logs them once, at
/// the first present that shows content (`first_picture`).
public struct SessionMilestones: Sendable {
    public var firstHelloUS: UInt64 = 0
    public var hellos = 0
    /// The HELLO the canvas was configured from (the geometry-final one when
    /// the viewer asked for a size).
    public var runningUS: UInt64 = 0
    public var videoStartUS: UInt64 = 0
    public var firstVideoRxUS: UInt64 = 0
    public var firstVideoBytes = 0
    public var firstVideoSync = false
    /// First video frame decoded and on the canvas/overlay.
    public var firstVideoAppliedUS: UInt64 = 0
    public var firstTileUS: UInt64 = 0
    public var firstKeyframeUS: UInt64 = 0
    /// Earliest visible content of any kind (0 = none yet).
    public var firstContentUS: UInt64 {
        [firstVideoAppliedUS, firstTileUS, firstKeyframeUS].filter { $0 != 0 }.min() ?? 0
    }
}

public struct ViewerStats: Sendable {
    public var cacheStores = 0
    public var cacheRefsApplied = 0
    public var cacheRefMisses = 0
    public var scrollsApplied = 0
    public var datagramsReceived = 0
    public var malformedDatagrams = 0
    public var recordsApplied = 0
    public var recordsStale = 0
    public var recordsSkipped = 0
    /// Rejected records that would have won LWW, reported via DELTA_NACK.
    public var recordsRejectedNacked = 0
    /// Video frames a region decoder could not decode (see VideoRegionDecoder).
    public var videoDecodeFailures = 0
    public var acksSent = 0
    public var videoStarts = 0
    public var videoStops = 0
    public var videoFramesApplied = 0
    public var videoDropped = 0
    public var keyframesApplied = 0
    public var keyframesDropped = 0
    public var deltasApplied = 0
    public var deltaBaseMisses = 0
    public var reasmExpired = 0
    public var lossyPaintsApplied = 0
    /// Total wire bytes received (control + datagrams + video stream) —
    /// the app samples this for the title-bar bandwidth readout.
    public var bytesIn = 0
}

/// §5 — viewer engine. The canvas is a grid of last-writer-wins registers:
/// datagrams may arrive late, out of order, duplicated, or never, and
/// correctness holds (INV-2). Canvas bytes are exactly as coded (INV-8).
///
/// Queue confinement: every method must be called from one serial context (the
/// app's `applyQueue`); `@unchecked Sendable` reflects confinement, not
/// locking. Time is always injected (`nowUS`) for deterministic replay.
public final class ViewerEngine: @unchecked Sendable {
    public enum EngineState: Equatable, Sendable {
        case awaitingHello
        case running
        case failed
    }

    /// Largest legitimate tile payload: one full RAW tile. LZ4 payloads are
    /// only chosen when strictly smaller. Anything larger is hostile.
    static let maxTilePayload = TileGrid.tileSize * TileGrid.tileSize * 4

    public private(set) var state: EngineState = .awaitingHello
    public private(set) var stats = ViewerStats()
    /// Viewer-clock minus host-clock (µs), min-filtered over PINGs; nil until
    /// the first PING. Telemetry only (glass-to-glass across machines).
    public private(set) var hostClockOffsetEstimateUS: Int64?
    /// Host caps from the last HELLO (e.g. WireCaps.windowList gates
    /// single-window mode on the viewer UI).
    public private(set) var hostCaps: UInt32 = 0
    /// Cursor as metadata (§5): fired on the engine's confining queue; the app
    /// composites at present time (canvas untouched — INV-8).
    public var onCursorPos: ((Int, Int, Bool) -> Void)?
    public var onCursorImage: ((_ width: Int, _ height: Int, _ hotspotX: Int,
                                _ hotspotY: Int, _ scale: Int, _ bgra: [UInt8]) -> Void)?
    /// Clipboard sync (bidirectional): fired on inbound; the app applies
    /// it to the local pasteboard (with an echo guard).
    public var onClipboard: ((_ format: UInt8, _ data: [UInt8]) -> Void)?
    public func sendClipboard(format: UInt8, data: [UInt8]) {
        guard state == .running, data.count <= ControlMessage.maxClipboardBytes else { return }
        sendControl(.clipboard(format: format, data: data))
    }

    /// Single-window mode: host → viewer, the pickable-window snapshot.
    /// The app shows the picker; the choice comes back via sendWindowSelect.
    public var onWindowList: ((_ windows: [WireWindow]) -> Void)?
    /// The host ended the session on purpose (single-window mode: the shared
    /// window closed). The app shows why and does NOT redial.
    public var onHostEndedSession: ((_ reason: String) -> Void)?
    /// The engine entered `.failed` (terminal: incompatible or malformed
    /// peer, undecodable video). It sends nothing more; the app must tear
    /// the session down and reconnect. Fires on the engine queue, once.
    public var onFailed: ((_ reason: String) -> Void)?
    /// Last time any control bytes arrived (the host PINGs at 1 Hz while
    /// running) — the app's liveness watchdog reads this. Engine queue.
    public private(set) var lastControlRxUS: UInt64 = 0
    /// In-session geometry change (§4.10): the canvas was reconfigured to new
    /// dimensions on the live connection (no reconnect). Fired on the engine
    /// queue AFTER the canvas is reallocated; the app rebuilds its present
    /// surfaces to the new grid. Not fired for the first HELLO.
    public var onGeometryChanged: ((_ width: Int, _ height: Int) -> Void)?
    /// Single-window mode: viewer → host, pick a window from the last
    /// WINDOW_LIST (0 reverts to full display).
    public func sendWindowSelect(windowID: UInt32) {
        guard state == .running else { return }
        sendControl(.windowSelect(windowID: windowID))
    }
    /// Single-window mode: viewer → host, a window-chrome action (see
    /// WindowAction). width/height are the target points for a resize; 0
    /// otherwise.
    public func sendWindowControl(action: UInt8, width: UInt16 = 0, height: UInt16 = 0) {
        guard state == .running else { return }
        sendControl(.windowControl(action: action, width: width, height: height))
    }

    // MARK: Agents

    /// The host understands agent messages (WireCaps.agentControl).
    public var hostSupportsAgents: Bool { state == .running && hostCaps & WireCaps.agentControl != 0 }
    /// Host → viewer: AGENT_SCOPE (engine queue).
    public var onAgentScope: ((_ control: Bool, _ reason: String) -> Void)?
    /// Host → viewer: UI_TREE (engine queue).
    public var onUITree: ((_ requestID: UInt32, _ status: UInt8, _ json: [UInt8]) -> Void)?

    /// Type `text` on the host, split into TEXT_INPUT messages at character
    /// boundaries (each ≤ maxTextInputBytes — the receiver's bound). False
    /// when the host can't take it.
    @discardableResult
    public func sendTextInput(_ text: String) -> Bool {
        guard hostSupportsAgents else { return false }
        for chunk in text.utf8Chunks(maxBytes: ControlMessage.maxTextInputBytes) {
            sendControl(.textInput(text: chunk))
        }
        return true
    }

    @discardableResult
    public func sendAgentState(active: Bool, label: String) -> Bool {
        guard hostSupportsAgents else { return false }
        sendControl(.agentState(active: active, label: String(label.utf8Prefix(ControlMessage.maxAgentLabelBytes))))
        return true
    }

    @discardableResult
    public func sendUITreeRequest(requestID: UInt32, windowID: UInt32, maxNodes: Int) -> Bool {
        guard hostSupportsAgents else { return false }
        sendControl(.uiTreeRequest(requestID: requestID, windowID: windowID,
                                   maxNodes: UInt16(clamping: max(1, maxNodes))))
        return true
    }

    /// The host stores viewer logs sent with VIEWER_LOG (WireCaps.logUpload).
    public var hostAcceptsLogs: Bool { state == .running && hostCaps & WireCaps.logUpload != 0 }

    /// One chunk of a log upload (see ControlMessage.viewerLog). False if the
    /// session can't take it (not running, host lacks the cap, bad chunk).
    @discardableResult
    public func sendViewerLogChunk(name: String, offset: UInt32, total: UInt32, data: [UInt8]) -> Bool {
        guard hostAcceptsLogs, ControlMessage.isSafeLogName(name),
              data.count <= ControlMessage.maxViewerLogChunk, total <= ControlMessage.maxViewerLogTotal,
              UInt64(offset) + UInt64(data.count) <= UInt64(total) else { return false }
        sendControl(.viewerLog(name: name, offset: offset, total: total, data: data))
        return true
    }

    /// Client quality policy (viewer → host, QUALITY). Sent on connect and when
    /// the presented scale or the user's floor/preference changes. `floor`
    /// is a `QualityFloor` (0 = automatic, 1–3 = keep high/medium/low).
    public func sendQualityPolicy(presentedScalePct: Int, floor: Int, preferSharpness: Bool) {
        guard state == .running else { return }
        sendControl(.quality(presentedScalePct: UInt8(clamping: presentedScalePct),
                             floor: UInt8(clamping: min(max(floor, 0), Int(QualityFloor.maxKnown))),
                             preferSharpness: preferSharpness ? 1 : 0))
    }
    public private(set) var grid: TileGrid?

    private let transport: any GlassActTransport
    private var deframer = ControlDeframer()
    private let lz4 = LZ4Codec()
    private var canvas: UnsafeMutableRawBufferPointer?
    private var tileSeq = ContiguousArray<UInt32>()
    // Video overlay: region video decodes here, never
    // into the canvas, which stays exactly-as-coded (INV-8). A tile shows
    // the overlay while it holds video newer than the canvas's record
    // (`overlayOn` and newer(overlaySeq, tileSeq)); a newer record, or the
    // host's STOP reveal, hands it back to the canvas. Canvas-sized,
    // allocated on the first overlay frame.
    private var overlay: UnsafeMutableRawBufferPointer?
    private var overlaySeq = ContiguousArray<UInt32>()
    private var overlayOn = ContiguousArray<Bool>()
    private var decodeScratch: UnsafeMutableRawBufferPointer
    private var scrollWrites: ContiguousArray<Bool> = [] // SCROLL op: per-tile "this op writes it"
    private var scrollSkipped = ContiguousArray<UInt16>() // SCROLL_ACK report, capacity = tile count
    /// Encode buffer for the per-batch control frames (ACK, NACK, SCROLL_ACK,
    /// KEYFRAME_ACK, PONG — ControlFrames): sized for the largest ACK and a
    /// SCROLL_ACK listing every tile of the largest grid. The only
    /// allocation left per message is the Data the transport API takes.
    private let controlScratch: UnsafeMutableRawBufferPointer
    private var appliedCaptureTS = ContiguousArray<UInt64>()
    // Components: values stored inline (no per-datagram ARC or indirection),
    // confined to this engine's queue like everything else here. Canvas,
    // tileSeq, stats and the control stream stay with the engine; components
    // get what they need as parameters and hand back outcomes.
    private var dirty = DirtyTiles()
    private var reassembler = TileReassembler()
    private var tileCache = ViewerTileCache()
    private var keyframes = KeyframeApplier()
    private var video: VideoRegionTable
    private var acks = AckTracker()
    private let supportedVideoCodecs: [UInt8]
    /// Codec of the (first) active video region, nil when none is live.
    /// Engine-queue confined, like everything else here.
    public var activeVideoCodec: UInt8? {
        video.activeCodec
    }
    /// Fired on the engine queue when a video START lands (codec id) or the
    /// last region STOPs (nil) — status/log surface for the app.
    public var onVideoCodecChanged: ((UInt8?) -> Void)?
    /// Connect milestones (see SessionMilestones). Engine-queue.
    public private(set) var milestones = SessionMilestones()
    /// `nowUS` of the datagram being applied (tile milestones).
    private var rxNowUS: UInt64 = 0
    private var videoDeframer = VideoDeframer()
    /// Incomplete ACK slots older than this are abandoned: the host has
    /// long since timed the batch out (its timeout is capped at a few s).
    public static let ackSlotExpiryUS: UInt64 = AckTracker.slotExpiryUS

    /// The computer this viewer runs on, sent once (VIEWER_INFO) after the
    /// first HELLO_OK so the host can name it. Empty = don't send.
    public var deviceName = ""
    private var sentViewerInfo = false

    /// Handshake geometry request: (mode, widthPoints, heightPoints, scale).
    /// Included in HELLO_OK when the host's HELLO geometry differs and the
    /// host hasn't marked it final — the host then HOLDS pixel data, applies,
    /// and re-offers. Nil = Native (accept whatever the host has).
    public var requestedGeometry: (mode: UInt8, widthPoints: Int, heightPoints: Int, scale: Int)?

    /// Cursor as metadata: whether to advertise WireCaps.cursor. Client
    /// policy — metadata mode wins on pointer latency but can mis-report
    /// transient cursor shapes (drag badges); opting out keeps the host
    /// burning the pointer into pixels.
    private let advertiseCursor: Bool

    public init(transport: any GlassActTransport,
                videoDecoderFactory: (() -> any VideoRegionDecoder)? = nil,
                supportedVideoCodecs: [UInt8] = [VideoCodec.hevc],
                advertiseCursor: Bool = true) {
        self.transport = transport
        self.advertiseCursor = advertiseCursor
        self.video = VideoRegionTable(decoderFactory: videoDecoderFactory)
        self.supportedVideoCodecs = supportedVideoCodecs
        // One spare byte: the Compression framework returns dst.count for a
        // stream that decodes to MORE than fits, so with an exactly-sized
        // buffer an oversize LZ4/LZBITMAP payload passed the `== tightLen`
        // checks with truncated content. With the spare byte it decodes to
        // tightLen + 1 and fails them.
        decodeScratch = .allocate(byteCount: Self.maxTilePayload + 1, alignment: 64)
        let maxTiles = (TileGrid.maxDimension / TileGrid.tileSize) * (TileGrid.maxDimension / TileGrid.tileSize)
        controlScratch = .allocate(byteCount: max(ControlFrames.maxAckBytes,
                                                  ControlFrames.scrollAckBytes(skippedCount: maxTiles)),
                                   alignment: 16)
    }

    deinit {
        controlScratch.deallocate()
        decodeScratch.deallocate()
        canvas?.deallocate()
        overlay?.deallocate()
    }

    /// Video caps for HELLO_OK: one bit per supported codec, none without a
    /// decoder factory (headless agents run video-less).
    private var videoCaps: UInt32 {
        video.decodesRegions ? supportedVideoCodecs.reduce(0) { $0 | WireCaps.bit(forVideoCodec: $1) } : 0
    }

    /// Tiles currently presenting video from the overlay (0 once a dissolve
    /// has fully settled).
    public var overlayVisibleTileCount: Int {
        var n = 0
        for t in 0..<overlayOn.count where overlayShows(t) { n += 1 }
        return n
    }

    @inline(__always)
    /// Whether tile `t` currently presents video (vs its canvas copy).
    public func tileShowsVideo(_ t: Int) -> Bool {
        t >= 0 && t < overlayOn.count && overlayShows(t)
    }

    private func overlayShows(_ t: Int) -> Bool {
        overlayOn[t] && Serial.newer(overlaySeq[t], than: tileSeq[t])
    }

    // MARK: - Control plane

    public func handleControl(_ data: Data, nowUS: UInt64) {
        guard state != .failed else { return }
        lastControlRxUS = nowUS
        stats.bytesIn += data.count
        deframer.append(data)
        while let event = deframer.next() {
            guard case let .message(message) = event else { continue }
            switch message {
            case let .hello(ver, width, height, tileSize, pixfmt, hostCaps):
                self.hostCaps = hostCaps
                milestones.hellos += 1
                if milestones.firstHelloUS == 0 { milestones.firstHelloUS = max(nowUS, 1) }
                // In-session geometry change (§4.10): a HELLO while already running
                // is the host re-offering new capture dimensions on the SAME
                // connection (window resize / fullscreen / pick). Reconfigure
                // the canvas, ACK, and keep the session — no reconnect. The
                // host holds nextFrameSeq monotonic across its rebuild, so LWW
                // stays coherent even as tileSeq resets here.
                if state == .running {
                    guard WireVersion.isCompatible(ver),
                          tileSize == UInt8(TileGrid.tileSize),
                          pixfmt == PixelFormat.bgra8sRGB,
                          width >= 1, height >= 1, width <= TileGrid.maxDimension, height <= TileGrid.maxDimension
                    else {
                        // Ignoring it left the host holding pixels until its
                        // HELLO_OK that never comes — a silent wedge. Fail
                        // loudly so the app reconnects.
                        enterFailed("in-session HELLO rejected (\(width)×\(height), ver \(ver))")
                        return
                    }
                    if Int(width) != grid?.width || Int(height) != grid?.height {
                        reconfigure(width: Int(width), height: Int(height))
                        onGeometryChanged?(Int(width), Int(height))
                    }
                    // Accept unconditionally in-session (geoMode 0): window mode
                    // is host-authoritative — no geometry to negotiate.
                    sendControl(.helloOK(ver: WireVersion.current,
                                         caps: (advertiseCursor ? WireCaps.cursor : 0) | videoCaps,
                                         geoMode: GeometryMode.none, geoWidth: 0, geoHeight: 0, geoScale: 0))
                    break
                }
                guard state == .awaitingHello else { break }
                // Handshake geometry: request a different session geometry IN
                // the HELLO_OK — the host holds pixel data until settled, so
                // nothing streams at a size we're about to reject. A host
                // that already applied its best effort marks the HELLO with
                // geometryFinal; accept whatever it offers then.
                // Explicit geometry every session (native included, mode 3):
                // the host holds pixels, applies deterministically, and
                // re-offers with geometryFinal — no reliance on inherited
                // host state. Sent whenever a preference is set and the host
                // hasn't already finalized this handshake.
                var geo: (mode: UInt8, w: Int, h: Int, s: Int)?
                if let want = requestedGeometry, hostCaps & WireCaps.geometryFinal == 0 {
                    // A virtual display only from a host that offers one (a
                    // host without the virtual-display SPI can't make one);
                    // otherwise the closest thing, Client Resolution.
                    let mode = want.mode == GeometryMode.virtualDisplay && hostCaps & WireCaps.virtualDisplay == 0
                        ? GeometryMode.clientResolution : want.mode
                    geo = (mode, want.widthPoints, want.heightPoints, want.scale)
                }
                // Reply first so the host learns our version even on mismatch;
                // both sides then fail symmetrically.
                sendControl(.helloOK(ver: WireVersion.current,
                                     caps: (advertiseCursor ? WireCaps.cursor : 0) | videoCaps,
                                     geoMode: geo?.mode ?? GeometryMode.none,
                                     geoWidth: UInt16(clamping: geo?.w ?? 0),
                                     geoHeight: UInt16(clamping: geo?.h ?? 0),
                                     geoScale: UInt8(clamping: geo?.s ?? 0)))
                if !sentViewerInfo, !deviceName.isEmpty {
                    sentViewerInfo = true
                    let name = String(deviceName.utf8Prefix(ControlMessage.maxViewerNameBytes))
                    if !name.isEmpty { sendControl(.viewerInfo(name: name)) }
                }
                if geo != nil {
                    // Stay unconfigured: the host applies the request and
                    // re-offers HELLO with geometryFinal on this SAME
                    // connection (no reconnect); we configure from that one.
                    break
                }
                guard WireVersion.isCompatible(ver),
                      tileSize == UInt8(TileGrid.tileSize),
                      pixfmt == PixelFormat.bgra8sRGB,
                      width >= 1, height >= 1, width <= TileGrid.maxDimension, height <= TileGrid.maxDimension // INV-6: bound canvas allocation
                else {
                    enterFailed("HELLO rejected (\(width)×\(height), ver \(ver))")
                    return
                }
                configure(width: Int(width), height: Int(height))
                state = .running
                milestones.runningUS = max(nowUS, 1)
            case let .ping(nonce, tUS):
                // Cross-machine clock offset estimate for glass-to-glass
                // telemetry: (viewer now − host send time) = offset + one-way
                // delay; the minimum over samples is the tightest bound.
                let offsetSample = Int64(bitPattern: nowUS) &- Int64(bitPattern: tUS)
                hostClockOffsetEstimateUS = min(hostClockOffsetEstimateUS ?? offsetSample, offsetSample)
                sendFrame { ControlFrames.pong(nonce: nonce, tUS: tUS, recvTUS: nowUS, into: $0) }
            case let .scroll(frameSeq, x, y, width, height, dx, dy):
                applyScroll(seq: frameSeq, x: Int(x), y: Int(y),
                            rectW: Int(width), rectH: Int(height),
                            dx: Int(dx), dy: Int(dy))
            case let .cursorPos(x, y, visible):
                onCursorPos?(Int(x), Int(y), visible)
            case let .cursorImage(width, height, hotspotX, hotspotY, scale, bgra):
                onCursorImage?(Int(width), Int(height), Int(hotspotX), Int(hotspotY), Int(scale), bgra)
            case let .clipboard(format, data):
                onClipboard?(format, data)
            case let .windowList(windows):
                onWindowList?(windows)
            case let .windowControl(action, _, _):
                // Host → viewer endSession: the shared window is gone (closed,
                // or its app quit) — the session is over, not interrupted.
                if action == WindowAction.endSession {
                    onHostEndedSession?("the shared window was closed on the host")
                }
            case let .agentScope(control, reason):
                onAgentScope?(control, reason)
            case let .uiTree(requestID, status, json):
                onUITree?(requestID, status, json)
            case .helloOK, .ack, .pong, .scrollAck, .pauseHint, .keyframeAck, .deltaNack,
                 .resize, .input, .quality, .windowSelect, .viewerLog, .textInput, .agentState, .uiTreeRequest,
                 .viewerInfo:
                break // viewer-originated / not addressed to the viewer
            }
        }
        if deframer.isMalformed {
            enterFailed("malformed control stream")
        }
    }

    private func enterFailed(_ reason: String) {
        guard state != .failed else { return }
        state = .failed
        onFailed?(reason)
    }

    // MARK: - Video stream (§3.7, §5)

    public func handleVideo(_ data: Data, nowUS: UInt64) {
        // No factory guard here: keyframes decode via in-tree VP8L; the
        // region cases check the factory themselves.
        guard state == .running else { return }
        stats.bytesIn += data.count
        videoDeframer.append(data)
        // `state` re-checked per message: a region escalating to .failed
        // mid-chunk must not let a later keyframe apply and ACK.
        while state == .running, let event = videoDeframer.next() {
            guard case let .message(message) = event else { continue }
            switch message {
            case let .start(region, generation, x, y, w, h, codec, config):
                if milestones.videoStartUS == 0 { milestones.videoStartUS = max(nowUS, 1) }
                applyVideoStart(region: Int(region), generation: generation,
                                x: Int(x), y: Int(y), w: Int(w), h: Int(h),
                                codec: codec, config: config)
            case let .frame(region, generation, seq, sync, captureUS, claims, frameData):
                if milestones.firstVideoRxUS == 0 {
                    milestones.firstVideoRxUS = max(nowUS, 1)
                    milestones.firstVideoBytes = frameData.count
                    milestones.firstVideoSync = sync
                }
                applyVideoFrame(region: Int(region), generation: generation,
                                stamp: seq, sync: sync, captureUS: captureUS, claims: claims,
                                data: frameData, nowUS: nowUS)
            case let .stop(region, generation, reveal):
                applyVideoStop(region: Int(region), generation: generation, reveal: reveal)
            case let .reveal(region, generation, tiles):
                applyVideoReveal(region: Int(region), generation: generation, tiles: tiles)
            case let .keyframe(seq, x, y, w, h, codec, stripes):
                let painted = stats.keyframesApplied + stats.lossyPaintsApplied
                applyKeyframe(seq: seq, x: Int(x), y: Int(y), w: Int(w), h: Int(h),
                              codec: codec, stripes: stripes)
                if milestones.firstKeyframeUS == 0, stats.keyframesApplied + stats.lossyPaintsApplied > painted {
                    milestones.firstKeyframeUS = max(nowUS, 1)
                }
            }
        }
        // A malformed video stream is unrecoverable in-session (the byte
        // stream has lost framing), and ignoring it froze every region —
        // the whole screen, in pinned mode — while motion lasted. The canvas
        // is still LWW-correct, but only a reconnect restores video.
        if videoDeframer.isMalformed {
            enterFailed("malformed video stream")
        }
    }

    /// The transport replaced or lost the video stream (see QUICTransport
    /// `onVideoReset`): discard any partial TLV so the new stream's bytes
    /// frame from scratch. Regions resynchronize from the host's next START.
    public func resetVideoStream() {
        videoDeframer = VideoDeframer()
    }

    /// Lossless keyframe apply (§4.7, see KeyframeApplier); the ACK goes out only on
    /// successful lossless application.
    private func applyKeyframe(seq: UInt32, x: Int, y: Int, w: Int, h: Int,
                               codec: UInt8, stripes: [[UInt8]]) {
        guard let grid, let canvas else {
            stats.keyframesDropped += 1
            return
        }
        switch keyframes.apply(seq: seq, x: x, y: y, w: w, h: h, codec: codec, stripes: stripes,
                               canvas: canvas, grid: grid, tileSeq: &tileSeq, dirty: &dirty) {
        case .dropped:
            stats.keyframesDropped += 1
        case .appliedTransient:
            stats.lossyPaintsApplied += 1
        case .applied:
            stats.keyframesApplied += 1
            sendFrame { ControlFrames.keyframeAck(seq: seq, into: $0) }
        }
    }

    private func applyVideoStart(region: Int, generation: UInt32,
                                 x: Int, y: Int, w: Int, h: Int,
                                 codec: UInt8, config: [UInt8]) {
        guard let grid,
              video.start(region: region, generation: generation, x: x, y: y, w: w, h: h,
                          codec: codec, config: config, grid: grid) else {
            stats.videoDropped += 1
            return
        }
        stats.videoStarts += 1
        onVideoCodecChanged?(codec)
    }

    private func applyVideoFrame(region: Int, generation: UInt32, stamp: UInt32,
                                 sync: Bool, captureUS: UInt64, claims: VideoClaims,
                                 data: [UInt8], nowUS: UInt64) {
        guard let canvas, let grid else {
            stats.videoDropped += 1
            return
        }
        if overlay == nil {
            let o = UnsafeMutableRawBufferPointer.allocate(byteCount: canvas.count, alignment: 16_384)
            o.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: canvas.count)
            overlay = o
        }
        let result = video.applyFrame(region: region, generation: generation, stamp: stamp,
                                      sync: sync, claims: claims, data: data, nowUS: nowUS,
                                      overlay: overlay!, grid: grid, tileSeq: tileSeq, dirty: &dirty,
                                      overlaySeq: &overlaySeq, overlayOn: &overlayOn)
        guard !result.dropped else {
            stats.videoDropped += 1
            return
        }
        if result.blits > 0 && milestones.firstVideoAppliedUS == 0 {
            milestones.firstVideoAppliedUS = max(nowUS, 1)
        }
        for _ in 0..<result.blits {
            stats.videoFramesApplied += 1
            // Video-path glass-to-glass: the frame is on the overlay; feed the
            // capture_ts to the same telemetry the tile path uses (present
            // stamps the on-glass time and the app corrects the host offset).
            if captureUS > 0 && appliedCaptureTS.count < 8192 {
                appliedCaptureTS.append(captureUS)
            }
        }
        if !result.decoded {
            stats.videoDecodeFailures += 1
            if result.undecodableTooLong {
                enterFailed("video region undecodable for > \(VideoRegionTable.undecodableLimitUS / 1000) ms")
            }
        }
    }

    /// REVEAL: the host handed these tiles back to their exact canvas copy
    /// while the region keeps running (see VideoMessage.reveal).
    private func applyVideoReveal(region: Int, generation: UInt32, tiles: [UInt8]) {
        guard video.isCurrent(region: region, generation: generation) else { return }
        for t in 0..<min(overlayOn.count, tiles.count * 8)
        where overlayOn[t] && tiles[t >> 3] & (1 << UInt8(t & 7)) != 0 {
            overlayOn[t] = false
            dirty.mark(t)
        }
    }

    private func applyVideoStop(region: Int, generation: UInt32, reveal: [UInt8]) {
        guard video.stop(region: region, generation: generation) else { return }
        // Tiles the host says are unchanged under the video show the canvas
        // again now; the rest keep the last video frame until their (newer)
        // repaint record lands.
        for t in 0..<min(overlayOn.count, reveal.count * 8)
        where overlayOn[t] && reveal[t >> 3] & (1 << UInt8(t & 7)) != 0 {
            overlayOn[t] = false
            dirty.mark(t)
        }
        stats.videoStops += 1
        onVideoCodecChanged?(activeVideoCodec)
    }

    private func configure(width: Int, height: Int) {
        let g = TileGrid(width: width, height: height)
        grid = g
        let byteCount = width * height * 4
        let c = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 16_384) // page-aligned (§5)
        c.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        canvas = c
        tileSeq = ContiguousArray(repeating: 0, count: g.count)
        overlaySeq = ContiguousArray(repeating: 0, count: g.count)
        overlayOn = ContiguousArray(repeating: false, count: g.count)
        dirty.reset(tileCount: g.count)
        reassembler.reset(tileCount: g.count)
        scrollWrites = ContiguousArray(repeating: false, count: g.count)
        scrollSkipped.removeAll(keepingCapacity: true)
        scrollSkipped.reserveCapacity(g.count)
        tileCache.reset()
    }

    /// In-session canvas resize (re-HELLO on the live connection, §4.10). Frees
    /// the dim-scoped buffers, reallocates at the new size via `configure`, and
    /// resets all transient state so the fresh cold-start applies cleanly.
    /// Engine-queue confined. Correctness rests on the host keeping
    /// nextFrameSeq monotonic across its rebuild: tileSeq resets to 0 here, so
    /// every new record (larger seq) wins, and the host re-sends every tile.
    private func reconfigure(width: Int, height: Int) {
        // Live video regions are old-canvas scoped — stop their decoders.
        video.stopAll()
        // Free everything configure() reallocates (else the pointers leak).
        canvas?.deallocate()
        overlay?.deallocate()
        overlay = nil
        keyframes.releaseScratch()
        configure(width: width, height: height)
        appliedCaptureTS.removeAll(keepingCapacity: true)
        acks.reset()
        // NB: the video stream is reliable + ordered and spans the engine swap
        // continuously — do NOT reset videoDeframer here (that
        // could misframe trailing bytes). Stale frames are dropped by the
        // region generation guard now that the slots are cleared above.
    }

    // MARK: - SCROLL op (§4.8)

    /// Applies a reliable scroll op: each destination pixel in the (clamped)
    /// rect takes the pre-op content at `+ (dx, dy)`. Gated per tile by
    /// `newer(seq, tileSeq)` — a residual record of the following batch that
    /// arrived *before* this op leaves its tile untouched here, and either
    /// ordering converges to the same canvas. Row spans whose source falls
    /// outside the canvas are skipped (the host invalidates and re-sends those
    /// tiles as residuals).
    private func applyScroll(seq: UInt32, x: Int, y: Int, rectW: Int, rectH: Int, dx: Int, dy: Int) {
        guard state == .running, let grid, let canvas else { return }
        let width = grid.width
        let height = grid.height
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(width, x + rectW)
        let y1 = min(height, y + rectH)
        guard x0 < x1, y0 < y1 else { return }
        let base = canvas.baseAddress!
        let tileSize = TileGrid.tileSize
        let tr0 = y0 / tileSize, tr1 = (y1 - 1) / tileSize
        let tc0 = x0 / tileSize, tc1 = (x1 - 1) / tileSize
        scrollSkipped.removeAll(keepingCapacity: true)
        var digest: UInt64 = 0

        // Which rect tiles this op writes (LWW); skipped ones keep their
        // content and still serve as pre-op sources.
        for tr in tr0...tr1 {
            for tc in tc0...tc1 {
                let idx = tr * grid.cols + tc
                scrollWrites[idx] = Serial.newer(seq, than: tileSeq[idx])
                if !scrollWrites[idx] {
                    traceTile(idx, "viewer scroll-SKIP seq=\(seq) tileSeq=\(tileSeq[idx])")
                }
            }
        }

        // In place, no snapshot (it was a full-canvas copy — 59 MB at 5K —
        // per scroll op). Every destination must read PRE-op content, so rows
        // are visited moving away from their sources: dy > 0 reads rows below
        // → ascending; dy < 0 → descending. Source rows are then always
        // untouched when read. Within one row (dy == 0) the spans are visited
        // in the direction of dx and moved with memmove.
        let rowStride = width * 4
        let colsForward = dx >= 0
        func copyRow(_ row: Int) {
            let srcRow = row + dy
            guard srcRow >= 0, srcRow < height else { return }
            let tr = row / tileSize
            for step in 0...(tc1 - tc0) {
                let tc = colsForward ? tc0 + step : tc1 - step
                let idx = tr * grid.cols + tc
                guard scrollWrites[idx] else { continue }
                let spanX0 = max(tc * tileSize, x0)
                let spanX1 = min(tc * tileSize + tileSize, x1, width)
                guard spanX0 < spanX1, spanX0 + dx >= 0, spanX1 + dx <= width else { continue }
                memmove(base.advanced(by: row * rowStride + spanX0 * 4),
                        base.advanced(by: srcRow * rowStride + (spanX0 + dx) * 4),
                        (spanX1 - spanX0) * 4)
            }
        }
        if dy > 0 {
            for row in y0..<y1 { copyRow(row) }
        } else {
            for row in stride(from: y1 - 1, through: y0, by: -1) { copyRow(row) }
        }

        for tr in tr0...tr1 {
            for tc in tc0...tc1 {
                let idx = tr * grid.cols + tc
                guard scrollWrites[idx] else { continue }
                scrollWrites[idx] = false
                let (tx, ty, tw, th) = grid.rect(of: idx)
                guard max(tx, x0) < min(tx + tw, x1), max(ty, y0) < min(ty + th, y1) else { continue }
                tileSeq[idx] = seq
                // Verified scroll promotion: fold the actual written result so
                // the host can check its optimistic mirror marks.
                let h = XXH64.hashRows(frame: UnsafeRawBufferPointer(canvas),
                                       bytesPerRow: rowStride, x: tx, y: ty, tw: tw, th: th)
                digest ^= scrollDigestMix(tile: idx, hash: h)
                traceTile(idx, "viewer scroll-write seq=\(seq) dy=\(dy) resultHash=\(String(h, radix: 16))")
                dirty.mark(idx)
            }
        }
        stats.scrollsApplied += 1
        // Contamination report: ANY tile already carrying a seq ≥ this scroll's
        // (a record from this-or-a-later batch beat the TLV) may have polluted
        // the pre-scroll snapshot — including tiles OUTSIDE the rect that
        // in-rect destinations sourced from (found via per-tile tracing of a
        // real-trace golden divergence). In-rect such tiles were LWW-skipped
        // above; out-of-rect ones are collected here.
        for idx in 0..<tileSeq.count where !Serial.newer(seq, than: tileSeq[idx]) && tileSeq[idx] != seq {
            scrollSkipped.append(UInt16(idx))
        }
        // Always sent: the digest verifies the host's optimistic promotion
        // even when nothing was LWW-skipped.
        scrollSkipped.withUnsafeBufferPointer { skipped in
            sendFrame { ControlFrames.scrollAck(frameSeq: seq, skipped: skipped, digest: digest, into: $0) }
        }
    }

    // MARK: - Datagram apply (§5)

    public func handleDatagram(_ data: Data, nowUS: UInt64) {
        rxNowUS = nowUS
        guard state == .running else { return }
        let signpostState = Signposts.viewer.beginInterval("apply", id: Signposts.viewer.makeSignpostID())
        defer { Signposts.viewer.endInterval("apply", signpostState) }
        stats.datagramsReceived += 1
        stats.bytesIn += data.count
        let ok = data.withUnsafeBytes { buf -> Bool in
            var headerReader = ByteReader(buf)
            guard let header = DatagramHeader.parse(&headerReader) else { return false }
            guard Datagram.parse(buf, { [self] h, record in
                processRecord(h, record, nowUS: nowUS)
            }) else { return false }
            acks.note(header, nowUS: nowUS) { sendAck(frameSeq: $0, dgramCnt: $1, bitmap: $2) }
            return true
        }
        if !ok {
            stats.malformedDatagrams += 1 // INV-6: reject atomically, never crash
        }
    }

    /// ACK cadence (§3.5) + reassembly expiry. Call regularly (~1 ms in tests).
    public func tick(nowUS: UInt64) {
        guard state == .running else { return }
        acks.tick(nowUS: nowUS) { sendAck(frameSeq: $0, dgramCnt: $1, bitmap: $2) }
        reassembler.expire(nowUS: nowUS) { tile, seq in
            stats.reasmExpired += 1
            // Received ≠ applied (the DELTA_NACK principle, third instance):
            // this partial's datagrams may all have been delivered and ACKed
            // — spread past the expiry window by queuing/reorder — in which
            // case the host has promoted a tile this canvas never applied,
            // and static content then never re-qualifies: a permanent stale
            // square. Report it so the host demotes and re-sends.
            sendFrame { ControlFrames.deltaNack(frameSeq: seq, tile: UInt16(tile), into: $0) }
        }
    }

    /// Received ≠ applied (the DELTA_NACK principle, general form): the
    /// datagram carrying this record will be ACKed, and on that ACK the host
    /// promotes the tile as delivered. If the record would have won the LWW
    /// gate but could not be applied (malformed, undecodable, reassembly
    /// rejected), the canvas keeps stale pixels the host believes are
    /// current — and static content never re-qualifies. NACK so the host
    /// demotes the tile and re-sends it absolute. (NACKs precede the batch
    /// ACK: records are processed before `acks.note`, on the ordered control
    /// stream.) A record that lost LWW needs no NACK — the newer send owns
    /// the host's in-flight slot, so this one's ACK is stale there anyway.
    private func rejectRecord(tile: Int, seq: UInt32) {
        stats.recordsSkipped += 1
        guard Serial.newer(seq, than: tileSeq[tile]) else { return }
        stats.recordsRejectedNacked += 1
        sendFrame { ControlFrames.deltaNack(frameSeq: seq, tile: UInt16(tile), into: $0) }
    }

    private func processRecord(_ header: DatagramHeader, _ record: TileRecord, nowUS: UInt64) {
        guard let grid, Int(record.tileIdx) < grid.count else {
            stats.recordsSkipped += 1
            return
        }
        let tile = Int(record.tileIdx)
        guard record.payload.count <= Self.maxTilePayload + 16 else {
            rejectRecord(tile: tile, seq: header.frameSeq)
            return
        }
        // INV-2: per-tile LWW — never drop a whole batch as stale. Cache
        // records bypass this pre-gate: a canvas-stale STORE must still store
        // (receipt ⇒ stored); applyCacheRecord re-applies the canvas gate.
        guard Serial.newer(header.frameSeq, than: tileSeq[tile]) || record.opcode == Opcode.cache else {
            stats.recordsStale += 1
            traceTile(tile, "viewer stale-block seq=\(header.frameSeq) tileSeq=\(tileSeq[tile])")
            return
        }
        if record.fragCnt == 1 {
            applyPayload(tile: tile, seq: header.frameSeq, opcode: record.opcode,
                         payload: record.payload, captureTimestampUS: header.captureTimestampUS)
        } else {
            switch reassembler.reassemble(tile: tile, opcode: record.opcode,
                                          fragIdx: record.fragIdx, fragCnt: record.fragCnt,
                                          payload: record.payload, seq: header.frameSeq,
                                          captureTimestampUS: header.captureTimestampUS, nowUS: nowUS) {
            case .pending, .ignored:
                break
            case .rejected:
                rejectRecord(tile: tile, seq: header.frameSeq)
            case let .complete(opcode, seq, captureTimestampUS, payload):
                // Re-check LWW: a newer unfragmented record may have applied
                // meanwhile. Cache records pass through — their store must
                // proceed regardless, and applyCacheRecord re-gates the
                // canvas write.
                guard Serial.newer(seq, than: tileSeq[tile]) || opcode == Opcode.cache else {
                    stats.recordsStale += 1
                    return
                }
                applyPayload(tile: tile, seq: seq, opcode: opcode, payload: payload,
                             captureTimestampUS: captureTimestampUS)
            }
        }
    }

    /// Hash-pinned DELTA (§4.8): verify the canvas tile hashes to the pinned
    /// base, then apply XOR (mode 0) or blit the absolute sub-rect (mode 1).
    /// A base mismatch is a clean drop (expected count: zero — quiescent-
    /// acked discipline makes the base provable; the stat exists so any
    /// unforeseen desync is loud in telemetry rather than silent).
    private func applyDelta(tile: Int, seq: UInt32,
                            payload: UnsafeRawBufferPointer, captureTimestampUS: UInt64) {
        guard let grid, let canvas else { return }
        let (x, y, tw, th) = grid.rect(of: tile)
        guard let delta = DeltaPayload.parse(payload, tileWidth: tw, tileHeight: th),
              let source = decodeInner(delta.innerOpcode, delta.inner, width: delta.width, height: delta.height)
        else {
            rejectRecord(tile: tile, seq: seq)
            return
        }
        guard Serial.newer(seq, than: tileSeq[tile]) else {
            stats.recordsStale += 1
            return
        }
        // Pin: the canvas tile must be exactly the base the host diffed against.
        let current = XXH64.hashRows(frame: UnsafeRawBufferPointer(canvas),
                                     bytesPerRow: grid.width * 4, x: x, y: y, tw: tw, th: th)
        guard current == delta.baseHash else {
            stats.deltaBaseMisses += 1
            traceTile(tile, "viewer DELTA base-miss seq=\(seq)")
            // Received ≠ applied for a hash-pinned residual: the host's
            // bitmap ACK would otherwise promote this record's target hash
            // as acked and every later delta would pin to a base this canvas
            // never had (a measured permanent-divergence spiral). Report it
            // so the host demotes the tile and heals with an absolute record.
            sendFrame { ControlFrames.deltaNack(frameSeq: seq, tile: UInt16(tile), into: $0) }
            return
        }
        if delta.mode == 0 {
            // `source` may point into the datagram at any byte offset: read
            // it unaligned (binding it as UInt32 was undefined behaviour).
            for row in 0..<th {
                let canvasRow = canvas.baseAddress!
                    .advanced(by: ((y + row) * grid.width + x) * 4)
                    .assumingMemoryBound(to: UInt32.self)
                for col in 0..<tw {
                    canvasRow[col] ^= source.loadUnaligned(fromByteOffset: (row * tw + col) * 4,
                                                           as: UInt32.self)
                }
            }
        } else {
            for row in 0..<delta.height {
                canvas.baseAddress!
                    .advanced(by: ((y + delta.y + row) * grid.width + x + delta.x) * 4)
                    .copyMemory(from: source.baseAddress!.advanced(by: row * delta.width * 4),
                                byteCount: delta.width * 4)
            }
        }
        commitTile(tile, seq: seq, captureTimestampUS: captureTimestampUS)
        stats.deltasApplied += 1
        traceTile(tile, "viewer DELTA apply seq=\(seq) mode=\(delta.mode)")
    }

    private func applyPayload(tile: Int, seq: UInt32, opcode: UInt8,
                              payload: UnsafeRawBufferPointer, captureTimestampUS: UInt64) {
        guard let grid, let canvas else { return }
        if opcode == Opcode.cache {
            applyCacheRecord(tile: tile, seq: seq, payload: payload,
                             captureTimestampUS: captureTimestampUS)
            return
        }
        if opcode == Opcode.delta {
            applyDelta(tile: tile, seq: seq, payload: payload,
                       captureTimestampUS: captureTimestampUS)
            return
        }
        // Non-cache records reach here only when LWW-newer (pre-gated).
        guard Serial.newer(seq, than: tileSeq[tile]) else {
            stats.recordsStale += 1
            return
        }
        let (x, y, tw, th) = grid.rect(of: tile)
        // Reserved/unknown opcodes land in decodeInner's default: skip, never crash.
        guard let source = decodeInner(opcode, payload, width: tw, height: th) else {
            rejectRecord(tile: tile, seq: seq)
            return
        }
        // INV-8: straight into the canvas rect, exactly as coded.
        TileOps.apply(tight: source, into: canvas, canvasWidth: grid.width, x: x, y: y, tw: tw, th: th)
        traceTile(tile, "viewer apply seq=\(seq) hash=\(String(XXH64.hash([UInt8](source)), radix: 16))")
        commitTile(tile, seq: seq, captureTimestampUS: captureTimestampUS)
    }

    /// Decodes an absolute-codec payload (RAW / LZ4 / LZBITMAP / VP8L) of a
    /// `width × height` BGRA rect; nil unless it decodes to exactly that
    /// many bytes. RAW is returned in place; the rest land in `decodeScratch`
    /// (valid until the next decode).
    private func decodeInner(_ opcode: UInt8, _ payload: UnsafeRawBufferPointer,
                             width: Int, height: Int) -> UnsafeRawBufferPointer? {
        let expected = width * height * 4
        let decoded: Int
        switch opcode {
        case Opcode.raw:
            return payload.count == expected ? payload : nil
        case Opcode.lz4:
            decoded = lz4.decode(src: payload, dst: decodeScratch)
        case Opcode.lzbitmap:
            decoded = lz4.decodeBitmap(src: payload, dst: decodeScratch)
        case Opcode.webpl:
            decoded = WebPTile.decodeLossless(src: payload, width: width, height: height, dst: decodeScratch)
        default:
            return nil
        }
        return decoded == expected ? UnsafeRawBufferPointer(rebasing: decodeScratch[0..<expected]) : nil
    }

    /// A record won LWW and its pixels are on the canvas: advance the tile's
    /// seq, queue it for present, and feed glass-to-glass telemetry.
    private func commitTile(_ tile: Int, seq: UInt32, captureTimestampUS: UInt64) {
        tileSeq[tile] = seq
        dirty.mark(tile)
        if appliedCaptureTS.count < 8192 { // glass-to-glass telemetry (§3.3 capture_ts)
            appliedCaptureTS.append(captureTimestampUS)
        }
        stats.recordsApplied += 1
        if milestones.firstTileUS == 0 { milestones.firstTileUS = max(rxNowUS, 1) }
    }


    // MARK: - Session tile cache (§4.8)

    private func applyCacheRecord(tile: Int, seq: UInt32,
                                  payload: UnsafeRawBufferPointer, captureTimestampUS: UInt64) {
        guard let grid, let canvas else { return }
        let (x, y, tw, th) = grid.rect(of: tile)
        guard tw == TileGrid.tileSize, th == TileGrid.tileSize,  // cache ops are full-tile only
              let op = CachePayload.parse(payload) else {
            rejectRecord(tile: tile, seq: seq)
            return
        }
        switch op {
        case let .storeApply(slotU16, innerOpcode, inner):
            guard Int(slotU16) < ViewerTileCache.slotCount,
                  let source = decodeInner(innerOpcode, inner, width: tw, height: th) else {
                rejectRecord(tile: tile, seq: seq)
                return
            }
            let slot = Int(slotU16)
            traceTile(tile, "viewer STORE decode inner=\(innerOpcode) payloadLen=\(inner.count)")
            // Store on receipt — independent of the canvas LWW gate, but
            // slot-LWW-gated by store seq (see ViewerTileCache.slotSeq).
            if tileCache.store(slot: slot, seq: seq, tile: source) {
                stats.cacheStores += 1
                traceTile(tile, "viewer STORE seq=\(seq) slot=\(slot)")
            } else {
                traceTile(tile, "viewer STORE slot-stale seq=\(seq) slot=\(slot) slotSeq=\(tileCache.storedSeq(slot))")
            }
            // Canvas apply, LWW-gated.
            if Serial.newer(seq, than: tileSeq[tile]) {
                traceTile(tile, "viewer STORE canvas-apply seq=\(seq) was=\(tileSeq[tile]) srcHash=\(String(XXH64.hash([UInt8](source)), radix: 16))")
                TileOps.apply(tight: source, into: canvas, canvasWidth: grid.width,
                              x: x, y: y, tw: tw, th: th)
                commitTile(tile, seq: seq, captureTimestampUS: captureTimestampUS)
            } else {
                stats.recordsStale += 1
            }
        case let .ref(slotU16, expected):
            guard Int(slotU16) < ViewerTileCache.slotCount else {
                rejectRecord(tile: tile, seq: seq)
                return
            }
            let slot = Int(slotU16)
            guard Serial.newer(seq, than: tileSeq[tile]) else {
                traceTile(tile, "viewer REF lww-stale seq=\(seq)")
                stats.recordsStale += 1
                return
            }
            guard let entry = tileCache.lookup(slot: slot, expectedHash: expected) else {
                traceTile(tile, "viewer REF MISS seq=\(seq) slot=\(slot) valid=\(tileCache.isValid(slot))")
                stats.cacheRefMisses += 1
                // Received ≠ applied: the host would promote this tile on
                // the ACK. The NACK also tells it this slot is unusable, so
                // the resend can't REF the same slot and miss again.
                sendFrame { ControlFrames.deltaNack(frameSeq: seq, tile: UInt16(tile), into: $0) }
                return
            }
            traceTile(tile, "viewer REF apply seq=\(seq) slot=\(slot)")
            TileOps.apply(tight: entry, into: canvas, canvasWidth: grid.width,
                          x: x, y: y, tw: tw, th: th)
            commitTile(tile, seq: seq, captureTimestampUS: captureTimestampUS)
            stats.cacheRefsApplied += 1
        }
    }

    // MARK: - ACK generation (§3.5)

    /// Every ACK the tracker emits goes out here, counted once.
    private func sendAck(frameSeq: UInt32, dgramCnt: UInt16, bitmap: UnsafeRawBufferPointer) {
        sendFrame { ControlFrames.ack(frameSeq: frameSeq, dgramCnt: dgramCnt, bitmap: bitmap, into: $0) }
        stats.acksSent += 1
    }

    /// Per-batch control frames: encoded into `controlScratch`, no
    /// intermediate arrays (§8.1). Silent once .failed, like sendControl.
    private func sendFrame(_ write: (UnsafeMutableRawBufferPointer) -> Int) {
        guard state != .failed else { return }
        let n = write(controlScratch)
        transport.sendControl(Data(bytes: controlScratch.baseAddress!, count: n))
    }

    private func sendControl(_ message: ControlMessage) {
        // .failed is terminal and silent (onFailed's contract), whatever
        // path a late send comes from.
        guard state != .failed else { return }
        // An oversize body would make the host tear the stream down.
        guard let bytes = message.encodedForSend() else { return }
        transport.sendControl(Data(bytes))
    }

    // MARK: - Canvas access

    /// RESIZE request (§3.5 reserved slot): ask the host for a session
    /// geometry. The host resets the session; reconnect lands the new HELLO.
    public func requestResize(mode: UInt8, widthPoints: Int, heightPoints: Int, scale: Int) {
        guard state == .running else { return }
        sendControl(.resize(mode: mode, width: UInt16(clamping: widthPoints),
                            height: UInt16(clamping: heightPoints),
                            scale: UInt8(clamping: scale)))
    }

    /// Remote input (viewer → host, reliable). Canvas-pixel coordinates.
    public func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int) {
        guard state == .running else { return }
        sendControl(.input(kind: kind, x: UInt16(clamping: x), y: UInt16(clamping: y),
                           a: Int32(clamping: a), b: Int32(clamping: b)))
    }

    /// Pause content entirely (keep-alives only — the viewer can't be seen)
    /// or resume it. Call on the engine's confining queue.
    public func setContentPaused(_ paused: Bool) {
        guard state == .running else { return }
        sendControl(.pauseHint(paused: paused))
    }

    /// Read access to the canvas (tests, and the present blit).
    public func withCanvas<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R? {
        guard let canvas else { return nil }
        return body(UnsafeRawBufferPointer(canvas))
    }

    /// Present: the buffer each tile shows from — the overlay while it holds
    /// newer video, else the canvas.
    public func withPresentSources<R>(_ body: (_ canvas: UnsafeRawBufferPointer,
                                               _ overlay: UnsafeRawBufferPointer?,
                                               _ showsOverlay: (Int) -> Bool) -> R) -> R? {
        guard let canvas else { return nil }
        guard let overlay else { return body(UnsafeRawBufferPointer(canvas), nil, { _ in false }) }
        return body(UnsafeRawBufferPointer(canvas), UnsafeRawBufferPointer(overlay)) { self.overlayShows($0) }
    }

    /// Drains the capture timestamps of records applied since the last call —
    /// consumed by the present path to compute glass-to-glass latency
    /// (capture_ts → present; same-machine loopback only, §10.1).
    public func drainAppliedCaptureTimestamps(into out: inout [UInt64]) {
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: appliedCaptureTS)
        appliedCaptureTS.removeAll(keepingCapacity: true)
    }

    /// Changes on every canvas or overlay write — compare two reads to tell
    /// whether the picture moved in between (without consuming the present
    /// path's dirty set). Engine queue.
    public var contentVersion: UInt64 { dirty.version }

    /// How many tiles changed after `contentVersion` was `since`, and of how many.
    public func tilesChanged(since: UInt64) -> (changed: Int, total: Int) {
        (dirty.changed(since: since), dirty.tileCount)
    }

    /// Drains the dirty-tile set (present-side consumption).
    public func drainDirtyTiles(into out: inout [Int]) {
        dirty.drain(into: &out)
    }
}
