import GlassActHybridVideo
import Testing

/// `ReducedFramesPolicy`: half size only from a run's `enterAfter + 1`th mostly-new inter frame,
/// only where the half-size round trip loses `marginDB` less than coding did, and back to full
/// size when a reduced stream's run ends; key frames neither extend nor break a run.
struct ReducedFramesPolicyTests {
    @Test func entersOnlyInALongRunWithTheMargin() {
        var p = ReducedFramesPolicy()
        p.wrote(key: true, codedShare: 1, lumaMSE: -1)
        for i in 1...3 {
            p.wrote(key: false, codedShare: 0.9, lumaMSE: 20)
            #expect(!p.wantsMargin, "after \(i) mostly-new pictures")
        }
        p.wrote(key: false, codedShare: 0.9, lumaMSE: 20)
        #expect(p.wantsMargin)
        // coding loses MSE 20; a round trip losing 6.4 or less is 5 dB under it
        #expect(p.entersReduced(resampleMSE: 6.0))
        #expect(!p.entersReduced(resampleMSE: 7.0))
        #expect(!p.entersReduced(resampleMSE: 20))
        // a picture that copies most of itself ends the run
        p.wrote(key: false, codedShare: 0.3, lumaMSE: 1)
        #expect(!p.wantsMargin && p.run == 0)
        // (a key frame neither extends nor breaks one)
        for _ in 0..<4 { p.wrote(key: false, codedShare: 0.8, lumaMSE: 20) }
        p.wrote(key: true, codedShare: 1, lumaMSE: -1)
        #expect(p.run == 4 && p.wantsMargin)
    }

    @Test func aReducedStreamLeavesWhenItsRunEnds() {
        var p = ReducedFramesPolicy()
        for _ in 0..<5 { p.wrote(key: false, codedShare: 1, lumaMSE: 20) }
        p.started(reduced: true)
        #expect(p.reduced && !p.wantsMargin && !p.leavesReduced)
        p.wrote(key: true, codedShare: 1, lumaMSE: -1)
        #expect(!p.leavesReduced, "its key frame")
        p.wrote(key: false, codedShare: 1, lumaMSE: 5)
        #expect(!p.leavesReduced, "still a run")
        p.wrote(key: false, codedShare: 0.2, lumaMSE: 1)
        #expect(!p.leavesReduced, "one quiet frame: a pause or a cut")
        p.wrote(key: false, codedShare: 1, lumaMSE: 5)
        p.wrote(key: false, codedShare: 0.2, lumaMSE: 1)
        #expect(!p.leavesReduced, "quiet again, but not twice in a row")
        p.wrote(key: false, codedShare: 0.1, lumaMSE: 1)
        #expect(p.leavesReduced, "two in a row")
        p.started(reduced: false)
        #expect(!p.reduced && !p.leavesReduced && p.run == 0 && !p.wantsMargin)
    }

    @Test func unmeasuredFramesDontOpenTheGate() {
        var p = ReducedFramesPolicy()
        for _ in 0..<6 { p.wrote(key: false, codedShare: 1, lumaMSE: -1) }
        #expect(!p.wantsMargin && !p.entersReduced(resampleMSE: 0.1))
    }
}
