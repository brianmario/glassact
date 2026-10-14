public import Foundation

/// Connection lifecycle as reported by a transport.
public enum TransportState: Equatable, Sendable {
    case connecting
    case ready
    case failed
    case cancelled
}

/// §6 — transport abstraction. Control is reliable and ordered (handshake, ACKs,
/// PING/PONG); datagrams are unreliable and carry pixels (INV-5). Conformers:
/// InProcTransport with seeded fault injection (tests, bench) and
/// QUICTransport.
///
/// The *video channel* (§3.7): reliable and ordered like control, but a
/// separate stream so multi-megabyte video frames never head-of-line block
/// ACKs. Host → viewer only. `videoBacklogBytes` reports bytes handed to the
/// transport but not yet accepted by the network — the host engine's
/// newest-wins pacing gate (a growing backlog means the link can't keep up,
/// and the correct response is to skip encoding new video frames, not queue).
public protocol GlassActTransport: AnyObject {
    var maxDatagramSize: Int { get }
    func sendControl(_ data: Data)
    func sendDatagram(_ data: Data)
    func sendVideo(_ data: Data)
    var videoBacklogBytes: Int { get }
    var onControl: (Data) -> Void { get set }
    var onDatagram: (Data) -> Void { get set }
    var onVideo: (Data) -> Void { get set }
    var onState: (TransportState) -> Void { get set }
    /// A batch's datagrams in order — one handoff instead of one per datagram.
    func sendDatagrams(_ batch: [Data])
    /// Datagram bytes handed over but still waiting in the transport's pacer
    /// — a batch sent now leaves only after these. Readable from any queue.
    var queuedDatagramBytes: Int { get }
    /// True if the transport paces datagrams itself; the host engine then
    /// adapts the rate (`setDatagramPaceRate`) and times batches out against it.
    var pacesDatagrams: Bool { get }
    /// Sets the pace for datagrams sent from now on. Callable from any queue.
    func setDatagramPaceRate(bytesPerSecond: Int)
    /// The transport's own RTT view of the path (QUIC's per-ACK smoothed
    /// RTT and the connection's minimum), or nil if it has none. Smoothed −
    /// minimum is the standing queue in the network — the signal PING (1/s,
    /// EWMA over 8 samples) sees ~8 s late. Readable from any queue.
    var transportRTT: (smoothedUS: UInt64, minUS: UInt64)? { get }
}

public extension GlassActTransport {
    func sendDatagrams(_ batch: [Data]) {
        for data in batch { sendDatagram(data) }
    }

    var queuedDatagramBytes: Int { 0 }
    var pacesDatagrams: Bool { false }
    func setDatagramPaceRate(bytesPerSecond: Int) {}
    var transportRTT: (smoothedUS: UInt64, minUS: UInt64)? { nil }
}

/// Sender-side datagram pacing (QUICTransport; the host engine adapts the
/// rate from loss, see `PaceController`). An unpaced batch leaves the
/// host in microseconds and overflows the viewer's UDP receive buffer
/// (~768 KB on macOS): measured on loopback, 83 % of a 4000-datagram burst
/// never arrived. Paced at this rate, 12k datagrams arrive whole. The host's
/// batch timeout grants serialization time at this same rate, so a paced
/// batch is never timed out while it is still leaving.
public enum DatagramPacing {
    /// The starting pace, and the serialization rate assumed for transports
    /// that don't pace. Below the ~50k datagrams/s a viewer drains on
    /// loopback (~57 MB/s at 1150 B; 256 per 2 ms already lost up to 67 %).
    public static let bytesPerSecond = 50_000_000
    /// Sent immediately from a full bucket: interactive batches (typing, a
    /// cursor blink) never wait on the pacer. Well under the receive buffer.
    public static let burstBytes = 256 * 1024
}
