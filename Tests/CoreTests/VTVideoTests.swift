import Foundation
import Testing
import GlassActWire
import GlassActCore
import GlassActTestSupport

/// VideoToolbox HEVC round trip on real hardware (Apple Silicon media
/// engine). Lossy by design: the bar is structural (config on first frame,
/// sync flags, dimensions) plus a PSNR floor, never byte equality — byte
/// exactness is the dissolve repaint's job.
@Suite struct VTVideoTests {
    private func makeFrames(width: Int, height: Int, count: Int) -> [[UInt8]] {
        var rng = SplitMix64(seed: 71)
        var frames: [[UInt8]] = []
        var frame = [UInt8](repeating: 0, count: width * height * 4)
        // Photographic-ish base: smooth gradients + noise patches, then a
        // moving rect so inter frames have real motion.
        for py in 0..<height {
            for px in 0..<width {
                let o = (py * width + px) * 4
                frame[o] = UInt8((px * 255) / width)
                frame[o + 1] = UInt8((py * 255) / height)
                frame[o + 2] = UInt8(((px + py) * 255) / (width + height))
                frame[o + 3] = 255
            }
        }
        for f in 0..<count {
            let bx = (f * 16) % max(1, width - 96)
            for py in 40..<min(height, 104) {
                for px in bx..<(bx + 96) {
                    let o = (py * width + px) * 4
                    frame[o] = UInt8(truncatingIfNeeded: rng.next())
                    frame[o + 1] = UInt8(truncatingIfNeeded: rng.next())
                    frame[o + 2] = UInt8(truncatingIfNeeded: rng.next())
                }
            }
            frames.append(frame)
        }
        return frames
    }

    /// PSNR over BGR, excluding the moving noise band (rows 40..<104): random
    /// noise is information-theoretically unreproducible at any sane bitrate
    /// and would dominate the metric — the quality bar belongs on the
    /// predictable content.
    private func psnr(_ a: [UInt8], _ b: [UInt8], width: Int) -> Double {
        precondition(a.count == b.count)
        var sumSq = 0.0
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let row = (i / 4) / width
            if (40..<104).contains(row) { continue }
            for c in 0..<3 {
                let d = Double(Int(a[i + c]) - Int(b[i + c]))
                sumSq += d * d
                n += 1
            }
        }
        let mse = sumSq / Double(n)
        return mse == 0 ? .infinity : 10 * log10(255.0 * 255.0 / mse)
    }

    @Test func hevcRoundTripOnHardware() {
        let width = 640
        let height = 384
        let queue = DispatchQueue(label: "test.vt.callback")
        let encoder = VTHEVCRegionEncoder(callbackQueue: queue)

        struct Delivered {
            var data: [UInt8]
            var sync: Bool
            var config: [UInt8]?
        }
        var delivered: [Delivered] = []
        let lock = NSLock()
        let firstArrived = DispatchSemaphore(value: 0)
        let allArrived = DispatchSemaphore(value: 0)
        let frameCount = 12

        let ok = encoder.start(width: width, height: height) { data, sync, config in
            lock.lock()
            delivered.append(Delivered(data: data, sync: sync, config: config))
            let count = delivered.count
            lock.unlock()
            if count == 1 { firstArrived.signal() }
            if count == frameCount { allArrived.signal() }
        }
        #expect(ok, "VT HEVC session must start on Apple Silicon")
        guard ok else { return }

        let frames = makeFrames(width: width, height: height, count: frameCount)
        for (i, frame) in frames.enumerated() {
            frame.withUnsafeBytes { encoder.encode(bgra: $0, forceSync: i == 0, timeUS: UInt64(i) * 16_667) }
        }
        #expect(allArrived.wait(timeout: .now() + 15) == .success, "encoder must deliver all frames")
        encoder.stop()

        lock.lock()
        let out = delivered
        lock.unlock()
        guard out.count == frameCount else { return }
        #expect(out[0].config != nil, "first frame must carry the parameter sets")
        #expect(out[0].sync, "first frame must be IDR")
        #expect(out.allSatisfy { !$0.data.isEmpty })
        let totalBytes = out.reduce(0) { $0 + $1.data.count }
        let rawBytes = frameCount * width * height * 4
        #expect(totalBytes < rawBytes / 10, "HEVC must be far below RAW (got \(totalBytes) of \(rawBytes))")

        // Decode side.
        let decoder = VTRegionDecoder()
        #expect(decoder.start(codec: VideoCodec.hevc, config: out[0].config ?? [],
                              width: width, height: height))
        var decodedCount = 0
        var lastPSNR = 0.0
        for (i, d) in out.enumerated() {
            decoder.decode(d.data, sync: d.sync) { pixels, bytesPerRow in
                decodedCount += 1
                lastPSNR = psnr(frames[i], tightPixels(pixels, bytesPerRow: bytesPerRow,
                                                       width: width, height: height), width: width)
            }
        }
        decoder.stop()
        #expect(decodedCount == frameCount, "every frame must decode")
        #expect(lastPSNR > 30, "decoded quality on predictable content must be high (PSNR \(lastPSNR))")

        // Wrong codec id and garbage config must be rejected cleanly.
        #expect(!VTRegionDecoder().start(codec: VideoCodec.reservedH264,
                                             config: out[0].config ?? [], width: width, height: height))
        #expect(!VTRegionDecoder().start(codec: VideoCodec.hevc,
                                             config: [3, 1, 0, 9], width: width, height: height))
    }
}
