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
///   for it. The BGRA picture, the colour conversions and the upscaler are made here, not per frame.
/// - **Decode**: one temporal unit, then the frame it shows converted to BGRA with vImage by the
///   matrix and range its sequence header gives (the hybrid's streams BT.709, its stills BT.601;
///   full or video range), 4:2:0 or 4:4:4. A reduced frame (decisions.h "Reduced frames": coded
///   smaller, its render size the stream's) is shown at the region's size, as VideoToolbox shows
///   it: its planes scaled up by Glass Act's upscaler (`av1g_upscaler`, Lanczos-5 in integers on
///   the decoder's threads; `upscale`), then converted as a full-size frame is. Any other size,
///   monochrome, or a matrix it doesn't know is a failure.
/// - **Failure**, as `VTRegionDecoder`'s: any error (damage, a frame outside the toolset, an inter
///   frame whose references the decoder doesn't hold) forgets the stream and drops every frame
///   until a sync frame, and `decode` returns false, so the engine asks for one (SYNC_REQUEST).
/// - **Stop** frees the decoder and the buffers; `start` again builds new ones.
///
/// The pixels `onPixels` gets are this decoder's own buffer (stride width × 4), valid for the
/// call. One region, one thread at a time (the engine's queue); the Rust decoder and upscaler run
/// on their own worker threads. `decode` allocates no buffers (no `err` text is asked for), except
/// for the first reduced frame: the region-size planes it's scaled into (again, larger, at the
/// first 4:4:4 one), and the upscaler's tables (again when the coded size changes).
public final class OwnAV1RegionDecoder: VideoRegionDecoder {
    /// Time spent per frame shown, in nanoseconds (the bench): the Rust decoder's, the conversion
    /// to BGRA, and the scaling of reduced frames.
    public struct Stats: Sendable, Equatable {
        public var framesShown = 0, keyFramesShown = 0
        public var decodeNS: UInt64 = 0, convertNS: UInt64 = 0, scaleNS: UInt64 = 0
        public var keyDecodeNS: UInt64 = 0, keyConvertNS: UInt64 = 0, keyScaleNS: UInt64 = 0
        public var failures = 0
    }

    /// How a reduced frame is scaled up to the region.
    public enum Upscale: String, Sendable, CaseIterable {
        /// Y, U and V each by `av1g_upscaler`, then converted at the region's size (the default:
        /// the cheapest, BENCHMARKS "Glass Act's decoder scales reduced frames up itself")
        case planes
        /// converted at the coded size, then the BGRA by `av1g_upscaler`
        case bgra
        /// converted at the coded size, then the BGRA by vImage's high-quality resampling (Lanczos;
        /// what it did before, ~20 ms a 5K frame)
        case vImage
    }

    /// Whether it shows a reduced frame for less than a full-size one, so a Viewer offers
    /// `videoReducedFrames` with it (`ViewerVideoDecoders.glassAct`). It does on both
    /// architectures: a 5K frame on an M4 Pro 8.7 ms against 14 at full size (15.5 against 28 on 4
    /// threads); x86_64 under Rosetta about 39 against 80 (BENCHMARKS, 2026-11-20).
    public static let showsReducedFramesCheaply = true

    public private(set) var stats = Stats()
    /// The decoder's threads (0: the available parallelism).
    public let threads: Int
    /// Reduced frames' scaling (the bench compares them); `filter` is the upscaler's
    /// (`AV1G_UPSCALE_*`). Both are read at `start`.
    public var upscale = Upscale.planes
    public var filter = Int32(AV1G_UPSCALE_LANCZOS5)

    private var decoder: OpaquePointer?
    private var upscaler: OpaquePointer?
    private var scaling = Upscale.planes
    private var width = 0
    private var height = 0
    private var awaitingSync = false
    /// The frame the last decode showed, valid until the next call into the decoder.
    private var picture = av1g_dec_picture()
    private var shown = false
    /// The region's BGRA picture (width × height × 4).
    private var bgra: UnsafeMutableRawPointer?
    /// Reduced frames: `.planes`' region-size Y, U and V (made at the first, larger at the first
    /// 4:4:4 one), or the others' BGRA at the coded size and vImage's scaling buffer.
    private var planes: UnsafeMutableRawPointer?
    private var planesBytes = 0
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
        scaling = upscale
        if scaling != .vImage {
            guard let u = av1g_upscaler_create(Int32(clamping: threads), filter) else {
                av1g_decoder_destroy(created)
                return false
            }
            upscaler = u
        }
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
        var scaleNS: UInt64 = 0
        guard rc == AV1G_OK, convert(into: bgra, scaleNS: &scaleNS) else {
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
        stats.convertNS &+= t2 &- t1 &- scaleNS
        stats.scaleNS &+= scaleNS
        if picture.key != 0 {
            stats.keyFramesShown += 1
            stats.keyDecodeNS &+= t1 &- t0
            stats.keyConvertNS &+= t2 &- t1 &- scaleNS
            stats.keyScaleNS &+= scaleNS
        }
        onPixels(UnsafeRawBufferPointer(start: bgra, count: width * height * 4), width * 4)
        return true
    }

    public func stop() {
        if let decoder { av1g_decoder_destroy(decoder) }
        decoder = nil
        if let upscaler { av1g_upscaler_destroy(upscaler) }
        upscaler = nil
        bgra?.deallocate()
        bgra = nil
        planes?.deallocate()
        planes = nil
        planesBytes = 0
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

    /// A plane for the conversion: `w` × `h` samples, rows `stride` bytes apart.
    private struct Plane {
        var base: UnsafePointer<UInt8>, stride: Int, w: Int, h: Int
    }

    /// `picture` into the region's BGRA buffer; `scaleNS` the time a reduced frame's scaling took.
    private func convert(into out: UnsafeMutableRawPointer, scaleNS: inout UInt64) -> Bool {
        let p = picture
        let (w, h) = (Int(p.width), Int(p.height))
        let c444 = p.chroma_format == UInt8(AV1G_CHROMA_444)
        guard p.monochrome == 0, let yp = p.planes.0, let up = p.planes.1, let vp = p.planes.2,
              w >= 1, h >= 1, w <= width, h <= height,
              Int(p.render_width) == width, Int(p.render_height) == height,
              let index = Self.conversionIndex(matrix: p.matrix_coefficients, fullRange: p.color_range != 0,
                                               chroma444: c444)
        else { return false }
        let decoded = (Plane(base: yp, stride: Int(p.stride.0), w: Int(p.plane_w.0), h: Int(p.plane_h.0)),
                       Plane(base: up, stride: Int(p.stride.1), w: Int(p.plane_w.1), h: Int(p.plane_h.1)),
                       Plane(base: vp, stride: Int(p.stride.2), w: Int(p.plane_w.2), h: Int(p.plane_h.2)))
        guard w != width || h != height else {
            return convert(decoded, w, h, c444: c444, index: index, into: out)
        }
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        switch scaling {
        case .planes:
            // each plane scaled up to its size at the region's (4:2:0 chroma (w+1)/2 × (h+1)/2), then
            // converted as a full-size frame is
            let (cw, ch) = c444 ? (width, height) : ((width + 1) / 2, (height + 1) / 2)
            if planesBytes < width * height + 2 * cw * ch {
                // (a stream's chroma format may change at a key frame: 4:4:4 takes twice 4:2:0's)
                planes?.deallocate()
                planesBytes = width * height + 2 * cw * ch
                planes = .allocate(byteCount: planesBytes, alignment: 64)
            }
            guard let upscaler, let planes else { return false }
            let y = planes.assumingMemoryBound(to: UInt8.self), u = y + width * height, v = u + cw * ch
            func scale(_ d: Plane, into to: UnsafeMutablePointer<UInt8>, _ tw: Int, _ th: Int) -> Bool {
                av1g_upscaler_scale(upscaler, d.base, UInt32(d.w), UInt32(d.h), d.stride, to, UInt32(tw), UInt32(th), tw,
                                    1) == AV1G_OK
            }
            guard scale(decoded.0, into: y, width, height), scale(decoded.1, into: u, cw, ch),
                  scale(decoded.2, into: v, cw, ch) else { return false }
            scaleNS = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- t0
            return convert((Plane(base: y, stride: width, w: width, h: height), Plane(base: u, stride: cw, w: cw, h: ch),
                            Plane(base: v, stride: cw, w: cw, h: ch)), width, height, c444: c444, index: index, into: out)
        case .bgra, .vImage:
            if codedBytes < w * h * 4 {
                // (the region's size: a reduced frame is never larger)
                coded?.deallocate()
                codedBytes = width * height * 4
                coded = .allocate(byteCount: codedBytes, alignment: 64)
            }
            guard let coded, convert(decoded, w, h, c444: c444, index: index, into: coded) else { return false }
            let t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            defer { scaleNS = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- t1 }
            if scaling == .bgra {
                guard let upscaler else { return false }
                return av1g_upscaler_scale(upscaler, coded, UInt32(w), UInt32(h), w * 4, out.assumingMemoryBound(to: UInt8.self),
                                           UInt32(width), UInt32(height), width * 4, 4) == AV1G_OK
            }
            var small = vImage_Buffer(data: coded, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var full = vImage_Buffer(data: out, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                     rowBytes: width * 4)
            let scaleFlags = vImage_Flags(kvImageHighQualityResampling)
            let need = vImageScale_ARGB8888(&small, &full, nil, scaleFlags | vImage_Flags(kvImageGetTempBufferSize))
            guard need >= 0 else { return false }
            if scaleTempBytes < need {
                scaleTemp?.deallocate()
                scaleTempBytes = need
                scaleTemp = .allocate(byteCount: max(1, need), alignment: 64)
            }
            return vImageScale_ARGB8888(&small, &full, scaleTemp, scaleFlags) == kvImageNoError
        }
    }

    /// Y, U, V planes of a `w` × `h` picture into BGRA (rows `w` × 4 bytes) by `conversions[index]`.
    private func convert(_ planes: (Plane, Plane, Plane), _ w: Int, _ h: Int, c444: Bool, index: Int,
                         into target: UnsafeMutableRawPointer) -> Bool {
        func buffer(_ p: Plane) -> vImage_Buffer {
            vImage_Buffer(data: UnsafeMutableRawPointer(mutating: p.base), height: vImagePixelCount(p.h),
                          width: vImagePixelCount(p.w), rowBytes: p.stride)
        }
        var y = buffer(planes.0), cb = buffer(planes.1), cr = buffer(planes.2)
        var dst = vImage_Buffer(data: target, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        let flags = vImage_Flags(kvImageNoFlags)
        if c444 {
            // A, Y', Cb, Cr interleaved (vImage converts no planar 4:4:4), then to ARGB in place
            return vImageConvert_Planar8ToXRGB8888(255, &y, &cb, &cr, &dst, flags) == kvImageNoError
                && vImageConvert_444AYpCbCr8ToARGB8888(&dst, &dst, conversions + index, permute, flags) == kvImageNoError
        }
        return vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&y, &cb, &cr, &dst, conversions + index, permute, 255,
                                                      flags) == kvImageNoError
    }
}
