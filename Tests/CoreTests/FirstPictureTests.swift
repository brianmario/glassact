import Testing
import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// Connect-to-first-picture milestones: the viewer's `SessionMilestones`
/// (logged once as `first_picture`) and the host's first-video-frame hook.
@Suite struct FirstPictureTests {
    @Test func pinnedColdStartRecordsTheVideoPathInOrder() {
        let h = Harness(width: 640, height: 640, video: true)
        var firstFrames: [(bytes: Int, sync: Bool)] = []
        h.host.onFirstVideoFrame = { bytes, sync, _ in firstFrames.append((bytes, sync)) }
        var rng = SplitMix64(seed: 7)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 200_000)
        for _ in 0..<5 {
            h.frame.fillRect(x: 0, y: 0, w: 640, h: 640, &rng)
            h.encodeFrame()
            h.run(untilUS: h.now + 16_667)
        }
        #expect(firstFrames.count == 1, "fires once per engine")
        #expect(firstFrames.first?.sync == true, "the cold-start picture is a sync frame")

        let m = h.viewer.milestones
        #expect(m.hellos == 1)
        #expect(m.firstHelloUS > 0 && m.runningUS >= m.firstHelloUS)
        #expect(m.videoStartUS >= m.runningUS)
        #expect(m.firstVideoRxUS >= m.videoStartUS)
        #expect(m.firstVideoBytes > 0 && m.firstVideoSync)
        #expect(m.firstVideoAppliedUS >= m.firstVideoRxUS)
        #expect(m.firstContentUS == m.firstVideoAppliedUS)
    }

    @Test func tileSessionRecordsFirstContent() {
        let h = Harness(width: 320, height: 240)
        #expect(h.viewer.milestones.firstContentUS == 0)
        var rng = SplitMix64(seed: 8)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 10_000))
        let m = h.viewer.milestones
        #expect(m.videoStartUS == 0 && m.firstVideoRxUS == 0)
        #expect(m.firstContentUS > 0 && m.firstContentUS >= m.runningUS)
    }
}
