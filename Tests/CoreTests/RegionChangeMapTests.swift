import Foundation
import Testing
import GlassActCore
import GlassActTestSupport

/// The change map the engine passes with each region frame (`encode(…changed:)`): per 64×64 of
/// the frame, what changed since the frame it passed before. The hybrid AV1 encoder's copy finder
/// compares only what's marked, so a 64×64 marked unchanged must equal the frame before's, every
/// pixel, whatever came between: frames the engine skipped (an encoder full of frames), dirty
/// rects or none, and partial 64×64s at the edges.
@Suite struct RegionChangeMapTests {
    /// Checks each frame's map against the frame before it, and holds its frames' delivery until
    /// `release()` (so the engine skips frames while two are pending).
    final class CheckingEncoder: VideoRegionEncoder {
        let inner = MockVideoEncoder(codecID: MockVideoEncoder.mockCodecID)
        var width = 0, height = 0
        private var onFrame: (([UInt8], Bool, [UInt8]?) -> Void)?
        private var held: [([UInt8], Bool, [UInt8]?)] = []
        private var last: [UInt8]?
        private(set) var frames = 0, maps = 0, unchanged = 0, marked = 0, nilMaps = 0
        private(set) var wrong: [String] = []
        var codecID: UInt8 { inner.codecID }

        func start(width: Int, height: Int, onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
            (self.width, self.height, self.onFrame, last) = (width, height, onFrame, nil)
            return inner.start(width: width, height: height) { [weak self] data, sync, config in
                self?.held.append((data, sync, config))
            }
        }

        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
            encode(bgra: bgra, forceSync: forceSync, timeUS: timeUS, changed: nil)
        }

        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64, changed: UnsafeBufferPointer<UInt8>?) {
            frames += 1
            let now = Array(bgra)
            let cols = (width + 63) / 64, rows = (height + 63) / 64
            if let changed {
                maps += 1
                if changed.count != cols * rows { wrong.append("frame \(frames): \(changed.count) entries, not \(cols * rows)") }
                if let last, changed.count == cols * rows {
                    for sy in 0..<rows {
                        for sx in 0..<cols {
                            let differs = (sy * 64..<min(height, sy * 64 + 64)).contains { y in
                                let o = (y * width + sx * 64) * 4, n = (min(width, sx * 64 + 64) - sx * 64) * 4
                                return now[o..<o + n] != last[o..<o + n]
                            }
                            if changed[sy * cols + sx] == 0 {
                                unchanged += 1
                                if differs { wrong.append("frame \(frames): 64×64 (\(sx), \(sy)) marked unchanged differs") }
                            } else {
                                marked += 1
                            }
                        }
                    }
                }
            } else {
                nilMaps += 1
            }
            last = now
            inner.encode(bgra: bgra, forceSync: forceSync, timeUS: timeUS)
        }

        /// Delivers the frames held.
        func release() {
            let out = held
            held = []
            for f in out { onFrame?(f.0, f.1, f.2) }
        }

        func stop() { inner.stop() }
    }

    @Test(.tags(.slow), .notInFastLane) func unchangedMarksAreExactAcrossSkippedFrames() {
        var rng = SplitMix64(seed: 4401)
        let encoder = CheckingEncoder()
        // 1300×650: partial tiles and 64×64s on the right and bottom edges
        let h = Harness(width: 1300, height: 650, video: true, encoderFactory: { _ in encoder })
        h.frame.fillRandom(&rng)
        h.encodeFrame()  // pinned cold start: the region forms on the first frame
        encoder.release()
        h.run(untilUS: h.now + 50_000)
        #expect(h.host.activeVideoRegionCount == 1, "setup: a pinned region")
        #expect(encoder.width == 1300 && encoder.height == 650, "setup: the region is the whole frame")
        for tick in 0..<80 {
            // enough change to keep the region up: a band of 40+ tiles, and a few small rects
            // (some straddling the partial edge 64×64s)
            let top = rng.int(0..<(650 - 128))
            h.frame.fillRect(x: 0, y: top, w: 1300, h: 128, &rng)
            var rects = [DirtyRect(x: 0, y: top, width: 1300, height: 128)]
            rects += h.mutateRandomRects(&rng, count: rng.int(0..<4))
            if tick % 9 == 4 { h.frame.fillRect(x: 1290, y: 640, w: 10, h: 10, &rng) }  // the corner, unannounced
            // dirty rects some ticks, none on others (the region's own comparison decides either way)
            h.encodeFrame(dirtyRects: tick % 3 == 0 ? nil : rects + [DirtyRect(x: 1280, y: 576, width: 20, height: 74)])
            // the encoder delivers only every third tick: the engine skips frames in between
            if tick % 3 == 2 { encoder.release() }
            h.run(untilUS: h.now + 16_000)
        }
        encoder.release()
        #expect(encoder.wrong.isEmpty, "\(encoder.wrong.prefix(5))")
        #expect(h.host.stats.videoEncoderFullSkips > 10, "skipped frames: \(h.host.stats.videoEncoderFullSkips)")
        #expect(encoder.maps > 20, "maps passed: \(encoder.maps) of \(encoder.frames)")
        #expect(encoder.unchanged > 500 && encoder.marked > 100, "unchanged \(encoder.unchanged), marked \(encoder.marked)")
        #expect(encoder.nilMaps >= 1, "the stream's first frame has none")
    }

    /// A new encoder (a re-formed region) gets no map with its first frame.
    @Test func aNewStreamStartsWithoutAMap() {
        var rng = SplitMix64(seed: 4402)
        let encoder = CheckingEncoder()
        let h = Harness(width: 640, height: 384, video: true, encoderFactory: { _ in encoder })
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        encoder.release()
        #expect(encoder.frames == 1 && encoder.nilMaps == 1)
        h.run(untilUS: h.now + 16_000)
        h.frame.fillRect(x: 0, y: 0, w: 640, h: 200, &rng)
        h.encodeFrame()
        encoder.release()
        #expect(encoder.frames == 2 && encoder.maps == 1)
        #expect(encoder.wrong.isEmpty, "\(encoder.wrong.prefix(5))")
    }
}
