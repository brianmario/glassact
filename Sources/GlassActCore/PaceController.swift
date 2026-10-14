import GlassActTransport

/// Adaptive datagram pace (host side). The transport's pacer spreads each
/// batch onto the wire at `rate`; this picks the rate from how large batches
/// actually fared, read off the viewer's ACK bitmaps.
///
/// Why loss, not delay: the failure being avoided is a receive buffer (the
/// viewer's UDP socket, or a bottleneck queue) overflowing during a burst.
/// That shows up as a *massive* loss fraction in exactly the batches that
/// were paced (50–80 % measured), while path noise is a few percent. Delay
/// is already the governor's signal for the average rate.
///
/// - More than `decreaseLossFraction` lost: the receiver drained roughly
///   `rate × (1 − lost)` of what was sent, so move toward that (with
///   headroom), at most halving per event — one catastrophic batch (a Wi-Fi
///   stall) must not crater the rate.
/// - At most `cleanLossFraction` lost, on a batch of at least
///   `probeMinBytes`: probe upward by 1/16. A smaller clean batch proves
///   nothing — it fits the receive buffer at any pace (measured: clean
///   ~300 KB batches walked the pace to the ceiling in one round, and the
///   next full-screen burst paid for it).
/// - In between: hold. Random loss in this band says nothing about pacing.
///
/// Only batches that were actually paced count (larger than the pacer's
/// instant burst, enough datagrams for a fraction to mean something), and
/// only batches sent at the *current* rate: batches already in flight when
/// the rate changed describe the old rate and would otherwise apply the
/// same correction twice.
public struct PaceController: Sendable {
    public static let initialRate = DatagramPacing.bytesPerSecond
    /// Above the governor's boosted average (8.4 MB/s): the pace shapes
    /// bursts and must never become the sustained bottleneck itself.
    public static let minRate = 10_000_000
    /// ~Gigabit wire speed; beyond it the link, not the pacer, is the limit.
    public static let maxRate = 120_000_000
    public static let minDatagrams = 64
    public static let decreaseLossFraction = 0.10
    public static let cleanLossFraction = 0.02
    /// ~2.6× macOS's default UDP receive buffer (786,896 B).
    public static let probeMinBytes = 2 << 20

    public private(set) var rate = PaceController.initialRate
    public private(set) var decreases = 0
    public private(set) var increases = 0

    public init() {}

    /// A batch resolved (fully ACKed, or timed out with `lost` datagrams
    /// unconfirmed). Returns true if the rate changed.
    @discardableResult
    public mutating func observe(sentAtRate: Int, datagrams: Int, bytes: Int, lost: Int) -> Bool {
        guard sentAtRate == rate, datagrams >= Self.minDatagrams,
              bytes > DatagramPacing.burstBytes else { return false }
        let lossFraction = Double(min(max(lost, 0), datagrams)) / Double(datagrams)
        let old = rate
        if lossFraction > Self.decreaseLossFraction {
            let factor = max(0.5, (1 - lossFraction) * 0.9)
            rate = max(Self.minRate, Int(Double(rate) * factor))
            if rate != old { decreases += 1 }
        } else if lossFraction <= Self.cleanLossFraction && bytes >= Self.probeMinBytes {
            rate = min(Self.maxRate, rate + rate / 16)
            if rate != old { increases += 1 }
        }
        return rate != old
    }
}
