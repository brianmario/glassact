import CryptoKit
public import Foundation
public import GlassActWire
import Network
public import Security
import Synchronization

// ## Deviations
//
// A session runs on **two QUIC tunnels** (§6), where one connection carrying
// streams and datagrams together would do:
//
//   - control: NWConnectionGroup on `port` — the host extracts the stream and
//     speaks first (HELLO), which surfaces at the viewer via
//     `newConnectionHandler` (verified: host-first delivery works only through
//     the group shape; on a plain client-dialed connection the server's first
//     send opens a server-initiated stream the client never sees).
//   - datagrams: a datagram-only QUIC connection (`isDatagram`) on
//     `port + 1`; host-first datagram delivery verified.
//
// Why two: this transport is built on the NWConnectionGroup /
// NWMultiplexGroup API, which doesn't model QUIC datagrams alongside
// streams — `group.extract(using: isDatagram options)` fails with ENETDOWN,
// and Apple DTS guidance is that only the newer `NetworkConnection` API
// models datagrams correctly
// (https://developer.apple.com/forums/thread/813467). That API needed
// macOS 26, newer than the deployment target when this transport was
// written. The floor is now macOS 27, so that reason is gone; the transport
// simply hasn't moved yet. Issue #10 tracks moving to one tunnel via
// `NetworkConnection`.
//
// The *video stream* is a second stream extracted from the control group
// (host → viewer, reliable, ordered, head-of-line isolated from control).
// Because the viewer sees host-opened streams as anonymous inbound
// connections, each video stream announces itself with a one-byte preamble
// (0x56 'V') before its first TLV; the control stream needs no tag — it
// always speaks HELLO (TLV type 0x01) first, so the first byte demuxes.
//
// Both tunnels run full mutual TLS with the same identities (§13): the
// viewer pins the host's certificate fingerprint, and the host admits only
// approved viewer keys to a session, on each tunnel.

public enum QUICError: Error {
    case identityImportFailed
    case invalidPort
    case invalidFingerprint
}

/// Monotonic wall-clock microseconds for real-transport wiring (engines take
/// injected time; the trace rig injects virtual time instead).
public enum MonotonicClock {
    @inline(__always)
    public static var nowUS: UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }
}

private let quicDebugEnabled = ProcessInfo.processInfo.environment["GLASSACT_QUIC_DEBUG"] != nil

func quicDebug(_ message: @autoclosure () -> String) {
    if quicDebugEnabled {
        FileHandle.standardError.write(Data(("[quic] " + message() + "\n").utf8))
    }
}

/// §6 — QUIC transport over Network.framework. See the Deviations note above
/// for the two-tunnel topology.
///
/// Threading: all callbacks (`onControl`/`onDatagram`/`onState`) fire on the
/// `queue` passed at construction — the app hops to engine queues from there.
/// Obtain via `QUICServer` (host) or `connect` (viewer), set callbacks, then
/// call `start()`.
public final class QUICTransport: GlassActTransport, @unchecked Sendable {
    static let alpn = "glassact"
    /// §3.9 — the sign-in connection's ALPN (same port as the control tunnel).
    static let signInALPN = "glassact-signin"
    static let requestedDatagramFrameSize = 1400

    enum Role { case host, viewer }

    static let videoPreamble: UInt8 = 0x56 // 'V'

    public var onControl: (Data) -> Void = { _ in }
    public var onDatagram: (Data) -> Void = { _ in }
    public var onVideo: (Data) -> Void = { _ in }
    public var onState: (TransportState) -> Void = { _ in }
    /// The video stream was lost or replaced mid-session (either side). Any
    /// partially received video TLV is garbage and in-flight video/keyframes
    /// are gone: the viewer resets its video deframer, the host dissolves its
    /// region (fresh START + sync frame on re-formation). Fires on `queue`.
    public var onVideoReset: () -> Void = {}

    /// Lifecycle contract: `onState(.ready)` at most once, then exactly one
    /// terminal `.failed`/`.cancelled` — whether the peer, the network, the
    /// establishment deadline, or a local `cancel()` ended it. After the
    /// terminal state every callback is released (breaking owner → transport
    /// → closure → owner cycles) and nothing fires again.
    static let establishTimeoutS = 10.0
    /// QUIC idle timeout with keepalives every `keepAliveS` on both tunnels:
    /// a dead peer, a dead path, or a half-open session (one tunnel lost)
    /// fails within ~idleTimeout instead of lingering. (Was 8 h with no
    /// keepalive — a crashed host froze the viewer for hours, and a viewer
    /// that vanished mid-handshake wedged the listener.)
    public static let idleTimeoutMS = 30_000
    static let keepAliveS = 5

    /// Effective QUIC datagram frame size, read back from the flow metadata
    /// (`usableDatagramFrameSize`) once ready; conservative until then.
    /// Written on `queue`, read by the engine on its own queue every tick.
    public var maxDatagramSize: Int {
        maxDatagramSizeAtomic.load(ordering: .relaxed)
    }
    private let maxDatagramSizeAtomic = Atomic<Int>(1200)

    private let role: Role
    private let queue: DispatchQueue
    private var started = false
    private var finished = false

    // Control tunnel
    private var controlGroup: NWConnectionGroup?
    private var controlCandidates: [NWConnection] = [] // viewer: inbound streams awaiting first bytes
    private var control: NWConnection?
    private var controlReady = false
    private var controlGroupReady = false
    private var pendingControl: [Data] = []

    // Path RTT sampler (host): consecutive data-transfer reports on the
    // control stream, collected every `rttSampleInterval`. The thin-link
    // rig (VideoSendGateTests) showed the report's smoothed RTT tracks a
    // bottleneck queue per ACK while PING-derived SRTT lags seconds.
    private var rttReport: NWConnection.PendingDataTransferReport?
    private let rttSmoothedUS = Atomic<UInt64>(0)
    private let rttMinUS = Atomic<UInt64>(0)
    private static let rttSampleInterval: DispatchTimeInterval = .milliseconds(250)

    // Video stream (§3.7): opened lazily by the host on first sendVideo; the
    // viewer adopts the inbound stream whose first byte is the preamble.
    private var video: NWConnection?
    private var videoReady = false
    private var pendingVideo: [Data] = []
    private let videoBacklogLock = NSLock()
    private var videoBacklogBytesLocked = 0

    // Datagram tunnel. Sends are paced by a token bucket on `queue`, at the
    // rate the host engine sets (starting at `DatagramPacing.bytesPerSecond`).
    // Released unpaced, a batch left in microseconds and the viewer's UDP
    // receive buffer kept ~675 datagrams
    // of it (83 % of a 4000-datagram burst lost on loopback); earlier still,
    // a synchronous blast overflowed NW's send path and starved the control
    // stream. `contentProcessed` fires at stack handoff, not at the wire, so
    // it bounds NW's backlog (the in-flight cap below) but cannot pace.
    // Overflow of the (batch-sized) queue drops the oldest — correct by
    // contract (INV-5: affected tiles re-qualify and re-encode).
    private var datagramReceiveErrorStreak = 0
    static let maxInflightDatagrams = 256
    /// A full-screen batch the engine admits whole must queue whole: the
    /// governor's 16 MB bucket plus admission slack is up to ~20 MB, ~18k
    /// datagrams of ~1.15 KB. The engine stops encoding while the pacer is
    /// backlogged, so beyond one batch the queue stays near empty.
    static let maxQueuedDatagrams = 32_768
    private var datagram: NWConnection?
    private var datagramReady = false
    private var datagramInflight = 0
    // Fixed ring (never grows, and a sent slot is released at once — the
    // old array kept every consumed Data alive until it fully drained, which
    // never happens under sustained load). Overflow drops the OLDEST queued
    // datagram: by then its batch has likely timed out and its tiles are
    // re-encoded fresh, so sending it late only duplicates work (INV-5).
    private var datagramRing = [Data?](repeating: nil, count: QUICTransport.maxQueuedDatagrams)
    private var datagramRingHead = 0
    private var datagramRingCount = 0
    private let queuedDatagramBytesAtomic = Atomic<Int>(0)
    public var queuedDatagramBytes: Int { queuedDatagramBytesAtomic.load(ordering: .relaxed) }
    // Pacer: byte tokens, refilled from the monotonic clock; a one-shot
    // timer wakes the pump when the bucket runs dry with datagrams queued.
    private var paceTokens = DatagramPacing.burstBytes
    private let paceRateAtomic = Atomic<Int>(DatagramPacing.bytesPerSecond)
    public var pacesDatagrams: Bool { true }
    public func setDatagramPaceRate(bytesPerSecond: Int) {
        paceRateAtomic.store(max(1_000_000, bytesPerSecond), ordering: .relaxed)
    }
    private var paceRefillNS: UInt64 = 0
    private var paceTimer: (any DispatchSourceTimer)?
    private var paceTimerArmed = false
    /// Datagrams dropped by the pacing queue (overflow). `queue` only.
    public private(set) var pacingDroppedDatagrams = 0

    private var announcedReady = false
    /// Server pairing: remote host of the control tunnel (host role).
    var remoteHost: NWEndpoint.Host?
    /// Host side: the viewer's address as dialed from ("100.64.0.7",
    /// "fe80::…"), for the approved-viewers list. Empty when unknown.
    public var remoteAddress: String { Self.addressString(remoteHost) }

    static func addressString(_ host: NWEndpoint.Host?) -> String {
        switch host {
        case let .name(name, _)?: name
        case let .ipv4(a)?: "\(a)"
        case let .ipv6(a)?: "\(a)"
        default: ""
        }
    }
    /// Server bookkeeping hook (internal): fires once, after the terminal state.
    var onTeardown: ((QUICTransport) -> Void)?
    /// `queue` only.
    var isEstablished: Bool { announcedReady }
    /// `queue` only.
    var isFinished: Bool { finished }
    /// Why the session ended — set at the fail site, for the app's log.
    public private(set) var lastFailReason = ""

    // Viewer dial target
    private var dialHost: String = ""
    private var dialControlPort: UInt16 = 0
    private var dialDatagramPort: UInt16 = 0
    private var pinnedFingerprint: String = ""
    private var clientIdentity: SecIdentity?
    private let observedHost = ObservedFingerprint()

    /// The certificate fingerprint the host actually presented on this dial
    /// (nil until its TLS handshake got that far) — recorded whether or not
    /// it matched the pin, so a changed host key can be reported as such.
    public var observedHostFingerprint: String? { observedHost.value.withLock { $0 } }

    private final class ObservedFingerprint: Sendable {
        let value = Mutex<String?>(nil)
    }

    /// Host side: the certificate the viewer presented on the control
    /// tunnel (mutual TLS) — its SHA-256 fingerprint and subject common name
    /// — read from the established connection, so it names exactly this
    /// session's peer. Nil until the control group is ready (`.ready` is
    /// announced after it), or when the viewer sent no certificate.
    public var peerCertificate: PeerCertificate? { peer.withLock { $0 } }
    private let peer = Mutex<PeerCertificate?>(nil)

    public struct PeerCertificate: Sendable, Equatable {
        public let fingerprint: String
        public let commonName: String
        public init(fingerprint: String, commonName: String) {
            self.fingerprint = fingerprint
            self.commonName = commonName
        }
        /// Headless Glass Act agents present this common name.
        /// Headless Glass Act agents present this common name.
        public var isAgent: Bool { commonName == "glassact-agent" }
    }

    /// `queue`: the leaf certificate of an established QUIC connection (its
    /// TLS 1.3 handshake lives in the QUIC metadata — the group exposes no
    /// separate TLS layer).
    static func peerCertificate(of metadata: NWProtocolMetadata?) -> PeerCertificate? {
        guard let quic = metadata as? NWProtocolQUIC.Metadata else { return nil }
        var leaf: SecCertificate?
        sec_protocol_metadata_access_peer_certificate_chain(quic.securityProtocolMetadata) { cert in
            if leaf == nil { leaf = sec_certificate_copy_ref(cert).takeRetainedValue() }
        }
        guard let leaf else { return nil }
        var cn: CFString?
        SecCertificateCopyCommonName(leaf, &cn)
        return PeerCertificate(fingerprint: QUICIdentity.fingerprint(of: leaf), commonName: (cn as String?) ?? "")
    }

    // MARK: - Construction

    /// Viewer side: dial `host:port` (control) and `host:datagramPort`
    /// (datagram flow, defaults to `port + 1`), pinning the host's certificate
    /// fingerprint on both tunnels. Set callbacks, then `start()`.
    /// `fingerprint` pins the host's certificate; empty means trust on first
    /// use (accept whatever the host presents — the caller records
    /// `observedHostFingerprint` once the session proves out).
    /// `identity` is the viewer's own certificate, presented on both tunnels
    /// (mutual TLS) — a host that authorizes viewers refuses dials without it.
    public static func connect(
        host: String, port: UInt16, fingerprint: String,
        datagramPort: UInt16? = nil, identity: SecIdentity? = nil,
        queue: DispatchQueue = DispatchQueue(label: "glassact.quic.client")
    ) -> QUICTransport {
        let transport = QUICTransport(role: .viewer, queue: queue)
        transport.clientIdentity = identity
        transport.dialHost = host
        transport.dialControlPort = port
        transport.dialDatagramPort = datagramPort ?? port &+ 1
        transport.pinnedFingerprint = QUICIdentity.normalize(fingerprint)
        return transport
    }

    init(role: Role, queue: DispatchQueue) {
        self.role = role
        self.queue = queue
    }

    /// Host side (called by QUICServer): adopt the accepted control tunnel,
    /// which the server has already started and seen become ready (it
    /// classifies tunnels by ALPN once their handshake completes).
    func attachControlGroup(_ group: NWConnectionGroup) {
        controlGroup = group
    }

    /// Host side (server, `queue`): an establishing session hands its
    /// datagram flow to the newer dial replacing it — the flow may belong to
    /// that newer dial (it can complete its handshake first). Newest-wins
    /// attachment corrects a stale one.
    func takeDatagramForHandoff() -> NWConnection? {
        guard !announcedReady, let flow = datagram else { return nil }
        datagram = nil
        datagramReady = false
        flow.stateUpdateHandler = nil // its later cancel must not fail us
        return flow
    }

    /// Host side (called by QUICServer): adopt the accepted datagram tunnel.
    /// Before establishment the newest flow wins: a flow left over from an
    /// abandoned dial attempt must not hold the slot against the live one.
    func attachDatagram(_ connection: NWConnection) {
        queue.async { [self] in
            guard !finished else {
                connection.cancel()
                return
            }
            if let existing = datagram {
                guard !announcedReady, existing !== connection else {
                    connection.cancel()
                    return
                }
                existing.stateUpdateHandler = nil // its cancel must not fail us
                existing.cancel()
                datagramReady = false
            }
            datagram = connection
            if started {
                configureDatagram(connection)
            }
        }
    }

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            switch role {
            case .host:
                startHost()
            case .viewer:
                startViewer()
            }
            // Both tunnels must come up together. A missing datagram tunnel
            // (port + 1 blocked or not forwarded) or a peer that vanishes
            // mid-handshake otherwise leaves the session half-built forever.
            queue.asyncAfter(deadline: .now() + Self.establishTimeoutS) { [weak self] in
                guard let self, !self.finished, !self.announcedReady else { return }
                self.fail("not established within \(Int(Self.establishTimeoutS)) s")
            }
        }
    }

    /// Local teardown. Emits `.cancelled` exactly once (unless the session
    /// already ended), like every other end of the session — owners must
    /// tell their own stale transports apart (identity check), not rely on
    /// silence.
    public func cancel() {
        queue.async { [self] in
            if lastFailReason.isEmpty { lastFailReason = "cancelled locally" }
            teardown(.cancelled)
        }
    }

    // MARK: - GlassActTransport

    public func sendControl(_ data: Data) {
        queue.async { [self] in
            guard !finished else { return }
            if controlReady, let control {
                control.send(content: data, completion: .contentProcessed { [weak self] error in
                    // The reliable stream failing is the session failing.
                    if let error { self?.fail("control send error: \(error)") }
                })
                quicDebug("\(role) control send \(data.count) B")
            } else {
                pendingControl.append(data) // flushed once the stream exists
                quicDebug("\(role) control send \(data.count) B -> pending (stream not ready)")
            }
        }
    }

    /// Bytes handed to the video stream but not yet accepted by the network
    /// (send completions outstanding + pre-ready buffer). Thread-safe — the
    /// engine polls this from its own queue as the newest-wins pacing gate.
    public var videoBacklogBytes: Int {
        videoBacklogLock.lock()
        defer { videoBacklogLock.unlock() }
        return videoBacklogBytesLocked
    }

    private func addVideoBacklog(_ delta: Int) {
        videoBacklogLock.lock()
        videoBacklogBytesLocked += delta
        videoBacklogLock.unlock()
    }

    public func sendVideo(_ data: Data) {
        addVideoBacklog(data.count)
        queue.async { [self] in
            guard !finished, role == .host else {
                addVideoBacklog(-data.count)
                return
            }
            if video == nil {
                openHostVideoStream()
            }
            if videoReady, let video {
                transmitVideo(video, data)
            } else {
                pendingVideo.append(data)
            }
        }
    }

    /// `queue` only.
    private func transmitVideo(_ stream: NWConnection, _ data: Data) {
        stream.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.addVideoBacklog(-data.count)
            if let error { quicDebug("video send error: \(error)") }
        })
    }

    /// `queue` only. Host: extract a second stream from the control group and
    /// tag it with the video preamble.
    private func openHostVideoStream() {
        guard video == nil, let group = controlGroup else { return }
        guard let stream = group.extract() else {
            quicDebug("host: video stream extract failed")
            return // video is optional — the session survives without it
        }
        video = stream
        stream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            quicDebug("host video stream: \(state)")
            switch state {
            case .ready:
                stream.send(content: Data([Self.videoPreamble]),
                            completion: .contentProcessed { _ in })
                self.videoReady = true
                let backlog = self.pendingVideo
                self.pendingVideo.removeAll()
                for data in backlog {
                    self.transmitVideo(stream, data)
                }
            case .failed, .cancelled:
                // Video-stream loss degrades, it does not end the session:
                // the next sendVideo opens a fresh stream (the viewer adopts
                // the newest preamble stream) and the engine is told so it
                // restarts its region cleanly.
                guard self.video === stream else { return }
                self.videoReady = false
                self.video = nil
                stream.cancel() // a failed NWConnection still holds resources
                for data in self.pendingVideo { self.addVideoBacklog(-data.count) }
                self.pendingVideo.removeAll()
                if !self.finished { self.onVideoReset() }
            default:
                break
            }
        }
        stream.start(queue: queue)
    }

    public var transportRTT: (smoothedUS: UInt64, minUS: UInt64)? {
        let smoothed = rttSmoothedUS.load(ordering: .relaxed)
        guard smoothed > 0 else { return nil }
        return (smoothed, rttMinUS.load(ordering: .relaxed))
    }

    /// `queue` only. Collects the running report and starts the next, until
    /// teardown or the stream is replaced.
    private func sampleTransportRTT(_ stream: NWConnection) {
        guard !finished, control === stream else { return }
        if let pending = rttReport {
            pending.collect(queue: queue) { [weak self] report in
                let path = report.aggregatePathReport
                guard let self, path.transportSmoothedRTT > 0 else { return }
                self.rttSmoothedUS.store(UInt64(path.transportSmoothedRTT * 1_000_000), ordering: .relaxed)
                self.rttMinUS.store(UInt64(path.transportMinimumRTT * 1_000_000), ordering: .relaxed)
            }
        }
        rttReport = stream.startDataTransferReport()
        queue.asyncAfter(deadline: .now() + Self.rttSampleInterval) { [weak self] in
            self?.sampleTransportRTT(stream)
        }
    }

    /// Tests only: kill the host's video stream as a network failure would.
    func testKillVideoStream() {
        queue.async { [self] in video?.cancel() }
    }

    /// `queue` only. Viewer: pump an adopted video stream.
    private func receiveVideo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.onVideo(data)
            }
            if error != nil || isComplete {
                quicDebug("viewer video stream ended")
                // Degraded, not fatal. Drop it so the host's replacement
                // stream is adopted, and discard any partial TLV.
                if self.video === connection {
                    self.video = nil
                    self.videoReady = false
                    connection.cancel()
                    self.onVideoReset()
                }
                return
            }
            self.receiveVideo(connection)
        }
    }

    public func sendDatagram(_ data: Data) {
        queue.async { [self] in
            enqueueDatagram(data)
            pumpDatagrams()
        }
    }

    /// One hop onto the transport queue for a whole batch (a 5K cold-start
    /// batch is ~12k datagrams — one `queue.async` each was that many
    /// dispatches on the engine's queue); the pacer releases it.
    public func sendDatagrams(_ batch: [Data]) {
        guard !batch.isEmpty else { return }
        queue.async { [self] in
            for data in batch { enqueueDatagram(data) }
            pumpDatagrams()
        }
    }

    /// `queue` only.
    private func enqueueDatagram(_ data: Data) {
        // Before the flow is ready, dropping is correct — datagrams are
        // unreliable by contract (INV-5) and content re-qualifies via ACKs.
        guard !finished, datagramReady, datagram != nil else { return }
        if datagramRingCount == Self.maxQueuedDatagrams { // full: drop the oldest
            let dropped = datagramRing[datagramRingHead]!
            datagramRing[datagramRingHead] = nil
            datagramRingHead = (datagramRingHead + 1) % Self.maxQueuedDatagrams
            datagramRingCount -= 1
            queuedDatagramBytesAtomic.subtract(dropped.count, ordering: .relaxed)
            pacingDroppedDatagrams += 1
        }
        datagramRing[(datagramRingHead + datagramRingCount) % Self.maxQueuedDatagrams] = data
        datagramRingCount += 1
        queuedDatagramBytesAtomic.add(data.count, ordering: .relaxed)
    }

    /// Releases queued datagrams as far as the token bucket and the
    /// in-flight cap allow; if tokens ran out first, arms the timer for the
    /// moment the deficit refills. `queue` only.
    private func pumpDatagrams() {
        guard !finished, datagramRingCount > 0, let datagram else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if paceRefillNS != 0 {
            let elapsed = min(now &- paceRefillNS, 1_000_000_000)
            let rate = paceRateAtomic.load(ordering: .relaxed)
            paceTokens = min(paceTokens + Int(elapsed) * rate / 1_000_000_000, DatagramPacing.burstBytes)
        }
        paceRefillNS = now
        guard paceTokens > 0, datagramInflight < Self.maxInflightDatagrams else {
            armPaceTimer()
            return
        }
        datagram.batch {
            while paceTokens > 0, datagramInflight < Self.maxInflightDatagrams, datagramRingCount > 0 {
                let next = datagramRing[datagramRingHead]!
                datagramRing[datagramRingHead] = nil
                datagramRingHead = (datagramRingHead + 1) % Self.maxQueuedDatagrams
                datagramRingCount -= 1
                queuedDatagramBytesAtomic.subtract(next.count, ordering: .relaxed)
                paceTokens -= next.count // may dip below zero by one datagram
                transmitDatagram(next)
            }
        }
        if datagramRingCount > 0 && paceTokens <= 0 { armPaceTimer() }
        // (Blocked on the in-flight cap instead: a completion re-pumps.)
    }

    /// `queue` only.
    private func armPaceTimer() {
        guard !paceTimerArmed, !finished, paceTokens <= 0 else { return }
        let timer: any DispatchSourceTimer
        if let paceTimer {
            timer = paceTimer
        } else {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.paceTimerArmed = false
                self.pumpDatagrams()
            }
            timer.schedule(deadline: .distantFuture)
            timer.resume()
            paceTimer = timer
        }
        // Wait until the deficit refills plus one typical datagram, at least
        // 1 ms (timer granularity; 1 ms at 50 MB/s is ~43 datagrams).
        let deficit = 1 - paceTokens + 1200
        let waitNS = max(1_000_000, deficit * 1_000_000_000 / paceRateAtomic.load(ordering: .relaxed))
        paceTimerArmed = true
        timer.schedule(deadline: .now() + .nanoseconds(waitNS), leeway: .microseconds(250))
    }

    /// `queue` only.
    private func transmitDatagram(_ data: Data) {
        guard !finished, let datagram else { return }
        datagramInflight += 1
        datagram.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self, !self.finished else { return } // completion fires on `queue`
            self.datagramInflight -= 1
            if self.datagramRingCount > 0 && !self.paceTimerArmed { self.pumpDatagrams() }
        })
    }

    // MARK: - Host

    private func startHost() {
        guard let group = controlGroup else {
            fail("host: no control group")
            return
        }
        group.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            quicDebug("host control group: \(state)")
            switch state {
            case .ready:
                self.hostControlGroupReady(group)
            case .failed, .cancelled:
                self.fail("control group state \(state)")
            default:
                self.onState(.connecting)
            }
        }
        group.newConnectionHandler = { connection in
            quicDebug("host control group: unexpected inbound stream")
            connection.cancel() // the host owns the control and video streams
        }
        // The server started the group to read its ALPN; it is ready by now
        // (and a group's state handler doesn't replay a state it has passed).
        hostControlGroupReady(group)
        if let datagram {
            configureDatagram(datagram)
        }
    }

    /// `queue` only. Idempotent.
    private func hostControlGroupReady(_ group: NWConnectionGroup) {
        guard !controlGroupReady, !finished else { return }
        controlGroupReady = true
        let peer = Self.peerCertificate(of: group.metadata(definition: NWProtocolQUIC.definition))
        self.peer.withLock { $0 = peer }
        enableKeepAlive(group.metadata(definition: NWProtocolQUIC.definition))
        openHostControlStream()
    }

    private func openHostControlStream() {
        guard control == nil, let group = controlGroup else { return }
        guard let stream = group.extract() else {
            quicDebug("host: control stream extract failed")
            fail("host: control stream extract failed")
            return
        }
        control = stream
        stream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            quicDebug("host control stream: \(state)")
            switch state {
            case .ready:
                self.controlReady = true
                self.flushPendingControl()
                self.receiveControl(stream)
                self.announceReadyIfComplete()
                self.sampleTransportRTT(stream)
            case .failed, .cancelled:
                self.fail("control stream state \(state)")
            default:
                break
            }
        }
        stream.start(queue: queue)
    }

    // MARK: - Viewer

    private func startViewer() {
        let controlOptions = Self.tunnelOptions(datagram: false)
        pinFingerprint(on: controlOptions)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(dialHost),
                                           port: NWEndpoint.Port(rawValue: dialControlPort) ?? 4433)
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint),
                                      using: NWParameters(quic: controlOptions))
        controlGroup = group
        group.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            quicDebug("viewer control group: \(state)")
            switch state {
            case .ready:
                self.controlGroupReady = true
                self.enableKeepAlive(group.metadata(definition: NWProtocolQUIC.definition))
                self.announceReadyIfComplete()
            case .failed, .cancelled:
                self.fail("viewer control connection state \(state)")
            default:
                self.onState(.connecting)
            }
        }
        group.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async { self.adoptControlCandidate(connection) }
        }
        group.start(queue: queue)

        let datagramOptions = Self.tunnelOptions(datagram: true)
        pinFingerprint(on: datagramOptions)
        let datagramEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(dialHost),
                                                   port: NWEndpoint.Port(rawValue: dialDatagramPort) ?? 4434)
        let flow = NWConnection(to: datagramEndpoint, using: NWParameters(quic: datagramOptions))
        datagram = flow
        configureDatagram(flow)
    }

    /// The host opens the control and video streams; both surface here as
    /// anonymous inbound connections. Streams that never deliver bytes
    /// (tunnel artifacts) are left idle; the first data byte demuxes — the
    /// video preamble adopts the video stream, anything else promotes THE
    /// control stream (HELLO's TLV type 0x01 can never collide with 0x56).
    private func adoptControlCandidate(_ connection: NWConnection) {
        quicDebug("viewer: inbound stream candidate")
        controlCandidates.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            quicDebug("viewer stream candidate: \(state)")
            if case .ready = state {
                self.receiveCandidateFirstData(connection)
            }
        }
        connection.start(queue: queue)
    }

    /// `queue` only. First delivery decides the stream's identity.
    private func receiveCandidateFirstData(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                if data[data.startIndex] == Self.videoPreamble, connection !== self.control {
                    quicDebug("viewer: adopted video stream")
                    // The host only opens a new video stream after its old one
                    // failed — the newest always wins, and the old one's
                    // partial TLV (if any) must not prefix the new bytes.
                    if let old = self.video, old !== connection {
                        old.cancel()
                        self.onVideoReset()
                    }
                    self.video = connection
                    self.videoReady = true
                    let rest = data.dropFirst()
                    if !rest.isEmpty { self.onVideo(Data(rest)) }
                    self.receiveVideo(connection)
                    return
                }
                if self.control == nil {
                    self.control = connection
                    self.controlReady = true
                    self.flushPendingControl()
                }
                if connection === self.control {
                    self.onControl(data)
                    self.receiveControl(connection)
                    return
                }
                // A third data-bearing stream: ignore its payload, keep draining.
            }
            if error != nil || isComplete { return }
            self.receiveCandidateFirstData(connection)
        }
    }

    // MARK: - Shared plumbing

    static func tunnelOptions(datagram: Bool, alpns: [String] = [alpn]) -> NWProtocolQUIC.Options {
        let options = NWProtocolQUIC.Options(alpn: alpns)
        // Pinned video mode leaves the datagram tunnel completely silent
        // (video + control + cursor all ride the other tunnel), so each
        // tunnel runs QUIC keepalives (enableKeepAlive, set once ready); the
        // idle timeout then only fires on a genuinely dead peer or path.
        options.idleTimeout = idleTimeoutMS
        if datagram {
            options.isDatagram = true
            options.maxDatagramFrameSize = requestedDatagramFrameSize
        } else {
            // Flow-control room for the video stream: one keyframe TLV is
            // up to 8 MiB, and a replacement stream can open while the old
            // one drains.
            options.initialMaxStreamsBidirectional = 64
            options.initialMaxData = 64 * 1024 * 1024 // control + video share
            options.initialMaxStreamDataBidirectionalLocal = 24 * 1024 * 1024
            options.initialMaxStreamDataBidirectionalRemote = 24 * 1024 * 1024
        }
        return options
    }

    /// §3.9 — a sign-in connection: one short request/response stream.
    static func signInOptions() -> NWProtocolQUIC.Options {
        let options = NWProtocolQUIC.Options(alpn: [signInALPN])
        options.idleTimeout = 15_000
        options.initialMaxStreamsBidirectional = 1
        options.initialMaxData = 16 * 1024
        options.initialMaxStreamDataBidirectionalLocal = 8 * 1024
        options.initialMaxStreamDataBidirectionalRemote = 8 * 1024
        return options
    }

    /// The ALPN a QUIC connection negotiated, from its metadata.
    static func negotiatedALPN(_ metadata: NWProtocolMetadata?) -> String? {
        guard let quic = metadata as? NWProtocolQUIC.Metadata else { return nil }
        return negotiatedALPN(quic.securityProtocolMetadata)
    }

    static func negotiatedALPN(_ metadata: sec_protocol_metadata_t) -> String? {
        guard let p = sec_protocol_metadata_copy_negotiated_protocol(metadata) else { return nil }
        defer { free(UnsafeMutablePointer(mutating: p)) }
        return String(cString: p)
    }

    private func enableKeepAlive(_ metadata: NWProtocolMetadata?) {
        (metadata as? NWProtocolQUIC.Metadata)?.keepAlive = .seconds(Self.keepAliveS)
    }

    /// Viewer side of both tunnels: pin the host's certificate and, when
    /// configured, present our own (mutual TLS).
    private func pinFingerprint(on options: NWProtocolQUIC.Options) {
        let expected = pinnedFingerprint
        let observed = observedHost
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trustRef, complete in
            let presented = QUICIdentity.leafFingerprint(of: trustRef)
            observed.value.withLock { $0 = presented }
            guard let presented else { return complete(false) }
            complete(expected.isEmpty || presented == expected) // empty pin: TOFU
        }, queue)
        if let clientIdentity, let secIdentity = sec_identity_create(clientIdentity) {
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        }
    }

    /// `queue` only. The connection may already be started (the server
    /// starts a pending flow to watch it die) — even already ready.
    private func configureDatagram(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.datagram === connection else { return }
            quicDebug("\(self.role) datagram: \(state)")
            switch state {
            case .ready:
                self.datagramBecameReady(connection)
            case .failed, .cancelled:
                self.fail("datagram connection state \(state)")
            default:
                break
            }
        }
        switch connection.state {
        case .setup:
            connection.start(queue: queue)
        case .ready:
            datagramBecameReady(connection)
        case .failed, .cancelled:
            fail("datagram connection already \(connection.state)")
        default:
            // A flow the server parked can finish its handshake while it is
            // handed over: that `.ready` may already be queued for the
            // parking handler, which ignores it. Look again once the queue
            // has delivered it.
            queue.async { [weak self] in
                guard let self, self.datagram === connection, !self.finished else { return }
                if connection.state == .ready { self.datagramBecameReady(connection) }
            }
        }
    }

    private func datagramBecameReady(_ connection: NWConnection) {
        guard !datagramReady else { return }
        datagramReady = true
        let metadata = connection.metadata(definition: NWProtocolQUIC.definition)
        enableKeepAlive(metadata)
        if let quic = metadata as? NWProtocolQUIC.Metadata, quic.usableDatagramFrameSize > 0 {
            maxDatagramSizeAtomic.store(quic.usableDatagramFrameSize, ordering: .relaxed)
        }
        receiveDatagrams(connection)
        announceReadyIfComplete()
    }

    private func receiveControl(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                quicDebug("\(self.role) control recv \(data.count) B (promoted: \(self.control == nil))")
                if self.control == nil {
                    self.control = connection
                    self.controlReady = true
                    self.flushPendingControl()
                }
                if connection === self.control {
                    self.onControl(data)
                }
            }
            if error != nil || isComplete {
                quicDebug("\(self.role) control stream ended: error=\(String(describing: error)) complete=\(isComplete)")
                if connection === self.control {
                    self.fail("control stream ended: \(String(describing: error)) complete=\(isComplete)")
                }
                return
            }
            self.receiveControl(connection)
        }
    }

    private func receiveDatagrams(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.datagramReceiveErrorStreak = 0
                self.onDatagram(data)
            }
            if let error {
                // A transient receive error on the UNRELIABLE flow is loss,
                // not session death — measured live: a full-screen burst
                // (9.3 MB/s) surfaced one and tore down an otherwise healthy
                // session. Genuine connection death arrives separately via
                // the state handler (.failed). Only a solid error streak
                // (nothing readable at all) still ends the session.
                quicDebug("\(self.role) datagram receive error: \(error)")
                self.datagramReceiveErrorStreak += 1
                if self.datagramReceiveErrorStreak >= 64 {
                    self.fail("datagram receive error streak: \(error)")
                    return
                }
            }
            self.receiveDatagrams(connection)
        }
    }

    private func flushPendingControl() {
        guard controlReady, let control else { return }
        for data in pendingControl {
            quicDebug("\(role) control flush \(data.count) B")
            control.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error { self?.fail("control flush error: \(error)") }
            })
        }
        pendingControl.removeAll()
    }

    /// Host: control stream + datagram flow ready. Viewer: control tunnel +
    /// datagram flow ready (the control *stream* only materializes when HELLO
    /// arrives, so it does not gate readiness).
    private func announceReadyIfComplete() {
        guard !announcedReady, datagramReady else { return }
        switch role {
        case .host:
            guard controlReady else { return }
        case .viewer:
            guard controlGroupReady else { return }
        }
        announcedReady = true
        onState(.ready)
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        if lastFailReason.isEmpty { lastFailReason = reason }
        quicDebug("\(role) FAIL: \(reason)")
        teardown(announcedReady ? .failed : .cancelled)
    }

    /// `queue` only. The single end-of-session path (see the lifecycle
    /// contract on `onVideoReset`'s neighbours): emit the terminal state
    /// once, cancel every NW object, release every callback.
    private func teardown(_ terminal: TransportState) {
        guard !finished else { return }
        finished = true
        rttReport = nil
        onState(terminal)
        control?.cancel()
        for candidate in controlCandidates where candidate !== control && candidate !== video {
            candidate.cancel()
        }
        controlCandidates.removeAll()
        video?.cancel()
        datagram?.cancel()
        controlGroup?.cancel()
        for data in pendingVideo { addVideoBacklog(-data.count) }
        pendingVideo.removeAll()
        pendingControl.removeAll()
        for i in datagramRing.indices { datagramRing[i] = nil }
        datagramRingHead = 0
        datagramRingCount = 0
        queuedDatagramBytesAtomic.store(0, ordering: .relaxed)
        paceTimer?.cancel()
        paceTimer = nil
        onControl = { _ in }
        onDatagram = { _ in }
        onVideo = { _ in }
        onVideoReset = {}
        onState = { _ in }
        let hook = onTeardown
        onTeardown = nil
        hook?(self)
    }
}

/// Host-side QUIC listener pair (control on `port`, datagram flow on
/// `port + 1`; with port 0 both are ephemeral — read `port`/`datagramPort`).
/// It serves a single viewer session at a time; each accepted session arrives
/// as an unstarted `QUICTransport` via `onTransport` — set callbacks, then
/// `start()` it.
///
/// Pairing: the two tunnels are matched by remote host, newest first. A
/// session that has not finished establishing yields to a newer dial from
/// any viewer (the old one is cancelled): a dial that stalled half-built must
/// never hold the only session slot. An established session is exclusive.
/// Host side of one sign-in connection (§3.9). Confined to the server's
/// queue; the server holds it until `end`. It never installs handlers on the
/// group: the server's (set once, at accept) route to it, so nothing that
/// arrives during the hand-off is lost.
private final class SignInExchange: @unchecked Sendable {
    typealias Handler = (SignInRequest, @escaping @Sendable (SignInResponse) -> Void) -> Void

    private let group: NWConnectionGroup
    private let queue: DispatchQueue
    private let onEnd: () -> Void
    private var handle: Handler?
    private var stream: NWConnection?
    private var received: [UInt8] = []
    private var ended = false

    init(group: NWConnectionGroup, queue: DispatchQueue, handle: @escaping Handler, onEnd: @escaping () -> Void) {
        self.group = group
        self.queue = queue
        self.handle = handle
        self.onEnd = onEnd
    }

    func take(_ candidate: NWConnection) {
        guard stream == nil, !ended else { return candidate.cancel() } // one request per connection
        stream = candidate
        if candidate.state == .setup { candidate.start(queue: queue) }
        receive()
    }

    private func receive() {
        guard let stream else { return }
        stream.receive(minimumIncompleteLength: 1, maximumLength: SignInRequest.maxEncodedBytes + 1) {
            [self] data, _, isComplete, error in
            if let data { received.append(contentsOf: data) }
            guard !ended, received.count <= SignInRequest.maxEncodedBytes, error == nil else { return end() }
            guard isComplete else { return receive() }
            let request = SignInRequest.parse(received)
            received = [] // don't keep the password around
            guard let request, let handle else { return end() }
            handle(request) { [self] response in
                queue.async { [self] in send(response) }
            }
        }
    }

    private func send(_ response: SignInResponse) {
        guard !ended, let stream else { return }
        stream.send(content: Data(response.encoded()), contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { [self] _ in
            // Give the answer time to reach the viewer before closing.
            queue.asyncAfter(deadline: .now() + 1) { [self] in end() }
        })
    }

    func end() {
        guard !ended else { return }
        ended = true
        handle = nil
        stream?.cancel()
        group.cancel()
        onEnd()
    }
}

public final class QUICServer: @unchecked Sendable {
    /// §3.9 — a sign-in request on its own connection: answer through
    /// `reply` (any thread, once). The peer is the key that connection
    /// presented, which is what gets approved.
    public typealias SignInHandler = @Sendable (
        _ request: SignInRequest, _ peer: QUICTransport.PeerCertificate, _ address: String,
        _ reply: @escaping @Sendable (SignInResponse) -> Void) -> Void

    public var onTransport: (QUICTransport) -> Void = { _ in }
    public var onReady: () -> Void = {}
    /// A listener failed (e.g. port in use, interface loss). Both listeners
    /// are cancelled; build a new server to listen again. Fires on `queue`.
    public var onFailed: (String) -> Void = { _ in }

    public var port: UInt16? { controlListener.port?.rawValue }
    public var datagramPort: UInt16? { datagramListener.port?.rawValue }

    private let controlListener: NWListener
    private let datagramListener: NWListener
    private let queue: DispatchQueue
    private var current: QUICTransport?
    private var pendingDatagram: NWConnection?
    private var controlListenerReady = false
    private var datagramListenerReady = false
    private var announcedReady = false
    private var failed = false
    private let signIn: SignInHandler?
    /// Control tunnels mid-handshake, by group, with any streams that arrived
    /// before classification (a sign-in request can). `queue` only.
    private var classifying: [ObjectIdentifier: [NWConnection]] = [:]
    /// Sign-in connections being answered. `queue` only.
    private var signIns: [ObjectIdentifier: SignInExchange] = [:]
    static let maxClassifying = 16
    static let maxSignIns = 4
    static let classifyTimeoutS = 10.0
    static let signInTimeoutS = 15.0

    /// `authorizeViewer`: when set, both listeners require a client
    /// certificate (mutual TLS) and admit a dial only if this returns true
    /// for its SHA-256 leaf fingerprint — before any application data flows.
    /// Called on `queue` during the TLS handshake; must not block.
    /// Nil admits any client (tests, and the pre-auth posture).
    /// `signIn` (requires an authorize callback): the control port also
    /// accepts sign-in connections (`glassact-signin`) from any key — they
    /// can only carry one sign-in exchange, never a session.
    public init(
        port: UInt16, identity: SecIdentity,
        queue: DispatchQueue = DispatchQueue(label: "glassact.quic.server", qos: .userInteractive),
        authorizeViewer: (@Sendable (String) -> Bool)? = nil,
        authorizePeer: (@Sendable (QUICTransport.PeerCertificate) -> Bool)? = nil,
        signIn: SignInHandler? = nil
    ) throws {
        // One check either way: the peer form also tells the host what the
        // certificate calls itself (an agent, say) before it asks its user.
        let authorize: (@Sendable (QUICTransport.PeerCertificate) -> Bool)? =
            authorizePeer ?? authorizeViewer.map { check in { @Sendable peer in check(peer.fingerprint) } }
        self.queue = queue
        let signIn = authorize == nil ? nil : signIn
        self.signIn = signIn
        guard let secIdentity = sec_identity_create(identity) else {
            throw QUICError.identityImportFailed
        }
        // port + 1 must exist: 65535 would wrap the datagram port to 0.
        guard port < UInt16.max else { throw QUICError.invalidPort }

        func makeListener(datagram: Bool, on listenPort: UInt16) throws -> NWListener {
            let acceptsSignIn = !datagram && signIn != nil
            let options = QUICTransport.tunnelOptions(
                datagram: datagram,
                alpns: acceptsSignIn ? [QUICTransport.alpn, QUICTransport.signInALPN] : [QUICTransport.alpn])
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
            if let authorize {
                let sec = options.securityProtocolOptions
                sec_protocol_options_set_peer_authentication_required(sec, true)
                sec_protocol_options_set_verify_block(sec, { metadata, trustRef, complete in
                    guard let peer = QUICIdentity.leafPeer(of: trustRef) else {
                        complete(false)
                        return
                    }
                    // Any key may open a sign-in connection — all it can do
                    // is sign in. The session ALPN admits approved keys only.
                    if acceptsSignIn, QUICTransport.negotiatedALPN(metadata) == QUICTransport.signInALPN {
                        complete(true)
                        return
                    }
                    complete(authorize(peer))
                }, queue)
            }
            guard let nwPort = NWEndpoint.Port(rawValue: listenPort) else { throw QUICError.invalidPort }
            return try NWListener(using: NWParameters(quic: options), on: nwPort)
        }

        controlListener = try makeListener(datagram: false, on: port)
        datagramListener = try makeListener(datagram: true, on: port == 0 ? 0 : port + 1)

        controlListener.newConnectionGroupHandler = { [weak self] group in
            self?.acceptControlGroup(group)
        }
        datagramListener.newConnectionHandler = { [weak self] connection in
            self?.acceptDatagram(connection)
        }
        controlListener.stateUpdateHandler = { [weak self] state in
            self?.listenerStateChanged(state, control: true)
        }
        datagramListener.stateUpdateHandler = { [weak self] state in
            self?.listenerStateChanged(state, control: false)
        }
    }

    static func host(of endpoint: NWEndpoint?) -> NWEndpoint.Host? {
        if case let .hostPort(host, _)? = endpoint { return host }
        return nil
    }

    /// Unknown on either side is permissive (pairing still falls back to
    /// newest-wins); a known mismatch never pairs.
    static func sameHost(_ a: NWEndpoint.Host?, _ b: NWEndpoint.Host?) -> Bool {
        guard let a, let b else { return true }
        return a == b
    }

    /// `queue` only. A control tunnel's ALPN is known only once its
    /// handshake completes, so the server starts it and classifies it then:
    /// the session ALPN becomes a session, the sign-in ALPN gets one sign-in
    /// exchange. A dial whose handshake fails (an unapproved key) never gets
    /// as far as displacing a session that is still establishing.
    private func acceptControlGroup(_ group: NWConnectionGroup) {
        guard classifying.count < Self.maxClassifying else {
            group.cancel()
            return
        }
        let id = ObjectIdentifier(group)
        classifying[id] = []
        // Set once and never swapped while the server owns the group (a
        // swapped handler can lose an event already queued for the old one):
        // streams go to whoever owns the group now.
        group.newConnectionHandler = { [weak self] stream in
            guard let self else { return stream.cancel() }
            if self.classifying[id] != nil {
                self.classifying[id]?.append(stream)
            } else if let exchange = self.signIns[id] {
                exchange.take(stream)
            } else {
                stream.cancel()
            }
        }
        group.stateUpdateHandler = { [weak self] state in
            guard let self else { return group.cancel() }
            switch state {
            case .ready:
                guard let early = self.classifying.removeValue(forKey: id) else { return }
                let alpn = QUICTransport.negotiatedALPN(group.metadata(definition: NWProtocolQUIC.definition))
                quicDebug("server: control tunnel ready, alpn \(alpn ?? "none")")
                switch alpn {
                case QUICTransport.alpn?:
                    early.forEach { $0.cancel() }
                    self.adoptSessionGroup(group)
                case QUICTransport.signInALPN? where self.signIn != nil:
                    self.answerSignIn(on: group, early: early)
                default:
                    early.forEach { $0.cancel() }
                    group.cancel()
                }
            case .failed, .cancelled:
                self.classifying.removeValue(forKey: id)?.forEach { $0.cancel() }
                self.signIns[id]?.end()
            default:
                break
            }
        }
        group.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.classifyTimeoutS) { [weak self] in
            guard let self, self.classifying[id] != nil else { return }
            group.cancel() // its .cancelled clears the entry
        }
    }

    /// `queue` only. A ready session-ALPN tunnel (its key is approved).
    private func adoptSessionGroup(_ group: NWConnectionGroup) {
        let remoteHost = Self.host(of: (group.descriptor as? NWMultiplexGroup)?.members.first)
        var handoff: NWConnection?
        if let current, !current.isFinished {
            guard !current.isEstablished else {
                group.cancel() // one established session at a time
                return
            }
            quicDebug("server: newer dial supersedes a session still establishing")
            if Self.sameHost(current.remoteHost, remoteHost) { handoff = current.takeDatagramForHandoff() }
            current.cancel()
        }
        let transport = QUICTransport(role: .host, queue: queue)
        transport.remoteHost = remoteHost
        transport.attachControlGroup(group)
        if let pending = pendingDatagram,
           Self.sameHost(Self.host(of: pending.endpoint), transport.remoteHost) {
            pendingDatagram = nil
            handoff?.cancel()
            transport.attachDatagram(pending)
        } else if let handoff {
            transport.attachDatagram(handoff)
        }
        transport.onTeardown = { [weak self] finished in
            if self?.current === finished { self?.current = nil }
        }
        current = transport
        onTransport(transport)
    }

    /// `queue` only. Read one request from the viewer's stream, answer, hang up.
    private func answerSignIn(on group: NWConnectionGroup, early: [NWConnection]) {
        guard let signIn, signIns.count < Self.maxSignIns,
              let peer = QUICTransport.peerCertificate(of: group.metadata(definition: NWProtocolQUIC.definition))
        else {
            early.forEach { $0.cancel() }
            group.cancel()
            return
        }
        let id = ObjectIdentifier(group)
        let address = QUICTransport.addressString(
            Self.host(of: (group.descriptor as? NWMultiplexGroup)?.members.first))
        let exchange = SignInExchange(group: group, queue: queue, handle: { request, reply in
            signIn(request, peer, address, reply)
        }, onEnd: { [weak self] in self?.signIns[id] = nil })
        signIns[id] = exchange
        early.forEach { exchange.take($0) }
        queue.asyncAfter(deadline: .now() + Self.signInTimeoutS) { [weak exchange] in exchange?.end() }
    }

    /// `queue` only.
    private func acceptDatagram(_ connection: NWConnection) {
        let host = Self.host(of: connection.endpoint)
        if let current, !current.isFinished, !current.isEstablished,
           Self.sameHost(host, current.remoteHost) {
            current.attachDatagram(connection) // newest wins while establishing
            return
        }
        // Park it (newest wins) for the next control tunnel, and watch it so
        // a flow abandoned by its viewer doesn't sit here to be mis-paired.
        pendingDatagram?.cancel()
        pendingDatagram = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                if self?.pendingDatagram === connection { self?.pendingDatagram = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func listenerStateChanged(_ state: NWListener.State, control: Bool) {
        switch state {
        case .ready:
            if control { controlListenerReady = true } else { datagramListenerReady = true }
            if controlListenerReady && datagramListenerReady && !announcedReady {
                announcedReady = true
                onReady()
            }
        case let .failed(error):
            guard !failed else { return }
            failed = true
            controlListener.cancel()
            datagramListener.cancel()
            onFailed("\(control ? "control" : "datagram") listener failed: \(error)")
        case .cancelled:
            if control { controlListenerReady = false } else { datagramListenerReady = false }
        default:
            break
        }
    }

    public func start() {
        controlListener.start(queue: queue)
        datagramListener.start(queue: queue)
    }

    /// Call when the active session's transport reports failed/cancelled so
    /// the listener accepts the next viewer (one session at a time).
    public func resetSession() {
        queue.async { [self] in
            // Cancel — not just drop — the active transport: a geometry apply
            // resets mid-session while the viewer's connection is still open
            // and merely waiting for the re-offered HELLO. Nil'ing the pointer
            // abandons the host engine but leaves the socket alive, so the
            // viewer waits forever ("waiting for HELLO") and its auto-reconnect
            // (fail-triggered) never fires. Cancelling drops the socket → the
            // viewer sees the failure and re-dials into the fresh session.
            current?.cancel()
            current = nil
            pendingDatagram?.cancel()
            pendingDatagram = nil
        }
    }

    public func cancel() {
        queue.async { [self] in
            failed = true // a deliberate stop is not a failure to report
            controlListener.cancel()
            datagramListener.cancel()
            signIns.values.forEach { $0.end() }
            signIns.removeAll()
            current?.cancel()
            current = nil
            pendingDatagram?.cancel()
            pendingDatagram = nil
        }
    }
}
