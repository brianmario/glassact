import Testing
import GlassActShare

/// The capture lifecycle (§4.1) over a scripted backend: starts, restarts,
/// the system stopping a stream, and recovery's pacing.
@MainActor @Suite struct ScreenCaptureTests {
    @Test func startRunsOneStream() async {
        let rig = await Rig().started()
        #expect(rig.events == ["started 200×100"])
        #expect(rig.capture.isActive && rig.capture.isCapturing)
        #expect(rig.backend.running.map(\.filter) == ["display 1"])
        await rig.finish()
        #expect(rig.backend.running.isEmpty)
    }

    @Test func aStartThatFailsLeavesCaptureInactive() async {
        let rig = Rig()
        rig.backend.failStarts = 1
        _ = await rig.started()
        #expect(rig.events.count == 1 && rig.events[0].hasPrefix("startFailed"))
        #expect(!rig.capture.isActive && !rig.capture.isCapturing)
        // A second start is allowed.
        _ = await rig.started()
        #expect(rig.events.last == "started 200×100")
        await rig.finish()
    }

    /// Stopping while the first stream is still starting abandons it: it's
    /// stopped as soon as it comes up, and never reported.
    @Test func stopAbandonsAStartInFlight() async {
        let rig = Rig()
        rig.backend.holdStarts = true
        _ = await rig.started()
        rig.capture.stop()
        rig.backend.releaseStarts()
        await rig.settle()
        #expect(rig.events.isEmpty)
        #expect(rig.backend.running.isEmpty)
        #expect(rig.backend.log == ["start 0", "stop 0"])
    }

    // MARK: - The system stopping a stream

    @Test func aSystemStopRecoversAtTheSameSettings() async {
        let rig = await Rig().started()
        rig.backend.streams[0].systemStops(.system("display asleep"))
        await rig.settle()
        #expect(rig.events == ["started 200×100", "recovered 1 display 1 1"])
        #expect(rig.sleeper.waits.isEmpty, "the first attempt doesn't wait")
        #expect(rig.backend.running.map(\.index) == [1])
        #expect(rig.backend.streams[1].settings == CaptureSettings(width: 200, height: 100))
        #expect(rig.capture.isCapturing)
        await rig.finish()
    }

    @Test func theMenuBarStopIsReportedNotRecovered() async {
        let rig = await Rig().started()
        rig.backend.streams[0].systemStops(.userStopped)
        await rig.settle()
        #expect(rig.events == ["started 200×100", "stoppedFromMenuBar"])
        #expect(rig.backend.streams.count == 1)
        await rig.finish()
    }

    /// A stop report from a stream a restart already replaced is old news.
    @Test func aReplacedStreamsStopIsIgnored() async {
        let rig = await Rig().started()
        rig.capture.restart(filter: "display 1", width: 100, height: 50)
        await rig.settle()
        rig.backend.streams[0].systemStops(.system("late"))
        await rig.settle()
        #expect(rig.backend.streams.count == 2)
        #expect(rig.backend.running.map(\.index) == [1])
        await rig.finish()
    }

    // MARK: - Recovery's pacing

    /// No display at all: quick retries with growing waits, then the
    /// capture waits for a display to wake, polling once a minute.
    @Test func noDisplayRetriesThenWaitsForOne() async {
        let rig = await Rig().started()
        rig.backend.content = { _ in throw CaptureError.noDisplay }
        rig.backend.streams[0].systemStops(.system("display asleep"))
        await rig.settle()
        for _ in 1..<CaptureRecovery.quickAttempts {
            rig.sleeper.pass()
            await rig.settle()
        }
        #expect(rig.sleeper.waits == [1, 2, 3, 4, 5, 60])
        #expect(rig.capture.awaitingDisplay)
        #expect(rig.status.filter { $0.hasPrefix("capture paused") }.count == 1)
        // Failed attempts are logged on the first and every 12th, not each.
        #expect(rig.status.filter { $0.hasPrefix("capture recovery attempt") }.count == 1)

        // The screens wake: recovery tries at once, not at the next poll.
        rig.backend.content = { _ in CaptureContent(filter: "display 2", displayID: 2) }
        rig.capture.displayMayBeBack()
        await rig.settle()
        #expect(rig.events.last == "recovered 1 display 2 2")
        #expect(!rig.capture.awaitingDisplay && rig.capture.isCapturing)
        // The slow poll that was pending finds nothing to do.
        rig.sleeper.pass()
        await rig.settle()
        #expect(rig.backend.running.count == 1)
        await rig.finish()
    }

    /// Waking the display when nothing is waiting is not a reason to rebuild.
    @Test func displayMayBeBackIsIgnoredWhileCapturing() async {
        let rig = await Rig().started()
        rig.capture.displayMayBeBack()
        await rig.settle()
        #expect(rig.backend.streams.count == 1)
        await rig.finish()
    }

    @Test func aViewerConnectingRetriesAtOnce() async {
        let rig = await Rig().started()
        rig.backend.content = { _ in throw CaptureError.noDisplay }
        rig.backend.streams[0].systemStops(.system("display asleep"))
        await rig.settle()
        #expect(rig.sleeper.waits == [1])
        rig.backend.content = { _ in CaptureContent(filter: "display 1", displayID: 1) }
        rig.capture.retryNow()
        await rig.settle()
        #expect(rig.events.last == "recovered 1 display 1 1")
        await rig.finish()
    }

    @Test func aRevokedGrantStopsRecovery() async {
        let rig = await Rig().started()
        rig.backend.content = { _ in throw FakeBackend.Failure() }
        rig.backend.screenRecording = false
        rig.backend.streams[0].systemStops(.system("denied"))
        await rig.settle()
        #expect(rig.events.last == "revoked")
        #expect(!rig.sleeper.isWaiting)
        await rig.finish()
    }

    /// The shared window closed: recovery ends there instead of falling
    /// back to the whole display.
    @Test func aClosedWindowEndsRecovery() async {
        let rig = await Rig(target: .window(7)).started()
        rig.backend.content = { _ in throw CaptureError.windowClosed }
        rig.backend.streams[0].systemStops(.system("window gone"))
        await rig.settle()
        #expect(rig.events.last == "windowClosed")
        #expect(rig.backend.targets == [.window(7)])
        #expect(!rig.sleeper.isWaiting)
        #expect(rig.backend.streams.count == 1)
        await rig.finish()
    }

    /// Recovery asks what to capture on every attempt.
    @Test func recoveryFollowsTheTarget() async {
        let rig = await Rig().started()
        var target = CaptureTarget.display(1)
        rig.capture.target = { target }
        rig.backend.content = { t in
            guard case .display(2) = t else { throw CaptureError.noDisplay }
            return CaptureContent(filter: "display 2", displayID: 2)
        }
        rig.backend.streams[0].systemStops(.system("unplugged"))
        await rig.settle()
        target = .display(2)
        rig.sleeper.pass()
        await rig.settle()
        #expect(rig.backend.targets == [.display(1), .display(2)])
        #expect(rig.events.last == "recovered 2 display 2 2")
        await rig.finish()
    }

    // MARK: - Silent stalls

    @Test func twoStalledChecksInARowRecover() async {
        let rig = await Rig().started()
        rig.backend.streams[0].stalled = true
        rig.capture.checkHealth()
        await rig.settle()
        #expect(rig.backend.streams.count == 1, "one miss is not enough")
        rig.capture.checkHealth()
        await rig.settle()
        #expect(rig.backend.streams[0].stopped)
        #expect(rig.events.last == "recovered 1 display 1 1")
        await rig.finish()
    }

    @Test func aHealthyCheckResetsTheMisses() async {
        let rig = await Rig().started()
        rig.backend.streams[0].stalled = true
        rig.capture.checkHealth()
        rig.backend.streams[0].stalled = false
        rig.capture.checkHealth()
        rig.backend.streams[0].stalled = true
        rig.capture.checkHealth()
        await rig.settle()
        #expect(rig.backend.streams.count == 1)
        await rig.finish()
    }

    // MARK: - Restarts

    /// The old stream stops before the new one starts; the pointer setting
    /// carries over and the frame rate goes back to 60.
    @Test func aRestartReplacesTheStream() async {
        let rig = await Rig().started()
        rig.capture.setShowsCursor(false)
        rig.capture.setFrameRate(1)
        await rig.settle()
        #expect(rig.backend.streams[0].applied.last == CaptureSettings(width: 200, height: 100,
                                                                      framesPerSecond: 1, showsCursor: false))
        rig.capture.restart(filter: "window 7", width: 100, height: 50)
        #expect(!rig.capture.isCapturing, "mid-restart")
        await rig.settle()
        #expect(rig.backend.log == ["start 0", "stop 0", "start 1"])
        #expect(rig.backend.streams[1].filter == "window 7")
        #expect(rig.backend.streams[1].settings == CaptureSettings(width: 100, height: 50, showsCursor: false))
        #expect(rig.capture.isCapturing)
        await rig.finish()
    }

    /// Restarts on top of each other: only the last one's stream is left
    /// running.
    @Test func overlappingRestartsLeaveOneStream() async {
        let rig = await Rig().started()
        rig.backend.holdStarts = true
        rig.capture.restart(filter: "display 1", width: 100, height: 50)
        await rig.settle()
        rig.capture.restart(filter: "display 1", width: 120, height: 60)
        rig.capture.restart(filter: "display 1", width: 140, height: 70)
        await rig.settle()
        rig.backend.releaseStarts()
        await rig.settle()
        #expect(rig.backend.running.map(\.settings.width) == [140])
        #expect(rig.capture.isCapturing)
        await rig.finish()
    }

    /// A restarted stream that won't start is recovered at its new size,
    /// not the old one.
    @Test func aRestartThatFailsRecoversAtTheNewSize() async {
        let rig = await Rig().started()
        rig.backend.failStarts = 1
        rig.capture.restart(filter: "display 1", width: 100, height: 50)
        await rig.settle()
        #expect(rig.sleeper.waits == [1], "recovery continues at attempt 2")
        rig.sleeper.pass()
        await rig.settle()
        #expect(rig.events.last == "recovered 2 display 1 1")
        #expect(rig.backend.running.map(\.settings) == [CaptureSettings(width: 100, height: 50)])
        await rig.finish()
    }

    @Test func restartingAStoppedCaptureDoesNothing() async {
        let rig = await Rig().started()
        rig.capture.stop()
        #expect(!rig.capture.restart(filter: "display 1", width: 100, height: 50))
        await rig.settle()
        #expect(rig.backend.streams.count == 1)
        await rig.finish()
    }

    @Test func recoveryPacing() {
        #expect((1...8).map(CaptureRecovery.delay) == [0, 1, 2, 3, 4, 5, 5, 5])
        #expect((1...25).filter(CaptureRecovery.logs) == [1, 12, 24])
    }
}
