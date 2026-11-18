// Copyright © 2026 Glass Act. All rights reserved.
//
// av1seq --vt-decode: the hybrid's stream through VideoToolbox's hardware AV1
// decoder, the one the Viewer uses (M3 and later), twice:
// - as the Viewer does: the av1C config built from the key frame's sequence
//   header (AV1Config.build, as VIDEO_START), each frame into VTRegionDecoder;
// - for exactness: a session with no output format requested, so the decoder's
//   own 4:2:0 output, compared sample for sample with the encoder's picture
//   (which libaom already matches).

import CoreMedia
import CoreVideo
import Foundation
import GlassActCore
import GlassActWire
import VideoToolbox

enum VTDecodeCheck {
    struct Frame {
        var obu: [UInt8]
        var key: Bool
        /// Y, U, V, cropped: Y width × height, chroma (w+1)/2 × (h+1)/2.
        var planes: [[UInt8]]
    }

    static func run(_ frames: [Frame], width: Int, height: Int) -> [String] {
        var lines: [String] = []
        guard let first = frames.first, first.key, let seq = AV1Config.sequenceHeaderOBU(inTemporalUnit: first.obu) else {
            return ["vt-decode: the first frame isn't a key frame with a sequence header"]
        }
        guard let config = AV1Config.build(sequenceHeaderOBU: seq) else {
            return ["vt-decode: AV1Config.build refused this sequence header (\(seq.count) bytes) — "
                    + "the Viewer's VIDEO_START path would fail before VideoToolbox sees a frame"]
        }
        let profile = Int(config[1] >> 5), level = Int(config[1] & 0x1F), tier = Int(config[2] >> 7)
        lines.append("vt-decode: av1C profile \(profile), seq_level_idx \(level), tier \(tier) · "
                     + "hardware AV1 decode \(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) ? "reported" : "NOT reported") · "
                     + "VTRegionDecoder.canDecodeAV1 \(VTRegionDecoder.canDecodeAV1)")

        // 1. As the Viewer does.
        let viewer = VTRegionDecoder()
        if !viewer.start(codec: VideoCodec.av1, config: config, width: width, height: height) {
            lines.append("  Viewer path: the session wasn't created (start failed)")
        } else {
            var failed: [Int] = []
            for (i, f) in frames.enumerated() where !viewer.decode(f.obu, sync: f.key, onPixels: { _, _ in }) {
                failed.append(i)
            }
            viewer.stop()
            if failed.isEmpty {
                lines.append("  Viewer path: all \(frames.count) frames decoded")
            } else {
                let firstFail = failed[0]
                lines.append("  Viewer path: \(failed.count) of \(frames.count) frames failed; the first is frame \(firstFail) "
                             + "(\(frames[firstFail].key ? "key" : "inter")); failed: "
                             + failed.prefix(20).map(String.init).joined(separator: " "))
            }
        }

        // 2. Exactness: the decoder's own output format.
        var desc: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": Data(config)] as CFDictionary,
        ]
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_AV1,
                                             width: Int32(width), height: Int32(height),
                                             extensions: extensions as CFDictionary, formatDescriptionOut: &desc) == noErr,
              let desc else {
            lines.append("  exactness: no format description")
            return lines
        }
        var made: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil,
                                           decompressionSessionOut: &made) == noErr, let session = made else {
            lines.append("  exactness: the native-format session wasn't created")
            return lines
        }
        defer { VTDecompressionSessionInvalidate(session) }
        var exact = 0, outputs = 0, formats = Set<String>()
        var problems: [String] = []
        // Written by the output handler, which runs inside DecodeFrame (no async flag).
        final class Result: @unchecked Sendable {
            var status: OSStatus = noErr
            var image: CVImageBuffer?
            var dropped = false
        }
        for (i, f) in frames.enumerated() {
            let result = Result()
            let submitted: OSStatus = f.obu.withUnsafeBytes { src in
                var block: CMBlockBuffer?
                guard CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                    blockLength: f.obu.count, blockAllocator: kCFAllocatorNull, customBlockSource: nil,
                    offsetToData: 0, dataLength: f.obu.count, flags: 0, blockBufferOut: &block) == noErr,
                      let block else { return -1 }
                var sample: CMSampleBuffer?
                var size = f.obu.count
                guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: desc,
                                                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                                sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                                sampleBufferOut: &sample) == noErr, let sample else { return -1 }
                return VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                    s, info, buffer, _, _ in
                    result.status = s
                    result.image = buffer
                    result.dropped = info.contains(.frameDropped)
                }
            }
            guard submitted == noErr, result.status == noErr, let image = result.image, !result.dropped else {
                problems.append("frame \(i) (\(f.key ? "key" : "inter")): submit \(submitted), status \(result.status)"
                                + (result.dropped ? ", dropped" : "") + (result.image == nil ? ", no image" : ""))
                continue
            }
            outputs += 1
            let format = CVPixelBufferGetPixelFormatType(image)
            formats.insert(fourCC(format))
            guard !f.planes.isEmpty else { continue } // --no-planes: decode only
            if let diff = compare(image, f.planes, width: width, height: height) {
                problems.append("frame \(i) (\(f.key ? "key" : "inter")): \(diff)")
            } else {
                exact += 1
            }
        }
        let checked = frames.first?.planes.isEmpty == false
        lines.append("  exactness: \(outputs) of \(frames.count) frames output (\(formats.sorted().joined(separator: ", ")))"
                     + (checked ? ", \(exact) identical to the encoder's picture" : ", not compared (--no-planes)"))
        for p in problems.prefix(12) { lines.append("    \(p)") }
        if problems.count > 12 { lines.append("    … and \(problems.count - 12) more") }
        return lines
    }

    private static func fourCC(_ t: OSType) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((t >> $0) & 0xFF))) }
        return String(chars)
    }

    /// nil if the decoded picture is the encoder's, else where it first differs.
    private static func compare(_ image: CVImageBuffer, _ planes: [[UInt8]], width: Int, height: Int) -> String? {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferGetWidth(image) >= width, CVPixelBufferGetHeight(image) >= height else {
            return "output \(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image)), expected \(width)×\(height)"
        }
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        let count = CVPixelBufferGetPlaneCount(image)
        func plane(_ k: Int) -> (UnsafePointer<UInt8>, Int)? {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(image, k) else { return nil }
            return (UnsafePointer(base.assumingMemoryBound(to: UInt8.self)), CVPixelBufferGetBytesPerRowOfPlane(image, k))
        }
        guard count >= 2, let (y, ys) = plane(0), let (c1, c1s) = plane(1) else {
            return "output has \(count) planes (\(fourCC(CVPixelBufferGetPixelFormatType(image)))), not 4:2:0 planar"
        }
        var lumaRows = 0, chromaRows = 0, firstLuma = -1, firstChroma = -1
        for r in 0..<height {
            let row = y + r * ys
            let differs = planes[0].withUnsafeBufferPointer { memcmp(row, $0.baseAddress! + r * width, width) != 0 }
            if differs { lumaRows += 1; if firstLuma < 0 { firstLuma = r } }
        }
        if count == 2 {
            // biplanar: U and V interleaved
            for r in 0..<ch {
                let row = c1 + r * c1s
                var differs = false
                for c in 0..<cw where row[2 * c] != planes[1][r * cw + c] || row[2 * c + 1] != planes[2][r * cw + c] {
                    differs = true
                    break
                }
                if differs { chromaRows += 1; if firstChroma < 0 { firstChroma = r } }
            }
        } else if let (c2, c2s) = plane(2) {
            for r in 0..<ch {
                let u = planes[1].withUnsafeBufferPointer { memcmp(c1 + r * c1s, $0.baseAddress! + r * cw, cw) != 0 }
                let v = planes[2].withUnsafeBufferPointer { memcmp(c2 + r * c2s, $0.baseAddress! + r * cw, cw) != 0 }
                if u || v { chromaRows += 1; if firstChroma < 0 { firstChroma = r } }
            }
        }
        if lumaRows == 0 && chromaRows == 0 { return nil }
        return "luma differs on \(lumaRows) rows (first \(firstLuma)), chroma on \(chromaRows) (first \(firstChroma))"
    }
}
