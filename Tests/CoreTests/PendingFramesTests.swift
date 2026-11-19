import Foundation
import Testing
@testable import GlassActCore
import GlassActTestSupport

/// How many frames the engine leaves waiting in a region's encoder before it skips new ones
/// (newest wins, §4.6): the encoder's own `maxPendingFrames`, 2 unless it says otherwise, at most
/// `HostEngine.videoPendingFramesCap`. The hybrid AV1 encoder keeps its pipeline full at 60 fps of
/// new 5K pictures only with three (BENCHMARKS "three frames waiting").
@Suite struct PendingFramesTests {
    /// Takes frames, delivers none until `release()`.
    final class HoldingEncoder: VideoRegionEncoder {
        let codecID = MockVideoEncoder.mockCodecID
        let maxPendingFrames: Int
        var submitted = 0
        private var onFrame: (([UInt8], Bool, [UInt8]?) -> Void)?
        private var held = 0
        init(maxPendingFrames: Int) { self.maxPendingFrames = maxPendingFrames }
        func start(width: Int, height: Int, onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
            self.onFrame = onFrame
            return true
        }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
            submitted += 1
            held += 1
        }
        /// Delivers one frame of those held (an empty one: the engine counts it delivered).
        func releaseOne() {
            guard held > 0 else { return }
            held -= 1
            onFrame?([], false, nil)
        }
        func stop() {}
    }

    /// Frames submitted while the encoder delivers nothing, over many ticks of motion.
    private func submittedWhileHeld(_ limit: Int) -> (submitted: Int, skips: Int) {
        var rng = SplitMix64(seed: 7301 + UInt64(limit))
        let encoder = HoldingEncoder(maxPendingFrames: limit)
        let h = Harness(width: 640, height: 384, video: true, encoderFactory: { _ in encoder })
        h.frame.fillRandom(&rng)
        h.encodeFrame()  // the pinned region forms on the first frame
        for _ in 0..<20 {
            h.frame.fillRect(x: 0, y: 0, w: 640, h: 256, &rng)
            h.encodeFrame()
            h.run(untilUS: h.now + 16_667)
        }
        return (encoder.submitted, h.host.stats.videoEncoderFullSkips)
    }

    @Test(arguments: [1, 2, 3, 4])
    func theEngineLeavesTheEncodersOwnLimitWaiting(_ limit: Int) {
        let (submitted, skips) = submittedWhileHeld(limit)
        #expect(submitted == limit, "\(submitted) submitted with a limit of \(limit)")
        #expect(skips > 10, "the rest skipped: \(skips)")
    }

    /// A limit past the cap is the cap (the engine's ring of submit times holds that many).
    @Test func aLimitPastTheCapIsTheCap() {
        let (submitted, _) = submittedWhileHeld(HostEngine.videoPendingFramesCap + 3)
        #expect(submitted == HostEngine.videoPendingFramesCap)
    }

    /// With three waiting, deliveries in order keep the engine's encode times paired with their
    /// submits (the ring wraps): every delivery frees a slot for the next frame.
    @Test func threeWaitingWrapsTheRing() {
        var rng = SplitMix64(seed: 7311)
        let encoder = HoldingEncoder(maxPendingFrames: 3)
        let h = Harness(width: 640, height: 384, video: true, encoderFactory: { _ in encoder })
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        for tick in 0..<40 {
            h.frame.fillRect(x: 0, y: 0, w: 640, h: 256, &rng)
            h.encodeFrame()
            if tick % 2 == 1 { encoder.releaseOne() }
            h.run(untilUS: h.now + 16_667)
        }
        #expect(encoder.submitted >= 3 + 19, "a slot freed by each delivery is used: \(encoder.submitted)")
        #expect(h.host.stats.videoEncoderStalls == 0)
    }
}
