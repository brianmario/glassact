@testable import GlassActSession
import Testing

/// Glass-to-glass latency samples: a frame's capture time rides the Host's clock and its present
/// the Viewer's, so a sample needs the PING-derived offset between them. Until the engine has one
/// the controller drops samples (with none, a sample was the two Macs' clock difference: the window
/// title read "593806874 ms latency" for a session's first second or two).
struct GlassToGlassTests {
    @Test func samplesMoveTheCaptureOntoTheViewersClock() {
        // the Viewer's clock 6.9 days ahead of the Host's
        let offset: Int64 = 593_806_763_800
        let captured: [UInt64] = [1_000_000, 1_010_000]
        let presented = UInt64(1_030_000 + offset)
        #expect(ViewerController.glassToGlassUS(captureTimestampsUS: captured, presentedUS: presented,
                                                hostClockOffsetUS: offset) == [30_000, 20_000])
    }

    @Test func aCaptureTheOffsetPutsAfterThePresentIsZero() {
        // (the offset is a minimum over PINGs: off by up to a one-way delay)
        #expect(ViewerController.glassToGlassUS(captureTimestampsUS: [5_000], presentedUS: 4_000,
                                                hostClockOffsetUS: 0) == [0])
    }

    @Test func aHostClockAheadOfTheViewersGivesANegativeOffset() {
        let offset: Int64 = -2_000_000_000
        let presented = UInt64(Int64(3_000_000_000) + offset + 25_000)
        #expect(ViewerController.glassToGlassUS(captureTimestampsUS: [3_000_000_000], presentedUS: presented,
                                                hostClockOffsetUS: offset) == [25_000])
    }
}
