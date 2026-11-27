public import GlassActWire

/// Display choice (§4.10), the Viewer's side: the host's displays, the one shown, a pick
/// waiting for its answer, and when the picker shows. Pure, so the rule is tested once and
/// both apps (the Mac's Displays menu, the iPad's list) draw from it. `ViewerController`
/// keeps one (main thread) and asks the host for the list only while picking can work.
public struct DisplayPicker: Equatable, Sendable {
    /// One display as the picker lists it.
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: UInt32
        /// The host's name for it, numbered when two share a name.
        public var name: String
        /// Its size in points, and "Main" for the host's main display.
        public var detail: String
        public var isShown: Bool
        /// Picked, waiting for the host's answer.
        public var isPending: Bool
    }

    /// The host offers display choice (caps bit 31).
    public private(set) var hostLists = false
    /// The last geometry this viewer asked for (`GeometryMode`).
    public private(set) var geometryMode = GeometryMode.none
    public private(set) var singleWindow = false
    /// The host's last list, left to right as the displays are arranged.
    public private(set) var displays: [WireDisplay] = []
    /// The display shared now: the list's, then each answer's.
    public private(set) var shownID: UInt32 = 0
    public private(set) var pendingID: UInt32?

    public init() {}

    /// A pick only takes effect while the host shares one whole physical display: not one
    /// window, not a virtual display (it mirrors every display into one) and not Client
    /// Resolution (it has switched the shared display's own mode). The host answers
    /// "not now" to those, so the picker isn't shown in them.
    public static func picksTakeEffect(geometryMode: UInt8, singleWindow: Bool) -> Bool {
        guard !singleWindow else { return false }
        switch geometryMode {
        case GeometryMode.virtualDisplay, GeometryMode.clientResolution: return false
        default: return true // Scale, Native, or none asked (the host's own size)
        }
    }

    /// Worth asking the host for its list.
    public var wantsList: Bool {
        hostLists && Self.picksTakeEffect(geometryMode: geometryMode, singleWindow: singleWindow)
    }

    /// The picker shows: picking can work and there's more than one display to pick.
    public var isVisible: Bool { wantsList && displays.count >= 2 }

    public var items: [Item] {
        var seen: [String: Int] = [:]
        let named = displays.map { d -> String in
            let base = d.name.isEmpty ? "Display" : d.name
            let count = displays.filter { ($0.name.isEmpty ? "Display" : $0.name) == base }.count
            guard count > 1 else { return base }
            seen[base, default: 0] += 1
            return "\(base) \(seen[base]!)"
        }
        return zip(displays, named).map { d, name in
            Item(id: d.displayID, name: name,
                 detail: "\(d.width) × \(d.height)" + (d.isMain ? " · Main" : ""),
                 isShown: d.displayID == shownID, isPending: d.displayID == pendingID)
        }
    }

    // MARK: - Events (the controller's, main thread)

    /// The session runs: what the host offers. Returns `wantsList`.
    @discardableResult
    public mutating func sessionStarted(hostLists: Bool) -> Bool {
        self.hostLists = hostLists
        return wantsList
    }

    /// A geometry request went out. Returns true when the list is newly worth asking for.
    public mutating func geometryRequested(mode: UInt8, singleWindow: Bool) -> Bool {
        let before = wantsList
        geometryMode = mode
        self.singleWindow = singleWindow
        return !before && wantsList
    }

    public mutating func received(_ list: [WireDisplay]) {
        displays = list.sorted { ($0.x, $0.y, $0.displayID) < ($1.x, $1.y, $1.displayID) }
        if let shown = list.first(where: \.isShown) { shownID = shown.displayID }
    }

    /// The person picked `id`. True: send it (not the display already shown, nor the one
    /// already waiting).
    public mutating func pick(_ id: UInt32) -> Bool {
        guard id != 0, displays.contains(where: { $0.displayID == id }) else { return false }
        if id == (pendingID ?? shownID) { return false }
        pendingID = id
        return true
    }

    /// The host's answer to a pick. Shown is what the host says it shares, refusal or not:
    /// the picker never moves ahead of it. Answers come in order; the newest pick may still
    /// be waiting behind an older one's answer.
    public mutating func received(_ answer: WireDisplaySelection) {
        if answer.status != .connectionLost, answer.displayID != 0 { shownID = answer.displayID }
        if answer.requestedID == pendingID { pendingID = nil }
    }

    /// The connection ended: nothing listed until the next session's list.
    public mutating func sessionEnded() {
        hostLists = false
        displays = []
        shownID = 0
        pendingID = nil
    }
}
