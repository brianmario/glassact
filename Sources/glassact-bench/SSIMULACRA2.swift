// SSIMULACRA2 for vquality: an optional external scorer, like the earlier
// avifenc/cjxl branches of `keyframe`. Luma SSIM on 8×8 blocks is weak at
// telling whether text has gone soft; SSIMULACRA2 (libjxl's perceptual
// metric, 100 = lossless, 90 visually lossless, 70 high quality) is a
// second opinion. When the `ssimulacra2` binary is on PATH (or named with
// --ssimulacra2), sampled reference/decoded pairs are written as PNG to a
// temporary directory during the run and scored after it, in parallel, so
// the scorer doesn't share the CPU with the encode-latency measurement.
import CoreGraphics
import Foundation
import ImageIO

final class SSIMULACRA2Scorer {
    let binary: URL
    private let dir: URL
    private var pairs: [(reference: URL, distorted: URL)] = []

    /// `setting` is the --ssimulacra2 value: nil looks the binary up on
    /// PATH, "off" disables, anything else is a path. Nil when disabled or
    /// not found; a named path that isn't executable is an error.
    static func make(setting: String?) throws -> SSIMULACRA2Scorer? {
        if setting == "off" { return nil }
        let binary: URL
        if let setting {
            guard FileManager.default.isExecutableFile(atPath: setting) else {
                throw BenchError("--ssimulacra2 \(setting): not an executable file")
            }
            binary = URL(fileURLWithPath: setting)
        } else {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            guard let dir = path.split(separator: ":").first(where: {
                FileManager.default.isExecutableFile(atPath: "\($0)/ssimulacra2")
            }) else { return nil }
            binary = URL(fileURLWithPath: "\(dir)/ssimulacra2")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassact-vquality-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SSIMULACRA2Scorer(binary: binary, dir: dir)
    }

    private init(binary: URL, dir: URL) {
        self.binary = binary
        self.dir = dir
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Writes a BGRA reference/distorted pair as PNG; returns its index for
    /// `scoreAll()`.
    func add(reference: UnsafeMutableRawBufferPointer, distorted: UnsafeMutableRawBufferPointer,
             width: Int, height: Int) throws -> Int {
        let index = pairs.count
        let ref = dir.appendingPathComponent("\(index)-ref.png")
        let dist = dir.appendingPathComponent("\(index)-dist.png")
        try writePNG(reference, width, height, to: ref)
        try writePNG(distorted, width, height, to: dist)
        pairs.append((ref, dist))
        return index
    }

    /// Scores every pair added so far, in index order, a few processes at a
    /// time (each is single-threaded and holds float planes of the frame).
    func scoreAll() throws -> [Double] {
        let count = pairs.count
        guard count > 0 else { return [] }
        let workers = min(count, max(1, min(6, ProcessInfo.processInfo.activeProcessorCount / 2)))
        // Each worker writes only its own indices of preallocated buffers.
        struct Results: @unchecked Sendable {
            let scores: UnsafeMutableBufferPointer<Double>
            let errors: UnsafeMutableBufferPointer<String?>
        }
        let results = Results(scores: .allocate(capacity: count), errors: .allocate(capacity: count))
        results.scores.initialize(repeating: .nan)
        results.errors.initialize(repeating: nil)
        defer {
            results.scores.deallocate()
            results.errors.deinitialize()
            results.errors.deallocate()
        }
        let pairs = self.pairs.map { [$0.reference, $0.distorted] }, binary = self.binary
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for i in stride(from: worker, to: count, by: workers) {
                do {
                    results.scores[i] = try Self.run(binary, pairs[i][0], pairs[i][1])
                } catch {
                    results.errors[i] = errorMessage(error)
                }
                pairs[i].forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
        if let failure = results.errors.compactMap({ $0 }).first { throw BenchError(failure) }
        return Array(results.scores)
    }

    private static func run(_ binary: URL, _ reference: URL, _ distorted: URL) throws -> Double {
        let process = Process()
        process.executableURL = binary
        process.arguments = [reference.path, distorted.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, let score = Double(text) else {
            let detail = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BenchError("\(binary.path) failed (exit \(process.terminationStatus)): \(detail.isEmpty ? text : detail)")
        }
        return score
    }
}

/// An opaque BGRA buffer as an sRGB PNG.
private func writePNG(_ pixels: UnsafeMutableRawBufferPointer, _ width: Int, _ height: Int, to url: URL) throws {
    guard let ctx = CGContext(data: pixels.baseAddress, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue),
          let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw BenchError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw BenchError("cannot write \(url.path)") }
}
