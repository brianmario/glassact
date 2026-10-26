import Testing
import GlassActWire
import GlassActTransport
@testable import GlassActCore
import GlassActTestSupport

/// AV1 only while the link has room (§4.6): the policy, judged on what the
/// Viewer received, and the engine moving a live region to the other codec
/// in place.
@Suite struct LinkRoomPolicyTests {
    static let thin = LinkRoomPolicy.thinBitsPerSecond / 8 - 1
    static let roomy = LinkRoomPolicy.roomyBitsPerSecond / 8

    @Test func startsOffAndTurnsOnOnceTheLinkDeliversRoom() {
        var p = LinkRoomPolicy()
        #expect(!p.hasRoom)
        let short = p.noteSecond(deliveredBytesPerSecond: Self.roomy - 1, recentCapacityBytesPerSecond: 0, reports: 4)
        let room = p.noteSecond(deliveredBytesPerSecond: Self.roomy, recentCapacityBytesPerSecond: 0, reports: 8)
        #expect(!short)
        #expect(room)
        #expect(p.hasRoom)
    }

    @Test func offAfterThreeThinSecondsInARow() {
        var p = LinkRoomPolicy()
        _ = p.noteSecond(deliveredBytesPerSecond: Self.roomy, recentCapacityBytesPerSecond: 0, reports: 4)
        let changed = (0..<3).map { _ in
            p.noteSecond(deliveredBytesPerSecond: Self.thin, recentCapacityBytesPerSecond: Self.thin, reports: 8)
        }
        #expect(changed == [false, false, true])
        #expect(!p.hasRoom)
    }

    /// A quiet screen delivers little and queues nothing: that says nothing
    /// about the link, so AV1 stays. A second that delivered room breaks a
    /// thin streak.
    @Test func aQuietScreenOrARoomySecondIsntThin() {
        var p = LinkRoomPolicy()
        _ = p.noteSecond(deliveredBytesPerSecond: Self.roomy, recentCapacityBytesPerSecond: 0, reports: 4)
        for _ in 0..<20 { _ = p.noteSecond(deliveredBytesPerSecond: 1_000, recentCapacityBytesPerSecond: 0, reports: 8) }
        #expect(p.hasRoom)
        for _ in 0..<2 { _ = p.noteSecond(deliveredBytesPerSecond: Self.thin, recentCapacityBytesPerSecond: Self.thin, reports: 8) }
        _ = p.noteSecond(deliveredBytesPerSecond: Self.roomy, recentCapacityBytesPerSecond: Self.thin, reports: 8)
        for _ in 0..<2 { _ = p.noteSecond(deliveredBytesPerSecond: Self.thin, recentCapacityBytesPerSecond: Self.thin, reports: 8) }
        #expect(p.hasRoom)
    }

    /// A Viewer from before RECEIVED reports gets AV1 as it did before the
    /// policy, after a few seconds.
    @Test func aViewerWithoutReportsGetsItAfterAFewSeconds() {
        var p = LinkRoomPolicy()
        let changed = (0..<LinkRoomPolicy.unreportedSeconds).map { _ in
            p.noteSecond(deliveredBytesPerSecond: 0, recentCapacityBytesPerSecond: 0, reports: 0)
        }
        #expect(changed == Array(repeating: false, count: LinkRoomPolicy.unreportedSeconds - 1) + [true])
        #expect(p.hasRoom)
    }

    @Test func governsAV1AndItsStandIn() {
        #expect(LinkRoomPolicy.governs(VideoCodec.av1))
        #expect(LinkRoomPolicy.governs(MockVideoEncoder.mockAltCodecID))
        #expect(!LinkRoomPolicy.governs(VideoCodec.hevc))
        #expect(!LinkRoomPolicy.governs(MockVideoEncoder.mockCodecID))
    }

    /// A session asking for the AV1 stand-in starts on the other codec. Once
    /// the link has delivered room, the next region forms on AV1; once a
    /// bottleneck makes it thin, the region after that is back on the other
    /// codec. A live region keeps its codec (no mid-motion switch), and the
    /// canvas still settles byte-identical.
    @Test(.tags(.slow), .notInFastLane) func theNextRegionFollowsTheLink() {
        var rng = SplitMix64(seed: 909)
        let both = [MockVideoEncoder.mockAltCodecID, MockVideoEncoder.mockCodecID]
        let h = Harness(width: 640, height: 384, video: true, hostCodecs: both, viewerCodecs: both)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        // Motion in the left 384×384 (36 tiles, enough to keep a region
        // alive) and the rest still, so it hands back to exact.
        func move(seconds: Double) {
            for _ in 0..<Int(seconds * 60) {
                h.frame.fillRect(x: 0, y: 0, w: 384, h: 384, &rng)
                h.encodeFrame()
                h.run(untilUS: h.now + 16_667)
            }
        }
        func rest(seconds: Double) {
            for _ in 0..<Int(seconds * 60) {
                h.encodeFrame()
                h.run(untilUS: h.now + 16_667)
            }
        }
        move(seconds: 3)
        #expect(h.host.activeVideoCodec == MockVideoEncoder.mockCodecID, "starts off AV1, and a live region keeps its codec")
        #expect(h.host.linkRoom.hasRoom, "the link has delivered room")
        rest(seconds: 4)
        #expect(h.host.activeVideoRegionCount == 0)
        move(seconds: 1)
        #expect(h.host.activeVideoCodec == MockVideoEncoder.mockAltCodecID)
        #expect(h.viewer.activeVideoCodec == MockVideoEncoder.mockAltCodecID)

        h.link.bottleneck = InProcLink.Bottleneck(bytesPerSecond: 250_000, bufferBytes: 250_000)
        move(seconds: 20)
        #expect(!h.host.linkRoom.hasRoom, "a thin link")
        #expect(h.host.activeVideoCodec == MockVideoEncoder.mockAltCodecID, "still the live region's codec")
        rest(seconds: 6)
        let withoutBefore = h.host.stats.videoRegionsWithoutAV1
        move(seconds: 1)
        #expect(h.host.activeVideoCodec == MockVideoEncoder.mockCodecID)
        #expect(h.viewer.activeVideoCodec == MockVideoEncoder.mockCodecID)
        #expect(h.host.stats.videoRegionsWithoutAV1 == withoutBefore + 1)
        h.link.bottleneck = nil
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }
}
