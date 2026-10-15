import Foundation
import Testing
import GlassActCore
import GlassActTransport

/// Session lifecycle: watchdogs, how a session ended, the redial budget —
/// driven by real engines over the virtual-time link with lifecycle faults
/// (sever, half-open silence).
@Suite struct SessionWatchdogTests {
    /// Runs `h` forward in 100 ms steps (engines ticked every 1 ms by
    /// `run`), returning the first non-ok verdict and when it fired.
    private func firstHostVerdict(_ h: Harness, _ dog: inout HostSessionWatchdog,
                                  forUS: UInt64) -> (HostSessionWatchdog.Verdict, UInt64)? {
        let end = h.now + forUS
        while h.now < end {
            h.run(untilUS: h.now + 100_000)
            let v = dog.check(h.host, nowUS: h.now)
            if v != .ok { return (v, h.now) }
        }
        return nil
    }

    @Test func hostResetsAViewerThatStopsAnsweringPings() {
        let h = Harness()
        var dog = HostSessionWatchdog()
        #expect(firstHostVerdict(h, &dog, forUS: 20_000_000) == nil, "a live viewer is never reset")
        h.link.silenceBToA = true // the viewer's PONGs (and ACKs) stop arriving
        let silencedAt = h.now
        guard let (verdict, at) = firstHostVerdict(h, &dog, forUS: 20_000_000) else {
            Issue.record("an unresponsive viewer was never reset")
            return
        }
        #expect(verdict == .reset(reason: "viewer unresponsive (no PONG for 10 s)"))
        // Last PONG ≤ 1 s before the silence, so the reset lands at 9–11.2 s.
        #expect(at - silencedAt >= 9_000_000 && at - silencedAt <= 11_200_000, "reset after \(at - silencedAt) µs")
    }

    @Test func hostResetsAViewerThatNeverFinishesTheHandshake() {
        let link = InProcLink()
        let host = HostEngine(width: 128, height: 128, transport: link.a)
        link.silenceBToA = true // HELLO_OK never arrives
        let viewer = ViewerEngine(transport: link.b)
        link.b.onControl = { viewer.handleControl($0, nowUS: link.nowUS) }
        host.start(nowUS: 0)
        var dog = HostSessionWatchdog()
        var fired: (HostSessionWatchdog.Verdict, UInt64)?
        var t: UInt64 = 0
        while fired == nil && t < 30_000_000 {
            t += 100_000
            link.advance(toUS: t)
            host.tick(nowUS: t)
            let v = dog.check(host, nowUS: t)
            if v != .ok { fired = (v, t) }
        }
        #expect(fired?.0 == .reset(reason: "viewer never completed the handshake"))
        #expect(fired.map { $0.1 > HostSessionWatchdog.handshakeTimeoutUS } == true)
        // The clock starts at the watchdog's first check (t = 100 ms).
        #expect(fired.map { $0.1 <= HostSessionWatchdog.handshakeTimeoutUS + 200_000 } == true)
    }

    /// An in-session geometry rebuild swaps the engine: its handshake gets a
    /// fresh deadline instead of inheriting the old session's clock.
    @Test func engineSwapRestartsTheHostPhaseClock() {
        let h = Harness()
        var dog = HostSessionWatchdog()
        #expect(firstHostVerdict(h, &dog, forUS: 14_000_000) == nil)
        h.link.silenceBToA = true
        h.reconfigure(width: 256, height: 192) // new engine, re-HELLO never answered
        // A reset must come from the NEW engine's 15 s handshake deadline,
        // not immediately from the old engine's accumulated time.
        let swappedAt = h.now
        guard let (verdict, at) = firstHostVerdict(h, &dog, forUS: 20_000_000) else {
            Issue.record("stalled rebuild never reset")
            return
        }
        #expect(verdict == .reset(reason: "viewer never completed the handshake"))
        #expect(at - swappedAt >= HostSessionWatchdog.handshakeTimeoutUS - 400_000)
    }

    @Test func viewerGivesUpOnADialThatNeverConnects() {
        let link = InProcLink()
        let viewer = ViewerEngine(transport: link.b)
        var dog = ViewerSessionWatchdog(dialStartUS: 0)
        var verdicts: [(ViewerSessionWatchdog.Verdict, UInt64)] = []
        for t in stride(from: UInt64(100_000), through: 12_000_000, by: 100_000) {
            let v = dog.check(viewer, nowUS: t)
            if v != .ok { verdicts.append((v, t)) }
        }
        #expect(verdicts.count == 1, "reported once")
        #expect(verdicts.first?.0 == .connectTimedOut)
        #expect(verdicts.first.map { $0.1 > ViewerSessionWatchdog.connectTimeoutUS } == true)
    }

    @Test func viewerNoticesASilentHost() {
        let h = Harness()
        h.link.establish()
        var dog = ViewerSessionWatchdog(dialStartUS: 0)
        dog.transportReady(nowUS: h.now)
        // 30 s of an idle but healthy session: host PINGs at 1 Hz keep it alive.
        let healthyUntil = h.now + 30_000_000
        while h.now < healthyUntil {
            h.run(untilUS: h.now + 100_000)
            #expect(dog.check(h.viewer, nowUS: h.now) == .ok)
        }
        h.link.silenceAToB = true // host → viewer path dies silently
        let silencedAt = h.now
        var fired: UInt64?
        while fired == nil && h.now < silencedAt + 20_000_000 {
            h.run(untilUS: h.now + 100_000)
            if dog.check(h.viewer, nowUS: h.now) == .hostUnresponsive { fired = h.now }
        }
        guard let fired else {
            Issue.record("a silent host was never noticed")
            return
        }
        #expect(fired - silencedAt >= 9_000_000 && fired - silencedAt <= 11_200_000)
        #expect(dog.check(h.viewer, nowUS: h.now + 1_000_000) == .ok, "reported once")
    }
}

@Suite struct InProcLifecycleTests {
    final class Log {
        var a: [TransportState] = []
        var b: [TransportState] = []
    }

    private func wired() -> (InProcLink, Log) {
        let link = InProcLink()
        let log = Log()
        link.a.onState = { log.a.append($0) }
        link.b.onState = { log.b.append($0) }
        return (link, log)
    }

    @Test func cancelIsCancelledHereAndFailedThereExactlyOnce() {
        let (link, log) = wired()
        link.establish()
        var delivered = 0
        link.b.onControl = { _ in delivered += 1 }
        link.a.sendControl(Data([1]))
        link.a.cancel()
        link.a.cancel()
        link.b.cancel()
        link.a.sendControl(Data([2]))
        link.advance(toUS: 1_000_000)
        #expect(log.a == [.ready, .cancelled])
        #expect(log.b == [.ready, .failed])
        #expect(delivered == 0, "nothing is delivered after the session ended")
    }

    @Test func severFailsBothSidesOnce() {
        let (link, log) = wired()
        link.establish()
        link.sever()
        link.sever()
        link.establish()
        #expect(log.a == [.ready, .failed] && log.b == [.ready, .failed])
    }

    @Test func silenceIsOneWayAndStateless() {
        let (link, log) = wired()
        link.establish()
        var toB = 0, toA = 0
        link.b.onControl = { _ in toB += 1 }
        link.a.onControl = { _ in toA += 1 }
        link.silenceAToB = true
        link.a.sendControl(Data([1]))
        link.b.sendControl(Data([2]))
        link.advance(toUS: 1_000_000)
        #expect(toB == 0 && toA == 1)
        #expect(log.a == [.ready] && log.b == [.ready], "a half-open path changes no state")
    }
}

@Suite struct SessionEndTests {
    private let pin = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)

    @Test func deliberateStopIsNeverAFailure() {
        #expect(ViewerSessionEnd.classify(stopped: true, everReady: false, pinnedHostFingerprint: pin,
                                          observedHostFingerprint: other, failReason: "x",
                                          verificationCode: "C") == .stopped)
    }

    @Test func pinnedHostPresentingAnotherKeyIsNotRetried() {
        #expect(ViewerSessionEnd.classify(stopped: false, everReady: false, pinnedHostFingerprint: pin,
                                          observedHostFingerprint: other, failReason: "tls",
                                          verificationCode: "C")
                == .hostKeyChanged(expected: pin, presented: other))
    }

    @Test func refusedFirstDialCarriesTheVerificationCodeHint() {
        // TOFU dial (no pin): the host saw our key and refused it — unapproved.
        let end = ViewerSessionEnd.classify(stopped: false, everReady: false, pinnedHostFingerprint: "",
                                            observedHostFingerprint: other, failReason: "tls",
                                            verificationCode: "ABCD-EFGH-JKMN-PQRS")
        #expect(end == .lost(reason: "tls", hint: "new viewer? Allow it on the host if it shows code ABCD-EFGH-JKMN-PQRS"))
    }

    @Test func establishedSessionLossHasNoHint() {
        #expect(ViewerSessionEnd.classify(stopped: false, everReady: true, pinnedHostFingerprint: pin,
                                          observedHostFingerprint: pin, failReason: "idle timeout",
                                          verificationCode: "C") == .lost(reason: "idle timeout", hint: nil))
        // A host that never answered at all: no key seen, no hint.
        #expect(ViewerSessionEnd.classify(stopped: false, everReady: false, pinnedHostFingerprint: "",
                                          observedHostFingerprint: nil, failReason: "timeout",
                                          verificationCode: nil) == .lost(reason: "timeout", hint: nil))
    }

    @Test func reconnectBudgetIsBoundedAndResetByASession() {
        var policy = ReconnectPolicy()
        for n in 1...ReconnectPolicy.maxAttempts { #expect(policy.nextAttempt() == n) }
        #expect(policy.nextAttempt() == nil, "budget spent")
        policy.sessionEstablished()
        #expect(policy.nextAttempt() == 1)
    }
}
