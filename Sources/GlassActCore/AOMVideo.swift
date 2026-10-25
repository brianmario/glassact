public import Foundation
import Accelerate
import GlassActWire
import libaom

/// Video regions (§4.6): software AV1 via the vendored libaom, for a Viewer
/// that opts in. Realtime mode with screen tools (palette, IntraBC), low
/// delay, CBR, key frames only on demand (region start / forceSync).
/// Apple silicon only: `isAvailable` is false on Intel, where the Host
/// doesn't offer AV1.
///
/// Rate control mirrors `VTHEVCRegionEncoder` so the engine treats both
/// alike: the same base bitrate, quality ladder and link cap, and the
/// frame-QP ceiling mapped onto libaom's quantizer scale.
///
/// Pipeline: BGRA → I420 (vImage, BT.709 video range) on the caller's
/// queue, then the encode on a private serial queue so the multi-millisecond
/// libaom call never stalls the engine's tick. Each submit delivers exactly
/// one frame on `callbackQueue` (an empty one when it failed), which the
/// engine's pending-frame pacing counts on.
///
/// Concurrency (`@unchecked Sendable`): `handle`, `width`, `height`,
/// `conversion`, the rate state and `onFrame` belong to the caller's queue
/// (the engine's). libaom calls run only on `encodeQueue`; work crossing to
/// it carries what it needs by value. `pool` is guarded by `poolLock`.
public final class AOMRegionEncoder: VideoRegionEncoder, @unchecked Sendable {
    public static var isAvailable: Bool { glassact_aom_available() != 0 }
    public var codecID: UInt8 { VideoCodec.av1 }

    private let callbackQueue: DispatchQueue
    private let encodeQueue = DispatchQueue(label: "glassact.av1.encode", qos: .userInteractive)
    private var handle: Handle?
    private var width = 0
    private var height = 0
    private var onFrame: (([UInt8], Bool, [UInt8]?) -> Void)?
    /// The av1C record, sent with the first delivered frame (a key frame).
    private var config: [UInt8]?
    private var conversion = vImage_ARGBToYpCbCr()
    private let poolLock = NSLock()
    private var pool: [I420Buffer] = []
    private var lastTimeUS: UInt64 = 0

    private var baseBitrate = 20_000_000
    private var qualityLevel = 0
    private var bitrateCap: Int?
    private var appliedBitrate = 0
    private var maxFrameQP = VTHEVCRegionEncoder.defaultMaxFrameQP

    /// libaom worker threads: most of the machine, leaving room for the tile
    /// path and capture. Measured at 8 (BENCHMARKS "AV2 on screen text").
    private let threads = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

    /// `callbackQueue` must be the host engine's confining queue (the
    /// VideoRegionEncoder threading contract).
    public init(callbackQueue: DispatchQueue) {
        self.callbackQueue = callbackQueue
    }

    public func start(width: Int, height: Int,
                      onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
        guard Self.isAvailable, width & 1 == 0, height & 1 == 0 else { return false }
        self.width = width
        self.height = height
        self.onFrame = onFrame
        // The same budget as HEVC: at equal bytes AV1's screen tools buy
        // sharper text, not more bandwidth.
        baseBitrate = min(20_000_000, max(2_000_000, width * height * 12))
        appliedBitrate = Self.target(base: baseBitrate, level: qualityLevel, cap: bitrateCap)
        guard let raw = glassact_aom_enc_create(Int32(width), Int32(height), Int32(threads),
                                                Int32(appliedBitrate / 1000)) else { return false }
        handle = Handle(raw: raw)
        glassact_aom_enc_set_max_quantizer(raw, Int32(Self.quantizer(forFrameQP: maxFrameQP)))
        var header = [UInt8](repeating: 0, count: 256)
        let length = glassact_aom_enc_sequence_header(raw, &header, header.count)
        guard length > 0, let record = AV1Config.build(sequenceHeaderOBU: Array(header.prefix(Int(length)))),
              Self.makeConversion(&conversion) else {
            teardown()
            return false
        }
        config = record
        poolLock.withLock { pool = (0..<4).map { _ in I420Buffer(width: width, height: height) } }
        lastTimeUS = 0
        return true
    }

    public func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
        guard let handle, onFrame != nil else { return }
        guard let buffer = poolLock.withLock({ pool.popLast() }) else {
            deliverNothing() // one delivery per submit
            return
        }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bgra.baseAddress),
                                height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: width * 4)
        var yp = vImage_Buffer(data: buffer.y.baseAddress, height: vImagePixelCount(height),
                               width: vImagePixelCount(width), rowBytes: width)
        var cb = vImage_Buffer(data: buffer.u.baseAddress, height: vImagePixelCount(height / 2),
                               width: vImagePixelCount(width / 2), rowBytes: width / 2)
        var cr = vImage_Buffer(data: buffer.v.baseAddress, height: vImagePixelCount(height / 2),
                               width: vImagePixelCount(width / 2), rowBytes: width / 2)
        var permuteMap: [UInt8] = [3, 2, 1, 0] // BGRA in memory → ARGB
        guard vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&src, &yp, &cb, &cr, &conversion, &permuteMap,
                                                      vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            recycle(buffer)
            deliverNothing()
            return
        }
        // Rate control budgets bits per unit of time: a frame's duration is
        // the time since the last submit, so frames skipped upstream don't
        // shrink this one's share (the VideoRegionEncoder contract).
        let duration = lastTimeUS == 0 ? 16_667 : min(1_000_000, max(1, timeUS &- lastTimeUS))
        lastTimeUS = timeUS
        let job = Job(handle: handle, buffer: buffer, width: width, height: height,
                      ptsUS: Int64(clamping: timeUS), durationUS: UInt32(duration), forceSync: forceSync,
                      config: config)
        config = nil // claimed: goes with this frame, which is a key frame (the first)
        encodeQueue.async { [weak self] in self?.run(job) }
    }

    public func setQualityLevel(_ level: Int) {
        guard handle != nil, level != qualityLevel else { return }
        qualityLevel = level
        applyBitrate()
    }

    public func setBitrateCap(_ bitsPerSecond: Int?) {
        bitrateCap = bitsPerSecond
        applyBitrate()
    }

    public func setMaxFrameQP(_ qp: Int?) {
        let ceiling = qp ?? VTHEVCRegionEncoder.defaultMaxFrameQP
        guard ceiling != maxFrameQP else { return }
        maxFrameQP = ceiling
        guard let handle else { return }
        let quantizer = Int32(Self.quantizer(forFrameQP: ceiling))
        encodeQueue.async { glassact_aom_enc_set_max_quantizer(handle.raw, quantizer) }
    }

    public func stop() {
        onFrame = nil
        teardown()
    }

    deinit {
        teardown()
    }

    // MARK: - Rate control

    /// The quality level's share of the base, under the link cap: the HEVC
    /// encoder's ladder (~0.66× per step).
    static func target(base: Int, level: Int, cap: Int?) -> Int {
        let factor = [1.0, 0.66, 0.45, 0.33][min(max(level, 0), 3)]
        var target = Int(Double(base) * factor)
        if let cap { target = max(300_000, min(target, cap)) }
        return target
    }

    /// HEVC frame QP (0–51) → libaom's quantizer (0–63): the same fraction
    /// of each scale. HEVC's 34 floor is 42, its sharp 28 is 35.
    static func quantizer(forFrameQP qp: Int) -> Int {
        min(63, max(0, Int((Double(qp) * 63 / 51).rounded())))
    }

    private func applyBitrate() {
        guard let handle else { return }
        let target = Self.target(base: baseBitrate, level: qualityLevel, cap: bitrateCap)
        // As for HEVC: skip moves under 5 %, each one resets rate control.
        guard abs(target - appliedBitrate) * 20 > appliedBitrate else { return }
        appliedBitrate = target
        let kbps = Int32(target / 1000)
        encodeQueue.async { glassact_aom_enc_set_bitrate(handle.raw, kbps) }
    }

    // MARK: - Encode queue

    /// The libaom encoder; used only on `encodeQueue` once created (destroy
    /// is queued behind every encode).
    private struct Handle: @unchecked Sendable {
        let raw: OpaquePointer
    }

    /// One submit, by value. `@unchecked`: the pooled buffer belongs to the
    /// one block that receives the job.
    private struct Job: @unchecked Sendable {
        let handle: Handle
        let buffer: I420Buffer
        let width: Int
        let height: Int
        let ptsUS: Int64
        let durationUS: UInt32
        let forceSync: Bool
        let config: [UInt8]?
    }

    private func run(_ job: Job) {
        defer { recycle(job.buffer) }
        var frame = glassact_aom_frame(
            planes: (UnsafePointer(job.buffer.y.baseAddress!.assumingMemoryBound(to: UInt8.self)),
                     UnsafePointer(job.buffer.u.baseAddress!.assumingMemoryBound(to: UInt8.self)),
                     UnsafePointer(job.buffer.v.baseAddress!.assumingMemoryBound(to: UInt8.self))),
            strides: (Int32(job.width), Int32(job.width / 2), Int32(job.width / 2)),
            width: Int32(job.width), height: Int32(job.height))
        // The first frame carries the config, so it must be a key frame.
        let forceKey: Int32 = job.forceSync || job.config != nil ? 1 : 0
        guard glassact_aom_enc_encode(job.handle.raw, &frame, job.ptsUS, job.durationUS, forceKey) == 0 else {
            deliverNothing()
            return
        }
        // Low delay: one temporal unit per frame. Joined in case libaom ever
        // splits one, since the engine counts one delivery per submit.
        var data: [UInt8] = []
        var sync = false
        var size = 0, isKey: Int32 = 0
        while let packet = glassact_aom_enc_next_packet(job.handle.raw, &size, &isKey) {
            data.append(contentsOf: UnsafeBufferPointer(start: packet, count: size))
            sync = sync || isKey != 0
        }
        guard !data.isEmpty else {
            deliverNothing()
            return
        }
        let (payload, isSync, config) = (data, sync, job.config)
        callbackQueue.async { [weak self] in
            guard let self, let onFrame = self.onFrame else { return }
            onFrame(payload, isSync, config)
        }
    }

    private func deliverNothing() {
        callbackQueue.async { [weak self] in
            guard let self, let onFrame = self.onFrame else { return }
            onFrame([], false, nil)
        }
    }

    private func recycle(_ buffer: I420Buffer) {
        poolLock.withLock { pool.append(buffer) }
    }

    private func teardown() {
        guard let handle else { return }
        self.handle = nil
        encodeQueue.async { glassact_aom_enc_destroy(handle.raw) } // after any encode in flight
    }

    /// BT.709 video range, as the y4m export and the HEVC encoder use.
    static func makeConversion(_ conversion: inout vImage_ARGBToYpCbCr) -> Bool {
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        // Our own constant: the vImage global is imported as shared mutable
        // state, which Swift 6 rejects.
        var matrix = vImage_ARGBToYpCbCrMatrix(
            R_Yp: 0.2126, G_Yp: 0.7152, B_Yp: 0.0722,
            R_Cb: -0.2126 / 1.8556, G_Cb: -0.7152 / 1.8556,
            B_Cb_R_Cr: 0.5, G_Cr: -0.7152 / 1.5748, B_Cr: -0.0722 / 1.5748)
        return vImageConvert_ARGBToYpCbCr_GenerateConversion(
            &matrix, &pixelRange, &conversion, kvImageARGB8888, kvImage420Yp8_Cb8_Cr8,
            vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
}

/// An I420 picture's three planes.
final class I420Buffer {
    let y: UnsafeMutableRawBufferPointer
    let u: UnsafeMutableRawBufferPointer
    let v: UnsafeMutableRawBufferPointer

    init(width: Int, height: Int) {
        y = .allocate(byteCount: width * height, alignment: 64)
        u = .allocate(byteCount: width * height / 4, alignment: 64)
        v = .allocate(byteCount: width * height / 4, alignment: 64)
    }

    deinit {
        y.deallocate()
        u.deallocate()
        v.deallocate()
    }
}

/// Software AV1 decode with libaom, for the bench and tests. (The Viewer
/// decodes AV1 in hardware.) Synchronous: `onPixels` runs inside `decode`
/// with BGRA converted from the decoded I420.
public final class AOMRegionDecoder: VideoRegionDecoder {
    private var decoder: OpaquePointer?
    private var conversion = vImage_YpCbCrToARGB()
    private var bgra: UnsafeMutableRawBufferPointer?
    private var width = 0
    private var height = 0

    public init() {}

    public func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
        guard codec == VideoCodec.av1, glassact_aom_available() != 0 else { return false }
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var matrix = vImage_YpCbCrToARGBMatrix(Yp: 1, Cr_R: 1.5748, Cr_G: -0.4681, Cb_G: -0.1873, Cb_B: 1.8556)
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(
            &matrix, &pixelRange, &conversion, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              let created = glassact_aom_dec_create(2) else { return false }
        stop()
        decoder = created
        self.width = width
        self.height = height
        bgra = .allocate(byteCount: width * height * 4, alignment: 64)
        return true
    }

    @discardableResult
    public func decode(_ data: [UInt8], sync: Bool,
                       onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
        guard let decoder, let bgra else { return false }
        var frame = glassact_aom_frame()
        guard glassact_aom_dec_decode(decoder, data, data.count, &frame) == 0,
              Int(frame.width) == width, Int(frame.height) == height,
              let y = frame.planes.0, let u = frame.planes.1, let v = frame.planes.2 else { return false }
        var yp = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: y), height: vImagePixelCount(height),
                               width: vImagePixelCount(width), rowBytes: Int(frame.strides.0))
        var cb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: u), height: vImagePixelCount(height / 2),
                               width: vImagePixelCount(width / 2), rowBytes: Int(frame.strides.1))
        var cr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: v), height: vImagePixelCount(height / 2),
                               width: vImagePixelCount(width / 2), rowBytes: Int(frame.strides.2))
        var dst = vImage_Buffer(data: bgra.baseAddress, height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width * 4)
        var permuteMap: [UInt8] = [3, 2, 1, 0] // ARGB → BGRA in memory
        guard vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&yp, &cb, &cr, &dst, &conversion, &permuteMap, 255,
                                                      vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return false
        }
        onPixels(UnsafeRawBufferPointer(bgra), width * 4)
        return true
    }

    public func stop() {
        if let decoder { glassact_aom_dec_destroy(decoder) }
        decoder = nil
        bgra?.deallocate()
        bgra = nil
    }

    deinit {
        stop()
    }
}

/// ISO/IEC 14496-15 `av1C` configuration record: what VIDEO_START carries
/// for AV1, and what VideoToolbox's AV1 decoder takes as its sample
/// description extension. Built from the encoder's sequence header OBU.
public enum AV1Config {
    public static func build(sequenceHeaderOBU obu: [UInt8]) -> [UInt8]? {
        guard let (profile, level, tier) = parse(obu) else { return nil }
        return [
            0x81, // marker 1, version 1
            UInt8(profile << 5 | level & 0x1F), // seq_profile, seq_level_idx_0
            UInt8(tier << 7) | 0x0C, // seq_tier_0; 8-bit, 4:2:0 (subsampling x and y)
            0x00, // no initial presentation delay
        ] + obu
    }

    /// (seq_profile, seq_level_idx[0], seq_tier[0]) from a sequence header
    /// OBU. Checked reads; nil for any shape this doesn't handle.
    static func parse(_ obu: [UInt8]) -> (Int, Int, Int)? {
        guard let first = obu.first, first & 0x80 == 0, (first >> 3) & 0x0F == 1 else { return nil }
        var i = first & 0x04 != 0 ? 2 : 1
        if first & 0x02 != 0 { // leb128 size
            while i < obu.count, obu[i] & 0x80 != 0 { i += 1 }
            i += 1
        }
        var bit = i * 8
        func read(_ n: Int) -> Int? {
            var value = 0
            for _ in 0..<n {
                guard bit >> 3 < obu.count else { return nil }
                value = value << 1 | Int(obu[bit >> 3] >> (7 - UInt8(bit & 7)) & 1)
                bit += 1
            }
            return value
        }
        guard let profile = read(3), read(1) != nil, let reduced = read(1) else { return nil }
        if reduced == 1 {
            guard let level = read(5) else { return nil }
            return (profile, level, 0)
        }
        // timing_info_present_flag 0 (libaom realtime doesn't write timing
        // info), initial_display_delay_present_flag, then operating point 0.
        guard read(1) == 0, read(1) != nil, read(5) != nil, read(12) != nil,
              let level = read(5) else { return nil }
        let tier = level > 7 ? read(1) ?? 0 : 0
        return (profile, level, tier)
    }
}
