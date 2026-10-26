import Foundation
import Testing
@testable import GlassActCore
import GlassActTestSupport
import GlassActWire

/// An encoder that stops answering mustn't take the session with it (§4.6):
/// live, the system's video encoder service went silent for minutes right
/// after a virtual display came up, and the session went black. After
/// `videoEncoderStallUS` with a frame still inside, video is given up for the
/// session and lossless tiles carry the screen.
@Suite struct EncoderStallTests {
    /// Takes frames and never delivers one.
    final class SilentEncoder: VideoRegionEncoder {
        var codecID: UInt8 { MockVideoEncoder.mockCodecID }
        var submitted = 0
        func start(width: Int, height: Int, onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool { true }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) { submitted += 1 }
        func stop() {}
    }

    @Test func aSilentEncoderGivesVideoUpAndTilesCarryTheScreen() {
        var rng = SplitMix64(seed: 5101)
        let encoder = SilentEncoder()
        let h = Harness(width: 640, height: 384, video: true, encoderFactory: { _ in encoder })
        var stalls = 0
        h.host.onVideoEncoderStalled = { stalls += 1 }
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        #expect(h.host.activeVideoRegionCount == 1, "setup: the pinned region formed")
        for _ in 0..<(5 * 60) { // 5 s of motion, the encoder answering nothing
            h.frame.fillRect(x: 0, y: 0, w: 384, h: 384, &rng)
            h.encodeFrame()
            h.run(untilUS: h.now + 16_667)
        }
        #expect(stalls == 1)
        #expect(h.host.stats.videoEncoderStalls == 1)
        #expect(h.host.activeVideoRegionCount == 0, "no region re-forms on a stalled encoder")
        #expect(encoder.submitted <= HostEngine.videoMaxPendingFrames, "the gate stops at the frames in flight")
        #expect(h.viewer.state == .running, "the session keeps going")
        #expect(h.settle())
        #expect(h.canvasMatchesFrame(), "lossless tiles carried the screen")
    }
}
