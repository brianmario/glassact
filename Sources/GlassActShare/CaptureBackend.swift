public import CoreGraphics
public import Foundation

/// What `ScreenCapture` drives (§4.1): finding content to capture, and
/// streams of it. `ScreenCaptureKitBackend` is the real one; tests use a
/// fake, which is how the capture lifecycle (restarts, recovery, the
/// system stopping a stream) gets `swift test` coverage.
///
/// Calls arrive on the main thread, or in main-actor tasks.
public protocol CaptureBackend: Sendable {
    /// What a stream captures (`SCContentFilter`).
    associatedtype Filter
    associatedtype Stream: CaptureStream

    /// The content `target` names, now: the window if it still exists,
    /// else the display, or any display if that one is gone. Throws
    /// `CaptureError.windowClosed` or `.noDisplay` when there's nothing.
    func content(for target: CaptureTarget) async throws -> CaptureContent<Filter>

    /// A stream of `filter`, not yet started. Each frame goes into `frames`
    /// and is then announced with `onFrame` (on the capture queue);
    /// `onStop` reports the system stopping the stream (any thread).
    func makeStream(filter: Filter, settings: CaptureSettings, frames: LatestFrameSlot,
                    onFrame: @escaping @Sendable () -> Void,
                    onStop: @escaping @Sendable (CaptureStop) -> Void) throws -> Stream

    /// Whether Screen Recording is still granted. A revoked grant is the
    /// one failure retrying can't fix.
    func screenRecordingAllowed() -> Bool
}

/// One capture stream. Main-thread calls, or main-actor tasks.
public protocol CaptureStream: AnyObject, Sendable {
    func start() async throws
    func stop() async
    /// Main thread. Applies new settings to the running stream; calls take
    /// effect in the order they're made.
    func apply(_ settings: CaptureSettings)
    /// The stream stopped without telling its delegate (only macOS 27 can
    /// tell; earlier systems always say false).
    var isStalled: Bool { get }
}

/// What a capture should show; recovery asks again on every attempt, so a
/// change of display or window between attempts is followed.
public enum CaptureTarget: Equatable, Sendable {
    case display(CGDirectDisplayID)
    /// A single window (§4.10), by window ID.
    case window(UInt32)
}

public struct CaptureContent<Filter> {
    public let filter: Filter
    /// The display `filter` shows; nil for a window.
    public let displayID: CGDirectDisplayID?

    public init(filter: Filter, displayID: CGDirectDisplayID?) {
        self.filter = filter
        self.displayID = displayID
    }
}

extension CaptureContent: Sendable where Filter: Sendable {}

public enum CaptureError: Error, Equatable {
    /// No display to capture: asleep, or every display gone.
    case noDisplay
    /// The shared window was closed, or its app quit.
    case windowClosed
}

extension CaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noDisplay: "no display available"
        case .windowClosed: "the shared window is gone"
        }
    }
}

/// Why the system stopped a stream.
public enum CaptureStop: Sendable {
    /// Someone ended the share from the menu-bar screen-recording control.
    case userStopped
    /// Anything else: display sleep or disconnect, the lock screen, a window
    /// gone. The description is the system's.
    case system(String)
}

/// A stream's output (§4.1): BGRA, sRGB, `queueDepth` 3.
public struct CaptureSettings: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// 60, or 1 while the viewer is occluded (§4.9 pause hint).
    public var framesPerSecond: Int
    /// The pointer drawn into the pixels: true until the cursor cap is
    /// active (CURSOR_POS/IMAGE instead).
    public var showsCursor: Bool

    public init(width: Int, height: Int, framesPerSecond: Int = 60, showsCursor: Bool = true) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.showsCursor = showsCursor
    }
}
