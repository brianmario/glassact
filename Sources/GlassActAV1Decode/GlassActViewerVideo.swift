public import GlassActCore

public extension ViewerVideoDecoders {
    /// A Viewer's decoders with Glass Act's own AV1 decoder (§4.6): HEVC from VideoToolbox, and
    /// AV1 when the user opted in (`av1`), from VideoToolbox where this Mac or iPad decodes AV1 in
    /// hardware (any Host's), else from `OwnAV1RegionDecoder` (the hybrid's streams: an up-to-date
    /// Host's). The Mac and iPad Viewers' choice.
    static func glassAct(av1: Bool) -> ViewerVideoDecoders {
        glassAct(av1: av1, hardwareAV1: VTRegionDecoder.canDecodeAV1)
    }

    /// With the hardware's answer given (tests).
    static func glassAct(av1: Bool, hardwareAV1: Bool) -> ViewerVideoDecoders {
        offer(av1: av1, hardwareAV1: hardwareAV1, hardware: { VTRegionDecoder() }, glassActAV1: { OwnAV1RegionDecoder() })
    }
}
