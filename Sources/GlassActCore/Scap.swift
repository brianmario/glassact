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
        try appendCompressed(timestampUS: timestampUS, dirtyRects: dirtyRects,
                             lz4: UnsafeRawBufferPointer(start: compressBuffer.baseAddress, count: lz4Len))
    }

    /// A frame another thread compressed (`ScapRaw.compress`).
    public func appendCompressed(timestampUS: UInt64, dirtyRects: [DirtyRect], lz4: UnsafeRawBufferPointer) throws {
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
        w.writeU32(UInt32(lz4.count))
        try write(w.bytes)
        try writeRaw(lz4.baseAddress!, count: lz4.count)
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

/// A capture's frames as they came, for `ScapRaw.compress` to turn into a `.scap` afterwards: the
/// header with its own magic, and records as `.scap`'s with the tight frame in place of its LZ4.
/// Nothing but the file system stands between a captured frame and the disk, so a capture doesn't
/// fall behind on frames that compress slowly (a full 5K picture of video: ~55 ms of LZ4, ~9 of
/// write; BENCHMARKS "the trace recorder"). Not read by anything else.
public final class ScapRawWriter {
    public static let magic: [UInt8] = Array("SCPR".utf8)

    public let header: ScapHeader
    public private(set) var frameCount = 0

    private let fd: Int32
    private var tight: UnsafeMutableRawBufferPointer?

    public init(url: URL, width: Int, height: Int) throws {
        header = ScapHeader(width: width, height: height)
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw ScapError.ioError }
        // past the page cache: a capture writes far more than memory holds
        _ = fcntl(fd, F_NOCACHE, 1)
        var w = ByteWriter(reserving: ScapHeader.diskSize)
        w.writeBytes(Self.magic)
        w.writeU8(header.version)
        w.writeU16(UInt16(width))
        w.writeU16(UInt16(height))
        w.writeU8(header.pixfmt)
        w.writeU8(header.tile)
        try w.bytes.withUnsafeBytes { try writeAll($0) }
    }

    deinit {
        tight?.deallocate()
        close(fd)
    }

    /// `frame` holds `height` rows `bytesPerRow` apart, each starting with `width * 4` bytes of pixels.
    public func appendFrame(timestampUS: UInt64, dirtyRects: [DirtyRect], frame: UnsafeRawBufferPointer,
                            bytesPerRow: Int) throws {
        let n = header.frameByteCount, rowBytes = header.width * 4
        precondition(bytesPerRow >= rowBytes && frame.count >= bytesPerRow * (header.height - 1) + rowBytes)
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
        w.writeU32(UInt32(n))
        try w.bytes.withUnsafeBytes { try writeAll($0) }
        if bytesPerRow == rowBytes {
            try writeAll(UnsafeRawBufferPointer(rebasing: frame[0..<n]))
        } else {
            let t = tight ?? .allocate(byteCount: n, alignment: 64)
            tight = t
            for row in 0..<header.height {
                t.baseAddress!.advanced(by: row * rowBytes)
                    .copyMemory(from: frame.baseAddress!.advanced(by: row * bytesPerRow), byteCount: rowBytes)
            }
            try writeAll(UnsafeRawBufferPointer(t))
        }
        frameCount += 1
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer) throws {
        var done = 0
        while done < bytes.count {
            let k = write(fd, bytes.baseAddress!.advanced(by: done), bytes.count - done)
            if k < 0 && errno == EINTR { continue }
            guard k > 0 else { throw ScapError.ioError }
            done += k
        }
    }
}

/// Turns a `ScapRawWriter` file into a `.scap`, with every core compressing.
public enum ScapRaw {
    /// Writes `.scap` to `output`, frame for frame, and returns its frame count. A record cut short
    /// at the end (a capture that was killed) is left out. `progress` gets the frames done so far.
    public static func compress(raw: URL, to output: URL, threads: Int = ProcessInfo.processInfo.activeProcessorCount,
                                progress: (Int) -> Void = { _ in }) throws -> Int {
        guard let input = try? FileHandle(forReadingFrom: raw) else { throw ScapError.ioError }
        defer { try? input.close() }
        func read(_ count: Int) throws -> Data? {
            guard let d = try input.read(upToCount: count), d.count == count else { return nil }
            return d
        }
        guard let head = try read(ScapHeader.diskSize) else { throw ScapError.truncated }
        guard [UInt8](head.prefix(4)) == ScapRawWriter.magic else { throw ScapError.badMagic }
        let width = Int(head[5]) | Int(head[6]) << 8, height = Int(head[7]) | Int(head[8]) << 8
        guard width >= 1, height >= 1, width <= 16_384, height <= 16_384 else { throw ScapError.badHeader }

        let writer = try ScapWriter(url: output, width: width, height: height)
        let n = writer.header.frameByteCount, bound = ScapWriter.compressBound(n), workers = max(1, threads)
        typealias Meta = (timestampUS: UInt64, rects: [DirtyRect])
        let dst = (0..<workers).map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: bound, alignment: 64) }
        let codecs = (0..<workers).map { _ in LZ4Codec() }
        defer { dst.forEach { $0.deallocate() } }
        var done = 0, atEnd = false
        while !atEnd {
            var metas: [Meta] = [], frames: [Data] = []
            while metas.count < workers {
                guard let m = try read(10) else { atEnd = true; break }
                let ts = (0..<8).reduce(UInt64(0)) { $0 | UInt64(m[m.startIndex + $1]) << UInt64(8 * $1) }
                let count = Int(m[m.startIndex + 8]) | Int(m[m.startIndex + 9]) << 8
                guard let r = try read(count * 8 + 4) else { atEnd = true; break }
                let u16 = { (i: Int) in Int(r[r.startIndex + i]) | Int(r[r.startIndex + i + 1]) << 8 }
                let rects = (0..<count).map { k in
                    DirtyRect(x: u16(k * 8), y: u16(k * 8 + 2), width: u16(k * 8 + 4), height: u16(k * 8 + 6))
                }
                let length = (0..<4).reduce(0) { $0 | Int(r[r.startIndex + count * 8 + $1]) << (8 * $1) }
                guard length == n else { throw ScapError.badFrame }
                guard let f = try read(n) else { atEnd = true; break }
                metas.append((ts, rects))
                frames.append(f)
            }
            var lengths = [Int](repeating: 0, count: frames.count)
            lengths.withUnsafeMutableBufferPointer { out in
                let batch = Batch(frames: frames, codecs: codecs, dst: dst, lengths: out.baseAddress)
                DispatchQueue.concurrentPerform(iterations: batch.frames.count) { batch.compress($0) }
            }
            for i in frames.indices {
                guard lengths[i] > 0 else { throw ScapError.badFrame }
                try writer.appendCompressed(timestampUS: metas[i].timestampUS, dirtyRects: metas[i].rects,
                                            lz4: UnsafeRawBufferPointer(start: dst[i].baseAddress, count: lengths[i]))
            }
            done += frames.count
            progress(done)
        }
        try writer.finish()
        return done
    }

    /// Frames being compressed, each by its own worker: frame i touches only codecs[i], dst[i] and
    /// lengths[i].
    private struct Batch: @unchecked Sendable {
        let frames: [Data]
        let codecs: [LZ4Codec]
        let dst: [UnsafeMutableRawBufferPointer]
        let lengths: UnsafeMutablePointer<Int>?

        func compress(_ i: Int) {
            frames[i].withUnsafeBytes { lengths?[i] = codecs[i].encodeUnbounded(src: $0, dst: dst[i]) }
        }
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
