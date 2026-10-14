// glassact-trace — .scap record-file inspection (§7).
import Foundation
import GlassActCore

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("glassact-trace: " + message + "\n").utf8))
    exit(1)
}

func formatBytes(_ n: Int) -> String {
    n >= 1_048_576 ? String(format: "%.2f MB", Double(n) / 1_048_576)
        : n >= 1024 ? String(format: "%.1f KB", Double(n) / 1024)
        : "\(n) B"
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let path = argv.first(where: { !$0.hasPrefix("--") }) else {
    print("""
    usage: glassact-trace <file.scap> [--list] [--verify] [--diff]
      --list    print one line per frame
      --verify  decompress every frame and validate sizes
      --diff    report which tiles changed between consecutive frames
    """)
    exit(2)
}
let list = argv.contains("--list")
let diff = argv.contains("--diff")
let verify = argv.contains("--verify") || diff

do {
    let reader = try ScapReader(url: URL(fileURLWithPath: path))
    let header = reader.header
    print("scap: \(path)")
    print("  geometry: \(header.width)x\(header.height)  pixfmt: \(header.pixfmt)  tile: \(header.tile)  ver: \(header.version)")

    var frameBuf: UnsafeMutableRawBufferPointer?
    var prevBuf: UnsafeMutableRawBufferPointer?
    if verify {
        frameBuf = .allocate(byteCount: header.frameByteCount, alignment: 64)
    }
    if diff {
        prevBuf = .allocate(byteCount: header.frameByteCount, alignment: 64)
    }
    defer {
        frameBuf?.deallocate()
        prevBuf?.deallocate()
    }
    let grid = TileGrid(width: header.width, height: header.height)

    func changedTiles(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> [Int] {
        var changed: [Int] = []
        for idx in 0..<grid.count {
            let (x, y, tw, th) = grid.rect(of: idx)
            for row in 0..<th {
                let offset = ((y + row) * header.width + x) * 4
                if memcmp(a.baseAddress! + offset, b.baseAddress! + offset, tw * 4) != 0 {
                    changed.append(idx)
                    break
                }
            }
        }
        return changed
    }

    var frames = 0
    var totalLZ4 = 0
    var totalRects = 0
    var firstTS: UInt64?
    var lastTS: UInt64 = 0
    var rects: [DirtyRect] = []

    while true {
        let meta: ScapFrameMeta?
        if let buf = frameBuf {
            meta = try reader.readFrame(rects: &rects, into: buf)
        } else {
            meta = try reader.skimFrame()
        }
        guard let meta else { break }
        if firstTS == nil { firstTS = meta.timestampUS }
        lastTS = meta.timestampUS
        if diff, let buf = frameBuf, let prev = prevBuf {
            if frames > 0 {
                let changed = changedTiles(UnsafeRawBufferPointer(prev), UnsafeRawBufferPointer(buf))
                if !changed.isEmpty {
                    var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
                    for idx in changed {
                        let (x, y, tw, th) = grid.rect(of: idx)
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x + tw); maxY = max(maxY, y + th)
                    }
                    let rel = meta.timestampUS &- (firstTS ?? 0)
                    print(String(format: "  #%-4d t+%8.1f ms  %3d tiles changed  bbox (%d,%d)–(%d,%d)",
                                 frames, Double(rel) / 1000.0, changed.count, minX, minY, maxX, maxY))
                }
            }
            prev.copyMemory(from: UnsafeRawBufferPointer(buf))
        }
        if list {
            let rel = meta.timestampUS &- (firstTS ?? 0)
            print(String(format: "  #%-5d t+%8.1f ms  rects %-3d  lz4 %@ (%.1f%%)",
                         frames, Double(rel) / 1000.0, meta.rectCount,
                         formatBytes(meta.lz4Length),
                         100.0 * Double(meta.lz4Length) / Double(header.frameByteCount)))
        }
        frames += 1
        totalLZ4 += meta.lz4Length
        totalRects += meta.rectCount
    }

    let durationS = frames > 1 ? Double(lastTS &- (firstTS ?? 0)) / 1_000_000 : 0
    print("  frames: \(frames)  duration: \(String(format: "%.2f", durationS)) s")
    print("  lz4 payload: \(formatBytes(totalLZ4)) total"
          + (frames > 0 ? ", \(formatBytes(totalLZ4 / frames))/frame avg" : "")
          + String(format: " (%.1f%% of raw)",
                   frames > 0 ? 100.0 * Double(totalLZ4) / Double(header.frameByteCount * frames) : 0))
    print("  dirty rects: \(totalRects) total" + (frames > 0 ? String(format: ", %.1f/frame avg", Double(totalRects) / Double(frames)) : ""))
    if verify {
        print("  verify: all \(frames) frames decompressed to exactly \(formatBytes(header.frameByteCount)) — OK")
    }
} catch let error as ScapError {
    die("trace error: \(error)")
}
