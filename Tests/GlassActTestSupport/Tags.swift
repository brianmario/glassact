public import Testing
import Foundation

extension Tag {
    /// Real QUIC over loopback: real sockets, real time, TLS handshakes.
    @Tag public static var quic: Self
    /// Over ~10 s serially (long simulated sessions, 5K-scale floods).
    @Tag public static var slow: Self
}

extension Trait where Self == ConditionTrait {
    /// Skipped when `GLASSACT_FAST` is set (`just test-fast`). `swift test` has
    /// no tag filter, so the fast lane keys on this trait; pair it with
    /// `.tags(.quic)` / `.tags(.slow)` for Xcode's navigator.
    public static var notInFastLane: Self {
        .enabled(if: ProcessInfo.processInfo.environment["GLASSACT_FAST"] == nil, "GLASSACT_FAST: fast lane")
    }
}
