import Testing
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Single-window mode: when the shared window closes on the host, the
/// host tells the viewer the session is over (WINDOW_CONTROL endSession,
/// host → viewer) so it can show why instead of redialing.
@Suite struct SharedWindowClosedTests {
    @Test func hostEndingTheSessionReachesTheViewer() {
        let h = Harness(width: 320, height: 240)
        var reasons: [String] = []
        h.viewer.onHostEndedSession = { reasons.append($0) }
        h.host.sendSharedWindowClosed()
        h.run(untilUS: h.now + 100_000)
        #expect(reasons.count == 1)
        #expect(h.viewer.state == .running, "the viewer decides what to do; the engine doesn't fail")
    }
}
