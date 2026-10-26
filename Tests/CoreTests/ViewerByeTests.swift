import Foundation
import Testing
@testable import GlassActCore
import GlassActTestSupport
import GlassActWire

/// VIEWER_BYE (§3.5): the viewer says why it's closing, so the host can
/// tell its user leaving (restore and lock at once) from a drop (wait for
/// a reconnect) — a cleanly closed stream alone can't, since the viewer's
/// own watchdog closes it cleanly too.
@Suite struct ViewerByeTests {
    @Test func theHostHearsWhy() {
        let host = HostEngine(width: 256, height: 192, transport: CaptureTransport())
        var heard: [UInt8] = []
        host.onViewerBye = { heard.append($0) }
        host.start(nowUS: 0)
        host.handleControl(Data(ControlMessage.viewerBye(reason: ViewerBye.quit).encoded()), nowUS: 1_000)
        #expect(heard == [ViewerBye.quit])
    }

    @Test func onlyItsUserLeavingCountsAsOnPurpose() {
        for closedCleanly in [false, true] {
            #expect(ViewerBye.leftOnPurpose(bye: ViewerBye.disconnected, closedCleanly: closedCleanly))
            #expect(ViewerBye.leftOnPurpose(bye: ViewerBye.quit, closedCleanly: closedCleanly))
            // The watchdog and a failed session close cleanly, but are drops.
            #expect(!ViewerBye.leftOnPurpose(bye: ViewerBye.hostUnresponsive, closedCleanly: closedCleanly))
            #expect(!ViewerBye.leftOnPurpose(bye: ViewerBye.sessionFailed, closedCleanly: closedCleanly))
            // An older viewer (or a lost goodbye), or a reason this build
            // doesn't know: how the stream ended, as before.
            #expect(ViewerBye.leftOnPurpose(bye: nil, closedCleanly: closedCleanly) == closedCleanly)
            #expect(ViewerBye.leftOnPurpose(bye: 200, closedCleanly: closedCleanly) == closedCleanly)
        }
    }
}
