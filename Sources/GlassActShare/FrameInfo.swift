public import CoreMedia
public import GlassActCore
public import ScreenCaptureKit

/// Reading a captured frame's ScreenCaptureKit attachments.
public enum FrameInfo {
    /// Why a frame's dirty rects were (or weren't) usable — tallied per
    /// status interval to find why SCK hints vanish in tile mode.
    public enum DirtyRectVerdict: String, Sendable {
        case ok, noAttachments = "no-attach", absent, badEntry = "bad-entry",
             zeroRect = "zero-rect", emptyList = "empty-list", outOfFrame = "out-of-frame"
    }

    public static func attachments(of sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
    }

    /// Whether the frame has pixels: `.idle` and other incomplete frames
    /// carry none (§4.1). A frame without a status counts as complete.
    public static func isComplete(_ attachments: [SCStreamFrameInfo: Any]) -> Bool {
        guard let raw = attachments[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return true }
        return status == .complete
    }

    /// The frame's dirty rects in its own pixels. Dirty rects are hints only
    /// (§4.3): on any parse doubt the rects are nil (full scan — the hash
    /// gate keeps it correct either way), and the verdict says why.
    public static func dirtyRects(_ attachments: [SCStreamFrameInfo: Any], frameWidth width: Int,
                                  frameHeight height: Int) -> (rects: [DirtyRect]?, verdict: DirtyRectVerdict) {
        guard let raw = attachments[.dirtyRects] as? [NSDictionary] else { return (nil, .absent) }
        // SCK rects are in the SOURCE's backing pixels (DirtyRectMapping):
        // source width = content width (points) × SCK's scaleFactor.
        var rawRects: [(x: Double, y: Double, width: Double, height: Double)] = []
        rawRects.reserveCapacity(raw.count)
        for entry in raw {
            guard let rect = CGRect(dictionaryRepresentation: entry) else { return (nil, .badEntry) }
            rawRects.append((Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)))
        }
        let scaleFactor = (attachments[.scaleFactor] as? NSNumber)?.doubleValue ?? 0
        let contentWidth = (attachments[.contentRect] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) }.map { Double($0.width) } ?? 0
        switch DirtyRectMapping.map(raw: rawRects, frameWidth: width, frameHeight: height,
                                    sourcePixelWidth: contentWidth * scaleFactor) {
        case let .rects(rects):
            return (rects, .ok)
        case .empty:
            return (nil, .emptyList)
        case .unknown:
            return (nil, rawRects.contains { $0.width <= 0 || $0.height <= 0 } ? .zeroRect : .outOfFrame)
        }
    }
}
