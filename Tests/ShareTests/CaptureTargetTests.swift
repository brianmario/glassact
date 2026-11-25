import CoreGraphics
import Testing
import GlassActShare

/// The display capture shares is the one wanted, never another in its place.
@Suite struct CaptureTargetTests {
    @Test func theWantedDisplayOrNone() {
        let ids: [CGDirectDisplayID] = [7, 3, 9]
        #expect(CaptureTarget.pick(ids, wanted: 3, id: { $0 }) == 3)
        #expect(CaptureTarget.pick(ids, wanted: 5, id: { $0 }) == nil, "not the first listed: a display nobody chose")
        #expect(CaptureTarget.pick([CGDirectDisplayID](), wanted: 3, id: { $0 }) == nil)
    }
}
