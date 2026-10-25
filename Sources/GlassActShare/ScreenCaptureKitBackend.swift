public import CoreMedia
import Foundation
public import ScreenCaptureKit

/// `CaptureBackend` over ScreenCaptureKit (§4.1).
public struct ScreenCaptureKitBackend: CaptureBackend {
    /// Every stream's sample handler queue.
    private let queue = DispatchQueue(label: "glassact.host.capture", qos: .userInteractive)

    public init() {}

    public func content(for target: CaptureTarget) async throws -> CaptureContent<SCContentFilter> {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        switch target {
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
                throw CaptureError.windowClosed
            }
            return CaptureContent(filter: SCContentFilter(desktopIndependentWindow: window), displayID: nil)
        case let .display(wanted):
            guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first
            else { throw CaptureError.noDisplay }
            return CaptureContent(filter: SCContentFilter(display: display, excludingWindows: []),
                                  displayID: display.displayID)
        }
    }

    public func makeStream(filter: SCContentFilter, settings: CaptureSettings, frames: LatestFrameSlot,
                           onFrame: @escaping @Sendable () -> Void,
                           onStop: @escaping @Sendable (CaptureStop) -> Void) throws -> SCKCaptureStream {
        try SCKCaptureStream(filter: filter, settings: settings, queue: queue,
                             frames: frames, onFrame: onFrame, onStop: onStop)
    }

    public func screenRecordingAllowed() -> Bool { CGPreflightScreenCaptureAccess() }
}

/// One `SCStream`.
///
/// `@unchecked Sendable`: it's driven from main-actor tasks, and the output
/// callback touches only `Output`.
public final class SCKCaptureStream: CaptureStream, @unchecked Sendable {
    private let stream: SCStream
    /// The stream's output and delegate. Its own object, holding nothing
    /// that holds the stream: a superseded stream that never started is
    /// simply released.
    private let output: Output
    /// `updateConfiguration` REPLACES the configuration, so changes mutate
    /// this original: a fresh SCStreamConfiguration would reset dimensions
    /// and pixel format to defaults and break capture.
    private let configuration = SCStreamConfiguration()

    init(filter: SCContentFilter, settings: CaptureSettings, queue: DispatchQueue, frames: LatestFrameSlot,
         onFrame: @escaping @Sendable () -> Void, onStop: @escaping @Sendable (CaptureStop) -> Void) throws {
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 3
        Self.configure(configuration, settings)
        output = Output(frames: frames, onFrame: onFrame, onStop: onStop)
        // SCStream copies the configuration here: it must be complete first.
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
    }

    private static func configure(_ configuration: SCStreamConfiguration, _ settings: CaptureSettings) {
        configuration.width = settings.width
        configuration.height = settings.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(clamping: settings.framesPerSecond))
        configuration.showsCursor = settings.showsCursor
    }

    public func start() async throws {
        try await stream.startCapture()
    }

    public func stop() async {
        try? await stream.stopCapture()
    }

    /// Main thread. The change lands in `configuration` now, in call
    /// order, and every update sends that one object: updates that finish
    /// out of order still leave the stream at the latest settings.
    public func apply(_ settings: CaptureSettings) {
        Self.configure(configuration, settings)
        let update = Unchecked((stream, configuration))
        Task { try? await update.value.0.updateConfiguration(update.value.1) }
    }

    public var isStalled: Bool {
        // Earlier systems have no `isCapturing`; there a silent stop shows
        // only as a frozen picture.
        guard #available(macOS 27, *) else { return false }
        return !stream.isCapturing
    }

    private final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        private let frames: LatestFrameSlot
        private let onFrame: @Sendable () -> Void
        private let onStop: @Sendable (CaptureStop) -> Void

        init(frames: LatestFrameSlot, onFrame: @escaping @Sendable () -> Void,
             onStop: @escaping @Sendable (CaptureStop) -> Void) {
            self.frames = frames
            self.onFrame = onFrame
            self.onStop = onStop
        }

        // The capture queue → latest slot → the consumer.
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                    of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid,
                  let attachments = FrameInfo.attachments(of: sampleBuffer),
                  FrameInfo.isComplete(attachments) else { return }
            frames.publish(sampleBuffer)
            onFrame()
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            let ns = error as NSError
            if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userStopped.rawValue {
                onStop(.userStopped)
            } else {
                onStop(.system("\(error.localizedDescription) (\(ns.domain) \(ns.code))"))
            }
        }
    }
}
