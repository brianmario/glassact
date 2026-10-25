import CoreGraphics
import GlassActShare

/// A capture backend with no screen: content and streams are scripted, and
/// everything that happens is logged in order.
@MainActor
final class FakeBackend: CaptureBackend {
    struct Failure: Error {}

    /// What `content(for:)` answers; the default finds display 1.
    var content: (CaptureTarget) throws -> CaptureContent<String> = { target in
        switch target {
        case let .display(id): CaptureContent(filter: "display \(id)", displayID: id)
        case let .window(id): CaptureContent(filter: "window \(id)", displayID: nil)
        }
    }
    var screenRecording = true
    /// The next this many streams fail to start.
    var failStarts = 0
    /// New streams wait in `start()` until `releaseStarts()`.
    var holdStarts = false
    private(set) var streams: [FakeStream] = []
    private(set) var targets: [CaptureTarget] = []
    var log: [String] = []

    nonisolated func content(for target: CaptureTarget) async throws -> CaptureContent<String> {
        try await answer(target)
    }

    private func answer(_ target: CaptureTarget) throws -> CaptureContent<String> {
        targets.append(target)
        return try content(target)
    }

    nonisolated func makeStream(filter: String, settings: CaptureSettings, frames: LatestFrameSlot,
                                onFrame: @escaping @Sendable () -> Void,
                                onStop: @escaping @Sendable (CaptureStop) -> Void) throws -> FakeStream {
        MainActor.assumeIsolated {
            let stream = FakeStream(index: streams.count, filter: filter, settings: settings,
                                    backend: self, onStop: onStop)
            if failStarts > 0 {
                failStarts -= 1
                stream.failsToStart = true
            }
            stream.held = holdStarts
            streams.append(stream)
            return stream
        }
    }

    nonisolated func screenRecordingAllowed() -> Bool {
        MainActor.assumeIsolated { screenRecording }
    }

    func releaseStarts() {
        holdStarts = false
        for stream in streams { stream.release() }
    }

    /// The streams running now: started and not stopped.
    var running: [FakeStream] { streams.filter { $0.started && !$0.stopped } }
}

@MainActor
final class FakeStream: CaptureStream {
    let index: Int
    let filter: String
    let settings: CaptureSettings
    private unowned let backend: FakeBackend
    private let onStop: @Sendable (CaptureStop) -> Void
    var failsToStart = false
    var held = false
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var stopped = false
    private(set) var applied: [CaptureSettings] = []
    nonisolated(unsafe) var stalled = false

    init(index: Int, filter: String, settings: CaptureSettings, backend: FakeBackend,
         onStop: @escaping @Sendable (CaptureStop) -> Void) {
        self.index = index
        self.filter = filter
        self.settings = settings
        self.backend = backend
        self.onStop = onStop
    }

    nonisolated func start() async throws { try await run() }

    private func run() async throws {
        backend.log.append("start \(index)")
        if failsToStart { throw FakeBackend.Failure() }
        if held { await withCheckedContinuation { waiting = $0 } }
        started = true
    }

    func release() {
        held = false
        waiting?.resume()
        waiting = nil
    }

    nonisolated func stop() async { await markStopped() }

    private func markStopped() {
        stopped = true
        backend.log.append("stop \(index)")
    }

    nonisolated func apply(_ settings: CaptureSettings) {
        MainActor.assumeIsolated { applied.append(settings) }
    }

    nonisolated var isStalled: Bool { stalled }

    /// The system stops this stream (it's stopped already when it says so).
    func systemStops(_ why: CaptureStop) {
        stopped = true
        onStop(why)
    }
}

/// Recovery's waits, held until the test lets them pass.
@MainActor
final class FakeSleep {
    private(set) var waits: [Double] = []
    private var pending: [CheckedContinuation<Void, Never>] = []

    func sleep(_ seconds: Double) async {
        waits.append(seconds)
        await withCheckedContinuation { pending.append($0) }
    }

    var isWaiting: Bool { !pending.isEmpty }

    /// Lets every pending wait finish.
    func pass() {
        let ready = pending
        pending = []
        for c in ready { c.resume() }
    }
}

typealias Capture = ScreenCapture<FakeBackend>

/// A capture over a fake backend, recording its events and log lines.
@MainActor
final class Rig {
    let backend = FakeBackend()
    let sleeper = FakeSleep()
    let capture: Capture
    var events: [String] = []
    var status: [String] = []

    init(target: CaptureTarget = .display(1)) {
        let sleeper = sleeper
        capture = Capture(backend: backend, frames: LatestFrameSlot(), onFrame: {},
                          sleep: { await sleeper.sleep($0) })
        capture.target = { target }
        capture.onStatus = { [weak self] in self?.status.append($0) }
        capture.onEvent = { [weak self] event in
            switch event {
            case let .started(s): self?.events.append("started \(s.width)×\(s.height)")
            case let .startFailed(why): self?.events.append("startFailed \(why)")
            case let .recovered(attempt, filter, displayID):
                self?.events.append("recovered \(attempt) \(filter) \(displayID.map(String.init) ?? "-")")
            case .stoppedFromMenuBar: self?.events.append("stoppedFromMenuBar")
            case .screenRecordingRevoked: self?.events.append("revoked")
            case .sharedWindowClosed: self?.events.append("windowClosed")
            }
        }
    }

    /// Lets every task and main-queue hop that's ready run.
    func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    /// Starts capture of display 1 at 200×100 and waits for it.
    func started() async -> Rig {
        capture.start(filter: "display 1", settings: CaptureSettings(width: 200, height: 100))
        await settle()
        return self
    }

    /// Ends capture and lets anything still waiting finish.
    func finish() async {
        capture.stop()
        backend.releaseStarts()
        sleeper.pass()
        await settle()
    }
}
