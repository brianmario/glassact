public import Foundation
import GlassActWire
import GlassActCodec

/// §7 — `.scap` trace format errors.
public enum ScapError: Error, Equatable {
    case ioError
    case badMagic
    case badHeader
    case truncated
    case badFrame
}

/// §7 — `.scap` header: `{magic "SCAP", ver, w u16, h u16, pixfmt, tile}`,
/// little-endian, 11 bytes on disk.
public struct ScapHeader: Equatable, Sendable {
    public static let magic: [UInt8] = Array("SCAP".utf8)
    public static let diskSize = 11

    public var version: UInt8 = 1
    public var width: Int
    public var height: Int
    public var pixfmt: UInt8 = PixelFormat.bgra8sRGB
    public var tile: UInt8 = UInt8(TileGrid.tileSize)

    public var frameByteCount: Int { width * height * 4 }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Frame records: `{ts_us u64, rect_cnt u16, rects[(x,y,w,h) u16×4],
/// lz4_len u32, lz4(full tightly-packed frame)}`.
///
/// Convention: `rect_cnt == 0` means "no dirty info" — replay passes nil to the
/// engine (full scan), matching a capture callback without dirtyRects.
public struct ScapFrameMeta: Equatable, Sendable {
    public var timestampUS: UInt64
    public var rectCount: Int
    public var lz4Length: Int
}

/// Streams frames to disk. Used by the host-side recorder flag and the
/// synthetic trace generator (`glassact-bench synth`).
public final class ScapWriter {
    public let header: ScapHeader
    public private(set) var frameCount = 0

    private let handle: FileHandle
    private let lz4 = LZ4Codec()
    private let compressBuffer: UnsafeMutableRawBufferPointer

    public init(url: URL, width: Int, height: Int) throws {
        header = ScapHeader(width: width, height: height)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { throw ScapError.ioError }
        handle = h
        compressBuffer = .allocate(byteCount: Self.compressBound(header.frameByteCount), alignment: 64)
        var w = ByteWriter(reserving: ScapHeader.diskSize)
        w.writeBytes(ScapHeader.magic)
        w.writeU8(header.version)
        w.writeU16(UInt16(width))
        w.writeU16(UInt16(height))
        w.writeU8(header.pixfmt)
        w.writeU8(header.tile)
        try write(w.bytes)
    }

    deinit {
        compressBuffer.deallocate()
        try? handle.close()
    }

    static func compressBound(_ n: Int) -> Int {
        n + n / 8 + 4096 // LZ4 worst-case headroom
    }

    /// `frame` must be the full tightly-packed BGRA frame (`w*h*4`).
    public func appendFrame(timestampUS: UInt64, dirtyRects: [DirtyRect], frame: UnsafeRawBufferPointer) throws {
        precondition(frame.count == header.frameByteCount, "frame must be tightly packed w*h*4")
        let lz4Len = lz4.encodeUnbounded(src: frame, dst: compressBuffer)
        guard lz4Len > 0 else { throw ScapError.badFrame }
        let rects = dirtyRects.prefix(Int(UInt16.max))
        var w = ByteWriter(reserving: 14 + rects.count * 8)
        w.writeU64(timestampUS)
        w.writeU16(UInt16(rects.count))
        for r in rects {
            w.writeU16(UInt16(clamping: r.x))
            w.writeU16(UInt16(clamping: r.y))
            w.writeU16(UInt16(clamping: r.width))
            w.writeU16(UInt16(clamping: r.height))
        }
        w.writeU32(UInt32(lz4Len))
        try write(w.bytes)
        try writeRaw(compressBuffer.baseAddress!, count: lz4Len)
        frameCount += 1
    }

    public func finish() throws {
        try handle.close()
    }

    private func write(_ bytes: [UInt8]) throws {
        do { try handle.write(contentsOf: Data(bytes)) } catch { throw ScapError.ioError }
    }

    private func writeRaw(_ base: UnsafeRawPointer, count: Int) throws {
        do { try handle.write(contentsOf: Data(bytes: base, count: count)) } catch { throw ScapError.ioError }
    }
}

/// Streams frames back. Byte-identical inputs → deterministic outputs (§7).
public final class ScapReader {
    public let header: ScapHeader

    private let handle: FileHandle
    private let lz4 = LZ4Codec()

    public init(url: URL) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ScapError.ioError }
        handle = h
        guard let head = try Self.readExact(h, ScapHeader.diskSize) else { throw ScapError.truncated }
        let parsed: ScapHeader? = head.withUnsafeBytes { raw in
            var r = ByteReader(raw)
            guard let m = r.readBytes(4), [UInt8](m) == ScapHeader.magic else { return nil }
            guard let ver = r.readU8(), ver == 1,
                  let w = r.readU16(), let hgt = r.readU16(),
                  let pixfmt = r.readU8(), let tile = r.readU8(),
                  w >= 1, hgt >= 1, w <= 16_384, hgt <= 16_384,
                  pixfmt == PixelFormat.bgra8sRGB, tile == UInt8(TileGrid.tileSize)
            else { return nil }
            var hd = ScapHeader(width: Int(w), height: Int(hgt))
            hd.version = ver
            return hd
        }
        guard let parsed else {
            throw [UInt8](head.prefix(4)) == ScapHeader.magic ? ScapError.badHeader : ScapError.badMagic
        }
        header = parsed
    }

    deinit {
        try? handle.close()
    }

    /// Reads the next frame. Returns nil at clean EOF; throws on truncation or
    /// corruption. `frame` must hold `w*h*4` bytes.
    public func readFrame(rects: inout [DirtyRect], into frame: UnsafeMutableRawBufferPointer) throws -> ScapFrameMeta? {
        precondition(frame.count >= header.frameByteCount)
        guard let meta = try readMeta(rects: &rects) else { return nil }
        guard let payload = try Self.readExact(handle, meta.lz4Length) else { throw ScapError.truncated }
        let decoded = payload.withUnsafeBytes { lz4.decode(src: $0, dst: frame) }
        guard decoded == header.frameByteCount else { throw ScapError.badFrame }
        return meta
    }

    /// Reads the next frame's metadata and seeks past its payload (fast
    /// inspection without decompression). Returns nil at clean EOF.
    public func skimFrame() throws -> ScapFrameMeta? {
        var rects: [DirtyRect] = []
        guard let meta = try readMeta(rects: &rects) else { return nil }
        do { try handle.seek(toOffset: handle.offsetInFile + UInt64(meta.lz4Length)) } catch { throw ScapError.truncated }
        return meta
    }

    private func readMeta(rects: inout [DirtyRect]) throws -> ScapFrameMeta? {
        rects.removeAll(keepingCapacity: true)
        guard let fixed = try Self.readExact(handle, 10, allowEOF: true) else { return nil }
        var timestampUS: UInt64 = 0
        var rectCount = 0
        fixed.withUnsafeBytes { raw in
            var r = ByteReader(raw)
            timestampUS = r.readU64()!
            rectCount = Int(r.readU16()!)
        }
        if rectCount > 0 {
            guard let rectBytes = try Self.readExact(handle, rectCount * 8) else { throw ScapError.truncated }
            rectBytes.withUnsafeBytes { raw in
                var r = ByteReader(raw)
                for _ in 0..<rectCount {
                    rects.append(DirtyRect(x: Int(r.readU16()!), y: Int(r.readU16()!),
                                           width: Int(r.readU16()!), height: Int(r.readU16()!)))
                }
            }
        }
        guard let lenBytes = try Self.readExact(handle, 4) else { throw ScapError.truncated }
        let lz4Len = lenBytes.withUnsafeBytes { raw -> Int in
            var r = ByteReader(raw)
            return Int(r.readU32()!)
        }
        guard lz4Len > 0, lz4Len <= ScapWriter.compressBound(header.frameByteCount) else {
            throw ScapError.badFrame
        }
        return ScapFrameMeta(timestampUS: timestampUS, rectCount: rectCount, lz4Length: lz4Len)
    }

    private static func readExact(_ handle: FileHandle, _ count: Int, allowEOF: Bool = false) throws -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            guard let chunk = try? handle.read(upToCount: count - out.count), !chunk.isEmpty else {
                if out.isEmpty && allowEOF { return nil }
                throw ScapError.truncated
            }
            out.append(contentsOf: chunk)
        }
        return out
    }
}
