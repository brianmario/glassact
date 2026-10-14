import Foundation
import Testing
import GlassActCore
import GlassActTransport
import GlassActTestSupport

@Suite struct ScapTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("glassact-scap-\(name)-\(UInt64.random(in: 0...UInt64.max)).scap")
    }

    @Test func roundTripPreservesFramesExactly() throws {
        var rng = SplitMix64(seed: 77)
        let width = 96, height = 64
        let url = tempURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }

        var written: [(ts: UInt64, rects: [DirtyRect], frame: [UInt8])] = []
        let writer = try ScapWriter(url: url, width: width, height: height)
        for i in 0..<5 {
            let frame = rng.bytes(width * height * 4)
            let rects = i == 0 ? [] : [DirtyRect(x: rng.int(0..<32), y: rng.int(0..<32),
                                                 width: rng.int(1..<64), height: rng.int(1..<32))]
            try frame.withUnsafeBytes { raw in
                try writer.appendFrame(timestampUS: UInt64(i) * 16_667, dirtyRects: rects, frame: raw)
            }
            written.append((UInt64(i) * 16_667, rects, frame))
        }
        try writer.finish()

        let reader = try ScapReader(url: url)
        #expect(reader.header.width == width && reader.header.height == height)
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
        defer { buf.deallocate() }
        var rects: [DirtyRect] = []
        var index = 0
        while let meta = try reader.readFrame(rects: &rects, into: buf) {
            #expect(meta.timestampUS == written[index].ts)
            #expect(rects == written[index].rects)
            #expect([UInt8](UnsafeRawBufferPointer(buf)) == written[index].frame, "frame \(index)")
            index += 1
        }
        #expect(index == 5)
    }

    @Test func skimMatchesFullRead() throws {
        var rng = SplitMix64(seed: 78)
        let url = tempURL("skim")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ScapWriter(url: url, width: 64, height: 64)
        for i in 0..<3 {
            let frame = rng.bytes(64 * 64 * 4)
            try frame.withUnsafeBytes { raw in
                try writer.appendFrame(timestampUS: UInt64(i), dirtyRects: [], frame: raw)
            }
        }
        try writer.finish()

        let skimmer = try ScapReader(url: url)
        var metas: [ScapFrameMeta] = []
        while let m = try skimmer.skimFrame() { metas.append(m) }
        #expect(metas.count == 3)
        #expect(metas.map(\.timestampUS) == [0, 1, 2])
    }

    @Test func truncatedFileThrows() throws {
        var rng = SplitMix64(seed: 79)
        let url = tempURL("truncated")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ScapWriter(url: url, width: 64, height: 64)
        let frame = rng.bytes(64 * 64 * 4)
        try frame.withUnsafeBytes { raw in
            try writer.appendFrame(timestampUS: 1, dirtyRects: [], frame: raw)
        }
        try writer.finish()

        var data = try Data(contentsOf: url)
        data = data.dropLast(data.count / 3)
        try data.write(to: url)

        let reader = try ScapReader(url: url)
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 64 * 4, alignment: 64)
        defer { buf.deallocate() }
        var rects: [DirtyRect] = []
        #expect(throws: ScapError.self) {
            _ = try reader.readFrame(rects: &rects, into: buf)
        }
    }

    @Test func badMagicThrows() throws {
        let url = tempURL("badmagic")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x4E, 0x4F, 0x50, 0x45, 1, 64, 0, 64, 0, 1, 64]).write(to: url)
        #expect(throws: ScapError.badMagic) {
            _ = try ScapReader(url: url)
        }
    }

    /// §7 — replay a recorded trace through the full loop and require the
    /// viewer canvas to be byte-identical to the final frame (trace-driven
    /// variant of the golden divergence test).
    @Test func traceReplayGoldenThroughHarness() throws {
        var rng = SplitMix64(seed: 80)
        let url = tempURL("golden")
        defer { try? FileManager.default.removeItem(at: url) }

        let width = 320, height = 240
        let writer = try ScapWriter(url: url, width: width, height: height)
        var source = TestFrame(width: width, height: height)
        source.fillRandom(&rng)
        try source.bytes.withUnsafeBytes { raw in
            try writer.appendFrame(timestampUS: 0, dirtyRects: [], frame: raw)
        }
        for i in 1...8 {
            var rects: [DirtyRect] = []
            for _ in 0..<2 {
                let w = rng.int(8..<100), h = rng.int(8..<100)
                let x = rng.int(0..<(width - w)), y = rng.int(0..<(height - h))
                source.fillRect(x: x, y: y, w: w, h: h, &rng)
                rects.append(DirtyRect(x: x, y: y, width: w, height: h))
            }
            try source.bytes.withUnsafeBytes { raw in
                try writer.appendFrame(timestampUS: UInt64(i) * 16_667, dirtyRects: rects, frame: raw)
            }
        }
        try writer.finish()

        var faults = FaultConfig()
        faults.dropPermille = 50
        faults.reorderPermille = 100
        faults.latencyMinUS = 10_000
        faults.latencyMaxUS = 40_000
        faults.seed = 4
        let harness = Harness(width: width, height: height, faults: faults)

        let reader = try ScapReader(url: url)
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: width * height * 4, alignment: 64)
        defer { buf.deallocate() }
        var rects: [DirtyRect] = []
        while let meta = try reader.readFrame(rects: &rects, into: buf) {
            harness.frame.bytes = [UInt8](UnsafeRawBufferPointer(buf))
            harness.encodeFrame(dirtyRects: meta.rectCount == 0 ? nil : rects)
            harness.run(untilUS: harness.now + 16_000)
        }
        #expect(harness.settle())
        #expect(harness.canvasMatchesFrame())
    }
}
