import Foundation
import Testing
import GlassActCore
import GlassActWire
import GlassActTestSupport

/// A batch's timeout clock starts when it is handed to the transport, not
/// when its tick started. Found over real QUIC: a 2048² noise cold start
/// spent 2.3 s in one encode tick, so its batch was "2.3 s old" at the next
/// tick and timed out before the viewer had ACKed anything — every tile sent
/// twice, and the adaptive pace halved itself on the phantom loss.
@Suite struct SendStampTests {
    /// Returns (tiles + keyframes sent, pace decreases) after a cold start
    /// whose encode tick "took" `stallUS`, then a settle.
    private func coldStartAfterSlowTick(sendClock: Bool, stallUS: UInt64) -> (sends: Int, exact: Bool) {
        var rng = SplitMix64(seed: 6101)
        let h = Harness(width: 320, height: 320, sendClock: sendClock)
        h.frame.fillRandom(&rng)
        let tickStart = h.now
        h.run(untilUS: tickStart + stallUS) // the encode's wall time passes…
        h.frame.encode(host: h.host, nowUS: tickStart) // …inside a tick stamped at its start
        let exact = h.settle(maxSimMS: 30_000) && h.canvasMatchesFrame()
        return (h.host.stats.tilesSent + h.host.stats.keyframesSent, exact)
    }

    @Test func slowTickDoesNotTimeOutItsOwnBatch() {
        let reference = coldStartAfterSlowTick(sendClock: true, stallUS: 0)
        let slow = coldStartAfterSlowTick(sendClock: true, stallUS: 3_000_000)
        #expect(reference.exact && slow.exact)
        #expect(slow.sends == reference.sends,
                "a slow tick re-sent its own batch: \(slow.sends) sends vs \(reference.sends)")
    }

    /// Callers pass one `nowUS` to encodeTick and then tick; a send stamp
    /// later than that must read as "just sent", not wrap to a huge age.
    @Test func stampLaterThanCallerNowIsNotAnAncientBatch() {
        #expect(HostEngine.elapsedUS(1_000, since: 5_000) == 0)
        #expect(HostEngine.elapsedUS(5_000, since: 1_000) == 4_000)
    }

    /// Geometry negotiation (§4.10): HELLO → HELLO_OK asking for a switch → the
    /// app applies it (seconds: a display mode change) → final HELLO →
    /// HELLO_OK. The SRTT seed is the FINAL exchange's round trip; measured
    /// from the first HELLO it seeded SRTT with the whole negotiation, and
    /// batch timeouts (3 × SRTT) ran seconds long until PINGs decayed it.
    @Test func renegotiatedHandshakeSeedsSRTTFromTheFinalHello() {
        let capture = CaptureTransport()
        let host = HostEngine(width: 640, height: 480, transport: capture)
        host.onResizeRequested = { _, _, _, _ in }
        host.start(nowUS: 0)
        let switchRequest = ControlMessage.helloOK(ver: WireVersion.current, caps: 0,
                                                   geoMode: 1, geoWidth: 1280, geoHeight: 800, geoScale: 1)
        host.handleControl(Data(switchRequest.encoded()), nowUS: 20_000)
        host.reofferHelloFinal(nowUS: 3_000_000) // the switch took ~3 s
        let final = ControlMessage.helloOK(ver: WireVersion.current, caps: 0,
                                           geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0)
        host.handleControl(Data(final.encoded()), nowUS: 3_020_000)
        #expect(host.state == .running)
        #expect(host.srttUS == 20_000, "SRTT seeded with \(host.srttUS) µs")
    }
}
