import Testing
import GlassActWire
@testable import GlassActCore
import GlassActTestSupport

/// A live region moves to AV1 once the link allows it (`HostEngine.upgradeRegionCodec`, §4.6):
/// a session starts without room, so its first region forms on HEVC, and a screen that never
/// stops moving never dissolves for the next region to form on AV1. Live (26.11.2, 2026-11-18)
/// a lock screen's video ran HEVC for as long as it was shown. The mocks: 0x7E stands in for
/// AV1, under its caps bit and LinkRoomPolicy; 0x7F for HEVC.
@Suite struct CodecUpgradeTests {
    static let (av1, hevc) = (MockVideoEncoder.mockAltCodecID, MockVideoEncoder.mockCodecID)

    static func session(ready: @escaping () -> Bool = { true }) -> Harness {
        Harness(width: 640, height: 384, video: true, hostCodecs: [av1, hevc], viewerCodecs: [av1, hevc],
                encoderFactory: { codec in
                    codec == av1 && !ready() ? nil : MockVideoEncoder(codecID: codec)
                })
    }

    static func motion(_ h: Harness, frames: Int, _ rng: inout SplitMix64) {
        for _ in 0..<frames {
            h.frame.fillRect(x: 0, y: 0, w: 384, h: 384, &rng)
            h.encodeFrame()
            h.run(untilUS: h.now + 16_667)
        }
    }

    static func roomy(_ h: Harness) {
        _ = h.host.linkRoom.noteSecond(deliveredBytesPerSecond: LinkRoomPolicy.roomyBitsPerSecond / 8,
                                      recentCapacityBytesPerSecond: 0, reports: 1)
    }

    /// The region forms on HEVC before the link has shown room, and moves to AV1 in place once it
    /// has: one region, no dissolve, a second VIDEO_START the Viewer decodes.
    @Test func aMovingRegionMovesToAV1OnceTheLinkHasRoom() {
        var rng = SplitMix64(seed: 1118)
        let h = Self.session()
        var codecs: [UInt8] = []
        h.host.onVideoCodecChanged = { if let codec = $0 { codecs.append(codec) } }
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        #expect(!h.host.linkRoom.hasRoom && h.host.activeVideoCodec == Self.hevc,
                "setup: the region formed on HEVC, before the link showed room")
        Self.roomy(h)
        Self.motion(h, frames: 150, &rng)
        #expect(h.host.activeVideoCodec == Self.av1, "the live region moved to AV1")
        #expect(codecs == [Self.hevc, Self.av1])
        #expect(h.host.stats.videoCodecUpgrades == 1)
        #expect(h.host.stats.videoRegionsFormed == 1 && h.host.stats.videoRegionsDissolved == 0,
                "in place: no dissolve, no lossless repaint")
        #expect(h.viewer.activeVideoCodec == Self.av1, "the Viewer decodes the new stream")
        #expect(h.viewer.stats.videoStarts == 2)
        #expect(h.viewer.stats.videoDecodeFailures == 0 && h.viewer.stats.videoDropped == 0)
        #expect(h.viewer.state == .running)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }

    /// AV1's encoder isn't ready when the region forms (its kernels compiling: the factory has
    /// none): HEVC, then AV1 within a second of it being ready.
    @Test func aMovingRegionMovesToAV1OnceItsEncoderIsReady() {
        var rng = SplitMix64(seed: 1119)
        var ready = false
        let h = Self.session(ready: { ready })
        Self.roomy(h)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        #expect(h.host.activeVideoCodec == Self.hevc, "setup: AV1 not ready, HEVC")
        Self.motion(h, frames: 90, &rng)
        #expect(h.host.activeVideoCodec == Self.hevc, "still not ready")
        ready = true
        Self.motion(h, frames: 90, &rng)
        #expect(h.host.activeVideoCodec == Self.av1)
        #expect(h.host.stats.videoCodecUpgrades == 1 && h.host.stats.videoRegionsDissolved == 0)
        #expect(h.viewer.activeVideoCodec == Self.av1)
        #expect(h.viewer.stats.videoDecodeFailures == 0)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }

    /// Only upward: a region on AV1 keeps it when the link loses its room (a sync frame mid-motion
    /// costs most on a thin link); the next region forms on HEVC.
    @Test func aRegionKeepsAV1WhenTheLinkLosesItsRoom() {
        var rng = SplitMix64(seed: 1120)
        let h = Self.session()
        Self.roomy(h)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        #expect(h.host.activeVideoCodec == Self.av1, "setup: the region formed on AV1")
        h.host.linkRoom = LinkRoomPolicy()  // no room
        h.host.upgradeRegionCodec(nowUS: h.now)
        #expect(h.host.allowedVideoCodecs == [Self.hevc])
        #expect(h.host.activeVideoCodec == Self.av1 && h.host.stats.videoCodecUpgrades == 0)
    }

    /// An AV1 that never answers (26.11.1's cold start, arriving through an upgrade).
    final class SilentEncoder: VideoRegionEncoder {
        let codecID = MockVideoEncoder.mockAltCodecID
        func start(width: Int, height: Int, onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool { true }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {}
        func stop() {}
    }

    /// An AV1 whose every delivery is empty (a failed encode).
    final class EmptyEncoder: VideoRegionEncoder {
        let codecID = MockVideoEncoder.mockAltCodecID
        private var onFrame: (([UInt8], Bool, [UInt8]?) -> Void)?
        func start(width: Int, height: Int, onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
            self.onFrame = onFrame
            return true
        }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) { onFrame?([], forceSync, nil) }
        func stop() { onFrame = nil }
    }

    /// The region dissolves after an upgrade but before the new stream's VIDEO_START went: the
    /// STOP goes to the stream the Viewer shows (HEVC's generation), so its region ends there
    /// and no tile stays on its overlay. Explicit dirty rects throughout: `settle()` would
    /// full-scan and repaint a tile left behind.
    @Test(arguments: ["silent", "empty"])
    func aDissolveRightAfterAnUpgradeStopsTheStreamTheViewerShows(_ kind: String) {
        var rng = SplitMix64(seed: 1122)
        let h = Harness(width: 640, height: 384, video: true, hostCodecs: [Self.av1, Self.hevc],
                        viewerCodecs: [Self.av1, Self.hevc],
                        encoderFactory: { codec -> (any VideoRegionEncoder)? in
                            if codec == Self.hevc { return MockVideoEncoder(codecID: codec) }
                            return kind == "silent" ? SilentEncoder() : EmptyEncoder()
                        })
        let moving = [DirtyRect(x: 0, y: 0, width: 384, height: 384)]
        h.frame.fillRandom(&rng)
        h.encodeFrame(dirtyRects: [DirtyRect(x: 0, y: 0, width: 640, height: 384)])
        h.run(untilUS: h.now + 100_000)
        #expect(h.host.activeVideoCodec == Self.hevc && h.viewer.activeVideoCodec == Self.hevc, "setup")
        Self.roomy(h)
        var ticks = 0
        while h.host.stats.videoRegionsDissolved == 0 && ticks < 6 * 60 {
            h.frame.fillRect(x: 0, y: 0, w: 384, h: 384, &rng)
            h.encodeFrame(dirtyRects: moving)
            h.run(untilUS: h.now + 16_667)
            ticks += 1
        }
        #expect(h.host.stats.videoCodecUpgrades == 1, "setup: the region moved to AV1")
        #expect(h.host.stats.videoRegionsDissolved == 1, "and its stream never started")
        #expect(h.viewer.stats.videoStarts == 1, "the Viewer never got AV1's START")
        for _ in 0..<(3 * 60) {  // still: nothing dirty
            h.encodeFrame(dirtyRects: [])
            h.run(untilUS: h.now + 16_667)
        }
        #expect(h.viewer.stats.videoStops == 1, "HEVC's stream was stopped")
        #expect(h.viewer.activeVideoCodec == nil, "no region left on the Viewer")
        #expect(h.viewer.overlayVisibleTileCount == 0, "no tile left on the old overlay")
        #expect(h.canvasMatchesFrame())
    }

    /// An encoder that won't start for the region leaves it as it was, and isn't tried again
    /// for it.
    @Test func anUpgradeWhoseEncoderWontStartLeavesTheRegion() {
        final class Refusing: VideoRegionEncoder {
            var starts = 0
            let codecID = MockVideoEncoder.mockAltCodecID
            func start(width: Int, height: Int, onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
                starts += 1
                return false
            }
            func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {}
            func stop() {}
        }
        var rng = SplitMix64(seed: 1121)
        let refusing = Refusing()
        let h = Harness(width: 640, height: 384, video: true, hostCodecs: [Self.av1, Self.hevc],
                        viewerCodecs: [Self.av1, Self.hevc],
                        encoderFactory: { $0 == Self.av1 ? refusing as any VideoRegionEncoder : MockVideoEncoder(codecID: $0) })
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        #expect(h.host.activeVideoCodec == Self.hevc)
        let formStarts = refusing.starts
        Self.roomy(h)
        Self.motion(h, frames: 180, &rng)
        #expect(h.host.activeVideoCodec == Self.hevc && h.host.stats.videoCodecUpgrades == 0)
        #expect(refusing.starts == formStarts + 1, "tried once for the region")
        #expect(h.viewer.stats.videoDecodeFailures == 0)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }
}
