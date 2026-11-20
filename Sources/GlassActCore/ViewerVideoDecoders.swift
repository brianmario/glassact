import GlassActWire

/// What a Viewer decodes video regions with, and the video caps it offers for them in HELLO_OK
/// (§3.8, §4.6): one decoder a region, made at its START for the codec the START names.
///
/// AV1 (codec 3) comes from two encoders. A Host on macOS 27 with an Apple-silicon GPU runs Glass
/// Act's (the hybrid); older releases ran libaom's. VideoToolbox decodes both, where the Mac or
/// iPad decodes AV1 in hardware (M3 and later); Glass Act's own decoder decodes only the hybrid's
/// toolset. So a Viewer offers `videoAV1` only with VideoToolbox's AV1, and `videoAV1GlassAct`
/// with either decoder, and takes VideoToolbox whenever it has it: a libaom stream can come only
/// to a Viewer that offered `videoAV1`.
///
/// The Rust decoder lives in GlassActAV1Decode, which GlassActCore doesn't link, so a Viewer that
/// has it passes it in (`ViewerVideoDecoders.glassAct(av1:)` there).
public struct ViewerVideoDecoders: Sendable {
    /// The video caps bits for HELLO_OK.
    public let caps: UInt32
    private let make: @Sendable (UInt8) -> (any VideoRegionDecoder)?

    public init(caps: UInt32, decoder: @escaping @Sendable (_ codec: UInt8) -> (any VideoRegionDecoder)?) {
        self.caps = caps
        make = decoder
    }

    /// A new decoder for a region of `codec`, nil for a codec this Viewer doesn't decode.
    public func decoder(forCodec codec: UInt8) -> (any VideoRegionDecoder)? { make(codec) }

    /// HEVC from `hardware` (VideoToolbox); AV1 too when the user opted in (`av1`): from
    /// `hardware` where it decodes AV1 (`hardwareAV1`), any encoder's, else from `glassActAV1`,
    /// Glass Act's encoder's only. With neither, HEVC alone.
    public static func offer(av1: Bool, hardwareAV1: Bool,
                             hardware: @escaping @Sendable () -> any VideoRegionDecoder,
                             glassActAV1: (@Sendable () -> any VideoRegionDecoder)?) -> ViewerVideoDecoders {
        let av1Decoder: (@Sendable () -> any VideoRegionDecoder)? = !av1 ? nil : hardwareAV1 ? hardware : glassActAV1
        var caps = WireCaps.videoHEVC
        if av1Decoder != nil { caps |= WireCaps.videoAV1GlassAct }
        // reduced frames with VideoToolbox's AV1 only: it scales them for free (8.8 ms a 5K frame
        // against 10.1 at full size), where Glass Act's decoder's Lanczos on the BGRA takes 22 ms
        // of its 29 (20 at full size: BENCHMARKS "reduced frames for soft video")
        if av1 && hardwareAV1 { caps |= WireCaps.videoAV1 | WireCaps.videoReducedFrames }
        return ViewerVideoDecoders(caps: caps) { codec in
            switch codec {
            case VideoCodec.hevc: hardware()
            case VideoCodec.av1: av1Decoder?()
            default: nil
            }
        }
    }

    /// VideoToolbox alone: HEVC, and AV1 when the user opted in and this Mac or iPad decodes it in
    /// hardware. What a Viewer without Glass Act's decoder offers.
    public static func videoToolbox(av1: Bool) -> ViewerVideoDecoders {
        offer(av1: av1, hardwareAV1: VTRegionDecoder.canDecodeAV1, hardware: { VTRegionDecoder() }, glassActAV1: nil)
    }
}
