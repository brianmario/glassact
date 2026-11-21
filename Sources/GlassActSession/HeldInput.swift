/// What a Viewer has pressed on the Host and not yet released: key codes and mouse buttons, and the
/// last canvas position it sent. The Host's input is the system's: a key the Viewer pressed and
/// never released stays held there. The Viewer misses a release whenever another app has the
/// keyboard as it happens (⌘-Tab away: the switcher takes the Tab and the ⌘'s release), and then
/// every remote click is a ⌘-click (a Dock icon reveals in Finder). So the Viewer releases what it
/// holds when its window stops being key, and a mouse button's release always goes out, at the
/// last position, even where the pointer has left the picture. Main thread.
public struct HeldInput: Sendable, Equatable {
    /// An input to send (`ViewerController.sendInput`'s arguments).
    public struct Event: Sendable, Equatable {
        public var kind: UInt8, x: Int, y: Int, a: Int, b: Int
        public init(kind: UInt8, x: Int, y: Int, a: Int, b: Int) { (self.kind, self.x, self.y, self.a, self.b) = (kind, x, y, a, b) }
    }

    public private(set) var keys: Set<Int> = []
    /// Mouse buttons down, one bit each (0 left, 1 right, 2 other).
    public private(set) var buttons = 0
    /// The last canvas position sent with a mouse event.
    public private(set) var position: (x: Int, y: Int)?

    public init() {}

    public static func == (l: HeldInput, r: HeldInput) -> Bool {
        l.keys == r.keys && l.buttons == r.buttons && l.position?.x == r.position?.x && l.position?.y == r.position?.y
    }

    /// An input was sent (kinds as the wire's: 1 move, 2/3 button down/up, 5/6 key down/up).
    public mutating func sent(kind: UInt8, x: Int, y: Int, b: Int) {
        switch kind {
        case 1: position = (x, y)
        case 2: position = (x, y); if (0...2).contains(b) { buttons |= 1 << b }
        case 3: position = (x, y); if (0...2).contains(b) { buttons &= ~(1 << b) }
        case 5: keys.insert(x)
        case 6: keys.remove(x)
        default: break
        }
    }

    /// The releases of everything held (keys first, in code order, with no modifier flags; then
    /// the buttons at the last position), and nothing held after.
    public mutating func releaseAll() -> [Event] {
        var out = keys.sorted().map { Event(kind: 6, x: $0, y: 0, a: 0, b: 0) }
        if let p = position {
            for b in 0...2 where buttons & (1 << b) != 0 { out.append(Event(kind: 3, x: p.x, y: p.y, a: 1, b: b)) }
        }
        (keys, buttons) = ([], 0)
        return out
    }
}
