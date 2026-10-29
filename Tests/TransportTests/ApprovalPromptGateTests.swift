import Testing
import GlassActTransport

/// Approval prompts (§13): one at a time, and quiet after a denial, so a
/// stream of new keys can't bury the person in dialogs.
@Suite struct ApprovalPromptGateTests {
    @Test func oneAtATime() {
        var gate = ApprovalPromptGate()
        do { let shown = gate.begin(now: 0); #expect(shown) }
        do { let shown = gate.begin(now: 1); #expect(!shown, "a second prompt waits for the first") }
        gate.end(allowed: true, now: 2)
        do { let shown = gate.begin(now: 2); #expect(shown, "an Allow leaves no quiet time") }
    }

    /// Each Don't Allow quiets prompts for twice as long as the one before,
    /// up to the cap.
    @Test func denialsQuietItDoublingToACap() {
        var gate = ApprovalPromptGate()
        var now = 0.0
        do { let shown = gate.begin(now: now); #expect(shown) }
        for k in 0..<10 {
            gate.end(allowed: false, now: now)
            let quiet = min(ApprovalPromptGate.maxQuietSeconds, ApprovalPromptGate.firstQuietSeconds * Double(1 << k))
            do { let shown = gate.begin(now: now + quiet - 0.5); #expect(!shown, "denial \(k + 1): still quiet") }
            do { let shown = gate.begin(now: now + quiet); #expect(shown, "denial \(k + 1): \(quiet) s") }
            now += quiet
        }
    }

    @Test func anAllowResetsTheQuiet() {
        var gate = ApprovalPromptGate()
        for i in 0..<5 {
            do { let shown = gate.begin(now: Double(i) * 1000); #expect(shown) }
            gate.end(allowed: false, now: Double(i) * 1000)
        }
        do { let shown = gate.begin(now: 4000 + ApprovalPromptGate.firstQuietSeconds); #expect(!shown) }
        do { let shown = gate.begin(now: 10_000); #expect(shown) }
        gate.end(allowed: true, now: 10_000)
        do { let shown = gate.begin(now: 10_001); #expect(shown) }
        gate.end(allowed: false, now: 10_001)
        do { let shown = gate.begin(now: 10_001 + ApprovalPromptGate.firstQuietSeconds); #expect(shown, "back to the first quiet time") }
    }
}
