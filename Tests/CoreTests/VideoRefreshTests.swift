import Foundation
import Testing
import GlassActWire
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Re-sharpening keyframes. VideoToolbox never re-codes content that stops
/// changing, so a large change coded under a thin budget (the startup cap,
/// a blank first capture) stays soft for as long as the region lives —
/// minutes of unreadable text while one panel animates (BENCHMARKS.md "Soft
/// video for minutes"). The host owes one keyframe once the region goes
/// quiet after large changes.
@Suite struct VideoRefreshTests {
    /// Records when (capture µs) a keyframe was asked for.
    final class SyncRecordingEncoder: VideoRegionEncoder {
        let inner = MockVideoEncoder(codecID: MockVideoEncoder.mockCodecID)
        var syncTimes: [UInt64] = []
        var codecID: UInt8 { inner.codecID }
        func start(width: Int, height: Int,
                   onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
            inner.start(width: width, height: height, onFrame: onFrame)
        }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
            if forceSync { syncTimes.append(timeUS) }
            inner.encode(bgra: bgra, forceSync: forceSync, timeUS: timeUS)
        }
        func stop() { inner.stop() }
    }

    // 1280×640: 200 tiles. The strip is 40 tiles — activity under the
    // pinned rules (≥ 32, so the region stays up) — but 20 % of the area,
    // a small update for the re-sharpen.
    static let width = 1280, height = 640
    static let strip = DirtyRect(x: 0, y: 0, width: 256, height: 640)
    static let whole = DirtyRect(x: 0, y: 0, width: 1280, height: 640)

    private func session(_ encoder: SyncRecordingEncoder, _ rng: inout SplitMix64) -> Harness {
        let h = Harness(width: Self.width, height: Self.height, video: true,
                        encoderFactory: { _ in encoder })
        h.frame.fillRandom(&rng)
        h.encodeFrame() // pinned cold start: the region forms on the first frame
        h.run(untilUS: h.now + 100_000)
        return h
    }

    private func animateStrip(_ h: Harness, _ rng: inout SplitMix64, seconds: Double) {
        let end = h.now + UInt64(seconds * 1_000_000)
        while h.now < end {
            h.frame.fillRect(x: 0, y: 0, w: Int(Self.strip.width), h: Int(Self.strip.height), &rng)
            h.encodeFrame(dirtyRects: [Self.strip])
            h.run(untilUS: h.now + 100_000)
        }
    }

    @Test(.tags(.slow), .notInFastLane) func quietRegionGetsOneResharpeningKeyframe() {
        var rng = SplitMix64(seed: 9101)
        let encoder = SyncRecordingEncoder()
        let h = session(encoder, &rng)
        #expect(h.host.activeVideoRegionCount == 1, "setup: pinned region")
        let formationSyncs = encoder.syncTimes.count

        // A large change (the content arriving), then only the strip moves.
        h.frame.fillRandom(&rng)
        h.encodeFrame(dirtyRects: [Self.whole])
        h.run(untilUS: h.now + 100_000)
        let changedAt = h.now
        animateStrip(h, &rng, seconds: 7)

        #expect(h.host.activeVideoRegionCount == 1, "the strip keeps the region up")
        #expect(h.host.stats.videoRefreshes == 1, "one re-sharpen once quiet")
        let refreshes = encoder.syncTimes.dropFirst(formationSyncs)
        #expect(refreshes.count == 1)
        if let at = refreshes.first {
            #expect(at >= changedAt + HostEngine.refreshQuietUS - 200_000,
                    "not before the region has been quiet for a while")
        }

        // Nothing large since: small updates alone never ask again.
        animateStrip(h, &rng, seconds: 6)
        #expect(h.host.stats.videoRefreshes == 1, "small updates alone don't re-sharpen")
    }

    @Test(.tags(.slow), .notInFastLane) func busyRegionIsNotInterrupted() {
        var rng = SplitMix64(seed: 9102)
        let encoder = SyncRecordingEncoder()
        let h = session(encoder, &rng)
        // Large changes on every tick: never quiet, so never a keyframe
        // in the middle of motion.
        let end = h.now + 8_000_000
        while h.now < end {
            h.frame.fillRandom(&rng)
            h.encodeFrame(dirtyRects: [Self.whole])
            h.run(untilUS: h.now + 100_000)
        }
        #expect(h.host.activeVideoRegionCount == 1)
        #expect(h.host.stats.videoRefreshes == 0, "motion is never interrupted by a re-sharpen")
    }

    @Test(.tags(.slow), .notInFastLane) func refreshesAreRateLimited() {
        var rng = SplitMix64(seed: 9103)
        let encoder = SyncRecordingEncoder()
        let h = session(encoder, &rng)
        // A large change every 1.5 s, the strip in between: each settle
        // would earn a keyframe, but no closer than the minimum interval.
        let end = h.now + 16_000_000
        while h.now < end {
            h.frame.fillRandom(&rng)
            h.encodeFrame(dirtyRects: [Self.whole])
            h.run(untilUS: h.now + 100_000)
            animateStrip(h, &rng, seconds: 1.4)
        }
        let syncs = encoder.syncTimes
        for (a, b) in zip(syncs, syncs.dropFirst()) {
            #expect(b - a >= HostEngine.refreshMinIntervalUS, "keyframes \((b - a) / 1000) ms apart")
        }
        #expect(h.host.stats.videoRefreshes >= 2, "settles keep earning re-sharpens")
    }
}
