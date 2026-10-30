public import Foundation
import CoreMedia
import CoreVideo
import GlassActWire
import Synchronization
import VideoToolbox

/// Video regions (§4.6) — hardware HEVC region codec via VideoToolbox
/// (Apple Silicon media engine). Realtime, no frame reordering (no B-frames — every frame refs
/// backward only, so latency is one frame deep), IDR only on demand
/// (region start / forceSync).
///
/// Config record layout (ours, carried opaque in VIDEO_START):
/// `{count u8, count × {len u16 LE, bytes}}` — the HEVC parameter sets
/// (VPS/SPS/PPS) in index order. Frame payloads are the encoder's native
/// 4-byte-length-prefixed NAL units, passed through untouched.
///
/// Concurrency (`@unchecked Sendable`): session state belongs to the
/// caller's queue (the engine's); VT's output handler runs on VT's own
/// thread and touches only `configClaimed` (a Mutex) and `callbackQueue`
/// (immutable); `onFrame` is read only on `callbackQueue` (the engine's
/// queue, where it's set).
///
/// Every VideoToolbox call (create, encode, set a property, invalidate) runs
/// on `vtQueue`, never the caller's: they're XPC calls to the system's
/// encoder service, and one that never answers would otherwise hold the
/// engine's queue (live in an airport lounge, 2026-10-26: the first encode
/// after a virtual display came up blocked in
/// `RemoteVideoEncoder_CopySupportedPropertyDictionary` for minutes, and the
/// session went black, then silent). `start` waits for the service at most
/// `startTimeout`; frames that never come back are the engine's to notice
/// (`HostEngine.videoEncoderStallUS`).
public final class VTHEVCRegionEncoder: VideoRegionEncoder, @unchecked Sendable {
    public var codecID: UInt8 { VideoCodec.hevc }

    private let callbackQueue: DispatchQueue
    private var session: VTCompressionSession?
    private var baseBitrate = 20_000_000
    private var qualityLevel = 0
    private var bitrateCap: Int?
    private var appliedBitrate = 0
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0
    /// Last presentation time handed to VT (µs); PTS must strictly increase.
    private var lastPTSUS: Int64 = -1
    /// Claimed on VT's output thread when the parameter sets are extracted
    /// (emit runs there, not on callbackQueue) — a plain Bool read there
    /// and written on callbackQueue would be a data race.
    private let configClaimed = Mutex(false)
    private var onFrame: (([UInt8], Bool, [UInt8]?) -> Void)?
    private let vtQueue = DispatchQueue(label: "glassact.vt.encode")
    /// How long `start` waits for the encoder service before reporting
    /// failure (creating a 5K session takes ~50 ms).
    static let startTimeout: DispatchTimeInterval = .seconds(2)

    /// Ask VideoToolbox for its low-latency rate control (the video-call
    /// mode). Falls back to the normal session if refused; `lowLatencyActive`
    /// says which ran. Off in the product: measured (`glassact-bench
    /// vquality`, BENCHMARKS 'Video-layer quality: low-latency RC and
    /// half-res encode, measured') it overshoots the target 20–100 % (9× on
    /// photos) with 2–3× burstier frames — wrong for a send gate that
    /// trusts the encoder's cap — for a quality edge that is mostly bytes.
    public let lowLatency: Bool
    public private(set) var lowLatencyActive = false
    /// Applied at `start`: a ceiling on frame QP — a quality floor: the
    /// encoder may not quantize coarser than this. Nil = VT's choice.
    public var maxFrameQP: Int? = VTHEVCRegionEncoder.defaultMaxFrameQP
    /// The floor in the product (`glassact-bench vquality`, BENCHMARKS
    /// 'Soft video for minutes: capture-time PTS, QP 34 floor, re-sharpen'):
    /// with capture-time stamps it never binds on a healthy
    /// link (byte-identical output at 12 Mbit/s on every reference trace),
    /// and on a thin one it keeps text legible (worst-frame SSIM 0.76 →
    /// 0.93 at 1 Mbit/s) — the bytes over the cap come out of frame rate
    /// via the send gate, never as lag.
    public static let defaultMaxFrameQP = 34
    /// Experiment (macOS 27): VT's constant-quality rate control, 0–1 —
    /// "consistent visual quality with or without bitrate limit
    /// constraints". Nil = average-bitrate rate control (the product).
    /// With `capWithVBV` the link cap becomes a VBV peak (1 s buffer) instead
    /// of an average + DataRateLimits.
    public var constantQualityFactor: Float?
    public var capWithVBV = false
    /// Bench-only: every frame at this QP (min = max allowed frame QP) under
    /// a bitrate that never binds, so bytes measure content, not a target.
    public var pinnedFrameQP: Int?
    /// Experiment: kVTCompressionPropertyKey_RealTime (the product: true).
    public var realTime = true
    /// Experiment: full-resolution chroma. Apple silicon's hardware HEVC
    /// encoder lists `HEVC_Main444_AutoLevel` among its supported profiles,
    /// though the SDK declares no constant for it.
    public var chroma444 = false
    public private(set) var chroma444Accepted = false
    /// Whether VT accepted each knob (VTSessionSetProperty status).
    public private(set) var maxFrameQPAccepted = false
    public private(set) var constantQualityAccepted = false


    /// `callbackQueue` must be the host engine's confining queue (the
    /// VideoRegionEncoder threading contract).
    public init(callbackQueue: DispatchQueue, lowLatency: Bool = false) {
        self.callbackQueue = callbackQueue
        self.lowLatency = lowLatency
    }

    public func start(width: Int, height: Int,
                      onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        nonisolated(unsafe) let onFrame = onFrame
        vtQueue.async { [self] in
            let ok = startOnVTQueue(width: width, height: height, onFrame: onFrame)
            started.withLock { $0 = ok }
            done.signal()
        }
        // Abandoned on a timeout: the engine drops this encoder, and deinit
        // invalidates whatever session the late call leaves behind.
        guard done.wait(timeout: .now() + Self.startTimeout) == .success else { return false }
        return started.withLock { $0 }
    }

    private func startOnVTQueue(width: Int, height: Int,
                                onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
        self.width = width
        self.height = height
        self.onFrame = onFrame
        configClaimed.withLock { $0 = false }

        func create(_ spec: CFDictionary?) -> VTCompressionSession? {
            var s: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: spec, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &s)
            return status == noErr ? s : nil
        }
        lowLatencyActive = false
        var created: VTCompressionSession?
        if lowLatency {
            created = create([kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!] as CFDictionary)
            lowLatencyActive = created != nil
        }
        if created == nil { created = create(nil) }
        guard let session = created else { return false }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: realTime ? kCFBooleanTrue : kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        if chroma444 {
            chroma444Accepted = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                                     value: "HEVC_Main444_AutoLevel" as CFString) == noErr
        }
        if !chroma444Accepted {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main_AutoLevel)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: 3600 as CFNumber) // IDRs are on-demand, not periodic
        // ~0.2 bpp at 60 fps (12 bits/pixel/s), clamped: broadcast-ish
        // quality on photographic churn; a half-5K region caps at 20 Mbps —
        // in family with Apple's high-performance screen-sharing budget.
        baseBitrate = min(20_000_000, max(2_000_000, width * height * 12))
        // Bench-only knob; the key exists from macOS 27.
        if #available(macOS 27, iOS 27, *), let cqf = constantQualityFactor {
            constantQualityAccepted = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ConstantQualityFactor,
                                                           value: cqf as CFNumber) == noErr
        }
        appliedBitrate = 0
        applyBitrate()
        if let qp = maxFrameQP {
            maxFrameQPAccepted = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                                                      value: qp as CFNumber) == noErr
        }
        if let qp = pinnedFrameQP {
            maxFrameQPAccepted = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                                                      value: qp as CFNumber) == noErr
                && VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MinAllowedFrameQP,
                                        value: qp as CFNumber) == noErr
        }

        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var p: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, poolAttrs as CFDictionary, &p) == noErr,
              let pool = p else {
            teardown()
            return false
        }
        self.pool = pool
        return true
    }

    /// Adaptive quality: scale the average bitrate down per level
    /// (measured: HEVC q is a bandwidth lever at ~free framerate cost).
    /// 0 = base, then ~0.66× per step. Runtime.
    public func setQualityLevel(_ level: Int) {
        guard session != nil, level != qualityLevel else { return }
        qualityLevel = level
        applyBitrate()
    }

    public func setBitrateCap(_ bitsPerSecond: Int?) {
        bitrateCap = bitsPerSecond
        applyBitrate()
    }

    /// Runtime change of the frame-QP ceiling (nil: the product default).
    /// VT applies MaxAllowedFrameQP mid-session; `maxFrameQPAccepted` says
    /// whether it took.
    public func setMaxFrameQP(_ qp: Int?) {
        let ceiling = qp ?? Self.defaultMaxFrameQP
        guard ceiling != maxFrameQP else { return }
        maxFrameQP = ceiling
        guard let session else { return }
        nonisolated(unsafe) let s = session
        vtQueue.async {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: ceiling as CFNumber)
        }
    }

    /// Quality level's share of the base, under the link cap. The cap also
    /// bounds bursts (DataRateLimits over 1 s): an average alone lets VT
    /// spend seconds of link time on one detailed frame.
    private func applyBitrate() {
        guard let session else { return }
        let factor = [1.0, 0.66, 0.45, 0.33][min(qualityLevel, 3)]
        var target = Int(Double(baseBitrate) * factor)
        if let cap = bitrateCap { target = max(300_000, min(target, cap)) }
        if pinnedFrameQP != nil { target = 500_000_000 }
        // Re-setting VT's rate costs a rate-control reset; skip < 5% moves.
        guard appliedBitrate == 0 || abs(target - appliedBitrate) * 20 > appliedBitrate else { return }
        appliedBitrate = target
        let vbv = capWithVBV, limits = bitrateCap != nil, rate = target
        nonisolated(unsafe) let s = session
        vtQueue.async {
            // Bench-only knob; the VBV keys exist from macOS 26.
            if #available(macOS 26, iOS 26, *), vbv {
                VTSessionSetProperty(s, key: kVTCompressionPropertyKey_VBVMaxBitRate, value: rate as CFNumber)
                VTSessionSetProperty(s, key: kVTCompressionPropertyKey_VBVBufferDuration, value: 1.0 as CFNumber)
                return
            }
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: rate as CFNumber)
            if limits {
                VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                                     value: [Double(rate) * 1.5 / 8, 1.0] as CFArray)
            }
        }
    }

    /// Stamped with the capture time. VT's rate control spends the average
    /// bitrate over presentation time: stamped 1/60 s apart, frames that
    /// actually arrive 1/10 s apart (newest-wins skips on a thin link) would
    /// get a sixth of the bits the link could carry — soft beyond reading.
    public func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
        guard let session, let pool else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == noErr, let pixelBuffer = pb else {
            deliverNothing()
            return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dst = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let rowBytes = width * 4
        for row in 0..<height {
            dst.advanced(by: row * dstStride)
                .copyMemory(from: bgra.baseAddress!.advanced(by: row * rowBytes), byteCount: rowBytes)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let us = max(Int64(clamping: timeUS), lastPTSUS + 1)
        lastPTSUS = us
        let pts = CMTime(value: us, timescale: 1_000_000)
        nonisolated(unsafe) let frame = pixelBuffer
        nonisolated(unsafe) let s = session
        vtQueue.async { [weak self] in
            let frameProps: CFDictionary? = forceSync
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
                : nil
            let status = VTCompressionSessionEncodeFrame(
                s, imageBuffer: frame, presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: frameProps,
                infoFlagsOut: nil
            ) { [weak self] status, _, sampleBuffer in
                // VT's own callback thread → hop to the engine queue.
                guard let self else { return }
                guard status == noErr, let sampleBuffer else {
                    self.deliverNothing()
                    return
                }
                self.emit(sampleBuffer)
            }
            if status != noErr {
                self?.deliverNothing()
            }
        }
    }

    /// Pacing correctness: the engine counts pending frames; every submit must
    /// produce exactly one delivery or the counter leaks. A failed encode
    /// delivers an empty frame the engine drops at zero cost.
    private func deliverNothing() {
        callbackQueue.async { [weak self] in
            guard let self, let onFrame = self.onFrame else { return }
            onFrame([], false, nil)
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        let sync = Self.isSync(sampleBuffer)
        // Copy out the payload. CopyDataBytes, not GetDataPointer: the
        // pointer from GetDataPointer is only valid for the first
        // contiguous piece, and a block buffer is not guaranteed to be one.
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            deliverNothing()
            return
        }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else {
            deliverNothing()
            return
        }
        var data = [UInt8](repeating: 0, count: length)
        let copied = data.withUnsafeMutableBytes { dst in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length,
                                       destination: dst.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else {
            deliverNothing()
            return
        }
        // Claimed only once this frame is certain to be delivered, so the
        // config can't be claimed by a frame that then goes nowhere.
        var config: [UInt8]?
        if !configClaimed.withLock({ $0 }),
           let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let sets = Self.extractParameterSets(desc) {
            config = sets
            configClaimed.withLock { $0 = true }
        }
        callbackQueue.async { [weak self, data, config] in
            guard let self, let onFrame = self.onFrame else { return }
            onFrame(data, sync, config)
        }
    }

    /// NotSync's value, not just its presence: the Apple silicon encoder
    /// leaves the key off sync frames, but the software HEVC encoder writes
    /// NotSync = false on them. Reading presence alone marks every frame
    /// not-sync there, and the Viewer waits for an IDR that never comes.
    static func isSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0
        else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        guard let value = CFDictionaryGetValue(dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        else { return true }
        return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    static func extractParameterSets(_ desc: CMFormatDescription) -> [UInt8]? {
        var count = 0
        var nalHeaderLength: Int32 = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            desc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength) == noErr,
            count > 0, count < 256, nalHeaderLength == 4 else { return nil }
        var out: [UInt8] = [UInt8(count)]
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                desc, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                let ptr, size > 0, size <= 0xFFFF else { return nil }
            out.append(UInt8(truncatingIfNeeded: size))
            out.append(UInt8(truncatingIfNeeded: size >> 8))
            out.append(contentsOf: UnsafeBufferPointer(start: ptr, count: size))
        }
        return out
    }

    public func stop() {
        onFrame = nil
        teardown()
    }

    private func teardown() {
        if let session {
            nonisolated(unsafe) let s = session
            vtQueue.async { VTCompressionSessionInvalidate(s) }
        }
        session = nil
        pool = nil
    }

    deinit {
        teardown()
    }
}

/// Decode side: hardware HEVC (parameter-set config) and hardware AV1
/// (`av1C` config; M3 and later — VideoToolbox has no software AV1 decoder,
/// so `start` fails on older Macs).
/// Synchronous decode (no async decompression flag), so `onPixels` fires
/// inline on the caller's thread — the viewer engine's queue — honoring the
/// VideoRegionDecoder contract without any hop.
public final class VTRegionDecoder: VideoRegionDecoder {
    /// Hardware AV1 decode that actually works: Apple silicon M3 and later.
    /// VideoToolbox's own answer isn't enough: a macOS VM (the CI runner)
    /// reports hardware AV1 support and then fails to create a session, and a
    /// Viewer that advertised AV1 there would get video it can't show. So
    /// this also creates a session once, for a tiny stream, and keeps the
    /// answer.
    public static let canDecodeAV1: Bool = {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) else { return false }
        let probe = VTRegionDecoder()
        defer { probe.stop() }
        return probe.start(codec: VideoCodec.av1, config: probeAV1C, width: 64, height: 64)
    }()

    /// The av1C record of a 64×64, 8-bit 4:2:0 stream from the vendored
    /// libaom (`AV1Config.build` of its sequence header).
    static let probeAV1C: [UInt8] = [0x81, 0x00, 0x0C, 0x00, 0x0A, 0x09, 0x00, 0x00, 0x00, 0x02, 0xAF, 0xFF,
                                     0x80, 0x34, 0x01]

    /// What this Viewer advertises, in Glass Act codec ids. AV1 only when the
    /// user opted in and this Mac decodes it: the Host prefers AV1 whenever
    /// it's offered (§4.6).
    public static func supportedCodecs(av1: Bool) -> [UInt8] {
        av1 && canDecodeAV1 ? [VideoCodec.av1, VideoCodec.hevc] : [VideoCodec.hevc]
    }

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var width = 0
    private var height = 0
    private var awaitingSync = false

    /// Written by VT's output handler, which runs synchronously inside
    /// DecodeFrame (no async flag) — before `decode` reads it.
    private final class DecodeResult: @unchecked Sendable {
        var status: OSStatus = noErr
        var image: CVImageBuffer?
    }

    public init() {}

    public func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
        self.width = width
        self.height = height
        switch codec {
        case VideoCodec.hevc: return startHEVC(config: config)
        case VideoCodec.av1: return startAV1(config: config)
        default: return false
        }
    }

    /// AV1: the wire config is the av1C record. It becomes the format
    /// description's sample description extension, as in an MP4 file.
    private func startAV1(config: [UInt8]) -> Bool {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1), config.count >= 5, config[0] == 0x81 else {
            return false
        }
        var desc: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": Data(config)] as CFDictionary,
        ]
        guard CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_AV1, width: Int32(width), height: Int32(height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &desc) == noErr,
              let desc else { return false }
        formatDescription = desc
        return createSession(with: desc)
    }

    private func startHEVC(config: [UInt8]) -> Bool {

        // Parse our config record back into parameter sets.
        var sets: [[UInt8]] = []
        var i = 0
        guard config.count >= 1 else { return false }
        let count = Int(config[0])
        i = 1
        for _ in 0..<count {
            guard i + 2 <= config.count else { return false }
            let len = Int(config[i]) | (Int(config[i + 1]) << 8)
            i += 2
            guard i + len <= config.count, len > 0 else { return false }
            sets.append([UInt8](config[i ..< i + len]))
            i += len
        }
        guard i == config.count, !sets.isEmpty else { return false }

        // Parameter-set pointers must stay valid for the Create call: flatten
        // into one backing array and derive pointers inside its scope.
        var desc: CMVideoFormatDescription?
        var flat: [UInt8] = []
        var offsets: [Int] = []
        for set in sets {
            offsets.append(flat.count)
            flat.append(contentsOf: set)
        }
        let sizes = sets.map(\.count)
        let status = flat.withUnsafeBufferPointer { flatBuf -> OSStatus in
            let pointers = offsets.map { flatBuf.baseAddress! + $0 }
            return pointers.withUnsafeBufferPointer { pp in
                sizes.withUnsafeBufferPointer { sp in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: sets.count,
                        parameterSetPointers: pp.baseAddress!, parameterSetSizes: sp.baseAddress!,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
                }
            }
        }
        guard status == noErr, let desc else { return false }
        formatDescription = desc
        return createSession(with: desc)
    }

    private func createSession(with desc: CMVideoFormatDescription) -> Bool {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: nil, formatDescription: desc, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &s) == noErr, let s else { return false }
        session = s
        return true
    }

    /// Recovery: any decode failure — a session invalidated under us
    /// (kVTInvalidSessionErr after sleep/wake or a media-engine reset) or
    /// corrupt data — rebuilds the session from the stored format
    /// description and drops frames until the next sync frame (a P-frame
    /// references state the new session doesn't have). Failures report
    /// `false`, so the engine asks the host for a sync frame (SYNC_REQUEST,
    /// §5) and, as a last resort, escalates a region that stays undecodable.
    @discardableResult
    public func decode(_ data: [UInt8], sync: Bool,
                       onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
        guard let formatDescription, !data.isEmpty else { return false }
        if awaitingSync && !sync { return false }
        if session == nil, !createSession(with: formatDescription) { return false }
        guard let session else { return false }
        // Decode is synchronous (the output handler runs before DecodeFrame
        // returns), so the block buffer can borrow `data`'s storage instead
        // of allocating and copying it (kCFAllocatorNull: never freed by CM).
        let result = DecodeResult()
        let status: OSStatus = data.withUnsafeBytes { src -> OSStatus in
            var blockBuffer: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                blockLength: data.count, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                flags: 0, blockBufferOut: &blockBuffer) == noErr, let blockBuffer else { return -1 }
            var sampleBuffer: CMSampleBuffer?
            var sampleSize = data.count
            guard CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: blockBuffer, formatDescription: formatDescription,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return -1 }
            let submit = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                // Synchronous decode: runs inline before DecodeFrame returns.
                result.status = status
                result.image = imageBuffer
            }
            return submit != noErr ? submit : result.status
        }
        guard status == noErr, let imageBuffer = result.image,
              CVPixelBufferGetWidth(imageBuffer) == width,
              CVPixelBufferGetHeight(imageBuffer) == height else {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            awaitingSync = true
            _ = createSession(with: formatDescription) // retried lazily if this fails
            return false
        }
        awaitingSync = false
        // Hand the engine the decoder's own buffer and stride — it blits
        // straight into the canvas (copying into a tight array first would
        // be a full extra frame copy per frame).
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(imageBuffer) else { return false }
        let stride = CVPixelBufferGetBytesPerRow(imageBuffer)
        onPixels(UnsafeRawBufferPointer(start: base, count: stride * (height - 1) + width * 4), stride)
        return true
    }

    public func stop() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    deinit {
        stop()
    }
}
