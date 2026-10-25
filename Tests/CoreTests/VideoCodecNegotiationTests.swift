import Foundation
import Testing
import GlassActWire
@testable import GlassActCore
import GlassActTestSupport

/// Video codec negotiation (§4.6). The encoder factory is codec-keyed so a second
/// codec (hardware AV1, once it exists) can slot in beside HEVC: the host's
/// preference order is intersected with the viewer's caps, and a region
/// starts on the first negotiated codec whose encoder starts. The rig's
/// alternate mock codec (0x7E) stands in for the second codec.
@Suite struct VideoCodecNegotiationTests {
    /// An encoder that refuses to start (no hardware session, say).
    final class RefusingEncoder: VideoRegionEncoder {
        let codecID: UInt8
        init(codecID: UInt8) { self.codecID = codecID }
        func start(width: Int, height: Int,
                   onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool { false }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {}
        func stop() {}
    }

    private static let both = [MockVideoEncoder.mockAltCodecID, MockVideoEncoder.mockCodecID]

    /// The pinned cold start forms the region on the first frame, so the
    /// codec that carries it is decided right there.
    private func coldStart(hostCodecs: [UInt8], viewerCodecs: [UInt8],
                           encoderFactory: ((UInt8) -> any VideoRegionEncoder?)? = nil) -> Harness {
        var rng = SplitMix64(seed: 701)
        let h = Harness(width: 320, height: 320, video: true,
                        hostCodecs: hostCodecs, viewerCodecs: viewerCodecs,
                        encoderFactory: encoderFactory)
        // The alt codec stands in for AV1, which needs a link that has shown
        // room (AV1LinkPolicy); this one already has.
        _ = h.host.av1Link.noteSecond(deliveredBytesPerSecond: AV1LinkPolicy.roomyBitsPerSecond / 8,
                                      recentCapacityBytesPerSecond: 0, reports: 1)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 200_000)
        return h
    }

    @Test func hostPreferenceWinsWhenBothSidesSupportIt() {
        let h = coldStart(hostCodecs: Self.both, viewerCodecs: Self.both)
        #expect(h.host.activeVideoRegionCount == 1)
        #expect(h.host.activeVideoCodec == MockVideoEncoder.mockAltCodecID)
        #expect(h.viewer.activeVideoCodec == MockVideoEncoder.mockAltCodecID,
                "VIDEO_START carries the codec id")
        #expect(h.viewer.stats.videoStarts == 1)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }

    /// The host prefers the alt codec, but a viewer that only advertises the
    /// primary bit gets the primary codec.
    @Test func negotiationRespectsViewerCaps() {
        let h = coldStart(hostCodecs: Self.both, viewerCodecs: [MockVideoEncoder.mockCodecID])
        #expect(h.host.activeVideoRegionCount == 1)
        #expect(h.host.activeVideoCodec == MockVideoEncoder.mockCodecID,
                "viewer caps must exclude the un-advertised codec")
        #expect(h.viewer.stats.videoStarts == 1)
    }

    /// A negotiated codec whose encoder won't start yields to the next one.
    @Test func firstNegotiatedCodecThatStartsCarriesTheRegion() {
        let h = coldStart(hostCodecs: Self.both, viewerCodecs: Self.both,
                          encoderFactory: { codec -> any VideoRegionEncoder? in
                              codec == MockVideoEncoder.mockAltCodecID
                                  ? RefusingEncoder(codecID: codec) : MockVideoEncoder(codecID: codec)
                          })
        #expect(h.host.activeVideoRegionCount == 1)
        #expect(h.host.activeVideoCodec == MockVideoEncoder.mockCodecID)
        #expect(h.viewer.activeVideoCodec == MockVideoEncoder.mockCodecID)
    }

    /// No encoder factory (`GLASSACT_TILE_ONLY`, headless agents): HELLO
    /// offers no video caps at all.
    @Test func hostWithoutEncoderFactoryOffersNoVideo() {
        let capture = CaptureTransport()
        let host = HostEngine(width: 320, height: 320, transport: capture)
        host.start(nowUS: 0)
        let hello = controlMessages(capture.sentControl).compactMap { message -> UInt32? in
            if case let .hello(_, _, _, _, _, caps) = message { return caps }
            return nil
        }
        #expect(hello.count == 1)
        #expect(hello.first.map { $0 & (WireCaps.videoHEVC | WireCaps.videoAV1) } == 0)
    }

    /// No codec in common: no video caps match, the session is tiles only.
    @Test func noCommonCodecMeansTilesOnly() {
        let h = coldStart(hostCodecs: [MockVideoEncoder.mockAltCodecID],
                          viewerCodecs: [MockVideoEncoder.mockCodecID])
        #expect(h.host.stats.videoRegionsFormed == 0)
        #expect(h.viewer.stats.videoStarts == 0)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
    }
}
