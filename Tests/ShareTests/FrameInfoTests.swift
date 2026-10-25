import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
import GlassActCore
import GlassActShare

/// Dirty rects as ScreenCaptureKit attaches them: dictionaries of rects in
/// the source's backing pixels (§4.3).
@Suite struct FrameInfoTests {
    static func attachments(_ rects: [CGRect], contentWidth: CGFloat = 1440,
                            scale: Double = 2) -> [SCStreamFrameInfo: Any] {
        [.dirtyRects: rects.map { $0.dictionaryRepresentation as NSDictionary },
         .scaleFactor: NSNumber(value: scale),
         .contentRect: CGRect(x: 0, y: 0, width: contentWidth, height: 810).dictionaryRepresentation as NSDictionary]
    }

    @Test func rectsMapIntoTheFrame() {
        let r = FrameInfo.dirtyRects(Self.attachments([CGRect(x: 2832, y: 2, width: 48, height: 4)]),
                                     frameWidth: 2880, frameHeight: 1620)
        #expect(r.verdict == .ok)
        #expect(r.rects == [DirtyRect(x: 2832, y: 2, width: 48, height: 4)])
    }

    @Test func eachDoubtMeansAFullScanAndSaysWhy() {
        let frame = (w: 2880, h: 1620)
        func verdict(_ a: [SCStreamFrameInfo: Any]) -> FrameInfo.DirtyRectVerdict {
            let r = FrameInfo.dirtyRects(a, frameWidth: frame.w, frameHeight: frame.h)
            #expect(r.rects == nil)
            return r.verdict
        }
        #expect(verdict([:]) == .absent)
        #expect(verdict([.dirtyRects: [NSDictionary()]]) == .badEntry)
        #expect(verdict(Self.attachments([])) == .emptyList)
        #expect(verdict(Self.attachments([.zero])) == .zeroRect)
        #expect(verdict(Self.attachments([CGRect(x: 5664, y: 4, width: 96, height: 8)])) == .outOfFrame)
    }

    @Test func aFrameWithoutAStatusCountsAsComplete() {
        #expect(FrameInfo.isComplete([:]))
        #expect(FrameInfo.isComplete([.status: SCFrameStatus.complete.rawValue]))
        #expect(!FrameInfo.isComplete([.status: SCFrameStatus.idle.rawValue]))
    }
}
