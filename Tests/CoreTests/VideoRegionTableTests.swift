import Testing
@testable import GlassActCore
import GlassActWire
import GlassActTestSupport

/// Viewer video regions (§5), driven on the table alone against a local
/// overlay buffer and a scripted decoder.
@Suite struct VideoRegionTableTests {
    /// Delivers `pixels` (tight, `width × height`) while `succeed`; else
    /// reports an undecodable frame without delivering.
    private final class ScriptedDecoder: VideoRegionDecoder {
        var acceptStart = true
        var succeed = true
        var pixels: [UInt8] = []
        var width = 0
        var stops = 0

        func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
            self.width = width
            return acceptStart
        }

        func decode(_ data: [UInt8], sync: Bool,
                    onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
            guard succeed else { return false }
            pixels.withUnsafeBytes { onPixels($0, width * 4) }
            return true
        }

        func stop() { stops += 1 }
    }

    private final class Harness {
        let grid = TileGrid(width: 128, height: 128) // 2×2 tiles
        let overlay: UnsafeMutableRawBufferPointer
        var tileSeq: ContiguousArray<UInt32> = [0, 0, 0, 0]
        var overlaySeq: ContiguousArray<UInt32> = [0, 0, 0, 0]
        var overlayOn: ContiguousArray<Bool> = [false, false, false, false]
        var dirty = DirtyTiles()
        let decoder = ScriptedDecoder()
        var table: VideoRegionTable

        init() {
            overlay = .allocate(byteCount: 128 * 128 * 4, alignment: 64)
            overlay.initializeMemory(as: UInt8.self, repeating: 0)
            dirty.reset(tileCount: 4)
            let decoder = decoder
            table = VideoRegionTable(decoderFactory: { decoder })
        }

        deinit { overlay.deallocate() }

        func frame(region: Int = 0, generation: UInt32 = 1, stamp: UInt32 = 5,
                   claims: VideoClaims = .all, nowUS: UInt64 = 0) -> VideoRegionTable.FrameResult {
            table.applyFrame(region: region, generation: generation, stamp: stamp, sync: true,
                             claims: claims, data: [0], nowUS: nowUS, overlay: overlay, grid: grid,
                             tileSeq: tileSeq, dirty: &dirty, overlaySeq: &overlaySeq, overlayOn: &overlayOn)
        }

        // Class-method wrappers: `#expect` can't call a mutating member.
        func start(region: Int, generation: UInt32, x: Int, y: Int, w: Int, h: Int, codec: UInt8) -> Bool {
            table.start(region: region, generation: generation, x: x, y: y, w: w, h: h,
                        codec: codec, config: [], grid: grid)
        }

        func stop(region: Int, generation: UInt32) -> Bool {
            table.stop(region: region, generation: generation)
        }

        func pixel(_ x: Int, _ y: Int) -> UInt8 { overlay[(y * 128 + x) * 4] }
    }

    @Test func frameBlitsUnderTheStampGateWithoutAdvancingSeq() {
        let h = Harness()
        // Region: the right column of tiles, 64×128 at x = 64.
        #expect(h.start(region: 0, generation: 1, x: 64, y: 0, w: 64, h: 128, codec: 1))
        #expect(h.table.activeCodec == 1)
        h.decoder.pixels = [UInt8](repeating: 0xAB, count: 64 * 128 * 4)
        h.tileSeq[3] = 9 // tile 3 already holds a record newer than the frame
        let r = h.frame(stamp: 5)
        #expect(!r.dropped && r.decoded && r.blits == 1 && !r.undecodableTooLong)
        #expect(h.pixel(64, 0) == 0xAB)   // tile 1 written
        #expect(h.pixel(64, 64) == 0)     // tile 3 LWW-skipped
        #expect(h.pixel(0, 0) == 0)       // outside the region
        #expect(h.tileSeq == [0, 0, 0, 9]) // video never advances tileSeq
        #expect(h.overlayOn == [false, true, false, false]) // tile 1 now shows video…
        #expect(h.overlaySeq == [0, 5, 0, 0])               // …stamped by the frame
        var drained: [Int] = []
        h.dirty.drain(into: &drained)
        #expect(drained == [1])
        // Wrong generation / unknown region: dropped.
        #expect(h.frame(generation: 2).dropped)
        #expect(h.frame(region: 3).dropped)
    }

    /// An unclaimed tile's overlay pixels refresh, but it keeps showing
    /// whatever it showed (its exact canvas copy after a handoff).
    @Test func onlyClaimedTilesRecordTheStamp() {
        let h = Harness()
        #expect(h.start(region: 0, generation: 1, x: 0, y: 0, w: 128, h: 128, codec: 1))
        h.decoder.pixels = [UInt8](repeating: 0xCD, count: 128 * 128 * 4)
        // Region-relative runs over the 2×2 box: tiles 1 and 2.
        let r = h.frame(stamp: 7, claims: .runs([.init(start: 1, count: 2)]))
        #expect(!r.dropped && r.blits == 1)
        #expect(h.overlayOn == [false, true, true, false])
        #expect(h.overlaySeq == [0, 7, 7, 0])
        #expect(h.pixel(0, 0) == 0xCD && h.pixel(64, 64) == 0xCD, "unclaimed tiles still refresh")
    }

    @Test func undecodableStreakEscalatesAfterTheLimitAndSuccessResetsIt() {
        let h = Harness()
        #expect(h.start(region: 1, generation: 7, x: 0, y: 0, w: 64, h: 64, codec: 1))
        h.decoder.pixels = [UInt8](repeating: 1, count: 64 * 64 * 4)
        h.decoder.succeed = false
        let limit = VideoRegionTable.undecodableLimitUS
        #expect(!h.frame(region: 1, generation: 7, nowUS: 1_000).undecodableTooLong) // streak starts
        #expect(!h.frame(region: 1, generation: 7, nowUS: 1_000 + limit).undecodableTooLong)
        // A success in between resets the streak.
        h.decoder.succeed = true
        #expect(h.frame(region: 1, generation: 7, nowUS: 1_000 + limit).decoded)
        h.decoder.succeed = false
        let later = 2_000 + limit
        #expect(!h.frame(region: 1, generation: 7, nowUS: later).undecodableTooLong)
        let r = h.frame(region: 1, generation: 7, nowUS: later + limit + 1)
        #expect(!r.decoded && r.blits == 0 && r.undecodableTooLong)
    }

    @Test func startStopAndStopAllManageTheDecoder() {
        let h = Harness()
        // Out-of-bounds rect and out-of-range slot are refused before any
        // decoder is built.
        #expect(!h.start(region: 0, generation: 1, x: 64, y: 0, w: 65, h: 64, codec: 1))
        #expect(!h.start(region: VideoRegionTable.slotCount, generation: 1, x: 0, y: 0, w: 64, h: 64, codec: 1))
        // A decoder that refuses the codec leaves the region inactive.
        h.decoder.acceptStart = false
        #expect(!h.start(region: 0, generation: 1, x: 0, y: 0, w: 64, h: 64, codec: 1))
        #expect(h.table.activeCodec == nil)
        h.decoder.acceptStart = true
        #expect(h.start(region: 0, generation: 1, x: 0, y: 0, w: 64, h: 64, codec: 3))
        #expect(!h.stop(region: 0, generation: 2)) // stale generation: ignored
        #expect(h.stop(region: 0, generation: 1))
        #expect(h.table.activeCodec == nil)
        #expect(h.decoder.stops == 1)
        #expect(h.start(region: 2, generation: 4, x: 0, y: 0, w: 64, h: 64, codec: 3))
        h.table.stopAll()
        #expect(h.decoder.stops == 2)
        #expect(h.frame(region: 2, generation: 4).dropped)
        #expect(!VideoRegionTable(decoderFactory: nil).decodesRegions)
    }
}
