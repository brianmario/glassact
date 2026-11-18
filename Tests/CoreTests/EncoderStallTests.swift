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
        let codecID: UInt8
        var submitted = 0
        init(codecID: UInt8 = MockVideoEncoder.mockCodecID) { self.codecID = codecID }
        func start(width: Int, height: Int, onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool { true }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) { submitted += 1 }
        func stop() {}
    }

    @Test func aSilentEncoderGivesVideoUpAndTilesCarryTheScreen() {
        var rng = SplitMix64(seed: 5101)
        let encoder = SilentEncoder()
        let h = Harness(width: 640, height: 384, video: true, encoderFactory: { _ in encoder })
        var stalls = 0
        h.host.onVideoEncoderStalled = { _, continues in stalls += 1; #expect(!continues) }
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

    /// One codec's encoder going silent gives up that codec, not video: live (26.11.1,
    /// 2026-11-17) Glass Act's AV1 never delivered its first frame on a Host whose Metal cache
    /// was cold, and the session lost HEVC with it. Now the next region forms on HEVC, and an
    /// in-session resize (a new engine, `continueSession`) doesn't bring AV1 back.
    @Test func aStalledAV1EncoderLeavesHEVC() {
        var rng = SplitMix64(seed: 5102)
        // (the mocks: 0x7E stands in for AV1, under its caps bit and LinkRoomPolicy; 0x7F for HEVC)
        let (av1, hevc) = (MockVideoEncoder.mockAltCodecID, MockVideoEncoder.mockCodecID)
        let silent = SilentEncoder(codecID: av1)
        let h = Harness(width: 640, height: 384, video: true, hostCodecs: [av1, hevc], viewerCodecs: [av1, hevc],
                        encoderFactory: { $0 == av1 ? silent as any VideoRegionEncoder : MockVideoEncoder(codecID: $0) })
        func roomy() {  // (AV1 runs only while the link has room, LinkRoomPolicy)
            _ = h.host.linkRoom.noteSecond(deliveredBytesPerSecond: LinkRoomPolicy.roomyBitsPerSecond / 8,
                                          recentCapacityBytesPerSecond: 0, reports: 1)
        }
        func motion(seconds: Int) {
            for _ in 0..<(seconds * 60) {
                h.frame.fillRect(x: 0, y: 0, w: 384, h: 384, &rng)
                h.encodeFrame()
                h.run(untilUS: h.now + 16_667)
            }
        }
        var stalls: [String] = []
        h.host.onVideoEncoderStalled = { stalls.append("\($0) \($1)") }
        roomy()
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        #expect(h.host.activeVideoCodec == av1, "setup: the region formed on AV1")
        motion(seconds: 5)
        #expect(stalls == ["\(av1) true"], "AV1 given up, video going on")
        #expect(h.host.stats.videoEncoderStalls == 1)
        #expect(h.host.activeVideoRegionCount == 1 && h.host.activeVideoCodec == hevc,
                "the motion re-formed the region on HEVC")
        #expect(h.viewer.activeVideoCodec == hevc, "the Viewer decodes it")
        #expect(h.viewer.state == .running)

        // a resize: the new engine negotiates again, without AV1
        h.reconfigure(width: 512, height: 384)
        h.host.onVideoEncoderStalled = { stalls.append("\($0) \($1)") }
        roomy()
        h.run(untilUS: h.now + 300_000)
        motion(seconds: 2)
        #expect(h.host.activeVideoCodec == hevc, "AV1 stays given up after a resize")
        #expect(stalls.count == 1, "no second stall: AV1 wasn't tried again")
        #expect(silent.submitted <= HostEngine.videoMaxPendingFrames)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }
}
