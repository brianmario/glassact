import Foundation
import Testing
import GlassActCore
import GlassActWire
import GlassActTestSupport

/// Codec routing memory (design from BENCHMARKS "Codec routing
/// measurement"): the VP8L probe's own outcome, remembered per tile position
/// with exponential backoff, is the photographic-content classifier — no
/// cheap static signal separates AA text from photo content, but class is
/// positionally coherent across churn.
@Suite struct RoutingTests {
    private func ackAll(_ host: HostEngine, _ capture: CaptureTransport, nowUS: UInt64) {
        for ack in fullAcks(for: capture.sentDatagrams) {
            host.handleControl(ack, nowUS: nowUS)
        }
    }

    /// Photographic (VP8L-hostile) churn: after one losing probe per tile the
    /// probes stop, re-fire only when the backoff countdown expires, and the
    /// backoff doubles on repeated failure.
    @Test func hostileTilesBackOffAndDouble() {
        var rng = SplitMix64(seed: 401)
        let (host, capture) = makeRunningHost(width: 128, height: 128) // 4 tiles
        var frame = TestFrame(width: 128, height: 128)
        var now: UInt64 = 10_000

        func tick() {
            frame.fillRandom(&rng) // fresh noise: every tile qualifies, VP8L loses
            frame.encode(host: host, nowUS: now)
            ackAll(host, capture, nowUS: now + 1_000)
            now += 10_000
        }

        tick()
        #expect(host.stats.webpProbes == 4, "cold tick probes every tile")
        #expect(host.stats.webpProbesSkipped == 0)

        // Backoff window 1: 8 skipped probes per tile.
        for _ in 0..<8 { tick() }
        #expect(host.stats.webpProbes == 4, "hostile tiles must not be re-probed inside the window")
        #expect(host.stats.webpProbesSkipped == 32)

        tick()
        #expect(host.stats.webpProbes == 8, "countdown expiry re-probes")

        // Window 2 doubled to 16: still only skips until it expires.
        for _ in 0..<16 { tick() }
        #expect(host.stats.webpProbes == 8)
        #expect(host.stats.webpProbesSkipped == 32 + 64)
        tick()
        #expect(host.stats.webpProbes == 12, "second expiry probes again (backoff doubled, capped later)")
    }

    /// Class change recovery: a hostile position whose content turns
    /// VP8L-friendly is re-probed after one backoff window, the win clears the
    /// backoff, and probing resumes every tick.
    @Test func classChangeRecoversAfterBackoffWindow() {
        var rng = SplitMix64(seed: 402)
        let (host, capture) = makeRunningHost(width: 128, height: 128)
        var frame = TestFrame(width: 128, height: 128)
        var now: UInt64 = 10_000

        func tick() {
            frame.encode(host: host, nowUS: now)
            ackAll(host, capture, nowUS: now + 1_000)
            now += 10_000
        }

        // One noise tick marks all 4 positions hostile.
        frame.fillRandom(&rng)
        tick()
        #expect(host.stats.webpProbes == 4)

        // Smooth 2D gradient, shifting every tick: LZ4-hostile (no byte
        // repeats) but VP8L-trivial (left-predictor residuals ~constant) —
        // the AA-text-like class the router must win back.
        func gradient(_ t: Int) {
            for py in 0..<128 {
                for px in 0..<128 {
                    let o = (py * 128 + px) * 4
                    frame.bytes[o] = UInt8((px + t) & 0xFF)
                    frame.bytes[o + 1] = UInt8((py &* 3 + t) & 0xFF)
                    frame.bytes[o + 2] = UInt8((px &+ py &+ t) & 0xFF)
                    frame.bytes[o + 3] = 255
                }
            }
        }
        for t in 1...8 { // backoff window: probes stay off
            gradient(t)
            tick()
        }
        #expect(host.stats.webpProbes == 4, "class change is invisible until the window expires")
        gradient(9)
        tick()
        #expect(host.stats.webpProbes == 8, "window expiry re-probes the changed class")
        gradient(10)
        tick()
        #expect(host.stats.webpProbes == 12, "a winning probe clears the backoff — probing resumes")
        gradient(11)
        tick()
        #expect(host.stats.webpProbes == 16)
    }
}
