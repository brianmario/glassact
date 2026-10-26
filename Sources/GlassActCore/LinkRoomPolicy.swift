import GlassActWire

/// Whether the link has room (§4.6), judged on what the Viewer reports it
/// received (`LinkEstimate`, §4.9). Two choices follow it:
/// - **AV1** (the Viewer's opt-in) only while there's room. Software AV1 beats
///   hardware HEVC with room to spare and loses on a thin link: its quality
///   floor keeps frames large, so the send gate admits fewer of them
///   (cursor-drag on 3 Mbit/s: 120 frames against HEVC's 278; BENCHMARKS
///   "AV1 back, as a Viewer opt-in"). Applied when the next region forms
///   (`allowedVideoCodecs`), not to a live one.
/// - **Prefer smooth motion** (QUALITY preference 2): the looser frame-QP
///   ceiling while there isn't (`updateSmoothFloor`).
///
/// - **Room** once the link has delivered `roomyBitsPerSecond` over any span
///   in the last 10 s. A delivered rate is a lower bound on the link, so a
///   thin link can't fake it; a fast one proves it in the cold start's
///   first burst.
/// - **No room** after `thinSeconds` in a row in which the link, while
///   queued, carried under `thinBitsPerSecond` (the last 10 s of queued spans)
///   and delivered no more than that elsewhere. A queued span reads the
///   link's own rate, so this is a thin link and not a quiet screen.
///
/// A session starts without room. Starting on AV1 and falling back was worse
/// than either codec alone on a thin link: the first 5K AV1 key frame can't
/// shrink below the quality floor, fills a second of a 2 Mbit/s link's
/// buffer, and the video estimate is cut to its floor for 20 s (cursor-drag
/// 15 frames; HEVC alone 289). A Viewer that sends no reports (a release
/// before them) gets room after `unreportedSeconds`, as before the policy.
///
/// Plain value type, judged once a second.
struct LinkRoomPolicy {
    static let thinBitsPerSecond = 4_000_000
    static let roomyBitsPerSecond = 6_000_000
    static let thinSeconds = 3
    static let unreportedSeconds = 3

    private(set) var hasRoom = false
    private var thinStreak = 0
    private var seconds = 0

    /// One second's reading (bytes/s, `LinkEstimate`); `reports`, how many
    /// RECEIVED reports the session has had. True when `hasRoom` changed.
    mutating func noteSecond(deliveredBytesPerSecond delivered: Int, recentCapacityBytesPerSecond capacity: Int,
                             reports: Int) -> Bool {
        seconds += 1
        guard reports > 0 else {
            guard !hasRoom, seconds >= Self.unreportedSeconds else { return false }
            hasRoom = true
            return true
        }
        let roomy = delivered * 8 >= Self.roomyBitsPerSecond
        let thin = !roomy && capacity > 0 && capacity * 8 < Self.thinBitsPerSecond
        thinStreak = thin ? thinStreak + 1 : 0
        if hasRoom && thinStreak >= Self.thinSeconds {
            hasRoom = false
            return true
        }
        if !hasRoom && roomy {
            hasRoom = true
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
