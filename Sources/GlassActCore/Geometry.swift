/// §3.1 — tile geometry. `tile = 64`, edge tiles crop.
public struct TileGrid: Equatable, Sendable {
    public static let tileSize = 64
    /// Largest canvas side either end accepts (the viewer bounds its HELLO
    /// allocation by it). It also keeps every tile index inside the wire's
    /// u16 `tile_idx`: 8192² is 16,384 tiles.
    public static let maxDimension = 8192

    public let width: Int
    public let height: Int
    public let cols: Int
    public let rows: Int

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        cols = (width + Self.tileSize - 1) / Self.tileSize
        rows = (height + Self.tileSize - 1) / Self.tileSize
    }

    public var count: Int { cols * rows }

    /// `tile_idx = row*cols + col`; edge tiles crop to the frame.
    @inline(__always)
    public func rect(of idx: Int) -> (x: Int, y: Int, tw: Int, th: Int) {
        let col = idx % cols
        let row = idx / cols
        let x = col * Self.tileSize
        let y = row * Self.tileSize
        return (x, y, min(Self.tileSize, width - x), min(Self.tileSize, height - y))
    }

    @inline(__always)
    public func tightByteCount(of idx: Int) -> Int {
        let (_, _, tw, th) = rect(of: idx)
        return tw * th * 4
    }
}

/// A changed region hint from capture (§4.1). Hints only: tiles intersecting
/// a dirty rect are *candidates*; the hash diff decides what actually sends.
public struct DirtyRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
