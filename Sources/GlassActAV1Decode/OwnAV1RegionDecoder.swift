public import AV1Core
import Accelerate
import Darwin
public import GlassActCore
import GlassActWire

/// Video regions (§4.6): Glass Act's own AV1 decoder (`rust/av1`'s, `av1g/decoder.h`) as a Viewer's
/// region decoder, for the hybrid encoder's streams where VideoToolbox can't show them: 4:4:4 (which
/// it refuses on every Mac), Macs and iPads with no AV1 hardware (M1, M2, older iPads) and Intel
/// Macs. It decodes the writer's toolset only (decoder.h), and on the CPU, so a Viewer offers it
/// under its own caps bit, `videoAV1GlassAct` (`ViewerVideoDecoders.glassAct`), never for libaom's
/// streams.
///
/// - **Start**: `VideoCodec.av1` with an `av1C` config (its sequence header isn't needed: every key
///   frame carries one). The decoder is capped at the region's size
///   (`av1g_decoder_create_capped`): a stream for larger frames fails before anything is allocated
///   for it. The BGRA picture and the colour conversions are made here, not per frame.
/// - **Decode**: one temporal unit, then the frame it shows converted to BGRA with vImage by the
///   matrix and range its sequence header gives (the hybrid's streams BT.709, its stills BT.601;
///   full or video range), 4:2:0 or 4:4:4. A reduced frame (decisions.h "Reduced frames": coded
///   smaller, its render size the stream's) is converted at its coded size and scaled up to the
///   region (vImage's high-quality resampling), since VideoToolbox hands the engine a reduced
///   frame already scaled to the region. Any other size, monochrome, or a matrix it doesn't know is
///   a failure.
/// - **Failure**, as `VTRegionDecoder`'s: any error (damage, a frame outside the toolset, an inter
///   frame whose references the decoder doesn't hold) forgets the stream and drops every frame
///   until a sync frame, and `decode` returns false, so the engine asks for one (SYNC_REQUEST).
/// - **Stop** frees the decoder and the buffers; `start` again builds new ones.
///
/// The pixels `onPixels` gets are this decoder's own buffer (stride width × 4), valid for the
/// call. One region, one thread at a time (the engine's queue); the Rust decoder runs its stages
/// on its own worker threads. `decode` allocates nothing (no `err` text is asked for), except the
/// first reduced frame's coded-size buffer and a larger scaling buffer when its size changes.
public final class OwnAV1RegionDecoder: VideoRegionDecoder {
    /// Time spent per frame shown, in nanoseconds (the bench): the Rust decoder's, and the
    /// conversion to BGRA (with the scaling of reduced frames).
    public struct Stats: Sendable, Equatable {
        public var framesShown = 0, keyFramesShown = 0
        public var decodeNS: UInt64 = 0, convertNS: UInt64 = 0
        public var keyDecodeNS: UInt64 = 0, keyConvertNS: UInt64 = 0
        public var failures = 0
    }

    public private(set) var stats = Stats()
    /// The decoder's threads (0: the available parallelism).
    public let threads: Int

    private var decoder: OpaquePointer?
    private var width = 0
    private var height = 0
    private var awaitingSync = false
    /// The frame the last decode showed, valid until the next call into the decoder.
    private var picture = av1g_dec_picture()
    private var shown = false
    /// The region's BGRA picture (width × height × 4).
    private var bgra: UnsafeMutableRawPointer?
    /// Reduced frames: the coded size's BGRA, and vImage's scaling buffer.
    private var coded: UnsafeMutableRawPointer?
    private var codedBytes = 0
    private var scaleTemp: UnsafeMutableRawPointer?
    private var scaleTempBytes = 0
    /// [3, 2, 1, 0]: vImage's ARGB into BGRA in memory.
    private let permute: UnsafeMutablePointer<UInt8>
    /// By `conversionIndex`: BT.709, BT.601, BT.2020 (non-constant luminance) × video, full range
    /// × 4:2:0, 4:4:4.
    private let conversions: UnsafeMutablePointer<vImage_YpCbCrToARGB>
    private static let conversionCount = 12
    private var conversionsMade = false

    public init(threads: Int = 0) {
        self.threads = threads
        permute = .allocate(capacity: 4)
        (permute[0], permute[1], permute[2], permute[3]) = (3, 2, 1, 0)
        conversions = .allocate(capacity: Self.conversionCount)
        conversions.initialize(repeating: vImage_YpCbCrToARGB(), count: Self.conversionCount)
    }

    deinit {
        stop()
        permute.deallocate()
        conversions.deinitialize(count: Self.conversionCount)
        conversions.deallocate()
    }

    public func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
        stop()
        let maxSide = Int(AV1G_DEC_MAX_DIM)
        guard codec == VideoCodec.av1, config.count >= 4, config[0] == 0x81,
              (1...maxSide).contains(width), (1...maxSide).contains(height),
              makeConversions(),
              let created = av1g_decoder_create_capped(Int32(clamping: threads), UInt32(width), UInt32(height))
        else { return false }
        decoder = created
        self.width = width
        self.height = height
        bgra = .allocate(byteCount: width * height * 4, alignment: 64)
        return true
    }

    @discardableResult
    public func decode(_ data: [UInt8], sync: Bool,
                       onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
        guard let decoder, let bgra, !data.isEmpty else { return false }
        if awaitingSync && !sync { return false }
        shown = false
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let rc = data.withUnsafeBufferPointer { av1g_decoder_decode(decoder, $0.baseAddress, $0.count, &picture, nil, 0) }
        let t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard rc == AV1G_OK, convert(into: bgra) else {
            // (the Rust decoder drops its references on an error but keeps the sequence header,
            // which the damage may have reached: the stream starts over at a sync frame)
            av1g_decoder_reset(decoder)
            awaitingSync = true
            stats.failures += 1
            return false
        }
        let t2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        awaitingSync = false
        shown = true
        stats.framesShown += 1
        stats.decodeNS &+= t1 &- t0
        stats.convertNS &+= t2 &- t1
        if picture.key != 0 {
            stats.keyFramesShown += 1
            stats.keyDecodeNS &+= t1 &- t0
            stats.keyConvertNS &+= t2 &- t1
        }
        onPixels(UnsafeRawBufferPointer(start: bgra, count: width * height * 4), width * 4)
        return true
    }

    public func stop() {
        if let decoder { av1g_decoder_destroy(decoder) }
        decoder = nil
        bgra?.deallocate()
        bgra = nil
        coded?.deallocate()
        coded = nil
        codedBytes = 0
        scaleTemp?.deallocate()
        scaleTemp = nil
        scaleTempBytes = 0
        awaitingSync = false
        shown = false
        picture = av1g_dec_picture()
    }

    /// The frame the last `decode` showed, as decoded (Y, U, V before the conversion; planes valid
    /// for the call): nil when it showed none.
    public func withShownPicture<R>(_ body: (av1g_dec_picture) throws -> R) rethrows -> R? {
        guard shown, decoder != nil else { return nil }
        return try body(picture)
    }

    /// The region's size from `start`.
    public var size: (width: Int, height: Int) { (width, height) }

    // MARK: - Colour

    /// `conversions`' index for a picture's colour description, nil for one it doesn't convert.
    static func conversionIndex(matrix: UInt32, fullRange: Bool, chroma444: Bool) -> Int? {
        let m: Int
        switch matrix {
        case 1, 2: m = 0  // BT.709; unspecified, as the Viewer's other decoders take a stream
        case 5, 6: m = 1  // BT.470BG, BT.601
        case 9: m = 2     // BT.2020, non-constant luminance
        default: return nil
        }
        return (m * 2 + (fullRange ? 1 : 0)) * 2 + (chroma444 ? 1 : 0)
    }

    /// Every conversion `conversionIndex` names, once.
    private func makeConversions() -> Bool {
        if conversionsMade { return true }
        for (m, (kr, kb)) in [(0.2126, 0.0722), (0.299, 0.114), (0.2627, 0.0593)].enumerated() {
            let kg = 1 - kr - kb
            var matrix = vImage_YpCbCrToARGBMatrix(
                Yp: 1, Cr_R: Float(2 * (1 - kr)), Cr_G: Float(-2 * kr * (1 - kr) / kg),
                Cb_G: Float(-2 * kb * (1 - kb) / kg), Cb_B: Float(2 * (1 - kb)))
            for full in [false, true] {
                var range = full
                    ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
                                              YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
                    : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                              YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
                for c444 in [false, true] {
                    let i = (m * 2 + (full ? 1 : 0)) * 2 + (c444 ? 1 : 0)
                    guard vImageConvert_YpCbCrToARGB_GenerateConversion(
                        &matrix, &range, conversions + i, c444 ? kvImage444AYpCbCr8 : kvImage420Yp8_Cb8_Cr8,
                        kvImageARGB8888, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
                }
            }
        }
        conversionsMade = true
        return true
    }

    /// `picture` into the region's BGRA buffer.
    private func convert(into out: UnsafeMutableRawPointer) -> Bool {
        let p = picture
        let (w, h) = (Int(p.width), Int(p.height))
        guard p.monochrome == 0, let yp = p.planes.0, let up = p.planes.1, let vp = p.planes.2,
              w >= 1, h >= 1, w <= width, h <= height,
              Int(p.render_width) == width, Int(p.render_height) == height,
              let index = Self.conversionIndex(matrix: p.matrix_coefficients, fullRange: p.color_range != 0,
                                               chroma444: p.chroma_format == UInt8(AV1G_CHROMA_444))
        else { return false }
        let reduced = w != width || h != height
        if reduced && codedBytes < w * h * 4 {
            // (the region's size: a reduced frame is never larger)
            coded?.deallocate()
            codedBytes = width * height * 4
            coded = .allocate(byteCount: codedBytes, alignment: 64)
        }
        guard let target = reduced ? coded : out else { return false }
        func buffer(_ base: UnsafePointer<UInt8>, _ k: Int, _ stride: UInt32) -> vImage_Buffer {
            let (pw, ph) = k == 0 ? (p.plane_w.0, p.plane_h.0) : k == 1 ? (p.plane_w.1, p.plane_h.1) : (p.plane_w.2, p.plane_h.2)
            return vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(ph),
                                 width: vImagePixelCount(pw), rowBytes: Int(stride))
        }
        var y = buffer(yp, 0, p.stride.0), cb = buffer(up, 1, p.stride.1), cr = buffer(vp, 2, p.stride.2)
        var dst = vImage_Buffer(data: target, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        let flags = vImage_Flags(kvImageNoFlags)
        if p.chroma_format == UInt8(AV1G_CHROMA_444) {
            // A, Y', Cb, Cr interleaved (vImage converts no planar 4:4:4), then to ARGB in place
            guard vImageConvert_Planar8ToXRGB8888(255, &y, &cb, &cr, &dst, flags) == kvImageNoError,
                  vImageConvert_444AYpCbCr8ToARGB8888(&dst, &dst, conversions + index, permute, flags) == kvImageNoError
            else { return false }
        } else {
            guard vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&y, &cb, &cr, &dst, conversions + index, permute, 255,
                                                         flags) == kvImageNoError else { return false }
        }
        guard reduced else { return true }
        var full = vImage_Buffer(data: out, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                 rowBytes: width * 4)
        let scaleFlags = vImage_Flags(kvImageHighQualityResampling)
        let need = vImageScale_ARGB8888(&dst, &full, nil, scaleFlags | vImage_Flags(kvImageGetTempBufferSize))
        guard need >= 0 else { return false }
        if scaleTempBytes < need {
            scaleTemp?.deallocate()
            scaleTempBytes = need
            scaleTemp = .allocate(byteCount: max(1, need), alignment: 64)
        }
        return vImageScale_ARGB8888(&dst, &full, scaleTemp, scaleFlags) == kvImageNoError
    }
}
