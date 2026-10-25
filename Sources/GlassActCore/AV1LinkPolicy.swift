import GlassActWire

/// Whether the link has room for AV1 (§4.6). Software AV1 beats hardware
/// HEVC with room to spare and loses on a thin link: its quality floor keeps
/// frames large, so the send gate admits fewer of them (cursor-drag on
/// 3 Mbit/s: 120 frames against HEVC's 278; on 5 Mbit/s AV1 leads, 430
/// against 383; BENCHMARKS "AV1 back, as a Viewer opt-in"). So a Viewer that
/// asked for AV1 gets it only while the link has room, judged by what the
/// Viewer reports it received (`LinkEstimate`, §4.9):
///
/// - **On** once the link has delivered `roomyBitsPerSecond` over any span
///   in the last 10 s. A delivered rate is a lower bound on the link, so a
///   thin link can't fake it; a fast one proves it in the cold start's
///   first burst.
/// - **Off** after `thinSeconds` in a row in which the link, while queued,
///   carried under `thinBitsPerSecond` (the last 10 s of queued spans) and
///   delivered no more than that elsewhere. A queued span reads the link's
///   own rate, so this is a thin link and not a quiet screen.
///
/// A session starts on HEVC. Starting on AV1 and falling back was worse than
/// either codec alone on a thin link: the first 5K AV1 key frame can't
/// shrink below the quality floor, fills a second of a 2 Mbit/s link's
/// buffer, and the video estimate is cut to its floor for 20 s (cursor-drag
/// 15 frames; HEVC alone 289). A Viewer that sends no reports (a release
/// before them) gets AV1 after `unreportedSeconds`, as before the policy.
///
/// Plain value type, judged once a second; the engine applies a change when
/// the next region forms (`allowedVideoCodecs`), not to a live one.
struct AV1LinkPolicy {
    static let thinBitsPerSecond = 4_000_000
    static let roomyBitsPerSecond = 6_000_000
    static let thinSeconds = 3
    static let unreportedSeconds = 3

    private(set) var allowed = false
    private var thinStreak = 0
    private var seconds = 0

    /// One second's reading (bytes/s, `LinkEstimate`); `reports`, how many
    /// RECEIVED reports the session has had. True when `allowed` changed.
    mutating func noteSecond(deliveredBytesPerSecond delivered: Int, recentCapacityBytesPerSecond capacity: Int,
                             reports: Int) -> Bool {
        seconds += 1
        guard reports > 0 else {
            guard !allowed, seconds >= Self.unreportedSeconds else { return false }
            allowed = true
            return true
        }
        let roomy = delivered * 8 >= Self.roomyBitsPerSecond
        let thin = !roomy && capacity > 0 && capacity * 8 < Self.thinBitsPerSecond
        thinStreak = thin ? thinStreak + 1 : 0
        if allowed && thinStreak >= Self.thinSeconds {
            allowed = false
            return true
        }
        if !allowed && roomy {
            allowed = true
            return true
        }
        return false
    }

    /// Whether `codec` is one the policy governs (AV1, and the rig's mock
    /// that stands in for it).
    static func governs(_ codec: UInt8) -> Bool {
        WireCaps.bit(forVideoCodec: codec) == WireCaps.videoAV1
    }
}
