import Foundation
import Synchronization
import Testing
import GlassActTransport
import GlassActTestSupport

/// A batch the governor admits whole (its bucket holds one full-screen
/// change, up to ~14k datagrams) must reach the viewer, not the floor.
/// Unpaced, the whole batch left in ~0.01 ms and the viewer's UDP receive
/// buffer (~768 KB on macOS) kept ~675 datagrams of it: 83 % of a 4000-
/// datagram burst lost on loopback, recovered only by timeout + re-send.
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
        #expect(got * 100 >= count * 99, "delivered \(got)/\(count)")
    }
}
