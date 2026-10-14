import Testing
import GlassActCodec
import GlassActTestSupport

@Suite struct TileOpsTests {
    @Test func extractApplyRoundTripWithStride() {
        var rng = SplitMix64(seed: 21)
        let width = 100, height = 70 // forces cropped edge tiles
        let padding = 64
        let bytesPerRow = width * 4 + padding // capture buffers pad bytesPerRow (§4.1)
        let frame = rng.bytes(bytesPerRow * height)

        // Extract a cropped edge tile (x 64, tw 36; y 64, th 6).
        let x = 64, y = 64, tw = 36, th = 6
        var tight = [UInt8](repeating: 0, count: tw * th * 4)
        _ = frame.withUnsafeBytes { src in
            tight.withUnsafeMutableBytes { dst in
                TileOps.extract(src: src, bytesPerRow: bytesPerRow, x: x, y: y, tw: tw, th: th, into: dst)
            }
        }
        // Tight form must be exactly the strided rows, concatenated.
        for row in 0..<th {
            let srcStart = (y + row) * bytesPerRow + x * 4
            let expected = Array(frame[srcStart ..< srcStart + tw * 4])
            let got = Array(tight[row * tw * 4 ..< (row + 1) * tw * 4])
            #expect(got == expected, "row \(row)")
        }

        // Apply into a tight canvas and read back.
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        tight.withUnsafeBytes { src in
            canvas.withUnsafeMutableBytes { dst in
                TileOps.apply(tight: src, into: dst, canvasWidth: width, x: x, y: y, tw: tw, th: th)
            }
        }
        var readBack = [UInt8](repeating: 0, count: tw * th * 4)
        _ = canvas.withUnsafeBytes { src in
            readBack.withUnsafeMutableBytes { dst in
                TileOps.extract(src: src, bytesPerRow: width * 4, x: x, y: y, tw: tw, th: th, into: dst)
            }
        }
        #expect(readBack == tight)
    }

    @Test func canonicalByteOrderForHashing() {
        // §4.5: one canonical byte order — hashing the extracted tight tile
        // must equal hashing manually concatenated rows.
        var rng = SplitMix64(seed: 34)
        let width = 200, height = 150
        let bytesPerRow = width * 4 + 32
        let frame = rng.bytes(bytesPerRow * height)
        let x = 128, y = 64, tw = 64, th = 64

        var tight = [UInt8](repeating: 0, count: tw * th * 4)
        _ = frame.withUnsafeBytes { src in
            tight.withUnsafeMutableBytes { dst in
                TileOps.extract(src: src, bytesPerRow: bytesPerRow, x: x, y: y, tw: tw, th: th, into: dst)
            }
        }
        var manual = [UInt8]()
        manual.reserveCapacity(tw * th * 4)
        for row in 0..<th {
            let start = (y + row) * bytesPerRow + x * 4
            manual.append(contentsOf: frame[start ..< start + tw * 4])
        }
        #expect(XXH64.hash(tight) == XXH64.hash(manual))
    }
}
