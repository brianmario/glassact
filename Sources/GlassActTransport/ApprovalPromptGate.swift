/// Bounds the Host's approval prompts (§13), which any key can ask for
/// under "Ask", and an agent's key under "Sign in" too: one on screen at a
/// time, and after a Don't Allow none for a while: `firstQuietSeconds`,
/// doubling with each further denial up to `maxQuietSeconds`. An Allow
/// resets it. A key turned away here is refused as usual; its dialer's next
/// retry asks again. Pure; time is passed in.
public struct ApprovalPromptGate: Sendable {
    public static let firstQuietSeconds = 10.0
    public static let maxQuietSeconds = 600.0

    private var showing = false
    private var denials = 0
    private var quietUntil = 0.0

    public init() {}

    /// Whether a prompt may go up now; if so, it counts as showing until `end`.
    public mutating func begin(now: Double) -> Bool {
        guard !showing, now >= quietUntil else { return false }
        showing = true
        return true
    }

    public mutating func end(allowed: Bool, now: Double) {
        showing = false
        if allowed {
            denials = 0
            quietUntil = 0
        } else {
            quietUntil = now + min(Self.maxQuietSeconds, Self.firstQuietSeconds * Double(1 << min(denials, 16)))
            denials += 1
        }
    }
}
