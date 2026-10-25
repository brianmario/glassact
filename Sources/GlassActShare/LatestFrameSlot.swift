public import CoreMedia
public import ScreenCaptureKit
import os

/// One-deep latest-frame slot (§4.1): newest capture replaces an unprocessed
/// older one — that drop is correct and desired.
///
/// OSAllocatedUnfairLock, not an os_unfair_lock stored in a class `var`:
/// Swift may move stored properties, and an unfair lock must never move.
/// `@unchecked`: the slot hands a CMSampleBuffer (not Sendable) from the
/// capture queue to the encode queue — ownership passes, it's never shared.
public final class LatestFrameSlot: @unchecked Sendable {
    /// A frame the encoder never saw still changed pixels, and SCK's dirty
    /// rects are deltas against the previous frame: the newest frame's
    /// rects don't cover what changed in the ones it replaced. Their
    /// attachments ride along (the pixel buffer is released — SCK's pool is
    /// only queueDepth deep) and the consumer unions their rects in. Past
    /// `maxSuperseded`, `overflowed` asks for a full scan instead.
    public struct Taken {
        public let buffer: CMSampleBuffer
        public let superseded: [[SCStreamFrameInfo: Any]]
        public let overflowed: Bool
    }
    public static let maxSuperseded = 16
    private struct State {
        var buffer: CMSampleBuffer?
        var superseded: [[SCStreamFrameInfo: Any]] = []
        var overflowed = false
    }
    private let slot = OSAllocatedUnfairLock<State>(uncheckedState: State())

    public init() {}

    public func publish(_ sampleBuffer: CMSampleBuffer) {
        slot.withLockUnchecked { state in
            if let old = state.buffer {
                if state.superseded.count < Self.maxSuperseded, let oldAttachments = FrameInfo.attachments(of: old) {
                    state.superseded.append(oldAttachments)
                } else {
                    state.overflowed = true
                }
            }
            state.buffer = sampleBuffer
        }
    }

    public func take() -> Taken? {
        slot.withLockUnchecked { state in
            guard let buffer = state.buffer else { return nil }
            let taken = Taken(buffer: buffer, superseded: state.superseded, overflowed: state.overflowed)
            state = State()
            return taken
        }
    }
}
