/// Row-copy primitives between strided BGRA frames and tightly-packed tile
/// bytes (§3.1). The tightly-packed form — `th` rows of `tw*4` bytes, no
/// stride — is the one canonical byte order: it is what gets hashed, encoded,
/// and shipped. Capture buffers have padded `bytesPerRow`, so all frame-side
/// addressing goes through these helpers.
public enum TileOps {
    /// Copies a tile out of a strided frame into tightly-packed bytes.
    /// Returns the tight byte count (`tw*th*4`).
    @discardableResult
    @inline(__always)
    public static func extract(
        src: UnsafeRawBufferPointer, bytesPerRow: Int,
        x: Int, y: Int, tw: Int, th: Int,
        into dst: UnsafeMutableRawBufferPointer
    ) -> Int {
        let rowBytes = tw * 4
        precondition(x >= 0 && y >= 0 && tw > 0 && th > 0)
        precondition((y + th - 1) * bytesPerRow + (x + tw) * 4 <= src.count, "tile exceeds source frame")
        precondition(rowBytes * th <= dst.count, "tile exceeds destination")
        let srcBase = src.baseAddress!
        let dstBase = dst.baseAddress!
        for row in 0..<th {
            dstBase.advanced(by: row * rowBytes)
                .copyMemory(from: srcBase.advanced(by: (y + row) * bytesPerRow + x * 4), byteCount: rowBytes)
        }
        return rowBytes * th
    }

    /// Copies tightly-packed tile bytes into a canvas rect. The canvas is
    /// tightly packed itself (`bytesPerRow == canvasWidth*4`).
    @inline(__always)
    public static func apply(
        tight: UnsafeRawBufferPointer,
        into canvas: UnsafeMutableRawBufferPointer, canvasWidth: Int,
        x: Int, y: Int, tw: Int, th: Int
    ) {
        let rowBytes = tw * 4
        precondition(tight.count >= rowBytes * th)
        precondition((y + th - 1) * canvasWidth * 4 + (x + tw) * 4 <= canvas.count, "tile exceeds canvas")
        let srcBase = tight.baseAddress!
        let dstBase = canvas.baseAddress!
        for row in 0..<th {
            dstBase.advanced(by: ((y + row) * canvasWidth + x) * 4)
                .copyMemory(from: srcBase.advanced(by: row * rowBytes), byteCount: rowBytes)
        }
    }
}
