import Compression

/// Apple Compression-framework wrapper for the tile codecs: LZ4 (framed,
/// opcode 0x02) and LZBITMAP (opcode 0x09 — Apple's SIMD codec, built
/// for pixel-shaped data). Both ends use this framework; liblz4 block
/// interop is a non-goal. (Despite its name, `LZ4Codec` serves both.)
///
/// Holds preallocated scratch (INV-7: no per-frame allocation). Not
/// thread-safe: one instance per engine, confined to that engine's queue.
public final class LZ4Codec {
    private let encodeScratch: UnsafeMutableRawPointer
    private let decodeScratch: UnsafeMutableRawPointer
    private let bitmapEncodeScratch: UnsafeMutableRawPointer
    private let bitmapDecodeScratch: UnsafeMutableRawPointer

    public init() {
        encodeScratch = .allocate(byteCount: max(1, compression_encode_scratch_buffer_size(COMPRESSION_LZ4)), alignment: 16)
        decodeScratch = .allocate(byteCount: max(1, compression_decode_scratch_buffer_size(COMPRESSION_LZ4)), alignment: 16)
        // Sized for any algorithm the bench experiment may swap in.
        let encodeScratch = [COMPRESSION_LZBITMAP, COMPRESSION_BROTLI, COMPRESSION_ZLIB, COMPRESSION_LZFSE]
            .map { compression_encode_scratch_buffer_size($0) }.max() ?? 1
        bitmapEncodeScratch = .allocate(byteCount: max(1, encodeScratch), alignment: 16)
        bitmapDecodeScratch = .allocate(byteCount: max(1, compression_decode_scratch_buffer_size(COMPRESSION_LZBITMAP)), alignment: 16)
    }

    deinit {
        encodeScratch.deallocate()
        decodeScratch.deallocate()
        bitmapEncodeScratch.deallocate()
        bitmapDecodeScratch.deallocate()
    }

    /// Bench experiment (`glassact-bench replay --no-lzbitmap`): what LZBITMAP
    /// is worth inside the encoder's best-of choice — it is Apple-only, the
    /// one payload a non-Apple peer couldn't decode. Set before encoding
    /// starts; never in the apps.
    nonisolated(unsafe) public static var experimentDisableBitmap = false
    /// Bench experiment (`--bitmap-codec`): another Compression algorithm in
    /// LZBITMAP's slot, to size a cross-platform replacement. Encode-only
    /// replays only — the opcode on the wire would be wrong.
    nonisolated(unsafe) public static var experimentBitmapAlgorithmRaw: UInt32 = COMPRESSION_LZBITMAP.rawValue

    /// LZBITMAP compression with the strictly-smaller-than-source gate.
    /// Returns 0 when incompressible or on failure.
    public func encodeBitmap(src: UnsafeRawBufferPointer, dst: UnsafeMutableRawBufferPointer) -> Int {
        guard !Self.experimentDisableBitmap else { return 0 }
        guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress, src.count > 1 else { return 0 }
        let dstCap = min(dst.count, src.count - 1)
        guard dstCap > 0 else { return 0 }
        return compression_encode_buffer(
            dstBase.assumingMemoryBound(to: UInt8.self), dstCap,
            srcBase.assumingMemoryBound(to: UInt8.self), src.count,
            bitmapEncodeScratch, compression_algorithm(rawValue: Self.experimentBitmapAlgorithmRaw))
    }

    /// LZBITMAP decompression; callers must verify the expected size (INV-6).
    public func decodeBitmap(src: UnsafeRawBufferPointer, dst: UnsafeMutableRawBufferPointer) -> Int {
        guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress,
              src.count > 0, dst.count > 0 else { return 0 }
        return compression_decode_buffer(
            dstBase.assumingMemoryBound(to: UInt8.self), dst.count,
            srcBase.assumingMemoryBound(to: UInt8.self), src.count,
            bitmapDecodeScratch, COMPRESSION_LZBITMAP)
    }

    /// Compresses `src` into `dst`, but only accepts results strictly smaller
    /// than the source. Returns the compressed byte count, or 0 when the data
    /// is incompressible (caller sends RAW) or inputs are empty.
    public func encode(src: UnsafeRawBufferPointer, dst: UnsafeMutableRawBufferPointer) -> Int {
        guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress, src.count > 1 else { return 0 }
        let dstCap = min(dst.count, src.count - 1) // strictly-smaller-than-RAW gate
        guard dstCap > 0 else { return 0 }
        return compression_encode_buffer(
            dstBase.assumingMemoryBound(to: UInt8.self), dstCap,
            srcBase.assumingMemoryBound(to: UInt8.self), src.count,
            encodeScratch, COMPRESSION_LZ4)
    }

    /// Compresses without the strictly-smaller gate — for the `.scap` trace
    /// format (§7), which stores the LZ4 stream whatever its size. `dst` must
    /// be sized by the caller with LZ4 worst-case headroom. Returns 0 on
    /// failure (insufficient `dst`).
    public func encodeUnbounded(src: UnsafeRawBufferPointer, dst: UnsafeMutableRawBufferPointer) -> Int {
        guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress,
              src.count > 0, dst.count > 0 else { return 0 }
        return compression_encode_buffer(
            dstBase.assumingMemoryBound(to: UInt8.self), dst.count,
            srcBase.assumingMemoryBound(to: UInt8.self), src.count,
            encodeScratch, COMPRESSION_LZ4)
    }

    /// Decompresses `src` into `dst`. Returns the decoded byte count (0 on
    /// failure). Callers must verify the result equals the expected tile size
    /// before applying (INV-6: malformed payloads are skipped, never trusted).
    public func decode(src: UnsafeRawBufferPointer, dst: UnsafeMutableRawBufferPointer) -> Int {
        guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress,
              src.count > 0, dst.count > 0 else { return 0 }
        return compression_decode_buffer(
            dstBase.assumingMemoryBound(to: UInt8.self), dst.count,
            srcBase.assumingMemoryBound(to: UInt8.self), src.count,
            decodeScratch, COMPRESSION_LZ4)
    }
}
