import Foundation
import Network
import Synchronization
import Testing
@testable import GlassActTransport
import GlassActCore
import GlassActTestSupport

/// The video send gate on a thin link. A host offers ~10 Mbps of video into
/// a 3 Mbps bottleneck (64 KB drop-tail buffer, 80 ms base RTT) — the shape
/// of a remote session on airport Wi-Fi (2.5 Mbps, where a 512 KB byte gate
/// gives 1.6–2.2 s p50 glass-to-glass). It asserts that a byte gate fails
/// (seconds of lag) and the time gate, `VideoRateController` fed as
/// `HostEngine` feeds it, passes.
///
/// The transport's contentProcessed backlog matches the stream report's
/// sentApplicationByteCount to within a frame, so the host can always see
/// its send queue; what matters is limiting it by time, not bytes. The
/// report's smoothed − minimum RTT shows the bottleneck's queue per ACK.
@Suite(.serialized, .tags(.quic, .slow), .notInFastLane) struct VideoSendGateTests {
    static let frameBytes = 20_000

    /// Per-frame one-way delay (ms), sorted, for frames sent after the first
    /// `settleS` seconds (startup — slow-start drops at the bottleneck and
    /// their retransmits, before any rate is measured — is reported
    /// separately by the caller via settleS = 0). `gate` returns the size of the
    /// frame to send this tick (0 = skip) — the encoder's output under its
    /// bitrate target.
    private func run(settleS: Double, gate: (_ backlog: Int, _ host: QUICTransport, _ nowUS: UInt64, _ handed: Int) -> Int) throws -> [Double] {
        let (identity, fingerprint) = try QUICLoopbackTests.makeTestIdentity()
        let serverQueue = DispatchQueue(label: "g.server"), clientQueue = DispatchQueue(label: "g.client")
        let server = try QUICServer(port: 0, identity: identity, queue: serverQueue)
        defer { server.cancel() }
        let listening = DispatchSemaphore(value: 0)
        server.onReady = { listening.signal() }
        nonisolated(unsafe) var host: QUICTransport?
        let hostReady = DispatchSemaphore(value: 0)
        server.onTransport = { t in
            host = t
            t.onState = { if $0 == .ready { hostReady.signal() } }
            t.start()
        }
        server.start()
        guard listening.wait(timeout: .now() + 5) == .success, let port = server.port, let dport = server.datagramPort else { return [] }
        let r1 = try LossyRelay(targetPort: port, dropPermille: 0, oneWayDelayMS: 40, seed: 1,
                                rateBytesPerSecond: 375_000, queueBytes: 64_000)
        let r2 = try LossyRelay(targetPort: dport, dropPermille: 0, oneWayDelayMS: 40, seed: 2)
        defer { r1.cancel(); r2.cancel() }
        let client = QUICTransport.connect(host: "127.0.0.1", port: r1.port, fingerprint: fingerprint,
                                           datagramPort: r2.port, queue: clientQueue)
        // Frame = [len u32][sent_us u64][fill]; the stream delivers
        // arbitrary chunks, so reassemble by length.
        let delays = Mutex<[Double]>([])
        let settleUS = Atomic<UInt64>(.max)
        nonisolated(unsafe) var pending = [UInt8]()
        client.onVideo = { data in
            pending.append(contentsOf: data)
            while pending.count >= 12 {
                let len = Int(pending.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                guard pending.count >= len else { break }
                let sent = pending.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
                let now = MonotonicClock.nowUS
                if sent >= settleUS.load(ordering: .relaxed) {
                    delays.withLock { $0.append(Double(now &- sent) / 1000) }
                }
                pending.removeFirst(len)
            }
        }
        client.start()
        defer { client.cancel() }
        guard hostReady.wait(timeout: .now() + 15) == .success, let host else { Issue.record("no session"); return [] }
        var handed = 0
        let t0 = Date()
        settleUS.store(MonotonicClock.nowUS + UInt64(settleS * 1_000_000), ordering: .relaxed)
        while Date().timeIntervalSince(t0) < 6 {
            let now = MonotonicClock.nowUS
            let size = gate(host.videoBacklogBytes, host, now, handed)
            if size > 0 {
                var frame = [UInt8](repeating: 7, count: size)
                frame.withUnsafeMutableBytes {
                    $0.storeBytes(of: UInt32(size), as: UInt32.self)
                    $0.storeBytes(of: now, toByteOffset: 4, as: UInt64.self)
                }
                host.sendVideo(Data(frame))
                handed += size
            }
            Thread.sleep(forTimeInterval: 1.0 / 60) // 20 KB × 60 Hz ≈ 9.6 Mbps offered
        }
        Thread.sleep(forTimeInterval: 1.0) // let the tail land (it still counts)
        return delays.withLock { $0 }.sorted()
    }

    private func p(_ sorted: [Double], _ q: Int) -> Double {
        sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1, sorted.count * q / 100)]
    }

    @Test func timeGateBoundsVideoLatencyOnAThinLink() throws {
        // Baseline byte gate: 512 KB of backlog once SRTT > 50 ms.
        let byteGate = try run(settleS: 1.5) { backlog, _, _, _ in backlog < 512 << 10 ? Self.frameBytes : 0 }
        // The time gate, fed exactly as HostEngine feeds it.
        nonisolated(unsafe) var c = VideoRateController()
        nonisolated(unsafe) var lastHanded = 0
        // Steady state: from 3 s — the startup ramp (3 Mbit/s, ×1.25 per clean
        // window) overshoots a link this thin once, inside the first seconds.
        let timeGate = try run(settleS: Double(ProcessInfo.processInfo.environment["GLASSACT_RIG_SETTLE"] ?? "") ?? 3) { backlog, host, now, handed in
            c.noteHanded(handed - lastHanded)
            lastHanded = handed
            let q = host.transportRTT.map { $0.smoothedUS > $0.minUS ? $0.smoothedUS - $0.minUS : 0 }
            if c.observe(nowUS: now, backlogBytes: backlog, networkQueueUS: q), ProcessInfo.processInfo.environment["GLASSACT_TRACE_GATE"] != nil {
                print("trace t=\((now / 1000) % 100000) cap=\(c.bitrateCap ?? -1) rate=\(c.rate) backlog=\(backlog) q=\(q.map { $0 / 1000 } ?? 0)ms limit=\(c.queueLimitBytes) backoffs=\(c.backoffs)")
            }
            guard c.allowsFrame(backlogBytes: backlog) else { return 0 }
            // The encoder aims at its cap (VT's average bitrate), at 60 Hz.
            return c.bitrateCap.map { min(Self.frameBytes, max(2_000, $0 / 8 / 60)) } ?? Self.frameBytes
        }
        print("byte gate: n=\(byteGate.count) p50=\(p(byteGate, 50)) p95=\(p(byteGate, 95)) ms; time gate: n=\(timeGate.count) p50=\(p(timeGate, 50)) p95=\(p(timeGate, 95)) ms rate=\(c.rate) B/s")
        #expect(p(byteGate, 95) > 1000, "rig must reproduce the byte gate's seconds of lag (p95 \(p(byteGate, 95)) ms)")
        #expect(p(timeGate, 95) < 500, "p95 one-way video delay \(p(timeGate, 95)) ms")
        // Throughput is the link's, not starved: ≥ 70 % of 3 Mbps over the
        // scored 3 s.
        #expect(timeGate.count * Self.frameBytes > 375_000 * 3 * 7 / 10, "delivered \(timeGate.count) frames")
    }
}
