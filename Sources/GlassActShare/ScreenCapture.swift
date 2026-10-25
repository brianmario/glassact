public import CoreGraphics
import Foundation

/// The capture lifecycle (§4.1): starting a stream, rebuilding it at a new
/// size or of new content, and keeping it alive when the system takes it
/// away. What to capture and what the frames mean stay with the caller;
/// frames go into `frames` and `onFrame` announces each one.
///
/// Recovery: a stream the system stopped (display sleep or disconnect, the
/// lock screen) or one that stalled silently is rebuilt from fresh content
/// at the same settings, so the session on top carries on as if frames had
/// paused. Only someone ending the share from the menu bar, a revoked
/// Screen Recording grant, or the shared window closing ends it.
///
/// Concurrency: main-thread confined, like the Host's other control state;
/// streams start and stop in main-actor tasks. `generation` serializes
/// them: every start, restart, recovery and stop bumps it, and a task that
/// finds it moved on abandons (and stops) its stream, so overlapping
/// restarts can't leave one capturing untracked. `@unchecked Sendable` so
/// those hops compile under Swift 6 strict concurrency.
public final class ScreenCapture<Backend: CaptureBackend>: @unchecked Sendable {
    public enum Event {
        /// The first stream is running.
        case started(CaptureSettings)
        /// The first stream couldn't start; capture is inactive.
        case startFailed(String)
        /// A new stream replaced one the system took away. `filter` and
        /// `displayID` are the content recovery found: the shared display
        /// may have gone (unplugged), and capture fell back to another.
        case recovered(attempt: Int, filter: Backend.Filter, displayID: CGDirectDisplayID?)
        /// Someone ended the share from the menu-bar screen-recording
        /// control: a privacy decision made at the Mac. Capture is still
        /// active; the caller stops it.
        case stoppedFromMenuBar
        /// Screen Recording was turned off. Recovery stops: retrying can't
        /// help until it's granted again (and macOS applies that to a fresh
        /// launch).
        case screenRecordingRevoked
        /// The shared window (`CaptureTarget.window`) is gone: closed, or
        /// its app quit. Recovery stops rather than fall back to the whole
        /// display, which would suddenly show the viewer the entire desktop.
        case sharedWindowClosed
    }

    /// Log lines, main thread.
    public var onStatus: (String) -> Void = { _ in }
    /// Main thread.
    public var onEvent: (Event) -> Void = { _ in }
    /// What recovery captures; asked on every attempt (main thread).
    public var target: () -> CaptureTarget = { .display(CGMainDisplayID()) }

    /// Main thread: between `start` and `stop`, whether or not a stream is
    /// running right now.
    public private(set) var isActive = false
    /// Main thread: a stream is running (not mid-restart or recovering).
    public var isCapturing: Bool { stream != nil }
    /// Main thread: recovery found no display and is waiting for one.
    public private(set) var awaitingDisplay = false

    private let backend: Backend
    private let frames: LatestFrameSlot
    private let onFrame: @Sendable () -> Void
    private let sleep: @Sendable (Double) async -> Void
    /// What streams are built with; recovery reuses it.
    private var settings: CaptureSettings?
    private var stream: Backend.Stream?
    /// Which stream `stream` is, for telling a stop report from a
    /// superseded one.
    private var streamToken = 0
    private var tokens = 0
    private var generation = 0
    /// Consecutive health checks that found the stream stalled.
    private var misses = 0
    /// App Nap exemption, held from the first start to stop, so PING
    /// cadence and batch-timeout timers keep millisecond resolution; the
    /// idle menu-bar app naps normally.
    private var activity: (any NSObjectProtocol)?

    /// `onFrame` runs on the backend's capture queue after each frame lands
    /// in `frames`. `sleep` waits between recovery attempts (tests pass
    /// their own).
    public init(backend: Backend, frames: LatestFrameSlot, onFrame: @escaping @Sendable () -> Void,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.backend = backend
        self.frames = frames
        self.onFrame = onFrame
        self.sleep = sleep
    }

    /// Main thread. Start capturing `filter`; `.started` or `.startFailed`
    /// follows.
    public func start(filter: Backend.Filter, settings: CaptureSettings) {
        guard !isActive else { return }
        isActive = true
        generation += 1
        let generation = generation
        self.settings = settings
        let boxed = Unchecked(filter)
        Task { @MainActor in
            do {
                let (stream, token) = try self.makeStream(boxed.value, settings)
                try await stream.start()
                guard generation == self.generation, self.isActive else {
                    await stream.stop() // stopped or restarted meanwhile
                    return
                }
                self.adopt(stream, token)
                if self.activity == nil {
                    self.activity = ProcessInfo.processInfo.beginActivity(
                        options: [.userInitiated, .latencyCritical], reason: "glassact capture active")
                }
                self.onStatus("capturing \(settings.width)×\(settings.height)")
                self.onEvent(.started(settings))
            } catch {
                guard generation == self.generation else { return }
                self.isActive = false
                self.settings = nil
                self.onEvent(.startFailed(error.localizedDescription))
            }
        }
    }

    /// Main thread. Rebuild the stream of `filter` at a new output size,
    /// keeping whether the pointer is drawn in. The frame rate goes back to
    /// 60. False, with nothing changed but the old stream stopped, if the
    /// stream couldn't be made.
    ///
    /// The old stream is fully stopped before the new one starts, and a
    /// restart superseded mid-flight (a window pick followed by the viewer's
    /// fit-resize, auto-scale + resize, …) stops its own stream instead of
    /// leaving it capturing untracked. If the new one fails to start,
    /// recovery takes over.
    @discardableResult
    public func restart(filter: Backend.Filter, width: Int, height: Int) -> Bool {
        guard isActive else { return false }
        generation += 1
        let generation = generation
        let old = stream
        stream = nil
        let settings = CaptureSettings(width: width, height: height,
                                       showsCursor: self.settings?.showsCursor ?? true)
        let made: (stream: Backend.Stream, token: Int)
        do {
            made = try makeStream(filter, settings)
        } catch {
            onStatus("resize: stream output failed: \(error)")
            if let old { Task { await old.stop() } }
            return false
        }
        self.settings = settings
        Task { @MainActor in
            await old?.stop()
            guard generation == self.generation, self.isActive else { return }
            do {
                try await made.stream.start()
            } catch {
                guard generation == self.generation, self.isActive else { return }
                self.onStatus("capture restart failed: \(error.localizedDescription) — recovering")
                self.recover(attempt: 2)
                return
            }
            guard generation == self.generation, self.isActive else {
                await made.stream.stop()
                return
            }
            self.adopt(made.stream, made.token)
        }
        return true
    }

    /// Main thread. Stop capturing; anything in flight is abandoned.
    public func stop() {
        isActive = false
        generation += 1 // abandons any task still in flight
        awaitingDisplay = false
        misses = 0
        settings = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if let old = stream {
            stream = nil
            Task { await old.stop() }
        }
    }

    /// Main thread: 1 fps while the viewer is occluded, 60 otherwise. A
    /// stream mid-restart starts at 60.
    public func setFrameRate(_ framesPerSecond: Int) {
        guard let stream, var settings else { return }
        settings.framesPerSecond = framesPerSecond
        self.settings = settings
        Task { await stream.apply(settings) }
    }

    /// Main thread: draw the pointer into the pixels, or leave it to cursor
    /// metadata.
    public func setShowsCursor(_ showsCursor: Bool) {
        guard let stream, var settings else { return }
        settings.showsCursor = showsCursor
        self.settings = settings
        Task { await stream.apply(settings) }
    }

    // MARK: - Recovery

    /// Main thread, 1 Hz. macOS 27 can tell a stream that stopped without
    /// telling its delegate: a frozen picture with nothing in the log. Two
    /// stalled checks in a row, then the same recovery a reported stop gets.
    public func checkHealth() {
        guard isActive, let stream, stream.isStalled else { misses = 0; return }
        misses += 1
        guard misses >= 2 else { return }
        misses = 0
        onStatus("capture stalled — the stream stopped without reporting an error — recovering")
        self.stream = nil
        Task { await stream.stop() }
        recover(attempt: 1)
    }

    /// Main thread. Something that can bring a display back happened (the
    /// screens woke, a display was reconfigured): if recovery is waiting
    /// for one, try now.
    public func displayMayBeBack() {
        if isActive && stream == nil && awaitingDisplay { recover(attempt: 1) }
    }

    /// Main thread. A viewer connected, which wakes the display: if capture
    /// died while nobody watched, try again right away.
    public func retryNow() {
        if isActive && stream == nil { recover(attempt: 1) }
    }

    /// Main thread. Rebuild the capture from freshly found content at the
    /// same settings. Retries with backoff (`CaptureRecovery.delay`) until
    /// it works or capture stops. With no display at all (asleep, nobody
    /// watching) it stops polling after `CaptureRecovery.quickAttempts`
    /// and waits for `displayMayBeBack` or `retryNow` instead, with a slow
    /// poll as a safety net: a display that sleeps all night used to be
    /// enumerated every 5 s (10,000+ attempts by morning).
    private func recover(attempt: Int, after delay: Double? = nil) {
        guard isActive else { return }
        generation += 1
        let generation = generation
        Task { @MainActor in
            let wait = delay ?? CaptureRecovery.delay(attempt: attempt)
            if wait > 0 { await self.sleep(wait) }
            guard generation == self.generation, self.isActive, let settings = self.settings else { return }
            do {
                let content = try await self.backend.content(for: self.target())
                guard generation == self.generation, self.isActive else { return }
                let (stream, token) = try self.makeStream(content.filter, settings)
                try await stream.start()
                guard generation == self.generation, self.isActive else {
                    await stream.stop()
                    return
                }
                self.adopt(stream, token)
                self.awaitingDisplay = false
                self.onStatus("capture recovered (attempt \(attempt))")
                self.onEvent(.recovered(attempt: attempt, filter: content.filter, displayID: content.displayID))
            } catch {
                guard generation == self.generation, self.isActive else { return }
                self.recoveryFailed(attempt: attempt, error)
            }
        }
    }

    private func recoveryFailed(attempt: Int, _ error: any Error) {
        if !backend.screenRecordingAllowed() {
            onStatus("capture stopped: Screen Recording was turned off")
            onEvent(.screenRecordingRevoked)
            return
        }
        let reason = error as? CaptureError
        if reason == .windowClosed {
            onEvent(.sharedWindowClosed)
            return
        }
        if reason == .noDisplay && attempt >= CaptureRecovery.quickAttempts {
            if !awaitingDisplay {
                awaitingDisplay = true
                onStatus("capture paused: no display to capture (asleep?) — waiting for one to wake")
            }
            recover(attempt: attempt + 1, after: CaptureRecovery.slowPollSeconds)
            return
        }
        if CaptureRecovery.logs(attempt: attempt) {
            onStatus("capture recovery attempt \(attempt) failed: \(error.localizedDescription) — retrying")
        }
        recover(attempt: attempt + 1)
    }

    /// Main thread. The system stopped stream `token`.
    private func systemStopped(_ why: CaptureStop, token: Int) {
        guard isActive, stream != nil, token == streamToken else { return } // superseded
        switch why {
        case .userStopped:
            onStatus("capture stopped from the menu-bar indicator — sharing ended")
            onEvent(.stoppedFromMenuBar)
        case let .system(description):
            onStatus("capture stopped by the system: \(description) — recovering")
            stream = nil
            recover(attempt: 1)
        }
    }

    // MARK: - Streams

    private func makeStream(_ filter: Backend.Filter, _ settings: CaptureSettings) throws
        -> (stream: Backend.Stream, token: Int) {
        tokens += 1
        let token = tokens
        let stream = try backend.makeStream(
            filter: filter, settings: settings, frames: frames, onFrame: onFrame,
            onStop: { [weak self] why in
                DispatchQueue.main.async { self?.systemStopped(why, token: token) }
            })
        return (stream, token)
    }

    private func adopt(_ stream: Backend.Stream, _ token: Int) {
        self.stream = stream
        streamToken = token
        misses = 0
    }
}

/// Recovery's pacing, apart from the lifecycle so tests can pin it.
public enum CaptureRecovery {
    /// Quick retries before an absent display counts as asleep (about 15 s).
    public static let quickAttempts = 6
    /// The safety-net poll while waiting for a display to wake.
    public static let slowPollSeconds = 60.0

    /// Before attempt `attempt`: none for the first, then 1 s, 2 s, … 5 s.
    public static func delay(attempt: Int) -> Double {
        attempt > 1 ? Double(min(5, attempt - 1)) : 0
    }

    /// Which failed attempts get a log line: the first, then every 12th.
    public static func logs(attempt: Int) -> Bool {
        attempt == 1 || attempt % 12 == 0
    }
}

/// Moves a value that isn't marked Sendable (`SCContentFilter`) into a
/// main-actor task; it's only ever used there.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
