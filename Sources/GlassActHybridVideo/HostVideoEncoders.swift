public import Foundation
public import GlassActCore
import GlassActWire

/// The Host's video encoders (§4.6): hardware HEVC, and AV1 from Glass Act's own encoder
/// (`HybridRegionEncoder`, the hybrid) where it runs. AV1 comes first, so a Viewer that asks for
/// it gets it.
///
/// libaom's encoder (`AOMRegionEncoder`) stays in the package, unused: `AV1.libaom` switches back
/// to it (one constant in the Host, `HostController.av1Encoder`). Each AV1 goes to the Viewers
/// that decode it (§3.8): Glass Act's to a Viewer offering `videoAV1` (VideoToolbox's AV1) or
/// `videoAV1GlassAct` (Glass Act's decoder too); libaom's only to `videoAV1`, since Glass Act's
/// decoder takes only the hybrid's toolset. Where the chosen AV1 can't run, the Host offers HEVC
/// alone: the other AV1 is no fallback.
public struct HostVideoEncoders {
    /// Which AV1 encoder the Host runs.
    public enum AV1: Sendable, Equatable {
        /// Glass Act's: macOS 27 and an Apple-silicon GPU (`HybridRegionEncoder.isAvailable`).
        case glassAct
        /// libaom's (vendored, arm64 only), as releases before Glass Act's encoder.
        case libaom
        /// None: HEVC only.
        case none
    }

    /// The AV1 this Host runs: the choice, where it can run.
    public let av1: AV1
    /// The engine's codec preference (`HostEngine.videoCodecPreference`).
    public let preference: [UInt8]
    /// The engine's `videoAV1FromGlassAct`.
    public var av1FromGlassAct: Bool { av1 == .glassAct }
    private let callbackQueue: DispatchQueue

    /// `callbackQueue` is the engine's (the VideoRegionEncoder threading contract).
    public init(choice: AV1, callbackQueue: DispatchQueue) {
        self.init(choice: choice, callbackQueue: callbackQueue,
                  glassActAvailable: Self.glassActAvailable, libaomAvailable: AOMRegionEncoder.isAvailable)
    }

    /// With availability given (tests).
    public init(choice: AV1, callbackQueue: DispatchQueue, glassActAvailable: Bool, libaomAvailable: Bool) {
        av1 = Self.resolve(choice: choice, glassActAvailable: glassActAvailable, libaomAvailable: libaomAvailable)
        preference = av1 == .none ? [VideoCodec.hevc] : [VideoCodec.av1, VideoCodec.hevc]
        self.callbackQueue = callbackQueue
    }

    /// The AV1 that runs: the one chosen if it can, else none.
    public static func resolve(choice: AV1, glassActAvailable: Bool, libaomAvailable: Bool) -> AV1 {
        switch choice {
        case .glassAct: glassActAvailable ? .glassAct : .none
        case .libaom: libaomAvailable ? .libaom : .none
        case .none: .none
        }
    }

    /// Glass Act's encoder runs here: macOS 27, an Apple-silicon GPU.
    public static var glassActAvailable: Bool {
        if #available(macOS 27, iOS 27, *) { return HybridRegionEncoder.isAvailable }
        return false
    }

    /// Starts compiling Glass Act's encoder's kernels, at launch, when it's the choice and it
    /// runs here: until they have, its regions start on HEVC instead of waiting for them. `done`
    /// (on another queue) hears whether they compiled; without them, video is HEVC only.
    public static func prepare(_ choice: AV1, done: (@Sendable (_ ready: Bool) -> Void)? = nil) {
        guard choice == .glassAct, glassActAvailable else { return }
        if #available(macOS 27, iOS 27, *) { HybridRegionEncoder.prepare(done: done) }
    }

    /// A region's encoder for a negotiated codec (the engine's `videoEncoderFactory`). Nil for a
    /// codec it doesn't run, and for Glass Act's AV1 until its kernels have compiled
    /// (`prepare`): the region then starts on the next codec, HEVC.
    public func encoder(forCodec codec: UInt8) -> (any VideoRegionEncoder)? {
        switch (codec, av1) {
        case (VideoCodec.hevc, _):
            return VTHEVCRegionEncoder(callbackQueue: callbackQueue)
        case (VideoCodec.av1, .glassAct):
            guard #available(macOS 27, iOS 27, *), HybridRegionEncoder.isReady else { return nil }
            return HybridRegionEncoder(callbackQueue: callbackQueue)
        case (VideoCodec.av1, .libaom):
            return AOMRegionEncoder(callbackQueue: callbackQueue)
        default:
            return nil
        }
    }

    /// For status lines: "HEVC", "AV1 (Glass Act) + HEVC", "AV1 (libaom) + HEVC".
    public var summary: String {
        switch av1 {
        case .glassAct: "AV1 (Glass Act) + HEVC"
        case .libaom: "AV1 (libaom) + HEVC"
        case .none: "HEVC"
        }
    }
}
