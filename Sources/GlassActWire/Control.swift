/// Single-window mode (§4.10) — one pickable window in a WINDOW_LIST. `appName`
/// and `title` are UTF-8 for display; `thumb` is a small lossy image in
/// `thumbFormat` (1 = WebP-lossy, 2 = AVIF-still, 0 = none) at
/// `thumbWidth`×`thumbHeight`. All fields are advisory display metadata — the
/// only load-bearing value is `windowID`, echoed back in WINDOW_SELECT.
public struct WireWindow: Equatable, Sendable {
    public var windowID: UInt32
    public var appName: String
    public var title: String
    public var thumbFormat: UInt8
    public var thumbWidth: UInt16
    public var thumbHeight: UInt16
    public var thumb: [UInt8]

    public init(windowID: UInt32, appName: String, title: String,
                thumbFormat: UInt8, thumbWidth: UInt16, thumbHeight: UInt16, thumb: [UInt8]) {
        self.windowID = windowID
        self.appName = appName
        self.title = title
        self.thumbFormat = thumbFormat
        self.thumbWidth = thumbWidth
        self.thumbHeight = thumbHeight
        self.thumb = thumb
    }
}

/// Single-window mode: thumbnail codecs for WireWindow.thumbFormat.
public enum WindowThumbFormat {
    public static let none: UInt8 = 0
    public static let webpLossy: UInt8 = 1
    public static let avif: UInt8 = 2
}

/// Single-window mode: WINDOW_CONTROL actions.
public enum WindowAction {
    public static let fullscreen: UInt8 = 1
    public static let resize: UInt8 = 2
    public static let endSession: UInt8 = 3
}

/// UI_TREE status codes.
public enum UITreeStatus {
    public static let ok: UInt8 = 0
    /// The host lacks Device Control and Data Access (Accessibility).
    public static let notPermitted: UInt8 = 1
    /// No such window, or nothing focused.
    public static let noWindow: UInt8 = 2
    /// This session isn't allowed to read it (view-only agents may; an
    /// agent with control switched off may not).
    public static let refused: UInt8 = 3
    /// The tree didn't fit in one control message.
    public static let tooLarge: UInt8 = 4
    public static let maxKnown: UInt8 = 4
}

/// Flags OR'd into INPUT's `kind`: the low 7 bits are the kind.
public enum InputFlags {
    /// Sent by an agent, not the person at the viewer: the host applies its
    /// agent policy (scope, "you always win", time limit) and audits it.
    public static let agent: UInt8 = 0x80
    public static let kindMask: UInt8 = 0x7F
}

/// QUALITY's `floor`: the lowest video quality the user accepts (Viewer ›
/// Settings › "When the network is slow"). The host's bandwidth loop steps
/// through quality levels 0 (best) to 3; a floor of n (1–3) caps it at
/// level n.
public enum QualityFloor {
    /// No floor: the bandwidth loop may use every level.
    public static let automatic: UInt8 = 0
    public static let high: UInt8 = 1
    public static let medium: UInt8 = 2
    public static let low: UInt8 = 3
    public static let maxKnown: UInt8 = 3
}

/// HELLO_OK geometry modes (geoMode).
public enum GeometryMode {
    public static let none: UInt8 = 0
    public static let clientResolution: UInt8 = 1
    public static let scale: UInt8 = 2
    public static let native: UInt8 = 3
    /// The host shares a virtual display made at the viewer's size.
    public static let virtualDisplay: UInt8 = 4
}

/// §3.5 — control-stream messages (reliable, ordered). TLV framing:
/// `{type u8, len varint, body}`.
/// HOST_NOTICE codes (§3.5).
public enum HostNotice {
    /// Nothing in force: clear what was shown.
    public static let none: UInt8 = 0
    /// The host's login session is off the screen (another user, or the
    /// login window, has it): the host can't capture, so the picture stays
    /// frozen until it comes back.
    public static let sessionOffScreen: UInt8 = 1
}

/// VIEWER_BYE reasons (§3.5): why the viewer is closing the session.
public enum ViewerBye {
    /// Its user ended the session: Disconnect, or the session window closed.
    public static let disconnected: UInt8 = 1
    /// Its user quit the Viewer.
    public static let quit: UInt8 = 2
    /// Nothing arrived from the host for the liveness timeout; redialing.
    public static let hostUnresponsive: UInt8 = 3
    /// The session failed at the viewer (a protocol or decode error); redialing.
    public static let sessionFailed: UInt8 = 4

    /// Whether the viewer left on purpose: what its VIEWER_BYE said, else
    /// (an older viewer, a code this build doesn't know, or the goodbye
    /// lost) whether it closed the control stream cleanly.
    public static func leftOnPurpose(bye: UInt8?, closedCleanly: Bool) -> Bool {
        switch bye {
        case disconnected?, quit?: true
        case hostUnresponsive?, sessionFailed?: false
        default: closedCleanly
        }
    }

    public static func describe(_ reason: UInt8) -> String {
        switch reason {
        case disconnected: "the user disconnected"
        case quit: "the user quit the Viewer"
        case hostUnresponsive: "nothing from the host, reconnecting"
        case sessionFailed: "the session failed at the viewer, reconnecting"
        default: "reason \(reason)"
        }
    }
}

public enum ControlMessage: Equatable, Sendable {
    case hello(ver: UInt8, width: UInt16, height: UInt16, tileSize: UInt8, pixfmt: UInt8, caps: UInt32)
    /// geoMode 0 = no geometry request; 1 Client Resolution, 2 Scale,
    /// 3 Native, 4 virtual display (only to a host advertising
    /// WireCaps.virtualDisplay) — see `GeometryMode`; requested
    /// IN the handshake so no pixel data ever flows at a geometry the
    /// viewer is about to reject (the host holds streaming, applies, and
    /// re-offers with WireCaps.geometryFinal set).
    case helloOK(ver: UInt8, caps: UInt32,
                 geoMode: UInt8, geoWidth: UInt16, geoHeight: UInt16, geoScale: UInt8)
    /// `bitmap` must be exactly `ceil(dgramCnt/8)` bytes; bit set = datagram received.
    case ack(frameSeq: UInt32, dgramCnt: UInt16, bitmap: [UInt8])
    case ping(nonce: UInt64, tUS: UInt64)
    case pong(nonce: UInt64, tUS: UInt64, recvTUS: UInt64)
    /// SCROLL (§4.8) — reliable, ordered scroll op: content of `rect` becomes the
    /// previous content at `+ (dx, dy)` (per destination pixel), gated
    /// per-tile by `frameSeq` under the same LWW rule as records. Residual
    /// tiles follow as ordinary absolute records under a newer seq.
    case scroll(frameSeq: UInt32, x: UInt16, y: UInt16, width: UInt16, height: UInt16, dx: Int16, dy: Int16)
    /// SCROLL_ACK (§4.8) — viewer → host, after applying a SCROLL: the tiles the op
    /// LWW-skipped (their tileSeq was already ≥ the scroll's seq, i.e. a
    /// newer record beat the TLV). The host invalidates destinations that
    /// sourced from these, closing the record-vs-scroll arrival race with a
    /// one-RTT repair. `digest` is an order-independent XOR fold of
    /// mix(tileIdx, post-scroll tile hash) over the tiles the viewer WROTE:
    /// the host compares it against its emit-time mirror marks and demotes
    /// the whole rect on mismatch — scroll promotion is verified, never
    /// trusted (the host's optimistic shifted-shadow promotion is only sound
    /// while its beliefs are true; a scroll racing a mid-heal window can
    /// promote a wrong hash with no later heal path). Sent for EVERY applied
    /// scroll.
    case scrollAck(frameSeq: UInt32, skipped: [UInt16], digest: UInt64)
    /// Viewer → host: the viewer can't be seen (occluded, hidden,
    /// minimized) — `paused` stops all content; false resumes it. While
    /// paused the host sends keep-alives only (PING) and keeps any video
    /// region alive, so resuming is a plain continuation. Changed pixels
    /// are never lost: they still differ from the ACKed shadow and
    /// re-qualify on the first tick after resume.
    case pauseHint(paused: Bool)
    /// Lossless keyframes (§4.7) — viewer → host: a keyframe with this seq
    /// was applied (per-tile LWW permitting). Sent on the reliable control
    /// stream; because the keyframe itself rode a reliable stream, this
    /// acknowledges *application*, and the host promotes acked hashes/shadow
    /// for the covered tiles exactly as a datagram ACK would.
    case keyframeAck(seq: UInt32)
    /// DELTA repair (§4.8) — viewer → host: DELTA records from `frameSeq` whose
    /// pinned base hash did not match the canvas, so they were received but
    /// NOT applied. Receipt does not imply application for hash-pinned
    /// residuals — the host must clear the in-flight slot WITHOUT promoting
    /// the acked hash (and drop any belief already promoted by the bitmap
    /// ACK), so the tile re-qualifies and heals with an absolute record.
    /// Without this, one base-miss cements a permanently wrong acked hash:
    /// every later delta pins to a base the viewer never had (the photos
    /// loop replay diverges). Sent only when non-empty.
    case deltaNack(frameSeq: UInt32, tiles: [UInt16])
    /// Cursor as metadata (§5) — host → viewer, pointer position
    /// in canvas pixels. Rides the control tunnel (measured to stay snappy
    /// even when the datagram path is saturated), so the composited cursor
    /// moves at control latency, independent of frames.
    case cursorPos(x: UInt16, y: UInt16, visible: Bool)
    /// Cursor as metadata — host → viewer, the pointer image: BGRA, `scale` backing
    /// pixels per point (Retina cursors are 2), hotspot in image pixels.
    /// Sent only when the shape changes.
    case cursorImage(width: UInt16, height: UInt16, hotspotX: UInt16, hotspotY: UInt16,
                     scale: UInt8, bgra: [UInt8])
    /// Viewer → host: request a session
    /// geometry. mode 1 = "Client Resolution" (switch the HOST DISPLAY to
    /// the viewer's logical size — Apple High-Performance style; the host
    /// is assumed personal/unattended), mode 2 = "Scale" (host display
    /// stays native; capture output downscales to the viewer's pixel size).
    /// width/height are the viewer's logical points; scale its backing
    /// factor. The host applies it in session and re-HELLOs on the same
    /// connection with the new dimensions (§4.10).
    case resize(mode: UInt8, width: UInt16, height: UInt16, scale: UInt8)
    /// Bidirectional clipboard sync (either side → the other, reliable).
    /// format 1 = UTF-8 plain text (more types later). Each side watches its
    /// pasteboard and pushes on change; an echo guard (content hash) prevents
    /// a received update from bouncing back. On by default,
    /// gate-able. Bounded by maxBodyLength (1 MB) — big/image types deferred.
    case clipboard(format: UInt8, data: [UInt8])
    /// Client quality policy (§3.5 QUALITY), viewer → host — bounds the
    /// host's automatic bandwidth loop with things only the client knows.
    /// presentedScalePct: how the viewer displays the canvas (100 = 1:1,
    /// <100 = downscaled → host may shed detail for free; 0 = unknown).
    /// floor: the lowest video quality the user accepts, a `QualityFloor`
    /// (0 = automatic, 1–3 = keep high / medium / low).
    /// preferSharpness: 1 = under pressure drop FRAMERATE not quality;
    /// 2 = prefer smooth motion on a thin link (only to a host advertising
    /// `WireCaps.smoothnessPreference`).
    case quality(presentedScalePct: UInt8, floor: UInt8, preferSharpness: UInt8)
    /// Remote input (viewer → host, reliable — a dropped keystroke is
    /// unacceptable). One TLV, internally discriminated by `kind`:
    ///   1 mouseMove   x,y (canvas px)
    ///   2 mouseDown   x,y, a = click count (1 single, 2 double…), b = button
    ///                 (0 L, 1 R, 2 other)
    ///   3 mouseUp     x,y, a = click count, b = button
    ///                 The click count is the viewer's (its own double-click
    ///                 speed and slop); a = 0 reads as 1. Without it every
    ///                 click would post as a first click — no double-click
    ///                 anywhere.
    ///   4 scroll      x,y, dx,dy (i16, line-ish units)
    ///   5 keyDown     keycode u16 (CGKeyCode), flags u32 (CGEventFlags subset)
    ///   6 keyUp       keycode, flags
    ///   7 scroll (px) x,y, dx,dy in points — precise devices (trackpad,
    ///                 Magic Mouse). Kind 4's line units would turn every
    ///                 pixel of a trackpad swipe into a line (~10× overscroll).
    ///                 Additive: receivers parse any non-zero kind and
    ///                 ignore unknown ones.
    /// Coordinates are canvas pixels; the host maps to its display. Both ends
    /// are macOS so CGKeyCodes match directly.
    case input(kind: UInt8, x: UInt16, y: UInt16, a: Int32, b: Int32)
    /// Single-window mode — host → viewer: the pickable on-screen windows,
    /// each with an app name, title, and small lossy thumbnail. Sent once when
    /// the viewer enters single-window mode (a HELLO cap gates it — the host
    /// must hold Screen Recording to enumerate). The list is a snapshot; the
    /// viewer picks one with WINDOW_SELECT. Bounded by maxBodyLength: the host
    /// caps window count and thumbnail size so the whole TLV stays under 1 MB.
    case windowList(windows: [WireWindow])
    /// Single-window mode — viewer → host: the chosen window id from a
    /// WINDOW_LIST. The host rebuilds its capture filter around that single
    /// window; the pinned-video path takes over unchanged. `windowID == 0`
    /// reverts to full-display.
    case windowSelect(windowID: UInt32)
    /// Single-window mode — viewer → host: a window-chrome action on the
    /// shared window:
    ///   1 fullscreen  — toggle the host window full-screen (via Accessibility);
    ///                   capture follows to the new geometry
    ///   2 resize      — commit the host window to (width, height) points, after
    ///                   a live viewer resize-drag settles (mouse-up)
    ///   3 endSession  — the viewer closed its window; stop single-window capture
    /// Minimize is viewer-local (hide + pause) and sends nothing — minimizing
    /// the host window would App-Nap the content away. width/height are 0 unless
    /// action == 2.
    case windowControl(action: UInt8, width: UInt16, height: UInt16)
    /// Viewer → host: one chunk of a viewer session-log file,
    /// so a remote user can hand their logs over the live session instead of
    /// a side channel. `name` is a bare file name (1–64 of [A-Za-z0-9._-],
    /// no leading dot); chunks arrive in order (`offset` = bytes already
    /// sent), `total` ≤ 16 MB, one chunk ≤ `maxViewerLogChunk`. Gated on the
    /// host's WireCaps.logUpload.
    case viewerLog(name: String, offset: UInt32, total: UInt32, data: [UInt8])
    /// Agents (§14), viewer → host: type this text as-is (the host
    /// posts it as Unicode keyboard input, so it doesn't depend on either
    /// side's keyboard layout). 1–`maxTextInputBytes` bytes of UTF-8.
    /// Gated on the host's WireCaps.agentControl.
    case textInput(text: String)
    /// Agents, viewer → host: an agent started (`active`) or stopped driving
    /// this session — headless or through a person's viewer. The host shows
    /// it, audits it, and applies its agent policy to input flagged
    /// `InputFlags.agent`. `label` names the agent for the indicator (≤ 64
    /// bytes UTF-8).
    case agentState(active: Bool, label: String)
    /// Agents, viewer → host: describe the accessibility tree of a window
    /// (`windowID` 0 = the focused window), at most `maxNodes` elements.
    /// Answered by UI_TREE with the same `requestID`.
    case uiTreeRequest(requestID: UInt32, windowID: UInt32, maxNodes: UInt16)
    /// Agents, host → viewer: the answer to a UI_TREE_REQUEST. `status` is a
    /// `UITreeStatus`; `json` (UTF-8, empty unless `.ok`) is the tree in
    /// canvas pixels — a JSON document, not parsed on any hot path.
    case uiTree(requestID: UInt32, status: UInt8, json: [UInt8])
    /// Agents, host → viewer: whether this session's agent input is accepted
    /// right now (`control`), and if not, why — view-only approval, agent
    /// control switched off at the host, the agent time limit. Sent when
    /// an agent becomes active and whenever the answer changes.
    case agentScope(control: Bool, reason: String)
    /// Viewer → host, once after its first HELLO_OK: the computer it runs on
    /// ("Alex’s MacBook Air"), so the host can name it in its approved-
    /// viewers list. 1–`maxViewerNameBytes` bytes of UTF-8. Display only —
    /// approval is by key, never by name.
    case viewerInfo(name: String)
    /// Video (§4.6, §5), viewer → host: the decoder of video region
    /// (`region`, `generation`) can't decode (a rebuilt hardware session
    /// waiting for a sync frame, or corrupt data) — send a fresh sync frame
    /// so the region recovers in place instead of the session failing. The
    /// host ignores it unless (region, generation) is its live region and
    /// answers at most one every 500 ms (requests inside that window
    /// coalesce into the next allowed sync); the viewer re-asks at most
    /// every 500 ms while the region stays undecodable.
    case syncRequest(region: UInt8, generation: UInt32)
    /// Viewer → host, every 250 ms while the host asks for it
    /// (`WireCaps.deliveryReports`): the bytes received so far, tile
    /// datagrams and video together, at the viewer's clock `tUS`. Between two
    /// reports, the rate the link actually delivered — what the host's own
    /// send-side readings can't see on a deep-buffered path.
    case received(bytes: UInt64, tUS: UInt64)
    /// Host → viewer: something about the host the viewer should show its
    /// user (`HostNotice`). Sent when it changes, and on connect while one is
    /// in force. Viewers ignore codes they don't know.
    case hostNotice(code: UInt8)
    /// Viewer → host, last on the control stream before the viewer closes
    /// it: why it's leaving (`ViewerBye`). Lets the host tell its user
    /// leaving from a drop, which a closed stream alone can't (the viewer's
    /// watchdog closes it cleanly too). Hosts ignore codes they don't know.
    case viewerBye(reason: UInt8)

    public static let maxViewerLogChunk = 64 << 10
    public static let maxTextInputBytes = 4096
    public static let maxAgentLabelBytes = 64
    public static let maxAgentReasonBytes = 160
    public static let maxViewerNameBytes = 64
    public static let maxViewerLogTotal: UInt32 = 16 << 20

    /// A bare, safe file name — the host writes it under its own directory.
    public static func isSafeLogName(_ name: String) -> Bool {
        let u = Array(name.utf8)
        guard (1...64).contains(u.count), u[0] != UInt8(ascii: ".") else { return false }
        return u.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == UInt8(ascii: ".") || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
        }
    }

    public var tlvType: UInt8 {
        switch self {
        case .hello: 0x01
        case .helloOK: 0x02
        case .ack: 0x03
        case .ping: 0x04
        case .pong: 0x05
        case .scroll: 0x06
        case .scrollAck: 0x07
        case .pauseHint: 0x08
        case .keyframeAck: 0x09
        case .deltaNack: 0x0A
        case .cursorPos: 0x0B
        case .cursorImage: 0x0C
        case .resize: 0x0D
        case .input: 0x0E
        case .clipboard: 0x0F
        case .quality: 0x10
        case .windowList: 0x11
        case .windowSelect: 0x12
        case .windowControl: 0x13
        case .viewerLog: 0x14
        case .textInput: 0x15
        case .agentState: 0x16
        case .uiTreeRequest: 0x17
        case .uiTree: 0x18
        case .agentScope: 0x19
        case .viewerInfo: 0x1A
        case .syncRequest: 0x1B
        case .received: 0x1C
        case .hostNotice: 0x1D
        case .viewerBye: 0x1E
        }
    }

    /// Full TLV encoding (type + varint length + body). Total: encodes any
    /// message, including one whose body exceeds `maxBodyLength` — which the
    /// receiver treats as a malformed stream and tears the session down.
    /// Senders use `encodedForSend()`.
    public func encoded() -> [UInt8] {
        Self.frame(type: tlvType, body: encodedBody())
    }

    /// The TLV encoding, or nil when the body exceeds `maxBodyLength` (the
    /// receiver's bound). Every engine send path goes through this: an
    /// oversize message is dropped or handled at the sender instead of
    /// killing the stream at the receiver.
    public func encodedForSend() -> [UInt8]? {
        let body = encodedBody()
        guard body.count <= Int(Self.maxBodyLength) else { return nil }
        return Self.frame(type: tlvType, body: body)
    }

    private static func frame(type: UInt8, body: [UInt8]) -> [UInt8] {
        var out = ByteWriter(reserving: body.count + 5)
        out.writeU8(type)
        out.writeVarint(UInt32(body.count))
        out.writeBytes(body)
        return out.bytes
    }

    private func encodedBody() -> [UInt8] {
        var body = ByteWriter(reserving: 32)
        switch self {
        case let .hello(ver, width, height, tileSize, pixfmt, caps):
            body.writeU8(ver)
            body.writeU16(width)
            body.writeU16(height)
            body.writeU8(tileSize)
            body.writeU8(pixfmt)
            body.writeU32(caps)
        case let .helloOK(ver, caps, geoMode, geoWidth, geoHeight, geoScale):
            body.writeU8(ver)
            body.writeU32(caps)
            body.writeU8(geoMode)
            body.writeU16(geoWidth)
            body.writeU16(geoHeight)
            body.writeU8(geoScale)
        case let .ack(frameSeq, dgramCnt, bitmap):
            precondition(dgramCnt >= 1 && bitmap.count == (Int(dgramCnt) + 7) / 8,
                         "ACK bitmap must be ceil(dgramCnt/8) bytes")
            body.writeU32(frameSeq)
            body.writeU16(dgramCnt)
            body.writeBytes(bitmap)
        case let .ping(nonce, tUS):
            body.writeU64(nonce)
            body.writeU64(tUS)
        case let .pong(nonce, tUS, recvTUS):
            body.writeU64(nonce)
            body.writeU64(tUS)
            body.writeU64(recvTUS)
        case let .scroll(frameSeq, x, y, width, height, dx, dy):
            body.writeU32(frameSeq)
            body.writeU16(x)
            body.writeU16(y)
            body.writeU16(width)
            body.writeU16(height)
            body.writeU16(UInt16(bitPattern: dx))
            body.writeU16(UInt16(bitPattern: dy))
        case let .scrollAck(frameSeq, skipped, digest):
            precondition(skipped.count <= 65_535)
            body.writeU32(frameSeq)
            body.writeU16(UInt16(skipped.count))
            for idx in skipped {
                body.writeU16(idx)
            }
            body.writeU64(digest)
        case let .pauseHint(paused):
            body.writeU8(paused ? 1 : 0)
        case let .keyframeAck(seq):
            body.writeU32(seq)
        case let .deltaNack(frameSeq, tiles):
            precondition(tiles.count <= 65_535)
            body.writeU32(frameSeq)
            body.writeU16(UInt16(tiles.count))
            for idx in tiles {
                body.writeU16(idx)
            }
        case let .cursorPos(x, y, visible):
            body.writeU16(x)
            body.writeU16(y)
            body.writeU8(visible ? 1 : 0)
        case let .cursorImage(width, height, hotspotX, hotspotY, scale, bgra):
            precondition(bgra.count == Int(width) * Int(height) * 4)
            body.writeU16(width)
            body.writeU16(height)
            body.writeU16(hotspotX)
            body.writeU16(hotspotY)
            body.writeU8(scale)
            body.writeBytes(bgra)
        case let .resize(mode, width, height, scale):
            body.writeU8(mode)
            body.writeU16(width)
            body.writeU16(height)
            body.writeU8(scale)
        case let .input(kind, x, y, a, b):
            body.writeU8(kind)
            body.writeU16(x)
            body.writeU16(y)
            body.writeU32(UInt32(bitPattern: a))
            body.writeU32(UInt32(bitPattern: b))
        case let .clipboard(format, data):
            body.writeU8(format)
            body.writeBytes(data)
        case let .quality(presentedScalePct, floor, preferSharpness):
            body.writeU8(presentedScalePct)
            body.writeU8(floor)
            body.writeU8(preferSharpness)
        case let .windowList(windows):
            precondition(windows.count <= 65_535)
            body.writeU16(UInt16(windows.count))
            for wnd in windows {
                let app = Array(wnd.appName.utf8)
                let ttl = Array(wnd.title.utf8)
                body.writeU32(wnd.windowID)
                body.writeVarint(UInt32(app.count))
                body.writeBytes(app)
                body.writeVarint(UInt32(ttl.count))
                body.writeBytes(ttl)
                body.writeU8(wnd.thumbFormat)
                body.writeU16(wnd.thumbWidth)
                body.writeU16(wnd.thumbHeight)
                body.writeVarint(UInt32(wnd.thumb.count))
                body.writeBytes(wnd.thumb)
            }
        case let .windowSelect(windowID):
            body.writeU32(windowID)
        case let .windowControl(action, width, height):
            body.writeU8(action)
            body.writeU16(width)
            body.writeU16(height)
        case let .viewerLog(name, offset, total, data):
            let n = Array(name.utf8)
            precondition(n.count <= 255)
            body.writeU8(UInt8(n.count))
            body.writeBytes(n)
            body.writeU32(offset)
            body.writeU32(total)
            body.writeBytes(data)
        case let .textInput(text):
            body.writeBytes(Array(text.utf8))
        case let .agentState(active, label):
            let l = Array(label.utf8)
            precondition(l.count <= Self.maxAgentLabelBytes)
            body.writeU8(active ? 1 : 0)
            body.writeU8(UInt8(l.count))
            body.writeBytes(l)
        case let .uiTreeRequest(requestID, windowID, maxNodes):
            body.writeU32(requestID)
            body.writeU32(windowID)
            body.writeU16(maxNodes)
        case let .uiTree(requestID, status, json):
            body.writeU32(requestID)
            body.writeU8(status)
            body.writeBytes(json)
        case let .agentScope(control, reason):
            let r = Array(reason.utf8)
            precondition(r.count <= Self.maxAgentReasonBytes)
            body.writeU8(control ? 1 : 0)
            body.writeU8(UInt8(r.count))
            body.writeBytes(r)
        case let .viewerInfo(name):
            body.writeBytes(Array(name.utf8))
        case let .syncRequest(region, generation):
            body.writeU8(region)
            body.writeU32(generation)
        case let .received(bytes, tUS):
            body.writeU64(bytes)
            body.writeU64(tUS)
        case let .hostNotice(code):
            body.writeU8(code)
        case let .viewerBye(reason):
            body.writeU8(reason)
        }
        return body.bytes
    }

    /// Body parse for a known TLV type. Bytes after the fields this build
    /// knows are ignored: a newer peer may append fields (§12). Returns nil
    /// for unknown types or any structural mismatch.
    public static func parseBody(type: UInt8, _ buf: UnsafeRawBufferPointer) -> ControlMessage? {
        var r = unsafe ByteReader(buf)
        switch type {
        case 0x01:
            guard let ver = r.readU8(), let width = r.readU16(), let height = r.readU16(),
                  let tileSize = r.readU8(), let pixfmt = r.readU8(), let caps = r.readU32() else { return nil }
            return .hello(ver: ver, width: width, height: height, tileSize: tileSize, pixfmt: pixfmt, caps: caps)
        case 0x02:
            guard let ver = r.readU8(), let caps = r.readU32(),
                  let geoMode = r.readU8(), geoMode <= GeometryMode.virtualDisplay,
                  let gw = r.readU16(), let gh = r.readU16(), let gs = r.readU8() else { return nil }
            return .helloOK(ver: ver, caps: caps,
                            geoMode: geoMode, geoWidth: gw, geoHeight: gh, geoScale: gs)
        case 0x03:
            guard let seq = r.readU32(), let cnt = r.readU16(), cnt >= 1,
                  let bitmap = unsafe r.readBytes((Int(cnt) + 7) / 8) else { return nil }
            return unsafe .ack(frameSeq: seq, dgramCnt: cnt, bitmap: [UInt8](bitmap))
        case 0x04:
            guard let nonce = r.readU64(), let t = r.readU64() else { return nil }
            return .ping(nonce: nonce, tUS: t)
        case 0x05:
            guard let nonce = r.readU64(), let t = r.readU64(), let recv = r.readU64() else { return nil }
            return .pong(nonce: nonce, tUS: t, recvTUS: recv)
        case 0x06:
            guard let seq = r.readU32(), let x = r.readU16(), let y = r.readU16(),
                  let w = r.readU16(), let h = r.readU16(), w >= 1, h >= 1,
                  let dx = r.readU16(), let dy = r.readU16() else { return nil }
            return .scroll(frameSeq: seq, x: x, y: y, width: w, height: h,
                           dx: Int16(bitPattern: dx), dy: Int16(bitPattern: dy))
        case 0x07:
            // Validate before allocating (INV-6): cnt indices + the digest.
            guard let seq = r.readU32(), let cnt = r.readU16(),
                  r.remaining >= Int(cnt) * 2 + 8 else { return nil }
            var skipped: [UInt16] = []
            skipped.reserveCapacity(Int(cnt))
            for _ in 0..<cnt {
                guard let idx = r.readU16() else { return nil }
                skipped.append(idx)
            }
            guard let digest = r.readU64() else { return nil }
            return .scrollAck(frameSeq: seq, skipped: skipped, digest: digest)
        case 0x08:
            guard let paused = r.readU8(), paused <= 1 else { return nil }
            return .pauseHint(paused: paused == 1)
        case 0x09:
            guard let seq = r.readU32() else { return nil }
            return .keyframeAck(seq: seq)
        case 0x0A:
            guard let seq = r.readU32(), let cnt = r.readU16(),
                  r.remaining >= Int(cnt) * 2 else { return nil }
            var tiles: [UInt16] = []
            tiles.reserveCapacity(Int(cnt))
            for _ in 0..<cnt {
                guard let idx = r.readU16() else { return nil }
                tiles.append(idx)
            }
            return .deltaNack(frameSeq: seq, tiles: tiles)
        case 0x0B:
            guard let x = r.readU16(), let y = r.readU16(), let v = r.readU8(), v <= 1 else { return nil }
            return .cursorPos(x: x, y: y, visible: v == 1)
        case 0x0C:
            guard let w = r.readU16(), let h = r.readU16(),
                  let hx = r.readU16(), let hy = r.readU16(), let scale = r.readU8(),
                  w >= 1, h >= 1, w <= 512, h <= 512, scale >= 1, scale <= 4,
                  let bgra = unsafe r.readBytes(Int(w) * Int(h) * 4) else { return nil }
            return unsafe .cursorImage(width: w, height: h, hotspotX: hx, hotspotY: hy,
                                scale: scale, bgra: [UInt8](bgra))
        case 0x0D:
            // 1 Client Resolution, 2 Scale, 4 virtual display (sent only to a
            // host advertising WireCaps.virtualDisplay: the viewer's window
            // size changed).
            guard let mode = r.readU8(), mode == 1 || mode == 2 || mode == GeometryMode.virtualDisplay,
                  let w = r.readU16(), let h = r.readU16(), w >= 1, h >= 1,
                  let scale = r.readU8(), scale >= 1, scale <= 4 else { return nil }
            return .resize(mode: mode, width: w, height: h, scale: scale)
        case 0x0E:
            // Any non-zero kind parses; receivers ignore kinds they don't
            // know. A range check here would make a newly added kind (e.g.
            // 7, pixel scroll) a "malformed control stream" that kills the
            // session on first use — additive kinds must stay additive.
            guard let kind = r.readU8(), kind >= 1,
                  let x = r.readU16(), let y = r.readU16(),
                  let a = r.readU32(), let b = r.readU32() else { return nil }
            return .input(kind: kind, x: x, y: y,
                          a: Int32(bitPattern: a), b: Int32(bitPattern: b))
        case 0x0F:
            guard let format = r.readU8() else { return nil }
            let bytes = unsafe r.readBytes(r.remaining).map { unsafe [UInt8]($0) } ?? []
            return .clipboard(format: format, data: bytes)
        case 0x10:
            guard let scale = r.readU8(), let floor = r.readU8(), floor <= QualityFloor.maxKnown,
                  let pref = r.readU8(), pref <= 2 else { return nil }
            return .quality(presentedScalePct: scale, floor: floor, preferSharpness: pref)
        case 0x11:
            // Every window is ≥ 12 bytes (id 4, three empty varints 3, fmt 1,
            // thumb dims 4): bound the reservation by what the body can hold.
            guard let count = r.readU16(), Int(count) <= r.remaining / 12 else { return nil }
            var windows: [WireWindow] = []
            windows.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let windowID = r.readU32(),
                      let appLen = r.readVarint(), let app = unsafe r.readBytes(Int(appLen)),
                      let ttlLen = r.readVarint(), let ttl = unsafe r.readBytes(Int(ttlLen)),
                      let fmt = r.readU8(), fmt <= 2,
                      let tw = r.readU16(), let th = r.readU16(),
                      let thumbLen = r.readVarint(), let thumb = unsafe r.readBytes(Int(thumbLen))
                else { return nil }
                unsafe windows.append(WireWindow(
                    windowID: windowID,
                    appName: String(decoding: app, as: UTF8.self),
                    title: String(decoding: ttl, as: UTF8.self),
                    thumbFormat: fmt, thumbWidth: tw, thumbHeight: th, thumb: [UInt8](thumb)))
            }
            return .windowList(windows: windows)
        case 0x12:
            guard let windowID = r.readU32() else { return nil }
            return .windowSelect(windowID: windowID)
        case 0x13:
            guard let action = r.readU8(), action >= 1, action <= 3,
                  let w = r.readU16(), let h = r.readU16() else { return nil }
            return .windowControl(action: action, width: w, height: h)
        case 0x14:
            guard let nameLen = r.readU8(), let nameBytes = unsafe r.readBytes(Int(nameLen)),
                  let offset = r.readU32(), let total = r.readU32(),
                  total <= Self.maxViewerLogTotal,
                  r.remaining <= Self.maxViewerLogChunk,
                  UInt64(offset) + UInt64(r.remaining) <= UInt64(total),
                  let data = unsafe r.readBytes(r.remaining) else { return nil }
            let name = unsafe String(decoding: nameBytes, as: UTF8.self)
            guard Self.isSafeLogName(name) else { return nil }
            return unsafe .viewerLog(name: name, offset: offset, total: total, data: [UInt8](data))
        case 0x15:
            guard (1...Self.maxTextInputBytes).contains(r.remaining),
                  let bytes = unsafe r.readBytes(r.remaining),
                  let text = unsafe String(validating: bytes, as: UTF8.self) else { return nil }
            return .textInput(text: text)
        case 0x16:
            guard let active = r.readU8(), active <= 1,
                  let len = r.readU8(), Int(len) <= Self.maxAgentLabelBytes,
                  let bytes = unsafe r.readBytes(Int(len)),
                  let label = unsafe String(validating: bytes, as: UTF8.self) else { return nil }
            return .agentState(active: active == 1, label: label)
        case 0x17:
            guard let requestID = r.readU32(), let windowID = r.readU32(),
                  let maxNodes = r.readU16(), maxNodes >= 1 else { return nil }
            return .uiTreeRequest(requestID: requestID, windowID: windowID, maxNodes: maxNodes)
        case 0x18:
            guard let requestID = r.readU32(), let status = r.readU8(),
                  status <= UITreeStatus.maxKnown,
                  let json = unsafe r.readBytes(r.remaining) else { return nil }
            return unsafe .uiTree(requestID: requestID, status: status, json: [UInt8](json))
        case 0x19:
            guard let control = r.readU8(), control <= 1,
                  let len = r.readU8(), Int(len) <= Self.maxAgentReasonBytes,
                  let bytes = unsafe r.readBytes(Int(len)),
                  let reason = unsafe String(validating: bytes, as: UTF8.self) else { return nil }
            return .agentScope(control: control == 1, reason: reason)
        case 0x1A:
            guard (1...Self.maxViewerNameBytes).contains(r.remaining),
                  let bytes = unsafe r.readBytes(r.remaining),
                  let name = unsafe String(validating: bytes, as: UTF8.self) else { return nil }
            return .viewerInfo(name: name)
        case 0x1B:
            guard let region = r.readU8(), let generation = r.readU32() else { return nil }
            return .syncRequest(region: region, generation: generation)
        case 0x1C:
            guard let bytes = r.readU64(), let tUS = r.readU64() else { return nil }
            return .received(bytes: bytes, tUS: tUS)
        case 0x1D:
            guard let code = r.readU8() else { return nil }
            return .hostNotice(code: code)
        case 0x1E:
            guard let reason = r.readU8() else { return nil }
            return .viewerBye(reason: reason)
        default:
            return nil
        }
    }

    /// Known TLV types. Everything beyond is skipped by the deframer
    /// using its declared length.
    public static func isKnownType(_ t: UInt8) -> Bool {
        (0x01...0x1E).contains(t)
    }
}

extension ControlMessage: TLVMessage {
    /// Upper bound on a single TLV body. The largest legitimate body is an
    /// ACK bitmap for 65 535 datagrams (≈ 8 KB); 1 MB leaves headroom without
    /// permitting unbounded buffering (INV-6).
    public static let maxBodyLength: UInt32 = 1 << 20
    /// CLIPBOARD body = 1 format byte + data, so the data gets one byte
    /// less: an exactly-1 MiB clipboard would be one byte over the bound
    /// and tear the session down.
    public static let maxClipboardBytes = Int(maxBodyLength) - 1
}

/// Incremental TLV deframer for the reliable control stream (shared framing
/// core in `TLVDeframer`; the video stream uses `VideoDeframer`).
public typealias ControlDeframer = TLVDeframer<ControlMessage>

extension String {
    /// The longest prefix whose UTF-8 encoding fits in `maxBytes`, cut at a
    /// character boundary.
    public func utf8Prefix(_ maxBytes: Int) -> Substring {
        guard utf8.count > maxBytes else { return self[...] }
        var end = startIndex, used = 0
        for i in indices {
            let n = self[i].utf8.count
            guard used + n <= maxBytes else { break }
            used += n
            end = index(after: i)
        }
        return self[..<end]
    }

    /// Consecutive pieces, each at most `maxBytes` of UTF-8, cut at character
    /// boundaries. A single character larger than `maxBytes` is dropped
    /// (no grapheme cluster comes close to TEXT_INPUT's 4 KB bound).
    public func utf8Chunks(maxBytes: Int) -> [String] {
        var out: [String] = [], current = "", used = 0
        for ch in self {
            let n = ch.utf8.count
            guard n <= maxBytes else { continue }
            if used + n > maxBytes {
                out.append(current)
                current = ""
                used = 0
            }
            current.append(ch)
            used += n
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
