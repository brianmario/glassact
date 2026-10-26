/// §4.9 resolution rung: when a link is too thin for the capture's pixel
/// count, the host suggests halving the capture for the rest of the session
/// (`HostEngine.onScalePressureConstrained`). Evaluated once a second, on
/// the PING cadence. Two kinds of evidence, each from fresh readings only:
///
/// - Tile ACK delay above the governor's severe mark for `severeSeconds` in
///   a row, counting only seconds with a new ACK-delay sample (an idle or
///   video-only session would otherwise keep counting a stale value).
/// - Video drain under `thinVideoBitsPerPixel` per captured pixel, and
///   under `thinVideoMaxBitsPerSecond`, for `thinVideoSeconds` in a row,
///   counting only seconds with a fresh link measurement: a window in which
///   video stayed backlogged, so the link set the pace
///   (`VideoRateController.linkMeasurements`). Both the smoothed estimate
///   and that window's drain must be under the bar. Seconds without a new
///   measurement (no video, a quiet or paused region, a link that never
///   backs up) hold the streak. Pinned video carries the motion, so on a
///   thin link the tile path can go quiet for long stretches: on plane
///   Wi-Fi the ACK-delay rule alone took 45 s to fire while video drained
///   at 0.3–2.3 Mbit/s for a 2900×1572 capture.
/// - The link's capacity as the viewer reports it (`LinkEstimate`: what
///   arrived while the path was queued, the last ~10 s) under the same bars
///   for `thinVideoSeconds` in a row, counting only seconds with a reading.
///   The video rule's evidence needs a window that stayed backlogged, and a
///   send gate that skips frames keeps video from backing up: in an airport
///   lounge at ~0.3 Mbit/s it never fired, while the viewer's reports said
///   0.3 Mbit/s for a minute.
///
/// Plain value type; latches once fired.
struct ScalePressure {
    static let severeSeconds = 6
    static let thinVideoSeconds = 5
    /// 0.75 bit/s per pixel is a 3.4 Mbit/s drain for a 2900×1572 capture
    /// and 11 Mbit/s for 5K. FaceTime's top screen-share tier (4.9 Mbit/s
    /// for 2736×2048) is 0.87.
    static let thinVideoBitsPerPixel = 0.75
    /// Only a genuinely thin link (plane, hotel, tether): a 5K capture on
    /// 10 Mbit/s home Wi-Fi is under 0.75 bit/s per pixel too, but halving
    /// it costs native-sharp text for the session, and that trade is the
    /// person's to make.
    static let thinVideoMaxBitsPerSecond = 4_000_000

    private(set) var constrained = false
    private var severeStreakS = 0
    private var thinVideoStreakS = 0
    private var thinLinkStreakS = 0
    private var prevAckSampleUS: UInt64 = 0
    private var prevVideoMeasurements = 0

    /// One second's evidence; true the one time it decides the link is
    /// constrained. `ackSampleUS` changes whenever a new ACK delay was
    /// measured, and `videoLinkMeasurements` whenever a backlogged video
    /// window measured the link. `linkCapacityBytesPerSecond`: the viewer's
    /// reading (0: none).
    mutating func noteSecond(ackSampleUS: UInt64, ackDelayUS: UInt64, severeAckDelayUS: UInt64,
                             videoLinkMeasurements: Int, videoRateBytesPerSecond: Int,
                             videoLastDrainBytesPerSecond: Int, linkCapacityBytesPerSecond: Int = 0,
                             pixels: Int) -> Bool {
        guard !constrained else { return false }
        if ackSampleUS != prevAckSampleUS {
            prevAckSampleUS = ackSampleUS
            severeStreakS = ackDelayUS > severeAckDelayUS ? severeStreakS + 1 : 0
        }
        if videoLinkMeasurements != prevVideoMeasurements {
            prevVideoMeasurements = videoLinkMeasurements
            let bits = max(videoRateBytesPerSecond, videoLastDrainBytesPerSecond) * 8
            thinVideoStreakS = Self.isThin(bitsPerSecond: bits, pixels: pixels) ? thinVideoStreakS + 1 : 0
        }
        if linkCapacityBytesPerSecond > 0 {
            let thin = Self.isThin(bitsPerSecond: linkCapacityBytesPerSecond * 8, pixels: pixels)
            thinLinkStreakS = thin ? thinLinkStreakS + 1 : 0
        }
        if severeStreakS >= Self.severeSeconds || thinVideoStreakS >= Self.thinVideoSeconds
            || thinLinkStreakS >= Self.thinVideoSeconds {
            constrained = true
            return true
        }
        return false
    }

    private static func isThin(bitsPerSecond bits: Int, pixels: Int) -> Bool {
        bits < thinVideoMaxBitsPerSecond && Double(bits) < Double(pixels) * thinVideoBitsPerPixel
    }
}
