import Foundation
import Testing
import GlassActWire
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// LWW property (INV-2): random subsets/orderings/dups of datagrams → canvas
/// equals a simple per-tile max-seq model.
@Suite struct LWWPropertyTests {
    @Test(arguments: [UInt64(3), 17, 99])
    func canvasMatchesModelUnderRandomDelivery(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let width = 320, height = 240
        let grid = TileGrid(width: width, height: height)
        let (viewer, _) = makeRunningViewer(width: width, height: height)

        // Generate batches 1...25, each touching a random subset of tiles with
        // random content, one unfragmented RAW record per datagram.
        struct Sent {
            var seq: UInt32
            var tile: Int
            var payload: [UInt8]
            var data: Data
        }
        var sent: [Sent] = []
        for seq in 1...25 {
            for tile in 0..<grid.count where rng.int(0..<3) == 0 {
                let payload = rng.bytes(grid.tightByteCount(of: tile))
                let data = makeDatagram(seq: UInt32(seq), records: [(UInt16(tile), payload)])
                sent.append(Sent(seq: UInt32(seq), tile: tile, payload: payload, data: data))
            }
        }

        // Random delivery plan: ~70% kept, ~15% of kept duplicated, then shuffled.
        var deliveries: [Sent] = []
        var model: [Int: (seq: UInt32, payload: [UInt8])] = [:]
        for s in sent {
            guard rng.int(0..<10) < 7 else { continue }
            deliveries.append(s)
            if rng.int(0..<100) < 15 {
                deliveries.append(s)
            }
            if let existing = model[s.tile] {
                if Serial.newer(s.seq, than: existing.seq) {
                    model[s.tile] = (s.seq, s.payload)
                }
            } else {
                model[s.tile] = (s.seq, s.payload)
            }
        }
        deliveries.shuffle(using: &rng)

        for d in deliveries {
            viewer.handleDatagram(d.data, nowUS: 0)
        }

        for tile in 0..<grid.count {
            let expected = model[tile]?.payload ?? [UInt8](repeating: 0, count: grid.tightByteCount(of: tile))
            #expect(canvasTile(viewer, tile) == expected, "tile \(tile)")
        }
    }
}

/// §7 golden divergence: replay with seeded faults, settle on the final frame,
/// then require the viewer canvas to be **byte-identical** to the final
/// capture. Zero tolerance — the canvas is all-lossless (video is an
/// overlay, excluded from goldens).
@Suite struct GoldenDivergenceTests {
    @Test(arguments: [UInt64(1), 2, 3])
    func byteExactUnderSeededFaults(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50      // 5% drop
        faults.dupPermille = 10       // 1% dup
        faults.reorderPermille = 100  // 10% reorder
        faults.latencyMinUS = 20_000  // 20–80 ms jitter
        faults.latencyMaxUS = 80_000
        faults.seed = seed

        let harness = Harness(width: 320, height: 240, faults: faults)
        #expect(harness.host.state == .running)
        #expect(harness.viewer.state == .running)

        var rng = SplitMix64(seed: seed &* 0x9E37_79B9)
        harness.frame.fillRandom(&rng)
        harness.encodeFrame() // cold start: all tiles
        harness.run(untilUS: harness.now + 16_000)

        for frameIdx in 0..<40 {
            let rects = harness.mutateRandomRects(&rng, count: rng.int(1..<4))
            // Alternate dirty-rect hints and full scans — both paths must converge.
            harness.encodeFrame(dirtyRects: frameIdx % 2 == 0 ? rects : nil)
            harness.run(untilUS: harness.now + 16_000)
        }

        #expect(harness.settle(), "encoder failed to settle within bounded iterations")
        #expect(harness.canvasMatchesFrame(), "viewer canvas diverged from final capture (seed \(seed))")
        #expect(harness.link.droppedDatagrams > 0, "fault injection did not engage")
    }

    /// High-RTT golden (airplane/satellite wifi): ~500 ms RTT with the
    /// standard fault mix must still converge byte-exact — the bar is
    /// graceful convergence, not speed. Video is on: the cold start is a
    /// pinned region whose dissolve repaint stays un-ACKed for ~the full RTT
    /// (reading that as churn would re-form the region from its own repaint
    /// in a permanent dissolve/re-form livelock — settle would never
    /// complete, even at 480 s of sim time).
    @Test(arguments: [UInt64(11), 12, 13])
    func highRTTGoldenConvergence(seed: UInt64) {
        var faults = FaultConfig()
        faults.dropPermille = 50      // 5% drop
        faults.dupPermille = 10       // 1% dup
        faults.reorderPermille = 100  // 10% reorder
        faults.latencyMinUS = 225_000 // ~500 ms RTT
        faults.latencyMaxUS = 275_000
        faults.seed = seed

        let harness = Harness(width: 320, height: 240, faults: faults, video: true)
        harness.run(untilUS: harness.now + 1_500_000) // handshake needs the full RTT
        #expect(harness.host.state == .running)
        #expect(harness.viewer.state == .running)

        var rng = SplitMix64(seed: seed &* 0x9E37_79B9)
        harness.frame.fillRandom(&rng)
        harness.encodeFrame()
        harness.run(untilUS: harness.now + 16_000)

        for frameIdx in 0..<40 {
            let rects = harness.mutateRandomRects(&rng, count: rng.int(1..<4))
            harness.encodeFrame(dirtyRects: frameIdx % 2 == 0 ? rects : nil)
            harness.run(untilUS: harness.now + 16_000)
        }

        #expect(harness.settle(maxSimMS: 240_000),
                "encoder failed to settle at ~500 ms RTT (seed \(seed))")
        #expect(harness.canvasMatchesFrame(),
                "viewer canvas diverged from final capture (seed \(seed))")
        #expect(harness.link.droppedDatagrams > 0, "fault injection did not engage")
    }

    @Test func losslessConvergenceWithoutFaults() {
        var rng = SplitMix64(seed: 1234)
        let harness = Harness(width: 320, height: 240)
        harness.frame.fillRandom(&rng)
        harness.encodeFrame()
        for _ in 0..<10 {
            _ = harness.mutateRandomRects(&rng, count: 2)
            harness.encodeFrame()
            harness.run(untilUS: harness.now + 16_000)
        }
        #expect(harness.settle())
        #expect(harness.canvasMatchesFrame())
    }
}
