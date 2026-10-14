import libwebp

/// VP8L lossless tile codec — opcode `0x0A WEBPL`, and the striped
/// keyframes (lossless, plus the lossy cold-start first paint). Backed by
/// vendored libwebp v1.5.0 (see ThirdParty/THIRD_PARTY.md for provenance and
/// the measurements that justified the dependency: ~2× smaller than LZBITMAP
/// on text tiles, round-trip byte-lossless).
///
/// INV-7 note (documented deviation): `WebPEncode` allocates internally per
/// call. The ~2× bandwidth win was judged worth it; encode-side cost is
/// included in the measured throughput and the encode phase runs off the
/// capture path. Decode is allocation-free (`WebPDecodeBGRAInto`).
public enum WebPTile {
    /// Encodes tight BGRA tile bytes losslessly. Returns the byte count
    /// written to `dst`, or 0 on failure or when not strictly smaller than
    /// the source (caller falls back).
    public static func encodeLossless(
        src: UnsafeRawBufferPointer, width: Int, height: Int,
        effort: Int32, dst: UnsafeMutableRawBufferPointer
    ) -> Int {
        guard let srcBase = src.baseAddress, src.count >= width * height * 4,
              let dstBase = dst.baseAddress else { return 0 }
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0,
              WebPConfigLosslessPreset(&config, effort) != 0 else { return 0 }
        // BYTE-lossless, not visually lossless: libwebp's default (exact = 0)
        // may discard RGB values under alpha≈0 pixels. Real screen content is
        // opaque, so this lurked for months — until a golden with random
        // alpha decoded a correct stream into different bytes (INV-1
        // violation, found by the keyframe golden).
        config.exact = 1
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { return 0 }
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(width)
        picture.height = Int32(height)
        picture.use_argb = 1
        guard WebPPictureImportBGRA(&picture, srcBase.assumingMemoryBound(to: UInt8.self),
                                    Int32(width * 4)) != 0 else { return 0 }
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let encoded = withUnsafeMutablePointer(to: &writer) { writerPtr -> Bool in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPtr)
            return WebPEncode(&config, &picture) != 0
        }
        guard encoded, writer.size > 0, writer.size < src.count, writer.size <= dst.count else {
            return 0
        }
        dstBase.copyMemory(from: writer.mem, byteCount: writer.size)
        return writer.size
    }

    /// VP8 lossy at `quality` (0–100): the transient striped first paint
    /// (`KeyframeCodec.webpLossyStriped`) and measurement
    /// tooling. Never used for canvas-exact content.
    public static func encodeLossy(
        src: UnsafeRawBufferPointer, width: Int, height: Int,
        quality: Float, dst: UnsafeMutableRawBufferPointer
    ) -> Int {
        guard let srcBase = src.baseAddress, src.count >= width * height * 4,
              let dstBase = dst.baseAddress else { return 0 }
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0,
              WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, quality) != 0 else { return 0 }
        config.method = 4
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { return 0 }
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(width)
        picture.height = Int32(height)
        guard WebPPictureImportBGRA(&picture, srcBase.assumingMemoryBound(to: UInt8.self),
                                    Int32(width * 4)) != 0 else { return 0 }
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let encoded = withUnsafeMutablePointer(to: &writer) { writerPtr -> Bool in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPtr)
            return WebPEncode(&config, &picture) != 0
        }
        guard encoded, writer.size > 0, writer.size <= dst.count else { return 0 }
        dstBase.copyMemory(from: writer.mem, byteCount: writer.size)
        return writer.size
    }

    /// Decodes a WEBPL payload into `dst` (tight BGRA), allocation-free.
    /// Returns the decoded byte count (`width*height*4`) or 0 on any
    /// mismatch/corruption (INV-6: callers skip, never trust).
    /// Lossless (VP8L) only: a lossy VP8 bitstream decodes "successfully" to
    /// approximate pixels, which would silently break INV-1 for a WEBPL tile,
    /// a DELTA/STORE inner payload, or a lossless keyframe.
    public static func decodeLossless(
        src: UnsafeRawBufferPointer, width: Int, height: Int,
        dst: UnsafeMutableRawBufferPointer
    ) -> Int {
        decode(src: src, width: width, height: height, dst: dst, requireLossless: true)
    }

    /// Decodes either WebP flavour — only for the transient lossy paint,
    /// which never becomes canvas truth (it doesn't advance tileSeq).
    public static func decodeBGRA(
        src: UnsafeRawBufferPointer, width: Int, height: Int,
        dst: UnsafeMutableRawBufferPointer
    ) -> Int {
        decode(src: src, width: width, height: height, dst: dst, requireLossless: false)
    }

    private static func decode(
        src: UnsafeRawBufferPointer, width: Int, height: Int,
        dst: UnsafeMutableRawBufferPointer, requireLossless: Bool
    ) -> Int {
        guard let srcBase = src.baseAddress, src.count > 0,
              let dstBase = dst.baseAddress else { return 0 }
        var features = WebPBitstreamFeatures()
        guard WebPGetFeatures(srcBase.assumingMemoryBound(to: UInt8.self), src.count,
                              &features) == VP8_STATUS_OK,
              Int(features.width) == width, Int(features.height) == height,
              features.has_animation == 0,
              !requireLossless || features.format == 2 // 2 = lossless (VP8L)
        else { return 0 }
        let byteCount = width * height * 4
        guard dst.count >= byteCount else { return 0 }
        guard WebPDecodeBGRAInto(srcBase.assumingMemoryBound(to: UInt8.self), src.count,
                                 dstBase.assumingMemoryBound(to: UInt8.self), byteCount,
                                 Int32(width * 4)) != nil else { return 0 }
        return byteCount
    }
}
