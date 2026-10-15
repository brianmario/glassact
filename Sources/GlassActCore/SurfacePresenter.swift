public import IOSurface
import Dispatch

/// §5 present path, blit half: two IOSurfaces as a flip pool. Each call
/// blits the union of the last TWO drains' dirty tiles (buffer age: the
/// back surface last saw the canvas two flips ago) from the engine's canvas
/// into the back surface, and hands that surface to the caller to flip.
///
/// Tiles showing region video read the engine's overlay layer instead of
/// the canvas — the composite happens here, at
/// present time, so the canvas itself stays exactly-as-coded (INV-8).
///
/// Confined to the viewer engine's queue (`applyQueue`) — the canvas's own
/// queue — so it reads the canvas without locks and the main thread never
/// waits on apply work. A display link running `queue.sync { blit }` on
/// main would make main do the copy (up to a full 5K frame) AND first wait
/// out whatever the apply queue was doing (a keyframe decode, a burst). The
/// caller flips `layer.contents` on main when a blit completes and starts
/// the next one no sooner than the next display tick, so a surface is never
/// written while it is the displayed one.
public final class SurfacePresenter: @unchecked Sendable {
    /// A finished blit: the surface to flip to, and the capture timestamps
    /// of the records it newly shows (glass-to-glass telemetry).
    public struct Frame: @unchecked Sendable {
        public let surface: IOSurface
        public let captureTimestampsUS: [UInt64]
        /// How long the copy took, and when it finished (uptime µs) — the
        /// session log's blit cost and blit→flip delay.
        public let blitUS: UInt64
        public let completedUptimeUS: UInt64
    }

    @inline(__always)
    public static func uptimeUS() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

    public let grid: TileGrid
    private let surfaces: [IOSurface]
    private var primed = [false, false]
    private var back = 0
    private var currentDirty: [Int] = []
    private var previousDirty: [Int] = []
    private var unionMark: [Bool]
    private var captureTimestamps: [UInt64] = []

    /// Main thread or any: construction only. Everything else: engine queue.
    public init(grid: TileGrid) {
        self.grid = grid
        surfaces = (0..<2).map { _ in
            IOSurface(properties: [
                .width: grid.width,
                .height: grid.height,
                .bytesPerElement: 4,
                .pixelFormat: UInt32(0x4247_5241), // 'BGRA'
            ])!
        }
        unionMark = [Bool](repeating: false, count: grid.count)
        currentDirty.reserveCapacity(grid.count)
        previousDirty.reserveCapacity(grid.count)
    }

    /// Engine queue. Nil when there is nothing new to show — or when the
    /// engine's canvas no longer matches this presenter's grid (§4.10: during
    /// an in-session resize the canvas is reallocated one beat before the
    /// view adopts a new presenter).
    public func blit(from engine: ViewerEngine) -> Frame? {
        guard let eg = engine.grid, eg.width == grid.width, eg.height == grid.height else { return nil }
        engine.drainDirtyTiles(into: &currentDirty)
        engine.drainAppliedCaptureTimestamps(into: &captureTimestamps)
        let fullBlit = !primed[back]
        guard fullBlit || !currentDirty.isEmpty || !previousDirty.isEmpty else { return nil }
        let startUS = Self.uptimeUS()
        let surface = surfaces[back]
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let dstBase = surface.baseAddress
        let dstBytesPerRow = surface.bytesPerRow
        let grid = self.grid
        let blitted: Bool? = engine.withPresentSources { canvas, overlay, showsOverlay in
            let canvasBase = canvas.baseAddress!
            let overlayBase = overlay?.baseAddress
            func blitTile(_ index: Int) {
                let (x, y, tw, th) = grid.rect(of: index)
                // Video overlay (same layout as the canvas) where this tile
                // shows newer video than its lossless record.
                let srcBase = overlayBase != nil && showsOverlay(index) ? overlayBase! : canvasBase
                for row in 0..<th {
                    dstBase.advanced(by: (y + row) * dstBytesPerRow + x * 4)
                        .copyMemory(from: srcBase.advanced(by: ((y + row) * grid.width + x) * 4),
                                    byteCount: tw * 4)
                }
            }
            if fullBlit {
                for index in 0..<grid.count { blitTile(index) }
            } else {
                for index in currentDirty { unionMark[index] = true }
                for index in previousDirty where !unionMark[index] { blitTile(index) }
                for index in currentDirty {
                    blitTile(index)
                    unionMark[index] = false
                }
            }
            return true
        }
        guard blitted == true else { return nil }
        primed[back] = true
        back = 1 - back
        swap(&previousDirty, &currentDirty)
        let doneUS = Self.uptimeUS()
        let frame = Frame(surface: surface, captureTimestampsUS: captureTimestamps,
                          blitUS: doneUS - startUS, completedUptimeUS: doneUS)
        captureTimestamps.removeAll(keepingCapacity: true)
        return frame
    }
}
