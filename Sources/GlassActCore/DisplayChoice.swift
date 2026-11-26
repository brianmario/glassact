/// The Host's rules for the display a viewer picks (§4.10 display choice), pure so they're
/// tested. From Duo Desktop's Host (github.com/Stratechery/duo-desktop).
public enum DisplayChoice {
    /// A display in global points (the main display's top-left is 0,0).
    public struct Rect: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public func contains(_ px: Double, _ py: Double) -> Bool {
            px >= x && py >= y && px < x + width && py < y + height
        }
    }

    /// The display to share: the viewer's pick while the host offers it, else `fallback`
    /// (the display chosen at the Mac, or the main one). Never "the first listed". `nil` or
    /// 0 (nothing picked: a viewer that never picks) is `fallback`, as before.
    public static func displayToShare(requested: UInt32?, offered: [UInt32], fallback: UInt32) -> UInt32 {
        if let requested, requested != 0, offered.contains(requested) { return requested }
        return fallback
    }

    /// Where the host puts the pointer on a switch: the point asked for, clamped inside
    /// `display` (one point in from each edge); no point asked for is the display's middle.
    public static func pointerPlacement(asked: (x: Double, y: Double)?, on display: Rect) -> (x: Double, y: Double) {
        guard let asked else { return (display.x + display.width / 2, display.y + display.height / 2) }
        let inset = 1.0
        let x = min(max(asked.x, display.x + min(inset, display.width / 2)),
                    display.x + display.width - min(inset, display.width / 2))
        let y = min(max(asked.y, display.y + min(inset, display.height / 2)),
                    display.y + display.height - min(inset, display.height / 2))
        return (x, y)
    }
}
