import Testing
@testable import GlassActCore

/// The VP8L effort policy (BENCHMARKS "VP8L effort sweep"): small ticks keep
/// effort 4, bursts drop to 1; keyframes use 0 on a fast send rate, 1 below.
@Suite struct EffortPolicyTests {
    @Test func tileEffortFollowsTickSize() {
        let (host, _) = makeRunningHost(width: 256, height: 256)
        #expect(host.tileEffort(qualifiedTiles: 3) == HostEngine.vp8lSmallTickEffort)
        #expect(host.tileEffort(qualifiedTiles: HostEngine.vp8lBurstTiles) == HostEngine.vp8lSmallTickEffort)
        #expect(host.tileEffort(qualifiedTiles: HostEngine.vp8lBurstTiles + 1) == HostEngine.vp8lBurstEffort)
        host.vp8lEffort = 6
        #expect(host.tileEffort(qualifiedTiles: 500) == 6, "an override wins")
    }

    @Test func keyframeEffortFollowsTheSendRate() {
        let (host, _) = makeRunningHost(width: 256, height: 256)
        #expect(host.currentKeyframeEffort == HostEngine.keyframeFastEffort, "auto starts at 8.4 MB/s")
        host.rateLimit = .megabits(8) // 1 MB/s: bytes dominate time to exact
        #expect(host.currentKeyframeEffort == HostEngine.keyframeSlowEffort)
        host.keyframeEffort = 4
        #expect(host.currentKeyframeEffort == 4, "an override wins")
    }
}
