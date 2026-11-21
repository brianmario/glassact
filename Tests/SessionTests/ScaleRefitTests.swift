import GlassActSession
import Testing

/// Scale Down re-fits the host's picture when the window outgrows it or is clearly smaller, in
/// either dimension (`ScaleRefit`).
struct ScaleRefitTests {
    // a 14-inch MacBook Pro's largest window shows the 5K host's picture at 2896 × 1628
    let picture = (width: 2896, height: 1628)

    @Test func theWindowItWasMadeForKeepsIt() {
        #expect(!ScaleRefit.shouldRefit(window: (2896, 1628), picture: picture))
        #expect(!ScaleRefit.shouldRefit(window: (2700, 1600), picture: picture), "under 10 % smaller")
    }

    @Test func aClearlyNarrowerWindowRefits() {
        // (before: only under 75 % of the width did)
        #expect(ScaleRefit.shouldRefit(window: (2400, 1628), picture: picture))
    }

    @Test func aShorterWindowRefitsToo() {
        // the width alone never saw this: the picture was scaled down locally instead
        #expect(ScaleRefit.shouldRefit(window: (2896, 1200), picture: picture))
    }

    @Test func aWindowThatOutgrewThePictureRefits() {
        #expect(ScaleRefit.shouldRefit(window: (3200, 1800), picture: picture))
        #expect(!ScaleRefit.shouldRefit(window: (2950, 1660), picture: picture), "within 2 %")
    }

    @Test func nothingBeforeThereIsAPicture() {
        #expect(!ScaleRefit.shouldRefit(window: (2896, 1628), picture: (0, 0)))
    }
}
