import Testing
import GlassActCodec
import GlassActWire
@testable import GlassActCore
import GlassActTestSupport

/// Lossless keyframe apply (§4.7), driven on the applier alone against a local canvas.
@Suite struct KeyframeApplierTests {
    /// Opaque low-entropy BGRA (a 4-colour palette), so VP8L compresses it.
    private static func image(_ w: Int, _ h: Int, _ rng: inout SplitMix64) -> [UInt8] {
        let palette: [[UInt8]] = (0..<4).map { _ in rng.bytes(3) + [0xFF] }
        var out: [UInt8] = []
        out.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { out += palette[Int(rng.next() % 4)] }
        return out
    }

    /// Lossless stripes of `image`, split into `count` row bands.
    private static func stripes(_ image: [UInt8], _ w: Int, _ h: Int, count: Int) -> [[UInt8]] {
        let bandH = (h + count - 1) / count
        return (0..<count).map { i in
            let rows = min(bandH, h - i * bandH)
            let band = Array(image[(i * bandH * w * 4)..<((i * bandH + rows) * w * 4)])
            var out = [UInt8](repeating: 0, count: band.count + 1024)
            let n = band.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    WebPTile.encodeLossless(src: src, width: w, height: rows, effort: 4, dst: dst)
                }
            }
            precondition(n > 0)
            return Array(out[0..<n])
        }
    }

    private static func tile(_ canvas: UnsafeMutableRawBufferPointer, _ grid: TileGrid, _ idx: Int) -> [UInt8] {
        let (x, y, tw, th) = grid.rect(of: idx)
        var out = [UInt8](repeating: 0, count: tw * th * 4)
        out.withUnsafeMutableBytes {
            _ = TileOps.extract(src: UnsafeRawBufferPointer(canvas), bytesPerRow: grid.width * 4,
                                x: x, y: y, tw: tw, th: th, into: $0)
        }
        return out
    }

    @Test func appliesPerTileUnderLWWAndOnlyLosslessAdvancesSeq() {
        var rng = SplitMix64(seed: 0x4B46)
        let grid = TileGrid(width: 128, height: 64) // 2 tiles
        let canvas = UnsafeMutableRawBufferPointer.allocate(byteCount: 128 * 64 * 4, alignment: 64)
        defer { canvas.deallocate() }
        canvas.initializeMemory(as: UInt8.self, repeating: 0)
        var tileSeq: ContiguousArray<UInt32> = [0, 10] // tile 1 already has a newer record
        var dirty = DirtyTiles()
        dirty.reset(tileCount: 2)
        var applier = KeyframeApplier()

        let img = Self.image(128, 64, &rng)
        let outcome = applier.apply(seq: 5, x: 0, y: 0, w: 128, h: 64, codec: KeyframeCodec.vp8lStriped,
                                    stripes: Self.stripes(img, 128, 64, count: 3),
                                    canvas: canvas, grid: grid, tileSeq: &tileSeq, dirty: &dirty)
        #expect(outcome == .applied)
        #expect(tileSeq == [5, 10])
        var expected0 = [UInt8]()
        for r in 0..<64 { expected0 += img[(r * 128 * 4)..<(r * 128 * 4 + 64 * 4)] }
        #expect(Self.tile(canvas, grid, 0) == expected0)
        #expect(Self.tile(canvas, grid, 1) == [UInt8](repeating: 0, count: 64 * 64 * 4)) // LWW-skipped
        var drained: [Int] = []
        dirty.drain(into: &drained)
        #expect(drained == [0])
    }

    @Test func invalidStripingOrCorruptStripeDropsWithoutTouchingTheCanvas() {
        var rng = SplitMix64(seed: 5)
        let grid = TileGrid(width: 64, height: 64)
        let canvas = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 64 * 4, alignment: 64)
        defer { canvas.deallocate() }
        canvas.initializeMemory(as: UInt8.self, repeating: 0)
        var tileSeq: ContiguousArray<UInt32> = [0]
        var dirty = DirtyTiles()
        dirty.reset(tileCount: 1)
        var applier = KeyframeApplier()

        // 3 stripes cannot each own rows of a 2-row rect (rejected before
        // any decode).
        let tooMany = applier.apply(seq: 1, x: 0, y: 0, w: 64, h: 2, codec: KeyframeCodec.vp8lStriped,
                                    stripes: [[1], [1], [1]],
                                    canvas: canvas, grid: grid, tileSeq: &tileSeq, dirty: &dirty)
        // One undecodable stripe fails the whole keyframe.
        var stripes = Self.stripes(Self.image(64, 64, &rng), 64, 64, count: 2)
        stripes[1] = rng.bytes(stripes[1].count)
        let corrupt = applier.apply(seq: 2, x: 0, y: 0, w: 64, h: 64, codec: KeyframeCodec.vp8lStriped,
                                    stripes: stripes,
                                    canvas: canvas, grid: grid, tileSeq: &tileSeq, dirty: &dirty)
        // Misaligned origin.
        let misaligned = applier.apply(seq: 3, x: 1, y: 0, w: 63, h: 64, codec: KeyframeCodec.vp8lStriped,
                                       stripes: stripes,
                                       canvas: canvas, grid: grid, tileSeq: &tileSeq, dirty: &dirty)
        #expect(tooMany == .dropped && corrupt == .dropped && misaligned == .dropped)
        #expect(tileSeq == [0])
        #expect(dirty.count == 0)
        #expect(Self.tile(canvas, grid, 0) == [UInt8](repeating: 0, count: 64 * 64 * 4))
    }
}
