/// §3.6 — u32 wraparound-safe sequence comparison (serial arithmetic).
public enum Serial {
    /// True iff `a` is strictly newer than `b`. Wraparound-safe: e.g.
    /// `newer(0, than: UInt32.max)` is true. When the circular distance is
    /// exactly 2^31 the ordering is undefined by serial arithmetic; this
    /// returns false in both directions (the update is dropped, which is safe:
    /// live sequences advance by small steps and can never legitimately jump
    /// half the space).
    @inline(__always)
    public static func newer(_ a: UInt32, than b: UInt32) -> Bool {
        a != b && (a &- b) < 0x8000_0000
    }
}
