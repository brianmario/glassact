import CoreGraphics
import Foundation
import GlassActCore
import GlassActTransport
public import GlassActWire
import Synchronization

/// An agent's hands and eyes on one viewer session: screenshots, mouse,
/// keyboard, clipboard, windows and the accessibility tree, in the action
/// vocabulary computer-use agents speak. Works the same on the Viewer app's
/// live session (attach) and on a headless one.
///
/// Coordinates: agents see the screen scaled so its longest edge is at most
/// `maxEdge` (vision models work best around there); every coordinate an
/// agent sends or receives is in that space, and the driver maps it to
/// canvas pixels. A host sharing a viewer-sized virtual display at that
/// size makes the two spaces identical.
///
/// Concurrency: operations run one at a time on `ops` (they block — waits,
/// pacing — so never on main or the engine queue); engine state is read
/// with `session.queue.sync`; callback-fed state sits behind a Mutex.
public final class AgentDriver: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public let session: ViewerSession
    public let label: String
    /// Longest edge of the agent's coordinate space (pixels).
    public var maxEdge: Int {
        get { shared.withLock { $0.maxEdge } }
        set { shared.withLock { $0.maxEdge = max(256, min(newValue, 8192)) } }
    }
    /// Extra fields for `status` (the headless runner adds dial state).
    public var statusExtras: (@Sendable () -> [String: Any])?
    /// Fired (any thread) when the agent starts or stops driving — the
    /// Viewer app shows it.
    public var onActiveChanged: (@Sendable (Bool) -> Void)?

    private let ops = DispatchQueue(label: "glassact.agent.ops")
    private struct Shared {
        var maxEdge = 1568
        var control = true
        var controlReason = ""
        var hostClipboard: String?
        var windows: [WireWindow]?
        var trees: [UInt32: (status: UInt8, json: [UInt8])] = [:]
        var nextTreeID: UInt32 = 1
        var humanInputUS: UInt64 = 0
        var active = false
        var lastOpUS: UInt64 = 0
    }
    private let shared = Mutex(Shared())
    /// `ops`: where the agent last put the pointer (canvas pixels).
    private var pointer: (x: Int, y: Int)?

    /// How long the person at the viewer keeps control after touching it.
    public static let humanGraceUS: UInt64 = 2_000_000

    public init(session: ViewerSession, label: String = "agent") {
        self.session = session
        self.label = label
        let engine = session.engine
        session.queue.async { [weak self] in
            engine.onAgentScope = { control, reason in
                self?.shared.withLock { $0.control = control; $0.controlReason = reason }
            }
            engine.onUITree = { requestID, status, json in
                self?.shared.withLock { $0.trees[requestID] = (status, json) }
            }
        }
    }

    // MARK: - Owner hooks (any thread)

    /// The host's clipboard changed (the owner forwards ViewerSession.onClipboard).
    public func noteHostClipboard(format: UInt8, data: [UInt8]) {
        guard format == 1, let text = String(bytes: data, encoding: .utf8) else { return }
        shared.withLock { $0.hostClipboard = text }
    }

    /// The host's window list arrived (the owner forwards ViewerSession.onWindowList).
    public func noteWindowList(_ windows: [WireWindow]) {
        shared.withLock { $0.windows = windows }
    }

    /// The person at this viewer used it: agent input yields for a moment.
    public func noteHumanInput() {
        shared.withLock { $0.humanInputUS = MonotonicClock.nowUS }
    }

    /// Tell the host an agent is driving now (a headless agent does this on
    /// connect, so it hears its scope before its first action).
    public func activate() {
        ops.async { [self] in setActive(true) }
    }

    /// The agent is done (its last client left, or the session ends).
    public func endAgentSession() {
        ops.async { [self] in setActive(false) }
    }

    /// Microseconds since the agent last did anything (∞ if never).
    public var idleUS: UInt64 {
        let last = shared.withLock { $0.lastOpUS }
        return last == 0 ? .max : MonotonicClock.nowUS - last
    }

    // MARK: - Operations

    /// Run one operation (blocking; call off main). `args` is decoded JSON.
    public func perform(_ op: String, _ args: [String: Any]) throws -> [String: Any] {
        try ops.sync { try performOnOps(op, Args(args)) }
    }

    /// Every operation, for the socket protocol's `help` and the MCP tool list.
    public static let operations = [
        "status", "screenshot", "zoom", "move", "click", "mouse_down", "mouse_up", "drag",
        "scroll", "key", "hold_key", "type", "wait", "wait_for_settle", "wait_for_change",
        "cursor_position", "list_windows", "share_window", "clipboard_get", "clipboard_set",
        "ui_tree",
    ]

    private func performOnOps(_ op: String, _ args: Args) throws -> [String: Any] {
        shared.withLock { $0.lastOpUS = MonotonicClock.nowUS }
        switch op {
        case "status":
            return status()
        case "screenshot":
            return try screenshot(settled: args.bool("settled") ?? true,
                                  timeout: args.optionalDouble("timeout") ?? 3,
                                  region: try args.rect("region"))
        case "zoom":
            guard let region = try args.rect("region") else { throw Failure("zoom needs region [x, y, width, height]") }
            return try screenshot(settled: args.bool("settled") ?? true, timeout: args.optionalDouble("timeout") ?? 3,
                                  region: region)
        case "wait":
            let seconds = min(60, max(0, args.optionalDouble("seconds") ?? 1))
            Thread.sleep(forTimeInterval: seconds)
            return ["waited": seconds]
        case "wait_for_settle":
            let result = try waitSettled(timeout: args.optionalDouble("timeout") ?? 5)
            return ["settled": result.settled, "moving_tiles": result.moving]
        case "wait_for_change":
            return try waitForChange(region: try args.rect("region"), timeout: args.optionalDouble("timeout") ?? 10)
        case "cursor_position":
            let (cw, ch) = try canvasSize()
            let s = scale(cw, ch)
            guard let p = pointer else { return ["x": NSNull(), "y": NSNull()] }
            return ["x": Int((Double(p.x) / s).rounded()), "y": Int((Double(p.y) / s).rounded())]
        case "list_windows":
            return try listWindows()
        case "share_window":
            try requireRunning()
            let id = try args.int("id")
            session.selectWindow(UInt32(clamping: id))
            return ["shared": id == 0 ? "whole display" : "window \(id)"]
        case "clipboard_get":
            let text = shared.withLock { $0.hostClipboard }
            return ["text": text.map { $0 as Any } ?? NSNull()]
        case "clipboard_set":
            try requireControl()
            let text = try args.string("text")
            let bytes = Array(text.utf8)
            guard bytes.count <= ControlMessage.maxClipboardBytes else { throw Failure("clipboard text over 1 MB") }
            session.sendClipboard(format: 1, data: bytes)
            return ["set": bytes.count]
        case "ui_tree":
            return try uiTree(windowID: args.optionalInt("window_id") ?? 0,
                              maxNodes: args.optionalInt("max_nodes") ?? 400)
        default:
            return try input(op, args)
        }
    }

    // MARK: Input

    private func input(_ op: String, _ args: Args) throws -> [String: Any] {
        guard Self.operations.contains(op) else {
            throw Failure("unknown operation “\(op)” (try: \(Self.operations.joined(separator: ", ")))")
        }
        try requireControl()
        switch op {
        case "move":
            let p = try point(args)
            send(1, p, 0, 0)
            return [:]
        case "click":
            let p = try args.has("x") ? point(args) : currentPointer()
            let button = try buttonCode(args.optionalString("button") ?? "left")
            let count = max(1, min(args.optionalInt("count") ?? 1, 3))
            let mods = try modifiers(args.optionalString("modifiers"))
            pressModifiers(mods, down: true)
            send(1, p, 0, 0)
            for n in 1...count {
                send(2, p, n, button)
                send(3, p, n, button)
            }
            pressModifiers(mods, down: false)
            return ["clicked": count]
        case "mouse_down", "mouse_up":
            let p = try args.has("x") ? point(args) : currentPointer()
            let button = try buttonCode(args.optionalString("button") ?? "left")
            if args.has("x") { send(1, p, 0, 0) }
            send(op == "mouse_down" ? 2 : 3, p, 1, button)
            return [:]
        case "drag":
            let path = try dragPath(args)
            let button = try buttonCode(args.optionalString("button") ?? "left")
            send(1, path[0], 0, 0)
            send(2, path[0], 1, button)
            for p in path.dropFirst() {
                Thread.sleep(forTimeInterval: 0.012) // apps sample drags; a burst looks like a jump
                send(1, p, 0, 0)
            }
            send(3, path[path.count - 1], 1, button)
            return ["points": path.count]
        case "scroll":
            let p = try args.has("x") ? point(args) : currentPointer()
            var dx = args.optionalInt("dx") ?? 0, dy = args.optionalInt("dy") ?? 0
            if let direction = args.optionalString("direction") {
                let amount = max(1, args.optionalInt("amount") ?? 3)
                switch direction.lowercased() {
                case "up": dy = amount
                case "down": dy = -amount
                case "left": dx = amount
                case "right": dx = -amount
                default: throw Failure("direction is up, down, left or right")
                }
            }
            send(1, p, 0, 0)
            send(4, p, dx, dy) // kind 4: a = horizontal, b = vertical (lines)
            return [:]
        case "key":
            let combo = try parseCombo(try args.string("key"))
            let repeats = max(1, min(args.optionalInt("repeat") ?? 1, 100))
            let action = args.optionalString("action") ?? "press"
            for _ in 0..<repeats {
                try pressCombo(combo, action: action)
            }
            return [:]
        case "hold_key":
            let combo = try parseCombo(try args.string("key"))
            let seconds = min(10, max(0, args.optionalDouble("seconds") ?? 0.5))
            try pressCombo(combo, action: "down")
            Thread.sleep(forTimeInterval: seconds)
            try pressCombo(combo, action: "up")
            return [:]
        case "type":
            let text = try args.string("text")
            guard !text.isEmpty else { return ["typed": 0] }
            let sent = session.queue.sync { session.engine.sendTextInput(text) }
            guard sent else { throw Failure("this host can't take typed text (update Glass Act Host)") }
            return ["typed": text.count]
        default:
            throw Failure("unknown operation “\(op)”")
        }
    }

    private func send(_ kind: UInt8, _ p: (x: Int, y: Int), _ a: Int, _ b: Int) {
        pointer = p
        session.sendInput(kind: kind | InputFlags.agent, x: p.x, y: p.y, a: a, b: b)
    }

    private func sendKey(_ code: UInt16, down: Bool, flags: UInt32) {
        session.sendInput(kind: (down ? 5 : 6) | InputFlags.agent, x: Int(code), y: 0,
                          a: Int(Int32(bitPattern: flags)), b: 0)
    }

    private func pressModifiers(_ mods: KeyMap.Modifier, down: Bool) {
        var held: KeyMap.Modifier = down ? [] : mods
        let order = down ? KeyMap.Modifier.order : KeyMap.Modifier.order.reversed()
        for m in order where mods.contains(m) {
            if down { held.insert(m) } else { held.remove(m) }
            if let code = m.keyCode { sendKey(code, down: down, flags: held.eventFlags) }
        }
    }

    private func pressCombo(_ combo: KeyMap.Combo, action: String) throws {
        let flags = combo.modifiers.eventFlags
        switch action {
        case "press":
            pressModifiers(combo.modifiers, down: true)
            if let code = combo.keyCode {
                sendKey(code, down: true, flags: flags)
                sendKey(code, down: false, flags: flags)
            }
            pressModifiers(combo.modifiers, down: false)
        case "down":
            pressModifiers(combo.modifiers, down: true)
            if let code = combo.keyCode { sendKey(code, down: true, flags: flags) }
        case "up":
            if let code = combo.keyCode { sendKey(code, down: false, flags: flags) }
            pressModifiers(combo.modifiers, down: false)
        default:
            throw Failure("action is press, down or up")
        }
    }

    private func parseCombo(_ text: String) throws -> KeyMap.Combo {
        do { return try KeyMap.parse(text) } catch { throw Failure(error.description) }
    }

    private func modifiers(_ text: String?) throws -> KeyMap.Modifier {
        guard let text, !text.isEmpty else { return [] }
        let combo = try parseCombo(text)
        guard combo.keyCode == nil else { throw Failure("modifiers takes modifier keys only, like “shift” or “cmd+shift”") }
        return combo.modifiers
    }

    private func buttonCode(_ name: String) throws -> Int {
        switch name.lowercased() {
        case "left": 0
        case "right": 1
        case "middle", "center", "other": 2
        default: throw Failure("button is left, right or middle")
        }
    }

    private func currentPointer() throws -> (x: Int, y: Int) {
        guard let p = pointer else { throw Failure("give x and y (the agent hasn't moved the pointer yet)") }
        return p
    }

    private func dragPath(_ args: Args) throws -> [(x: Int, y: Int)] {
        let (cw, ch) = try canvasSize()
        let s = scale(cw, ch)
        func toCanvas(_ x: Double, _ y: Double) -> (x: Int, y: Int) {
            (max(0, min(cw - 1, Int((x * s).rounded()))), max(0, min(ch - 1, Int((y * s).rounded()))))
        }
        var points: [(x: Double, y: Double)] = []
        if let path = args.raw["path"] as? [[Any]] {
            for p in path {
                guard p.count == 2, let x = (p[0] as? NSNumber)?.doubleValue, let y = (p[1] as? NSNumber)?.doubleValue
                else { throw Failure("path is [[x, y], …]") }
                points.append((x, y))
            }
        } else {
            let from = try args.pair("from"), to = try args.pair("to")
            points = [from, to]
        }
        guard points.count >= 2 else { throw Failure("a drag needs at least two points") }
        // Two-point drags get intermediate steps, so apps see a drag.
        if points.count == 2 {
            let (a, b) = (points[0], points[1])
            let steps = max(8, Int(hypot(b.x - a.x, b.y - a.y) / 24))
            points = (0...steps).map { i in
                let t = Double(i) / Double(steps)
                return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            }
        }
        return points.map { toCanvas($0.x, $0.y) }
    }

    // MARK: Session state

    private func requireRunning() throws {
        let running = session.queue.sync { session.engine.state == .running && session.engine.grid != nil }
        guard running else {
            throw Failure("not connected to a host yet" + ((statusExtras?()["waiting_for"] as? String).map { " — \($0)" } ?? ""))
        }
    }

    private func requireControl() throws {
        try requireRunning()
        let supported = session.queue.sync { session.engine.hostSupportsAgents }
        guard supported else { throw Failure("this host doesn't support agents (update Glass Act Host)") }
        setActive(true)
        let (control, reason, human) = shared.withLock { ($0.control, $0.controlReason, $0.humanInputUS) }
        guard control else { throw Failure("the host isn't accepting agent input: \(reason.isEmpty ? "control is off" : reason)") }
        if human != 0, MonotonicClock.nowUS - human < Self.humanGraceUS {
            throw Failure("the person at the viewer is using it — try again in a moment")
        }
    }

    /// `ops`.
    private func setActive(_ active: Bool) {
        let changed = shared.withLock { s -> Bool in
            guard s.active != active else { return false }
            s.active = active
            return true
        }
        guard changed else { return }
        let label = self.label
        session.queue.async { [session] in _ = session.engine.sendAgentState(active: active, label: label) }
        onActiveChanged?(active)
    }

    private func canvasSize() throws -> (Int, Int) {
        try requireRunning()
        guard let grid = session.queue.sync(execute: { session.engine.grid }) else { throw Failure("no picture yet") }
        return (grid.width, grid.height)
    }

    /// Canvas pixels per agent pixel.
    private func scale(_ cw: Int, _ ch: Int) -> Double {
        max(1, Double(max(cw, ch)) / Double(maxEdge))
    }

    private func point(_ args: Args) throws -> (x: Int, y: Int) {
        let (cw, ch) = try canvasSize()
        let s = scale(cw, ch)
        let x = try args.double("x"), y = try args.double("y")
        return (max(0, min(cw - 1, Int((x * s).rounded()))), max(0, min(ch - 1, Int((y * s).rounded()))))
    }

    private func status() -> [String: Any] {
        let snapshot = session.queue.sync { () -> (ViewerEngine.EngineState, TileGrid?, Bool, UInt8?) in
            let e = session.engine
            return (e.state, e.grid, e.hostSupportsAgents, e.activeVideoCodec)
        }
        let (control, reason, active) = shared.withLock { ($0.control, $0.controlReason, $0.active) }
        var out: [String: Any] = [
            "connected": snapshot.0 == .running && snapshot.1 != nil,
            "target": session.target,
            "agent_support": snapshot.2,
            "control": control,
            "agent_active": active,
            "max_edge": maxEdge,
        ]
        if !reason.isEmpty { out["control_reason"] = reason }
        if let grid = snapshot.1 {
            let s = scale(grid.width, grid.height)
            out["canvas"] = ["width": grid.width, "height": grid.height]
            out["screen"] = ["width": Int((Double(grid.width) / s).rounded()),
                             "height": Int((Double(grid.height) / s).rounded())]
        }
        if let code = snapshot.3 { out["video"] = VideoCodec.name(code) }
        for (k, v) in statusExtras?() ?? [:] { out[k] = v }
        return out
    }

    // MARK: Eyes

    /// Settled = for `quietUS`, at most a sliver of the screen changed (a
    /// spinner, a blinking caret — `stillFraction` of its tiles) and no more
    /// than that shows video. Real desktops are rarely perfectly still; what
    /// an agent needs is that what it's about to read has stopped moving.
    /// Everything that did settle is exact (lossless tiles). `moving` reports
    /// the tiles still changing at the end.
    private func waitSettled(timeout: Double, quietUS: UInt64 = 300_000,
                             stillFraction: Double = 0.005) throws -> (settled: Bool, moving: Int) {
        try requireRunning()
        let deadline = MonotonicClock.nowUS + UInt64(max(0, timeout) * 1_000_000)
        var windowStart = session.queue.sync { session.engine.contentVersion }
        var windowStartUS = MonotonicClock.nowUS
        var moving = 0
        while true {
            Thread.sleep(forTimeInterval: 0.05)
            let (changed, total, overlay) = session.queue.sync { () -> (Int, Int, Int) in
                let c = session.engine.tilesChanged(since: windowStart)
                return (c.changed, c.total, session.engine.overlayVisibleTileCount)
            }
            let allowance = max(4, Int(Double(total) * stillFraction))
            let now = MonotonicClock.nowUS
            moving = max(changed, overlay)
            if changed > allowance || overlay > allowance {
                // Restart the quiet window from here.
                windowStart = session.queue.sync { session.engine.contentVersion }
                windowStartUS = now
            } else if now - windowStartUS >= quietUS {
                return (true, moving)
            }
            if now >= deadline { return (false, moving) }
        }
    }

    private func frame() throws -> ScreenFrame {
        guard let f = session.queue.sync(execute: { ScreenFrame.capture(session.engine) }) else {
            throw Failure("no picture yet")
        }
        return f
    }

    private func screenshot(settled wantSettled: Bool, timeout: Double, region: CGRect?) throws -> [String: Any] {
        let settle = wantSettled ? try waitSettled(timeout: timeout) : (settled: false, moving: -1)
        let settled = settle.settled
        let f = try frame()
        let s = scale(f.width, f.height)
        guard let image = f.image() else { throw Failure("couldn't build the image") }
        var crop: CGRect?
        var outW = Int((Double(f.width) / s).rounded()), outH = Int((Double(f.height) / s).rounded())
        if let region {
            let r = CGRect(x: region.minX * s, y: region.minY * s, width: region.width * s, height: region.height * s)
                .intersection(CGRect(x: 0, y: 0, width: f.width, height: f.height))
            guard r.width >= 1, r.height >= 1 else { throw Failure("region is off screen") }
            crop = r
            // Zoom: the region at up to native resolution, within maxEdge.
            let zs = max(1, max(r.width, r.height) / Double(maxEdge))
            outW = max(1, Int((r.width / zs).rounded()))
            outH = max(1, Int((r.height / zs).rounded()))
        }
        guard let png = ImageEncoding.png(image, crop: crop, outWidth: outW, outHeight: outH) else {
            throw Failure("couldn't encode the screenshot")
        }
        var out: [String: Any] = [
            "png_base64": png.base64EncodedString(),
            "width": outW, "height": outH,
            "screen": ["width": Int((Double(f.width) / s).rounded()), "height": Int((Double(f.height) / s).rounded())],
            "settled": settled,
        ]
        if settle.moving > 0 { out["moving_tiles"] = settle.moving }
        if let region { out["region"] = [region.minX, region.minY, region.width, region.height] }
        return out
    }

    private func waitForChange(region: CGRect?, timeout: Double) throws -> [String: Any] {
        try requireRunning()
        let deadline = MonotonicClock.nowUS + UInt64(min(120, max(0, timeout)) * 1_000_000)
        if let region {
            let first = try frame()
            let s = scale(first.width, first.height)
            let (x, y) = (Int(region.minX * s), Int(region.minY * s))
            let (w, h) = (Int((region.width * s).rounded(.up)), Int((region.height * s).rounded(.up)))
            let baseline = first.digest(x: x, y: y, width: w, height: h)
            while MonotonicClock.nowUS < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                if try frame().digest(x: x, y: y, width: w, height: h) != baseline { return ["changed": true] }
            }
            return ["changed": false]
        }
        let baseline = session.queue.sync { session.engine.contentVersion }
        while MonotonicClock.nowUS < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            if session.queue.sync(execute: { session.engine.contentVersion }) != baseline { return ["changed": true] }
        }
        return ["changed": false]
    }

    private func listWindows() throws -> [String: Any] {
        try requireRunning()
        guard session.hostSupportsWindowList() else { throw Failure("this host can't list windows") }
        shared.withLock { $0.windows = nil }
        session.requestWindowList()
        let deadline = MonotonicClock.nowUS + 5_000_000
        while MonotonicClock.nowUS < deadline {
            if let windows = shared.withLock({ $0.windows }) {
                return ["windows": windows.map { ["id": Int($0.windowID), "app": $0.appName, "title": $0.title] as [String: Any] }]
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Failure("the host didn't send its window list")
    }

    private func uiTree(windowID: Int, maxNodes: Int) throws -> [String: Any] {
        try requireRunning()
        guard session.queue.sync(execute: { session.engine.hostSupportsAgents }) else {
            throw Failure("this host doesn't support agents (update Glass Act Host)")
        }
        setActive(true)
        let id = shared.withLock { s -> UInt32 in
            defer { s.nextTreeID &+= 1 }
            return s.nextTreeID
        }
        session.queue.async { [session] in
            _ = session.engine.sendUITreeRequest(requestID: id, windowID: UInt32(clamping: windowID),
                                                  maxNodes: max(1, min(maxNodes, 2000)))
        }
        let deadline = MonotonicClock.nowUS + 8_000_000
        while MonotonicClock.nowUS < deadline {
            if let answer = shared.withLock({ $0.trees.removeValue(forKey: id) }) {
                return try decodeTree(status: answer.status, json: answer.json)
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw Failure("the host didn't answer with the UI tree")
    }

    /// Host frames are canvas pixels; agents get their own space.
    private func decodeTree(status: UInt8, json: [UInt8]) throws -> [String: Any] {
        switch status {
        case UITreeStatus.ok: break
        case UITreeStatus.notPermitted: throw Failure("the host lacks Device Control and Data Access (Accessibility)")
        case UITreeStatus.noWindow: throw Failure("no such window (or nothing focused)")
        case UITreeStatus.refused: throw Failure("the host refused (agent access is off for this session)")
        case UITreeStatus.tooLarge: throw Failure("the tree is too large — ask for fewer nodes")
        default: throw Failure("the host answered with status \(status)")
        }
        guard var tree = try JSONSerialization.jsonObject(with: Data(json)) as? [String: Any] else {
            throw Failure("the host sent an unreadable tree")
        }
        let (cw, ch) = try canvasSize()
        let s = scale(cw, ch)
        if let nodes = tree["nodes"] as? [[String: Any]] {
            tree["nodes"] = nodes.map { node -> [String: Any] in
                var n = node
                if let f = node["frame"] as? [NSNumber], f.count == 4 {
                    n["frame"] = f.map { Int(($0.doubleValue / s).rounded()) }
                }
                return n
            }
        }
        return tree
    }
}

/// Typed reads over decoded JSON arguments.
struct Args {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func has(_ key: String) -> Bool { raw[key] != nil && !(raw[key] is NSNull) }

    func string(_ key: String) throws -> String {
        guard let s = raw[key] as? String else { throw AgentDriver.Failure("“\(key)” must be a string") }
        return s
    }
    func optionalString(_ key: String) -> String? { raw[key] as? String }

    func double(_ key: String) throws -> Double {
        guard let n = raw[key] as? NSNumber else { throw AgentDriver.Failure("“\(key)” must be a number") }
        return n.doubleValue
    }
    func optionalDouble(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }

    func int(_ key: String) throws -> Int {
        guard let n = raw[key] as? NSNumber else { throw AgentDriver.Failure("“\(key)” must be a number") }
        return n.intValue
    }
    func optionalInt(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue }

    func bool(_ key: String) -> Bool? { (raw[key] as? NSNumber)?.boolValue }

    func pair(_ key: String) throws -> (x: Double, y: Double) {
        guard let a = raw[key] as? [NSNumber], a.count == 2 else { throw AgentDriver.Failure("“\(key)” must be [x, y]") }
        return (a[0].doubleValue, a[1].doubleValue)
    }

    func rect(_ key: String) throws -> CGRect? {
        guard has(key) else { return nil }
        guard let a = raw[key] as? [NSNumber], a.count == 4, a[2].doubleValue > 0, a[3].doubleValue > 0 else {
            throw AgentDriver.Failure("“\(key)” must be [x, y, width, height]")
        }
        return CGRect(x: a[0].doubleValue, y: a[1].doubleValue, width: a[2].doubleValue, height: a[3].doubleValue)
    }
}
