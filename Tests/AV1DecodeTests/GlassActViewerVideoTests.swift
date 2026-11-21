import Testing
import GlassActAV1Decode
import GlassActCore
import GlassActWire

/// The apps' decoders (`ViewerVideoDecoders.glassAct`): VideoToolbox for HEVC, and for AV1
/// wherever it decodes AV1 in hardware; Glass Act's own decoder for AV1 where it doesn't; the
/// caps to match, reduced frames with either AV1 decoder (AV1PairingTests runs every pairing).
@Suite struct GlassActViewerVideoTests {
    @Test func withAV1HardwareVideoToolboxDecodesEverything() {
        let d = ViewerVideoDecoders.glassAct(av1: true, hardwareAV1: true)
        #expect(d.caps == WireCaps.videoHEVC | WireCaps.videoAV1 | WireCaps.videoAV1GlassAct | WireCaps.videoReducedFrames)
        #expect(d.decoder(forCodec: VideoCodec.av1) is VTRegionDecoder)
        #expect(d.decoder(forCodec: VideoCodec.hevc) is VTRegionDecoder)
    }

    /// Reduced frames too, where Glass Act's decoder shows them for less than a full-size frame.
    @Test func withoutItGlassActsDecoderTakesAV1UnderItsOwnBit() {
        let d = ViewerVideoDecoders.glassAct(av1: true, hardwareAV1: false)
        let reduced = OwnAV1RegionDecoder.showsReducedFramesCheaply ? WireCaps.videoReducedFrames : 0
        #expect(d.caps == WireCaps.videoHEVC | WireCaps.videoAV1GlassAct | reduced)
        #expect(d.decoder(forCodec: VideoCodec.av1) is OwnAV1RegionDecoder)
        #expect(d.decoder(forCodec: VideoCodec.hevc) is VTRegionDecoder)
    }

    @Test(arguments: [true, false])
    func withAV1OffHEVCAlone(hardwareAV1: Bool) {
        let d = ViewerVideoDecoders.glassAct(av1: false, hardwareAV1: hardwareAV1)
        #expect(d.caps == WireCaps.videoHEVC)
        #expect(d.decoder(forCodec: VideoCodec.av1) == nil)
    }

    /// The default asks this Mac: VideoToolbox's answer decides.
    @Test func theDefaultAsksVideoToolbox() {
        let d = ViewerVideoDecoders.glassAct(av1: true)
        #expect((d.caps & WireCaps.videoAV1 != 0) == VTRegionDecoder.canDecodeAV1)
        #expect(d.caps & WireCaps.videoAV1GlassAct != 0)
        #expect((d.caps & WireCaps.videoReducedFrames != 0)
                == (VTRegionDecoder.canDecodeAV1 || OwnAV1RegionDecoder.showsReducedFramesCheaply))
    }
}
