public import Foundation

/// Seeded fault model for `InProcLink` (§6). All tests that involve loss use
/// fixed seeds; the same seed and send schedule reproduce the same delivery
/// sequence exactly.
public struct FaultConfig: Sendable {
    /// Datagram drop probability, per mille (0–1000).
    public var dropPermille = 0
    /// Datagram duplication probability, per mille.
    public var dupPermille = 0
    /// Probability a datagram gets extra reorder latency, per mille.
    public var reorderPermille = 0
    public var reorderExtraMaxUS: UInt64 = 30_000
    /// Uniform per-datagram latency range. Control uses the midpoint, FIFO.
    public var latencyMinUS: UInt64 = 0
    public var latencyMaxUS: UInt64 = 0
    public var seed: UInt64 = 1

    public init() {}
    public static let none = FaultConfig()
}

struct SeededRNG {
    var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func permille() -> Int {
        Int(next() % 1000)
    }

    mutating func uniform(_ lo: UInt64, _ hi: UInt64) -> UInt64 {
        hi > lo ? lo &+ next() % (hi &- lo &+ 1) : lo
    }
}

/// One endpoint of an `InProcLink`. Delivery callbacks fire synchronously
/// inside `InProcLink.advance(toUS:)` on the caller's thread — the whole rig
/// is single-threaded and driven by virtual time for determinism.
public final class InProcTransport: GlassActTransport, @unchecked Sendable {
    public var maxDatagramSize: Int { 1452 }
    /// Video not yet in the network: without a bottleneck delivery inside
    /// `advance` is synchronous and nothing ever sits queued; with one, the
    /// host's video waits for room in the bottleneck (`InProcLink.Bottleneck`).
    public var videoBacklogBytes: Int { isA ? link?.videoSendBufferBytes ?? 0 : 0 }
    public var onControl: (Data) -> Void = { _ in }
    public var onDatagram: (Data) -> Void = { _ in }
    public var onVideo: (Data) -> Void = { _ in }
    public var onState: (TransportState) -> Void = { _ in }

    weak var link: InProcLink?
    let isA: Bool
    /// Lifecycle, like QUICTransport's contract: `.ready` at most once, then
    /// exactly one terminal state (`.cancelled` locally, `.failed` when the
    /// peer or the link ended it).
    public private(set) var state: TransportState = .connecting

    init(isA: Bool) {
        self.isA = isA
    }

    func emit(_ next: TransportState) {
        switch (state, next) {
        case (.connecting, .ready), (.connecting, .failed), (.connecting, .cancelled),
             (.ready, .failed), (.ready, .cancelled):
            state = next
            onState(next)
        default:
            break // after a terminal state nothing more is reported
        }
    }

    /// Ends the session: this side reports `.cancelled`, the peer `.failed`
    /// (a QUIC close), and nothing more is delivered either way.
    public func cancel() {
        link?.sever(cancelledByA: isA)
    }

    public func sendControl(_ data: Data) {
        link?.enqueueControl(fromA: isA, data)
    }

    public func sendDatagram(_ data: Data) {
        link?.enqueueDatagram(fromA: isA, data)
    }

    public func sendVideo(_ data: Data) {
        link?.enqueueVideo(fromA: isA, data)
    }

    /// Pacing is modeled only when the link has a bottleneck (host → viewer),
    /// so every other test gets instant, unpaced datagrams.
    public var pacesDatagrams: Bool { isA && link?.bottleneck != nil }
    public var queuedDatagramBytes: Int { isA ? link?.pacerQueuedBytes ?? 0 : 0 }
    public func setDatagramPaceRate(bytesPerSecond: Int) {
        if isA { link?.paceRate = max(1_000_000, bytesPerSecond) }
    }
    /// The host's QUIC RTT view, modeled only with a bottleneck.
    public var transportRTT: (smoothedUS: UInt64, minUS: UInt64)? { isA ? link?.modeledRTT : nil }
}

/// In-process pair of transports joined by a virtual-time event queue with
/// deterministic seeded fault injection on the datagram path (§6). Control is
/// reliable and ordered: fixed latency, never dropped, FIFO per direction.
public final class InProcLink: @unchecked Sendable {
    /// Host side by convention.
    public let a: InProcTransport
    /// Viewer side by convention.
    public let b: InProcTransport

    enum Channel { case control, datagram, video }

    private struct Event {
        var deliverUS: UInt64
        var seq: UInt64
        var channel: Channel
        var toA: Bool
        var data: Data
    }

    /// Mutable so tests can change link conditions MID-RUN (e.g. severe →
    /// healthy for auto-scale recovery); sampled per send, RNG unaffected.
    public var faults: FaultConfig
    public private(set) var nowUS: UInt64 = 0
    public private(set) var droppedDatagrams = 0
    public private(set) var duplicatedDatagrams = 0
    public private(set) var deliveredDatagrams = 0

    // MARK: Lifecycle faults (session-logic tests)

    /// Everything sent in that direction vanishes silently — no state
    /// change on either side (a half-open path: sleeping host, dead NAT
    /// binding, crashed process whose socket the OS hasn't closed).
    public var silenceAToB = false
    public var silenceBToA = false
    public private(set) var severed = false

    /// Both transports report `.ready` (the rig's "handshake done").
    public func establish() {
        guard !severed else { return }
        a.emit(.ready)
        b.emit(.ready)
    }

    /// The path dies abruptly: both sides report `.failed`, pending
    /// deliveries are discarded, later sends go nowhere.
    public func sever() {
        guard !severed else { return }
        severed = true
        pending.removeAll()
        videoSendQueue.removeAll()
        videoSendBufferBytes = 0
        a.emit(.failed)
        b.emit(.failed)
    }

    func sever(cancelledByA: Bool) {
        guard !severed else { return }
        severed = true
        pending.removeAll()
        videoSendQueue.removeAll()
        videoSendBufferBytes = 0
        (cancelledByA ? a : b).emit(.cancelled)
        (cancelledByA ? b : a).emit(.failed)
    }

    /// True if a send from this side must be dropped (severed or silenced).
    private func blocked(fromA: Bool) -> Bool {
        severed || (fromA ? silenceAToB : silenceBToA)
    }

    /// A receiver that drains host → viewer datagrams at `bytesPerSecond`
    /// through a `bufferBytes` queue (the viewer's UDP receive buffer, or a
    /// bottleneck link) — overflow drops. With one set, the host side also
    /// paces like QUICTransport: a GCRA token bucket at `paceRate` with a
    /// `DatagramPacing.burstBytes` instant burst. Virtual time, deterministic.
    ///
    /// The host's control and video streams share the same FIFO (one path
    /// out of the host's network). They are reliable, so they never drop:
    /// control joins the queue whatever its depth (it is small), and video
    /// waits in a send buffer — `videoBacklogBytes` — until the bottleneck
    /// has room for its next packet. Their queueing feeds `transportRTT`,
    /// QUIC's smoothed and minimum RTT.
    ///
    /// Deviations from QUICTransport: the video stream's congestion window
    /// is the whole buffer (a loss-based controller on a deep buffer that
    /// never drops a stream packet, so the worst case for standing queue),
    /// and the RTT is sampled per send rather than from Network.framework's
    /// periodic data-transfer reports.
    public struct Bottleneck: Sendable {
        public var bytesPerSecond: Int
        public var bufferBytes: Int
        public init(bytesPerSecond: Int, bufferBytes: Int) {
            self.bytesPerSecond = bytesPerSecond
            self.bufferBytes = bufferBytes
        }
    }
    public var bottleneck: Bottleneck?
    public internal(set) var paceRate = DatagramPacing.bytesPerSecond
    public private(set) var bottleneckDroppedDatagrams = 0
    private var paceTATUS: UInt64 = 0 // GCRA theoretical arrival time
    private var bottleneckFreeUS: UInt64 = 0
    /// Host video waiting for room in the bottleneck, oldest first, with
    /// the bytes of each not yet admitted.
    private var videoSendQueue: [(data: Data, unadmitted: Int)] = []
    private(set) var videoSendBufferBytes = 0
    private var nextVideoAdmitUS: UInt64 = 0
    /// Video enters the bottleneck a packet at a time.
    static let videoPacketBytes = 1200
    private var rttSampled = false
    private var rttSmoothedUS: UInt64 = 0
    private var rttMinUS: UInt64 = 0
    var modeledRTT: (smoothedUS: UInt64, minUS: UInt64)? {
        bottleneck != nil && rttSampled ? (rttSmoothedUS, rttMinUS) : nil
    }
    /// Time the modeled bottleneck still needs to drain what it holds (its
    /// queueing delay right now; 0 when idle or unmodeled).
    public var bottleneckBacklogUS: UInt64 { bottleneckFreeUS > nowUS ? bottleneckFreeUS - nowUS : 0 }
    /// Bytes the modeled pacer has accepted but not yet released.
    var pacerQueuedBytes: Int {
        let burstUS = UInt64(DatagramPacing.burstBytes) * 1_000_000 / UInt64(paceRate)
        guard paceTATUS > nowUS &+ burstUS else { return 0 }
        return Int((paceTATUS - nowUS - burstUS) * UInt64(paceRate) / 1_000_000)
    }

    private var pending: [Event] = []
    private var seqNo: UInt64 = 0
    private var rng: SeededRNG
    private var lastControlDeliverToA: UInt64 = 0
    private var lastControlDeliverToB: UInt64 = 0
    // The video channel is ordered within itself but NOT relative to control —
    // exactly two independent QUIC streams.
    private var lastVideoDeliverToA: UInt64 = 0
    private var lastVideoDeliverToB: UInt64 = 0

    public var pendingEventCount: Int { pending.count }

    public var pendingDatagramCount: Int {
        pending.reduce(0) { $0 + ($1.channel == .datagram ? 1 : 0) }
    }

    /// Video-channel messages still in flight (a STOP's reveal bitmap can be
    /// the last thing a settle is waiting on — no batch tracks it).
    public var pendingVideoCount: Int {
        pending.reduce(0) { $0 + ($1.channel == .video ? 1 : 0) } + videoSendQueue.count
    }

    public init(faults: FaultConfig = .none) {
        self.faults = faults
        rng = SeededRNG(seed: faults.seed)
        a = InProcTransport(isA: true)
        b = InProcTransport(isA: false)
        a.link = self
        b.link = self
    }

    func enqueueControl(fromA: Bool, _ data: Data) {
        guard !blocked(fromA: fromA) else { return }
        let latency = (faults.latencyMinUS + faults.latencyMaxUS) / 2
        var departUS = nowUS
        if fromA, let bottleneck { departUS = bottleneckAdmit(data.count, bottleneck) }
        var deliver = departUS &+ latency
        if fromA {
            deliver = max(deliver, lastControlDeliverToB)
            lastControlDeliverToB = deliver
        } else {
            deliver = max(deliver, lastControlDeliverToA)
            lastControlDeliverToA = deliver
        }
        seqNo &+= 1
        pending.append(Event(deliverUS: deliver, seq: seqNo, channel: .control, toA: !fromA, data: data))
    }

    /// Reliable, ordered, never dropped — same latency model as control but an
    /// independent FIFO (its own stream).
    func enqueueVideo(fromA: Bool, _ data: Data) {
        guard !blocked(fromA: fromA) else { return }
        if fromA, bottleneck != nil {
            videoSendQueue.append((data, data.count))
            videoSendBufferBytes += data.count
            pumpVideo()
            return
        }
        let latency = (faults.latencyMinUS + faults.latencyMaxUS) / 2
        var deliver = nowUS &+ latency
        if fromA {
            deliver = max(deliver, lastVideoDeliverToB)
            lastVideoDeliverToB = deliver
        } else {
            deliver = max(deliver, lastVideoDeliverToA)
            lastVideoDeliverToA = deliver
        }
        seqNo &+= 1
        pending.append(Event(deliverUS: deliver, seq: seqNo, channel: .video, toA: !fromA, data: data))
    }

    /// Bytes the bottleneck holds at `t`.
    private func bottleneckBacklogBytes(at t: UInt64, _ b: Bottleneck) -> Int {
        let us = bottleneckFreeUS > t ? bottleneckFreeUS - t : 0
        return Int(us * UInt64(b.bytesPerSecond) / 1_000_000)
    }

    /// Puts `bytes` of a reliable stream into the bottleneck now; returns when
    /// they have left it. The queue ahead of them is this send's RTT sample.
    private func bottleneckAdmit(_ bytes: Int, _ b: Bottleneck) -> UInt64 {
        let aheadUS = bottleneckFreeUS > nowUS ? bottleneckFreeUS - nowUS : 0
        let sample = faults.latencyMinUS &+ faults.latencyMaxUS &+ aheadUS // 2 × one way + queue
        if rttSampled {
            rttSmoothedUS = (rttSmoothedUS &* 7 &+ sample) / 8
            rttMinUS = min(rttMinUS, sample)
        } else {
            rttSampled = true
            rttSmoothedUS = sample
            rttMinUS = sample
        }
        bottleneckFreeUS = max(nowUS, bottleneckFreeUS) &+ UInt64(bytes) * 1_000_000 / UInt64(b.bytesPerSecond)
        return bottleneckFreeUS
    }

    /// Moves queued host video into the bottleneck while it has room; a
    /// message is delivered once its last byte has left. Otherwise notes
    /// when the next packet will fit (`advance` pumps again then).
    private func pumpVideo() {
        guard let b = bottleneck else { return }
        let latency = (faults.latencyMinUS + faults.latencyMaxUS) / 2
        while !videoSendQueue.isEmpty {
            let room = b.bufferBytes - bottleneckBacklogBytes(at: nowUS, b)
            let need = min(Self.videoPacketBytes, videoSendQueue[0].unadmitted)
            guard room >= need else {
                let waitUS = UInt64(need - room) * 1_000_000 / UInt64(b.bytesPerSecond)
                nextVideoAdmitUS = nowUS &+ max(1, waitUS)
                return
            }
            let take = min(room, videoSendQueue[0].unadmitted)
            let departUS = bottleneckAdmit(take, b)
            videoSendQueue[0].unadmitted -= take
            videoSendBufferBytes -= take
            if videoSendQueue[0].unadmitted == 0 {
                let data = videoSendQueue.removeFirst().data
                let deliver = max(departUS &+ latency, lastVideoDeliverToB)
                lastVideoDeliverToB = deliver
                seqNo &+= 1
                pending.append(Event(deliverUS: deliver, seq: seqNo, channel: .video, toA: false, data: data))
            }
        }
    }

    func enqueueDatagram(fromA: Bool, _ data: Data) {
        guard !blocked(fromA: fromA) else { return }
        var departUS = nowUS
        if fromA, let bottleneck {
            // Pacer (GCRA): released at once while within the burst window.
            let costUS = UInt64(data.count) * 1_000_000 / UInt64(paceRate)
            let burstUS = UInt64(DatagramPacing.burstBytes) * 1_000_000 / UInt64(paceRate)
            paceTATUS = max(paceTATUS, nowUS)
            let sendUS = max(nowUS, paceTATUS > burstUS ? paceTATUS - burstUS : 0)
            paceTATUS &+= costUS
            // Receiver/bottleneck FIFO: drop what doesn't fit its buffer.
            let backlogUS = bottleneckFreeUS > sendUS ? bottleneckFreeUS - sendUS : 0
            let backlogBytes = Int(backlogUS * UInt64(bottleneck.bytesPerSecond) / 1_000_000)
            guard backlogBytes + data.count <= bottleneck.bufferBytes else {
                bottleneckDroppedDatagrams += 1
                return
            }
            bottleneckFreeUS = max(sendUS, bottleneckFreeUS)
                &+ UInt64(data.count) * 1_000_000 / UInt64(bottleneck.bytesPerSecond)
            departUS = bottleneckFreeUS
        }
        if faults.dropPermille > 0 && rng.permille() < faults.dropPermille {
            droppedDatagrams += 1
            return
        }
        var copies = 1
        if faults.dupPermille > 0 && rng.permille() < faults.dupPermille {
            copies = 2
            duplicatedDatagrams += 1
        }
        for _ in 0..<copies {
            var deliver = departUS &+ rng.uniform(faults.latencyMinUS, faults.latencyMaxUS)
            if faults.reorderPermille > 0 && rng.permille() < faults.reorderPermille {
                deliver &+= rng.uniform(0, faults.reorderExtraMaxUS)
            }
            seqNo &+= 1
            pending.append(Event(deliverUS: deliver, seq: seqNo, channel: .datagram, toA: !fromA, data: data))
        }
    }

    /// Advances virtual time to `toUS`, delivering every due event in
    /// deterministic (deliverUS, enqueue-order) order. Deliveries may enqueue
    /// new events (e.g. an ACK in response to a datagram); the outer loop
    /// picks those up if they fall due within this advance. Batch extraction +
    /// sort keeps large in-flight queues (heavy traces) O(k log k) per step
    /// while preserving exactly the order the per-event min-scan produced.
    public func advance(toUS: UInt64) {
        // Host video waiting on the bottleneck enters it as room frees up,
        // interleaved with deliveries in time order.
        while !severed, !videoSendQueue.isEmpty, nextVideoAdmitUS <= toUS {
            deliverDue(upTo: nextVideoAdmitUS)
            nowUS = max(nowUS, nextVideoAdmitUS)
            pumpVideo()
        }
        deliverDue(upTo: toUS)
        nowUS = max(nowUS, toUS)
    }

    private func deliverDue(upTo toUS: UInt64) {
        while true {
            var due: [Event] = []
            due.reserveCapacity(64)
            var kept = 0
            for i in 0..<pending.count {
                if pending[i].deliverUS <= toUS {
                    due.append(pending[i])
                } else {
                    pending[kept] = pending[i]
                    kept += 1
                }
            }
            pending.removeLast(pending.count - kept)
            guard !due.isEmpty else { break }
            due.sort { ($0.deliverUS, $0.seq) < ($1.deliverUS, $1.seq) }
            for event in due {
                guard !severed else { break } // a callback ended the session
                nowUS = max(nowUS, event.deliverUS)
                let target = event.toA ? a : b
                switch event.channel {
                case .control:
                    target.onControl(event.data)
                case .video:
                    target.onVideo(event.data)
                case .datagram:
                    deliveredDatagrams += 1
                    target.onDatagram(event.data)
                }
            }
        }
    }
}
