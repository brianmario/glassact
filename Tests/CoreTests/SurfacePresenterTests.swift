import Foundation
import IOSurface
import Testing
import GlassActCore
import GlassActTestSupport

/// SurfacePresenter: whichever surface a blit hands back must equal the
/// canvas exactly — the buffer-age union (this drain + the previous one)
/// has to cover everything the back surface missed two flips ago.
@Suite struct SurfacePresenterTests {
    private func matches(_ frame: SurfacePresenter.Frame, _ h: Harness) -> Bool {
        let s = frame.surface
        s.lock(options: .readOnly, seed: nil)
        defer { s.unlock(options: .readOnly, seed: nil) }
        let w = h.frame.width, rows = h.frame.height
        return h.viewer.withCanvas { canvas in
            (0..<rows).allSatisfy { y in
                memcmp(s.baseAddress.advanced(by: y * s.bytesPerRow), canvas.baseAddress!.advanced(by: y * w * 4), w * 4) == 0
            }
        } ?? false
    }

    @Test func everyPresentedSurfaceEqualsTheCanvas() {
        var rng = SplitMix64(seed: 77)
        let h = Harness(width: 320, height: 256)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle())
        let presenter = SurfacePresenter(grid: TileGrid(width: 320, height: 256))
        var presented = 0
        for _ in 0..<60 {
            _ = h.mutateRandomRects(&rng, count: rng.int(0..<3))
            h.encodeFrame()
            h.run(untilUS: h.now + 16_000)
            if let frame = presenter.blit(from: h.viewer) {
                presented += 1
                #expect(matches(frame, h), "a presented surface diverged from the canvas")
            }
        }
        #expect(presented > 10)
        // Idle: nothing new, nothing to flip (after both surfaces caught up).
        _ = presenter.blit(from: h.viewer)
        #expect(presenter.blit(from: h.viewer) == nil)
    }

    @Test func mismatchedGridPresentsNothing() {
        let h = Harness(width: 320, height: 256)
        let presenter = SurfacePresenter(grid: TileGrid(width: 640, height: 480))
        #expect(presenter.blit(from: h.viewer) == nil)
    }

    /// Reference number for BENCHMARKS: a full 5K surface blit.
    @Test func fullFiveKBlitCost() {
        let h = Harness(width: 5120, height: 2880)
        let presenter = SurfacePresenter(grid: TileGrid(width: 5120, height: 2880))
        _ = presenter.blit(from: h.viewer) // surface A: full (first touch)
        _ = presenter.blit(from: h.viewer) // surface B: full (first touch)
        // Both surfaces now warm; force another full-screen change.
        var rng = SplitMix64(seed: 5)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        _ = h.settle(maxSimMS: 120_000)
        _ = presenter.blit(from: h.viewer)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let frame = presenter.blit(from: h.viewer) // buffer age: the full union again, warm
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        #expect(frame != nil)
        print(String(format: "SurfacePresenter: full 5K blit (warm) %.2f ms", ms))
    }
}
