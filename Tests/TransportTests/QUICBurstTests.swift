import Foundation
import Synchronization
import Testing
import GlassActTransport
import GlassActTestSupport

/// A batch the governor admits whole (its bucket holds one full-screen
/// change, up to ~14k datagrams) must reach the viewer, not the floor.
/// Unpaced, the whole batch would leave in ~0.01 ms and the viewer's UDP
/// receive buffer (~768 KB on macOS) would keep ~675 datagrams of it: 83 %
/// of a 4000-datagram burst lost on loopback, recovered only by timeout +
/// re-send.
@Suite(.serialized, .tags(.quic), .notInFastLane) struct QUICBurstTests {
    @Test(arguments: [4_000, 12_000])
    func largeBurstArrivesNearlyWhole(count: Int) throws {
        let (identity, fingerprint) = try QUICLoopbackTests.makeTestIdentity()
        let received = Atomic<Int>(0)
        guard let session = try QUICLoopbackTests.makeSession(
            fingerprint: fingerprint, identity: identity,
            configureHost: { _ in },
            configureClient: { client in
                client.onDatagram = { _ in received.add(1, ordering: .relaxed) }
            }
        ) else {
            Issue.record("QUIC loopback session failed to become ready")
            return
        }
        defer {
            session.client.cancel()
            session.host.cancel()
            session.server.cancel()
        }
        let payload = Data(repeating: 0xAB, count: min(1150, session.host.maxDatagramSize))
        session.host.sendDatagrams([Data](repeating: payload, count: count))

        let deadline = Date().addingTimeInterval(10)
        var last = -1
        while Date() < deadline { // until delivery stops moving
            Thread.sleep(forTimeInterval: 0.25)
            let now = received.load(ordering: .relaxed)
            if now == count || now == last { break }
            last = now
        }
        let got = received.load(ordering: .relaxed)
        let dropped = session.serverQueue.sync { session.host.pacingDroppedDatagrams }
        #expect(dropped == 0, "the pacing queue must hold a whole governor-sized batch")
        // Unpaced, about a third arrives (1347/4000, 4202/12000 on an M4 Pro,
        // 2026-10-26). GitHub's macOS VMs lose a few percent of a
        // paced burst now and then, with other QUIC suites running alongside
        // (94.1–98.1 % in 3 of 100 CI runs, 2026-10-23..26; 100 % locally,
        // even with every core busy), so the bar sits well above unpaced and
        // below that noise.
        #expect(got * 100 >= count * 90, "delivered \(got)/\(count)")
    }
}
