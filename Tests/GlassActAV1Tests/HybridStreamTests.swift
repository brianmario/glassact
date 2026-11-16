import AV1Core
import Foundation
import GlassActAV1
import GlassActTestSupport
import Metal
import Testing
import libaom

/// The hybrid's stream API (`startStream`, `submit`, `endStream`), as a session pushes pictures:
/// the bytes don't depend on when pictures arrive, a picture with nothing after it comes out, and
/// a key frame on demand starts the stream over in place.
@Suite(.enabled(if: AV1ShaderSource.hasCapableGPU && glassact_aom_available() != 0,
                "needs an Apple-silicon GPU (not a VM's paravirtual one) and libaom (arm64)"))
struct HybridStreamTests {
    /// Pictures that copy, scroll and change: rows of a few values, shifted and edited.
    @available(macOS 27, *)
    static func pictures(_ n: Int, width: Int, height: Int, seed: UInt64) -> [AV1HybridEncoder.Picture] {
        var rng = SplitMix64(seed: seed)
        var base = PartitionTests.Picture(width: width, height: height)
        for k in base.y.indices { base.y[k] = UInt8(truncatingIfNeeded: (k / width) * 7 + (k % 61 < 30 ? 40 : 200)) }
        return (0..<n).map { i in
            var p = base
            let shift = (i % 3) * 64 * width
            for k in p.y.indices { p.y[k] = base.y[(k + shift) % base.y.count] }
            for _ in 0..<(i % 4 == 3 ? width * height / 3 : 200) { p.y[rng.int(0..<p.y.count)] = UInt8(rng.int(0..<256)) }
            return AV1HybridEncoder.Picture(y: p.y, u: p.u, v: p.v, width: width, height: height)
        }
    }

    @available(macOS 27, *)
    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        let ready = DispatchSemaphore(value: 0)
        var frames: [(index: Int, frame: AV1HybridEncoder.Frame?)] = []
    }

    /// Pictures pushed one at a time (each once the one before is out) or all at once give the
    /// bytes `encode(count:)` gives, and every frame comes out without a picture after it.
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(640, 360, 80), (333, 201, 120)])
    func theBytesDontDependOnWhenPicturesArrive(width: Int, height: Int, qindex: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (1, 0)
        encoder.interFrames = true
        let pictures = Self.pictures(8, width: width, height: height, seed: 0x5717)
        var batch: [[UInt8]] = []
        try encoder.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { _, f in batch.append(f.obu) })
        for lone in [true, false] {
            let got = Collected()
            encoder.startStream { i, r in
                got.lock.withLock { got.frames.append((i, try? r.get())) }
                got.ready.signal()
            }
            for p in pictures {
                encoder.submit(p, qindex: qindex)
                if lone {
                    // (nothing after it: it must come out on its own)
                    #expect(got.ready.wait(timeout: .now() + 10) == .success, "a lone picture didn't come out")
                }
            }
            if !lone { for _ in pictures { #expect(got.ready.wait(timeout: .now() + 10) == .success) } }
            encoder.endStream()
            #expect(got.frames.map(\.index) == Array(pictures.indices), "frames out of order")
            #expect(got.frames.map { $0.frame?.obu ?? [] } == batch, "\(width)×\(height) \(lone ? "lone" : "all at once"): bytes differ from encode(count:)")
        }
    }

    /// A key frame on demand mid-stream: the frame is a key frame at the key frames' qindex, the
    /// stream decodes exactly through it, its sequence header is the first key frame's (a
    /// Viewer gets that one only, with the stream's start), and the rate hook sees each picture
    /// as it will be coded.
    @available(macOS 27, *)
    @Test func aKeyFrameOnDemandStartsTheStreamOverInPlace() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (1, 0)
        encoder.interFrames = true
        let (width, height) = (640, 360)
        let pictures = Self.pictures(7, width: width, height: height, seed: 0x6b3f)
        let got = Collected()
        final class Infos: @unchecked Sendable {
            let lock = NSLock()
            var all: [AV1HybridEncoder.PictureInfo] = []
        }
        let infos = Infos()
        encoder.startStream { i, r in
            got.lock.withLock { got.frames.append((i, try? r.get())) }
            got.ready.signal()
        }
        for (i, p) in pictures.enumerated() {
            encoder.submit(p, qindex: 80, forceKey: i == 4) { info in
                infos.lock.withLock { infos.all.append(info) }
                return 80 + 4 * info.index  // a qindex of its own each
            }
        }
        encoder.endStream()
        let frames = got.frames.compactMap(\.frame)
        try #require(frames.count == pictures.count)
        let seen = infos.lock.withLock { infos.all }
        #expect(seen.map(\.key) == [true, false, false, false, true, false, false])
        #expect(seen.allSatisfy { $0.superblocks == 60 && ($0.key ? $0.coded == 60 : $0.coded <= 60) })
        for (i, f) in frames.enumerated() {
            let key = f.params.frame_type != UInt8(AV1G_FRAME_INTER)
            #expect(key == (i == 0 || i == 4), "frame \(i): key \(key)")
            let base = 80 + 4 * i
            let want = key ? encoder.keyFrameQindex(base) : seen[i].fast ? f.timing.qindex : base
            #expect(f.timing.qindex == want, "frame \(i) at qindex \(f.timing.qindex), not \(want)")
        }
        let header0 = try #require(Self.sequenceHeader(frames[0].obu))
        #expect(Self.sequenceHeader(frames[4].obu) == header0, "the key frame on demand carries another sequence header")
        // the stream decodes, in order, to the encoder's pictures
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        for (i, f) in frames.enumerated() {
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, f.obu, f.obu.count, &frame) == 0, "frame \(i): libaom")
            let y = try #require(frame.planesTuple(0))
            let stride = Int(frame.stridesTuple(0))
            let rows = (0..<height).filter { r in (0..<width).contains { f.planes[0][r * width + $0] != y[r * stride + $0] } }
            #expect(rows.isEmpty, "frame \(i): luma differs from libaom on \(rows.count) rows")
        }
    }

    /// The first sequence header OBU in a temporal unit.
    static func sequenceHeader(_ tu: [UInt8]) -> [UInt8]? {
        var i = 0
        while i < tu.count {
            let header = tu[i]
            guard header & 0x02 != 0 else { return nil }
            var j = i + 1 + (header & 0x04 != 0 ? 1 : 0)
            var size = 0, shift = 0
            while j < tu.count {
                let b = tu[j]
                size |= Int(b & 0x7F) << shift
                j += 1
                if b & 0x80 == 0 { break }
                shift += 7
            }
            if (header >> 3) & 0x0F == 1 { return Array(tu[i..<min(tu.count, j + size)]) }
            i = j + size
        }
        return nil
    }
}
