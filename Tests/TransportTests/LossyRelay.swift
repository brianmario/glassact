import Foundation
import Network
import Synchronization

/// A user-space UDP relay for QUIC tests: forwards every packet between a
/// client and a target port on loopback, dropping a seeded fraction and
/// adding fixed one-way delay — packet loss without touching the system's
/// network configuration. One relay per tunnel (control, datagram).
/// Optionally a bottleneck: each direction drains at `rateBytesPerSecond`
/// through a drop-tail queue of `queueBytes` — a thin access link with a
/// finite buffer, so a sender that outruns it builds a standing queue here
/// (and sees it as RTT) until the buffer overflows.
final class LossyRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.relay", qos: .userInteractive)
    private let listener: NWListener
    private let targetPort: UInt16
    private let dropPermille: Int
    private let delay: DispatchTimeInterval
    private let rng: Mutex<UInt64>
    let forwarded = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    private var pairs: [NWConnection] = []
    private let rateBytesPerSecond: Int
    private let queueBytes: Int
    /// Per direction (keyed by the sending connection): when the bottleneck
    /// finishes serializing what is already queued. `queue` only.
    private var busyUntil: [ObjectIdentifier: DispatchTime] = [:]

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(targetPort: UInt16, dropPermille: Int, oneWayDelayMS: Int, seed: UInt64,
         rateBytesPerSecond: Int = 0, queueBytes: Int = 0) throws {
        self.rateBytesPerSecond = rateBytesPerSecond
        self.queueBytes = queueBytes
        self.targetPort = targetPort
        self.dropPermille = dropPermille
        self.delay = .milliseconds(oneWayDelayMS)
        rng = Mutex(seed | 1)
        listener = try NWListener(using: .udp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] inbound in self?.adopt(inbound) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func cancel() {
        queue.sync {
            listener.cancel()
            for c in pairs { c.cancel() }
            pairs.removeAll()
        }
    }

    private func adopt(_ inbound: NWConnection) {
        let outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!, using: .udp)
        pairs += [inbound, outbound]
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    private func shouldDrop() -> Bool {
        guard dropPermille > 0 else { return false }
        return rng.withLock { s in
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Int(s % 1000) < dropPermille
        }
    }

    /// When this packet leaves the bottleneck, or nil if its buffer is full.
    private func bottleneckDeparture(_ from: NWConnection, bytes: Int) -> DispatchTime? {
        let now = DispatchTime.now()
        guard rateBytesPerSecond > 0 else { return now }
        let key = ObjectIdentifier(from)
        let start = max(now, busyUntil[key] ?? now)
        let queuedNS = start.uptimeNanoseconds - now.uptimeNanoseconds
        if queueBytes > 0, Int(queuedNS) / 1000 * rateBytesPerSecond / 1_000_000 > queueBytes { return nil }
        let done = start + .nanoseconds(bytes * 1_000_000_000 / rateBytesPerSecond)
        busyUntil[key] = done
        return done
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if self.shouldDrop() {
                    self.dropped.add(1, ordering: .relaxed)
                } else if let departure = self.bottleneckDeparture(from, bytes: data.count) {
                    self.forwarded.add(1, ordering: .relaxed)
                    self.queue.asyncAfter(deadline: departure + self.delay) {
                        to.send(content: data, completion: .contentProcessed { _ in })
                    }
                } else {
                    self.dropped.add(1, ordering: .relaxed) // buffer full (drop-tail)
                }
            }
            if error == nil { self.pump(from: from, to: to) }
        }
    }
}
