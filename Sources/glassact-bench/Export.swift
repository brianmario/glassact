// Trace export commands: dumppng (visual forensics), dumptiles (raw tile
// corpora for external codec probes), y4m (feed real traces to external
// video encoders).
import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import GlassActCodec
import GlassActCore

// MARK: - dumppng

let dumpPNGCommand = Command(
    name: "dumppng",
    summary: "visual forensics: write frames (optionally cropped) as PNG",
    flags: [
        .trace,
        .string("out", "<prefix>", required: true, "output prefix; writes <prefix>-f<N>.png"),
        .ints("framelist", "<n,n,...>", count: 0, "frame indices to dump (default 100)"),
        .ints("rect", "<x,y,w,h>", count: 4, "crop rect (default: full frame)"),
    ],
    validate: { opts in
        if let frames = opts.ints("framelist"), frames.contains(where: { $0 < 0 }) {
            throw UsageError(message: "--framelist expects non-negative frame indices", command: opts.command)
        }
        if let r = opts.ints("rect"), r[0] < 0 || r[1] < 0 || r[2] <= 0 || r[3] <= 0 {
            throw UsageError(message: "--rect expects x,y ≥ 0 and w,h > 0", command: opts.command)
        }
    },
    run: { opts in
        try cmdDumpPNG(try openTrace(opts.required("trace")), opts: opts)
    }
)

func cmdDumpPNG(_ reader: ScapReader, opts: Options) throws {
    let out = opts.required("out")
    let width = reader.header.width
    let height = reader.header.height
    let frameList = opts.ints("framelist") ?? [100]
    var rx = 0, ry = 0, rw = width, rh = height
    if let p = opts.ints("rect") {
        rx = p[0]; ry = p[1]; rw = p[2]; rh = p[3]
        guard rx + rw <= width, ry + rh <= height else {
            throw BenchError("--rect (\(rx),\(ry) \(rw)×\(rh)) is outside the \(width)×\(height) trace")
        }
    }
    let frame = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { frame.deallocate() }
    var rects: [DirtyRect] = []
    var i = 0
    let wanted = Set(frameList)
    let maxWanted = frameList.max() ?? 0
    while i <= maxWanted, let _ = try reader.readFrame(rects: &rects, into: frame) {
        defer { i += 1 }
        guard wanted.contains(i) else { continue }
        var crop = [UInt8](repeating: 0, count: rw * rh * 4)
        crop.withUnsafeMutableBytes { dst in
            for row in 0..<rh {
                dst.baseAddress!.advanced(by: row * rw * 4)
                    .copyMemory(from: frame.baseAddress!.advanced(by: ((ry + row) * width + rx) * 4),
                                byteCount: rw * 4)
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        crop.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: rw, height: rh,
                                      bitsPerComponent: 8, bytesPerRow: rw * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue),
                  let image = ctx.makeImage() else { return }
            let url = URL(fileURLWithPath: "\(out)-f\(i).png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                print("wrote \(url.path)")
            }
        }
    }
}

// MARK: - dumptiles

let dumpTilesCommand = Command(
    name: "dumptiles",
    summary: "write a corpus of changed 64×64 tiles (raw BGRA, concatenated) for external codec probes",
    flags: [
        .trace,
        .string("out", "<file>", required: true, "corpus file to write"),
        .int("count", "<n>", 1...Int.max, "tiles to keep (default 400; every 7th changed tile)"),
    ],
    run: { opts in
        try cmdDumpTiles(try openTrace(opts.required("trace")), opts: opts)
    }
)

func cmdDumpTiles(_ reader: ScapReader, opts: Options) throws {
    let out = opts.required("out")
    let count = opts.int("count", 400)
    let width = reader.header.width
    let height = reader.header.height
    let grid = TileGrid(width: width, height: height)
    let cur = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    let prev = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { cur.deallocate(); prev.deallocate() }
    var rects: [DirtyRect] = []
    var tight = [UInt8](repeating: 0, count: 64 * 64 * 4)
    var outData = Data()
    var frames = 0
    var kept = 0
    var stride = 0
    while kept < count, let _ = try reader.readFrame(rects: &rects, into: cur) {
        defer { prev.copyMemory(from: UnsafeRawBufferPointer(cur)); frames += 1 }
        guard frames > 0 else { continue }
        for idx in 0..<grid.count where kept < count {
            let (x, y, tw, th) = grid.rect(of: idx)
            guard tw == 64 && th == 64 else { continue }
            var changed = false
            for row in 0..<th {
                let off = ((y + row) * width + x) * 4
                if memcmp(cur.baseAddress! + off, prev.baseAddress! + off, tw * 4) != 0 { changed = true; break }
            }
            guard changed else { continue }
            stride += 1
            guard stride % 7 == 0 else { continue } // spread the sample across content
            tight.withUnsafeMutableBytes { dst in
                _ = TileOps.extract(src: UnsafeRawBufferPointer(cur), bytesPerRow: width * 4,
                                    x: x, y: y, tw: tw, th: th, into: dst)
            }
            outData.append(contentsOf: tight)
            kept += 1
        }
    }
    try outData.write(to: URL(fileURLWithPath: out))
    print("dumped \(kept) tiles to \(out)")
}

// MARK: - y4m

let y4mCommand = Command(
    name: "y4m",
    summary: "export a trace as 4:2:0 Y4M (BT.709 video range) to feed external video encoders",
    flags: [
        .trace,
        .string("out", "<file.y4m>", required: true, "Y4M file to write"),
        .int("frames", "<n>", 1...Int.max, "stop after N frames (default 10000)"),
    ],
    run: { opts in
        try cmdY4M(try openTrace(opts.required("trace")), opts: opts)
    }
)

func cmdY4M(_ reader: ScapReader, opts: Options) throws {
    let out = opts.required("out")
    let width = reader.header.width
    let height = reader.header.height
    let maxFrames = opts.int("frames", 10_000)
    let frame = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
    defer { frame.deallocate() }
    var rects: [DirtyRect] = []

    var conversion = vImage_ARGBToYpCbCr()
    var pixelRange = vImage_YpCbCrPixelRange(
        Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
        YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
    var matrix = vImage_ARGBToYpCbCrMatrix(
        R_Yp: 0.2126, G_Yp: 0.7152, B_Yp: 0.0722,
        R_Cb: -0.2126 / 1.8556, G_Cb: -0.7152 / 1.8556,
        B_Cb_R_Cr: 0.5, G_Cr: -0.7152 / 1.5748, B_Cr: -0.0722 / 1.5748)
    guard vImageConvert_ARGBToYpCbCr_GenerateConversion(
        &matrix, &pixelRange, &conversion,
        kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    else { throw BenchError("vImage conversion setup failed") }

    var y = [UInt8](repeating: 0, count: width * height)
    var u = [UInt8](repeating: 0, count: width * height / 4)
    var v = [UInt8](repeating: 0, count: width * height / 4)
    FileManager.default.createFile(atPath: out, contents: nil)
    guard let fh = FileHandle(forWritingAtPath: out) else { throw BenchError("cannot open \(out) for writing") }
    try fh.write(contentsOf: Data("YUV4MPEG2 W\(width) H\(height) F60:1 Ip A1:1 C420jpeg\n".utf8))
    var frames = 0
    var firstTS: UInt64?
    var lastTS: UInt64 = 0
    while frames < maxFrames, let meta = try reader.readFrame(rects: &rects, into: frame) {
        firstTS = firstTS ?? meta.timestampUS
        lastTS = meta.timestampUS
        var src = vImage_Buffer(data: frame.baseAddress, height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width * 4)
        var permuteMap: [UInt8] = [3, 2, 1, 0]
        let ok: vImage_Error = y.withUnsafeMutableBytes { yb in
            u.withUnsafeMutableBytes { ub in
                v.withUnsafeMutableBytes { vb in
                    var yp = vImage_Buffer(data: yb.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width)
                    var cb = vImage_Buffer(data: ub.baseAddress, height: vImagePixelCount(height / 2),
                                           width: vImagePixelCount(width / 2), rowBytes: width / 2)
                    var cr = vImage_Buffer(data: vb.baseAddress, height: vImagePixelCount(height / 2),
                                           width: vImagePixelCount(width / 2), rowBytes: width / 2)
                    return vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(
                        &src, &yp, &cb, &cr, &conversion, &permuteMap, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        guard ok == kvImageNoError else { throw BenchError("conversion failed at frame \(frames)") }
        try fh.write(contentsOf: Data("FRAME\n".utf8))
        try fh.write(contentsOf: y); try fh.write(contentsOf: u); try fh.write(contentsOf: v)
        frames += 1
    }
    try? fh.close()
    let seconds = Double(lastTS &- (firstTS ?? 0)) / 1_000_000
    print("y4m: \(frames) frames (\(width)x\(height)), trace span \(String(format: "%.1f", seconds)) s -> \(out)")
}
