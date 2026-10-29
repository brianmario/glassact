import AppKit
import ApplicationServices
import Foundation
import GlassActTransport
import GlassActWire

/// What agents may do on this Mac, decided per input. An agent is either a
/// headless Glass Act agent (its certificate says so) or the agent side of a
/// person's viewer (its input arrives flagged `InputFlags.agent`). Rules:
/// - a key approved View Only sends no input, clipboard or window changes;
/// - agent input needs Allow Agent Control on (Options › Agents), the
///   session not paused, and the agent time limit not reached;
/// - the person at this Mac always wins: agent input waits while they're
///   using the mouse or keyboard;
/// - with no session loaded (before `beginSession`, after `endSession`)
///   nothing is admitted.
///
/// Thread-safe (NSLock): decisions run on the engine queue; the menu reads
/// and changes it on main.
final class AgentAccess: @unchecked Sendable {
    static let allowControlKey = "glassact.host.agentControl"
    static let timeLimitKey = "glassact.host.agentTimeLimitMinutes"
    /// Minutes; 0 = no limit.
    static let timeLimitChoices = [0, 15, 60, 240]
    /// How long local mouse or keyboard use holds agents off.
    static let humanGraceSeconds = 2.0

    enum Denial: Equatable {
        case noSession, viewOnly, controlOff, paused(String), humanActive

        var reason: String {
            switch self {
            case .noSession: "the session isn't set up yet"
            case .viewOnly: "approved to watch only"
            case .controlOff: "agent control is switched off on this Mac"
            case let .paused(why): why
            case .humanActive: "the person at this Mac is using it"
            }
        }
    }

    struct Snapshot: Equatable {
        var agentActive = false
        var label = ""
        var viewOnly = false
        var paused = false
        var pauseReason = ""
        var since: Date?
    }

    /// Main: something the menu or indicator shows changed.
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var loaded = false
    private var peer: QUICTransport.PeerCertificate?
    private var viewOnly = false
    private var agentActive = false
    private var label = ""
    private var activeSince: Date?
    private var paused = false
    private var pauseReason = ""
    private var lastInjectUptime: TimeInterval = 0

    init() {
        UserDefaults.standard.register(defaults: [Self.allowControlKey: true, Self.timeLimitKey: 60])
    }

    var allowControl: Bool {
        get { UserDefaults.standard.bool(forKey: Self.allowControlKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.allowControlKey); changed() }
    }

    var timeLimitMinutes: Int {
        get { UserDefaults.standard.integer(forKey: Self.timeLimitKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.timeLimitKey); changed() }
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(agentActive: agentActive, label: label, viewOnly: viewOnly,
                     paused: paused, pauseReason: pauseReason, since: activeSince)
        }
    }

    /// A viewer's session went live. A headless agent is active from the start.
    func beginSession(peer: QUICTransport.PeerCertificate?, viewOnly: Bool) {
        lock.withLock {
            loaded = true
            self.peer = peer
            self.viewOnly = viewOnly
            agentActive = peer?.isAgent == true
            label = agentActive ? "agent" : ""
            activeSince = agentActive ? Date() : nil
            paused = false
            pauseReason = ""
        }
        changed()
    }

    func endSession() {
        lock.withLock {
            loaded = false
            peer = nil
            viewOnly = false
            agentActive = false
            activeSince = nil
            paused = false
        }
        changed()
    }

    var sessionIsAgent: Bool { lock.withLock { peer?.isAgent == true } }

    /// A headless agent, or a person's viewer while its agent drives.
    var agentDriving: Bool { lock.withLock { agentActive } }

    /// AGENT_STATE from the viewer. Returns true when it changed.
    @discardableResult
    func agentState(active: Bool, label newLabel: String) -> Bool {
        let didChange = lock.withLock { () -> Bool in
            let wasActive = agentActive
            // A headless agent stays an agent; a viewer's agent comes and goes.
            agentActive = active || peer?.isAgent == true
            if !newLabel.isEmpty { label = newLabel }
            if agentActive && !wasActive { activeSince = Date(); paused = false }
            if !agentActive { activeSince = nil }
            return wasActive != agentActive
        }
        changed()
        return didChange
    }

    /// What to tell the viewer (AGENT_SCOPE).
    func scope() -> (control: Bool, reason: String) {
        if let denial = standingDenial() { return (false, denial.reason) }
        return (true, "")
    }

    /// Admit one input. `agentInput`: flagged, or from an agent's key. Nil = go.
    func admit(agentInput: Bool) -> Denial? {
        let (isLoaded, vo) = lock.withLock { (loaded, viewOnly) }
        guard isLoaded else { return .noSession }
        if vo { return .viewOnly }
        guard agentInput else { return nil }
        if let denial = standingDenial() { return denial }
        if localHumanActive() { return .humanActive }
        lock.withLock { lastInjectUptime = ProcessInfo.processInfo.systemUptime }
        return nil
    }

    /// Whether this session may have this Mac's clipboard, or the list of
    /// its windows: not a View Only key, nor an agent whose control is off,
    /// paused or out of time. No human check: neither moves the pointer.
    func admitShare() -> Denial? {
        let (isLoaded, agent) = lock.withLock { (loaded, agentActive) }
        guard isLoaded else { return .noSession }
        if let denial = standingDenial(), denial == .viewOnly || agent { return denial }
        return nil
    }

    /// Reading the accessibility tree (UI_TREE_REQUEST): a View Only key may
    /// (it watches this screen already); an agent may not while its control
    /// is off, paused or out of time.
    func admitRead() -> Denial? {
        let (isLoaded, agent) = lock.withLock { (loaded, agentActive) }
        guard isLoaded else { return .noSession }
        guard agent, let denial = standingDenial(), denial != .viewOnly else { return nil }
        return denial
    }

    /// Denials that hold until something changes (not the moment-to-moment
    /// human check). Expires the time limit as a side effect.
    private func standingDenial() -> Denial? {
        let limit = timeLimitMinutes
        let allow = allowControl
        let (vo, p, why, expired) = lock.withLock { () -> (Bool, Bool, String, Bool) in
            var expired = false
            if !paused, limit > 0, let since = activeSince, Date().timeIntervalSince(since) > Double(limit * 60) {
                paused = true
                pauseReason = "the \(Self.describe(minutes: limit)) agent time limit was reached — resume from the Glass Act Host menu"
                expired = true
            }
            return (viewOnly, paused, pauseReason, expired)
        }
        if expired { changed() }
        if vo { return .viewOnly }
        if !allow { return .controlOff }
        if p { return .paused(why) }
        return nil
    }

    /// The connected key's approval switched between control and view only.
    func setViewOnly(_ viewOnly: Bool) {
        lock.withLock { self.viewOnly = viewOnly }
        changed()
    }

    func pause(_ reason: String) {
        lock.withLock { paused = true; pauseReason = reason }
        changed()
    }

    func resume() {
        lock.withLock { paused = false; pauseReason = ""; if agentActive { activeSince = Date() } }
        changed()
    }

    /// Local mouse or keyboard use in the last moment that wasn't ours: HID
    /// event ages, minus a margin around our own last injection (posted
    /// events may count as HID activity too).
    private func localHumanActive() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .keyDown, .flagsChanged, .scrollWheel]
        let since = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        let sinceOurs = ProcessInfo.processInfo.systemUptime - lock.withLock { lastInjectUptime }
        return since < Self.humanGraceSeconds && since + 0.25 < sinceOurs
    }

    static func describe(minutes: Int) -> String {
        minutes == 0 ? "no" : minutes % 60 == 0 ? "\(minutes / 60)-hour" : "\(minutes)-minute"
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}

/// Append-only record of what agents did (~/Library/Application Support/Glass Act/agent-audit.log, 0600,
/// one line per action, rotated at 4 MB). Typed text is counted, never
/// written down — it may be a password.
final class AgentAudit: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "glassact.host.agent-audit")
    private let formatter = ISO8601DateFormatter()
    private var lastDenial = Date.distantPast

    init(directory: URL) {
        url = directory.appendingPathComponent("agent-audit.log")
    }

    var fileURL: URL { url }

    func log(_ line: String) {
        let stamp = formatter.string(from: Date())
        queue.async { [url] in
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 4 << 20 {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
        }
    }

    /// At most one denial line a second (an agent retrying shouldn't flood it).
    func denied(_ what: String, _ reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastDenial) >= 1 else { return }
        lastDenial = now
        log("denied \(what): \(reason)")
    }
}

/// The accessibility tree of one window, flattened for agents: each node's
/// role, subrole, title, description, value, enabled/focused state and
/// frame (canvas pixels), with its parent's index. Breadth-first, so a
/// node budget keeps the outer structure.
enum UITreeBuilder {
    /// Runs AX queries — call off main and off the engine queue.
    /// `toCanvas` maps a global (top-left origin) rect in points to canvas pixels.
    static func build(windowID: UInt32, maxNodes: Int,
                      toCanvas: @escaping (CGRect) -> CGRect) -> (status: UInt8, json: [UInt8]) {
        guard AXIsProcessTrusted() else { return (UITreeStatus.notPermitted, []) }
        guard let (app, window, appName) = target(windowID: windowID) else { return (UITreeStatus.noWindow, []) }
        AXUIElementSetMessagingTimeout(app, 0.3)

        var nodes: [[String: Any]] = []
        var queue: [(AXUIElement, Int, Int)] = [(window, -1, 0)]
        var head = 0
        var truncated = false
        let budget = max(1, min(maxNodes, 2000))
        while head < queue.count {
            guard nodes.count < budget else { truncated = true; break }
            let (element, parent, depth) = queue[head]
            head += 1
            let index = nodes.count
            nodes.append(describe(element, index: index, parent: parent, toCanvas: toCanvas))
            guard depth < 40 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                for child in list { queue.append((child, index, depth + 1)) }
            }
        }
        var windowTitle: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &windowTitle)
        let doc: [String: Any] = ["app": appName, "window": (windowTitle as? String) ?? "",
                                  "nodes": nodes, "truncated": truncated]
        guard let data = try? JSONSerialization.data(withJSONObject: doc) else { return (UITreeStatus.noWindow, []) }
        return (UITreeStatus.ok, [UInt8](data))
    }

    private static func target(windowID: UInt32) -> (AXUIElement, AXUIElement, String)? {
        if windowID == 0 {
            guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
            let app = AXUIElementCreateApplication(front.processIdentifier)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
               let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                return (app, focused as! AXUIElement, front.localizedName ?? "")
            }
            return nil
        }
        // A specific window: its owner, then the AX window with the same frame.
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return nil }
        let name = (info[kCGWindowOwnerName as String] as? String) ?? ""
        let match = list.first { frame(of: $0).map { abs($0.minX - bounds.minX) < 2 && abs($0.minY - bounds.minY) < 2 } ?? false }
        return match.map { (app, $0, name) }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func describe(_ element: AXUIElement, index: Int, parent: Int,
                                 toCanvas: (CGRect) -> CGRect) -> [String: Any] {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXValueAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXIdentifierAttribute] as [CFString]
        var values: CFArray?
        var node: [String: Any] = ["i": index, "p": parent]
        if AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
           let values = values as? [Any] {
            let keys = ["role", "subrole", "title", "description", "value", "enabled", "focused", "identifier"]
            for (key, value) in zip(keys, values) {
                switch value {
                case let s as String where !s.isEmpty: node[key] = String(s.prefix(200))
                case let n as NSNumber: node[key] = (key == "enabled" || key == "focused") ? n.boolValue as Any : n
                default: break
                }
            }
        }
        if let f = frame(of: element) {
            let c = toCanvas(f)
            node["frame"] = [Int(c.minX.rounded()), Int(c.minY.rounded()), Int(c.width.rounded()), Int(c.height.rounded())]
        }
        return node
    }
}
