import Foundation
import GlassActCodec

/// Video regions (§4.6) — host-side per-region encoder session. The engine
/// creates one per region via the injected factory at formation and stops
/// it at dissolve.
///
/// Threading contract: `onFrame` MUST be invoked on the engine's confining
/// queue. A synchronous encoder (the mock) may call it inline from
/// `encode`; an asynchronous one (VideoToolbox) is constructed with the
/// engine queue as its callback target and hops.
///
/// `config` is the codec configuration record (HEVC: hvcC) and must be
/// non-nil on at least the first delivered frame — the engine holds
/// VIDEO_START until it has one.
public protocol VideoRegionEncoder: AnyObject {
    /// Wire codec id (`VideoCodec.*`; the mock uses a rig-only id).
    var codecID: UInt8 { get }
    func start(width: Int, height: Int,
               onFrame: @escaping (_ data: [UInt8], _ sync: Bool, _ config: [UInt8]?) -> Void) -> Bool
    /// Submit one tightly-packed BGRA frame (stride = width*4), stamped
    /// with its capture time (monotonic µs). May drop (pacing/backpressure);
    /// dropped frames are simply never delivered. Rate control budgets bits
    /// per unit of TIME: frames skipped upstream (newest-wins pacing on a
    /// thin link) must not shrink each submitted frame's share. The mock
    /// rig is clock-free and ignores the time.
    func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64)
    /// Adaptive quality: 0 = best, higher = lower quality / fewer bytes.
    /// HEVC maps it to average bitrate. Runtime, no re-init.
    /// Default no-op (the mock rig is deterministic and ignores it).
    func setQualityLevel(_ level: Int)
    /// Ceiling on the average bitrate (bits/s) from the measured link rate;
    /// nil = none. Applied under the quality level's own target. Runtime.
    /// Default no-op (the mock rig ignores it).
    func setBitrateCap(_ bitsPerSecond: Int?)
    func stop()
}

public extension VideoRegionEncoder {
    func setQualityLevel(_ level: Int) {}
    func setBitrateCap(_ bitsPerSecond: Int?) {}
}

/// Video regions — viewer-side per-region decoder session. Same threading contract:
/// `onPixels` fires on the viewer engine's confining queue with the decoded
/// BGRA pixels and their row stride (≥ width*4) — straight from the decoder's
/// own buffer where possible, valid only for the call.
public protocol VideoRegionDecoder: AnyObject {
    func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool
    /// Returns false when the frame could not be decoded (corrupt data, a
    /// dead hardware session, or a non-sync frame while re-synchronizing
    /// after a failure). The engine then asks the host for a sync frame
    /// (SYNC_REQUEST) and detects a region that stays undecodable.
    @discardableResult
    func decode(_ data: [UInt8], sync: Bool,
                onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool
    func stop()
}

/// Deterministic stand-in codec for the trace/golden rig (tests and
/// glassact-bench). "Lossy" is modeled as 5-bit channel quantization (alpha
/// forced opaque); each frame is absolute (marker byte + LZ4-or-raw of the
/// quantized region), so the mock is byte-deterministic across runs — which
/// is exactly what the golden bar needs: the canvas *diverges measurably*
/// while a region is live and must return to byte-exact after dissolve +
/// lossless repaint. Never negotiated on a real wire (rig-only codec id).
public final class MockVideoEncoder: VideoRegionEncoder {
    public static let mockCodecID: UInt8 = 0x7F
    /// Second rig-only id (maps to the reserved AV1 caps bit) for codec
    /// negotiation tests.
    public static let mockAltCodecID: UInt8 = 0x7E
    public let codecID: UInt8

    private var width = 0
    private var height = 0
    private var onFrame: (([UInt8], Bool, [UInt8]?) -> Void)?
    private var sentFirst = false
    private let lz4 = LZ4Codec()
    private var quant: [UInt8] = []
    private var out: [UInt8] = []

    public init(codecID: UInt8 = MockVideoEncoder.mockCodecID) {
        self.codecID = codecID
    }

    public func start(width: Int, height: Int,
                      onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
        self.width = width
        self.height = height
        self.onFrame = onFrame
        sentFirst = false
        quant = [UInt8](repeating: 0, count: width * height * 4)
        out = [UInt8](repeating: 0, count: width * height * 4)
        return width > 0 && height > 0
    }

    public static func config(codecID: UInt8 = MockVideoEncoder.mockCodecID,
                              width: Int, height: Int) -> [UInt8] {
        [0x4D, 0x4B, codecID, // "MK" + id (decoder cross-checks id vs config)
         UInt8(truncatingIfNeeded: width), UInt8(truncatingIfNeeded: width >> 8),
         UInt8(truncatingIfNeeded: height), UInt8(truncatingIfNeeded: height >> 8)]
    }

    public func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
        guard let onFrame else { return }
        let n = width * height * 4
        precondition(bgra.count >= n)
        quant.withUnsafeMutableBytes { q in
            let src = bgra.bindMemory(to: UInt8.self)
            let dst = q.bindMemory(to: UInt8.self)
            for i in 0..<n {
                dst[i] = (i & 3) == 3 ? 0xFF : src[i] & 0xF8
            }
        }
        let lz4Len = quant.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                lz4.encode(src: s, dst: d)
            }
        }
        var frame: [UInt8]
        if lz4Len > 0 {
            frame = [1]
            frame.append(contentsOf: out[0..<lz4Len])
        } else {
            frame = [0]
            frame.append(contentsOf: quant)
        }
        let sync = !sentFirst || forceSync
        let config = sentFirst ? nil : Self.config(codecID: codecID, width: width, height: height)
        sentFirst = true
        onFrame(frame, sync, config)
    }

    public func stop() {
        onFrame = nil
    }
}

public final class MockVideoDecoder: VideoRegionDecoder {
    private var width = 0
    private var height = 0
    private var pixels: [UInt8] = []
    private let lz4 = LZ4Codec()

    public init() {}

    public func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
        guard codec == MockVideoEncoder.mockCodecID || codec == MockVideoEncoder.mockAltCodecID,
              config == MockVideoEncoder.config(codecID: codec, width: width, height: height)
        else { return false }
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        return true
    }

    @discardableResult
    public func decode(_ data: [UInt8], sync: Bool,
                       onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
        let n = width * height * 4
        guard let marker = data.first else { return false }
        switch marker {
        case 1:
            let ok = pixels.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    lz4.decode(src: UnsafeRawBufferPointer(rebasing: src[1...]), dst: dst) == n
                }
            }
            guard ok else { return false }
        case 0:
            guard data.count == n + 1 else { return false }
            pixels.replaceSubrange(0..<n, with: data[1...])
        default:
            return false
        }
        pixels.withUnsafeBytes { onPixels($0, width * 4) }
        return true
    }

    public func stop() {}
}
