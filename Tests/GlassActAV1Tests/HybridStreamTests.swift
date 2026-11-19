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

    /// The padded sources updated in place (only the 64×64s changed since the picture a pooled set
    /// holds) give the bytes of copying them whole: scrolls and edits, sizes with partial 64×64s,
    /// two screens in turn (GOLDEN_FRAME), a key frame on demand, 4:4:4, and pictures with the
    /// Host's change maps.
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(640, 360, false), (333, 201, false), (333, 201, true)])
    func sourcesUpdatedInPlaceGiveTheSameBytes(width: Int, height: Int, chroma444: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var pictures = Self.pictures(10, width: width, height: height, seed: 0x9a1)
            + Self.screensInTurn(8, width: width, height: height, salt: 1, seed: 0x9a2)
        if chroma444 {
            pictures = (0..<12).map { i in
                var p = Hybrid444Tests.picture(width: width, height: height, seed: 0x9a3 + UInt64(i % 3), repeats: true)
                if i % 4 == 1 { p.y[(i * 977) % p.y.count] ^= 0x40 }
                return p
            }
        }
        // the change map each picture's predecessor gives it (the Host's, here exact)
        for i in pictures.indices.dropFirst() where i % 2 == 0 {
            let (a, b) = (pictures[i], pictures[i - 1])
            let cols = (width + 63) / 64, rows = (height + 63) / 64
            let cw = chroma444 ? width : (width + 1) / 2, side = chroma444 ? 64 : 32
            pictures[i].changed = (0..<cols * rows).map { s in
                let (sx, sy) = (s % cols, s / cols)
                let luma = (sy * 64..<min(height, sy * 64 + 64)).contains { r in
                    a.y[r * width + sx * 64..<r * width + min(width, sx * 64 + 64)] != b.y[r * width + sx * 64..<r * width + min(width, sx * 64 + 64)]
                }
                let ch = a.u.count / cw
                let chroma = (sy * side..<min(ch, sy * side + side)).contains { r in
                    let x0 = r * cw + sx * side, x1 = r * cw + min(cw, sx * side + side)
                    return a.u[x0..<x1] != b.u[x0..<x1] || a.v[x0..<x1] != b.v[x0..<x1]
                }
                return luma || chroma ? 1 : 0
            }
        }
        func encode(inPlace: Bool) throws -> (bytes: [[UInt8]], copied: (whole: Int, inPlace: Int)) {
            let encoder = try AV1HybridEncoder(device: device)
            encoder.tiling = (1, 0)
            encoder.interFrames = true
            encoder.updatesSourcesInPlace = inPlace
            let got = Collected()
            encoder.startStream { i, r in
                got.lock.withLock { got.frames.append((i, try? r.get())) }
                got.ready.signal()
            }
            for (i, p) in pictures.enumerated() { encoder.submit(p, qindex: 100, forceKey: i == 13) }
            encoder.endStream()
            return (got.frames.sorted { $0.index < $1.index }.map { $0.frame?.obu ?? [] }, encoder.sourcesCopied)
        }
        let whole = try encode(inPlace: false), inPlace = try encode(inPlace: true)
        #expect(whole.copied.inPlace == 0)
        #expect(inPlace.copied.inPlace >= pictures.count / 2, "updated in place: \(inPlace.copied)")
        #expect(inPlace.bytes.allSatisfy { !$0.isEmpty } && inPlace.bytes == whole.bytes,
                "\(width)×\(height)\(chroma444 ? " 4:4:4" : ""): in place differs from whole")
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

    /// Two screens in turn (A A B B A A …), each picture with edits of its own: from the first
    /// return, inter frames copy the other screen's last state through GOLDEN_FRAME. `salt` makes
    /// another pair of screens.
    @available(macOS 27, *)
    static func screensInTurn(_ n: Int, width: Int, height: Int, salt: Int, seed: UInt64) -> [AV1HybridEncoder.Picture] {
        var rng = SplitMix64(seed: seed)
        var screens = [PartitionTests.Picture(width: width, height: height), PartitionTests.Picture(width: width, height: height)]
        for s in 0..<2 {
            for k in screens[s].y.indices {
                let (x, y) = (k % width, k / width)
                screens[s].y[k] = s == 0 ? UInt8(truncatingIfNeeded: y * (3 + salt) + (x % (29 + salt) < 14 ? 30 : 210))
                    : UInt8(truncatingIfNeeded: (x / (5 + salt)) * 11 + (y % 23 < 9 ? 180 : 60))
            }
            for k in screens[s].u.indices { screens[s].u[k] = UInt8(truncatingIfNeeded: 128 + (s == 0 ? 20 : -30) + salt) }
        }
        return (0..<n).map { i in
            var p = screens[(i / 2) % 2]
            for _ in 0..<120 { p.y[rng.int(0..<p.y.count)] = UInt8(rng.int(0..<256)) }
            return AV1HybridEncoder.Picture(y: p.y, u: p.u, v: p.v, width: width, height: height)
        }
    }

    /// Frames `frames` decoded in order by a decoder that starts at the first of them: each must
    /// be the encoder's own reconstruction, sample for sample in all three planes. A frame that
    /// predicted from a picture before the first (a reference slot the decoder never filled)
    /// wouldn't be.
    @available(macOS 27, *)
    static func expectDecodesExactly(_ frames: ArraySlice<AV1HybridEncoder.Frame>, width: Int, height: Int,
                                     _ what: String) throws {
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        for (i, f) in zip(frames.indices, frames) {
            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, f.obu, f.obu.count, &frame) == 0, "\(what): frame \(i): libaom")
            for plane in 0..<3 {
                let w = plane == 0 ? width : (width + 1) / 2, h = plane == 0 ? height : (height + 1) / 2
                let theirs = try #require(frame.planesTuple(plane))
                let stride = Int(frame.stridesTuple(plane))
                let rows = (0..<h).filter { r in (0..<w).contains { f.planes[plane][r * w + $0] != theirs[r * stride + $0] } }
                #expect(rows.isEmpty, "\(what): frame \(i) plane \(plane) differs from the decoder's on \(rows.count) rows")
            }
        }
    }

    /// What a Viewer's decoder loses and gets back: after GOLDEN_FRAME is in use (long-term
    /// pictures in slots of their own), a key frame on demand (a SYNC_REQUEST's answer) is the
    /// start of everything after it — a decoder rebuilt there decodes every later frame exactly —
    /// and so is a new stream's first frame (a region's START) on the encoder the last region
    /// used: no picture of the earlier stream, in any slot, is reachable from it.
    @available(macOS 27, *)
    @Test func nothingAfterAKeyFrameReachesBackPastIt() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (1, 0)
        encoder.interFrames = true
        let (width, height) = (640, 360)
        let streams = [Self.screensInTurn(16, width: width, height: height, salt: 0, seed: 0x51c0),
                       Self.screensInTurn(12, width: width, height: height, salt: 3, seed: 0x51c1)]
        let keyAt = 9
        func encodeStreams() throws -> [[AV1HybridEncoder.Frame]] {
            var coded: [[AV1HybridEncoder.Frame]] = []
            for (s, pictures) in streams.enumerated() {
                let got = Collected()
                encoder.startStream { i, r in
                    got.lock.withLock { got.frames.append((i, try? r.get())) }
                    got.ready.signal()
                }
                for (i, p) in pictures.enumerated() { encoder.submit(p, qindex: 96, forceKey: s == 0 && i == keyAt) }
                for _ in pictures { #expect(got.ready.wait(timeout: .now() + 20) == .success) }
                encoder.endStream()
                let frames = got.frames.compactMap(\.frame)
                try #require(frames.count == pictures.count)
                coded.append(frames)
            }
            return coded
        }
        let coded = try encodeStreams()
        // the encoder as the Host's adapter runs it, without its reconstruction (the closed loop's
        // references then stay in the filters' buffers): the same bytes
        encoder.returnsPlanes = false
        let live = try encodeStreams()
        #expect(live.map { $0.map(\.obu) } == coded.map { $0.map(\.obu) }, "the bytes depend on returnsPlanes")
        let (first, second) = (coded[0], coded[1])
        let golden = { (f: AV1HybridEncoder.Frame) in f.timing.goldenSlot >= 0 && f.timing.copiedGolden > 0 }
        // (or the test proves nothing: copies from long-term pictures before the key frame, and after it)
        #expect(first[..<keyAt].contains(where: golden), "no GOLDEN_FRAME before the key frame: \(first.map(\.timing.goldenSlot))")
        #expect(first[(keyAt + 1)...].contains(where: golden), "no GOLDEN_FRAME after the key frame: \(first.map(\.timing.goldenSlot))")
        #expect(second.contains(where: golden), "no GOLDEN_FRAME in the second stream: \(second.map(\.timing.goldenSlot))")
        #expect(first[keyAt].params.frame_type != UInt8(AV1G_FRAME_INTER))
        #expect(second[0].params.frame_type != UInt8(AV1G_FRAME_INTER))
        try Self.expectDecodesExactly(first[...], width: width, height: height, "the first stream, whole")
        try Self.expectDecodesExactly(first[keyAt...], width: width, height: height, "from the key frame on demand")
        try Self.expectDecodesExactly(second[...], width: width, height: height, "the next stream")
    }

    /// A picture that fails inside the stream, with the pictures after it already submitted (their
    /// analyses begun, waiting on gates its filters would have opened): every picture gets one
    /// output, in order — those before it their frames, it and every one after it a failure —
    /// the stream ends without waiting on a gate that won't open, and the next stream starts with
    /// a key frame that a new decoder decodes exactly from.
    @available(macOS 27, *)
    @Test func aPictureThatFailsFailsTheRestOfItsStreamInOrder() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1HybridEncoder(device: device)
        encoder.tiling = (1, 0)
        encoder.interFrames = true
        let (width, height) = (640, 360)
        let pictures = Self.screensInTurn(10, width: width, height: height, salt: 1, seed: 0xfa11)
        let failing = 4
        for (n, fails) in [(8, true), (5, false)] {
            encoder.failingPicture = fails ? failing : nil
            let got = Collected()
            encoder.startStream { i, r in
                got.lock.withLock { got.frames.append((i, try? r.get())) }
                got.ready.signal()
            }
            for p in pictures.prefix(n) { encoder.submit(p, qindex: 96) }  // (all at once)
            for i in 0..<n {
                try #require(got.ready.wait(timeout: .now() + 20) == .success, "picture \(i) has no output")
            }
            // (on a thread of its own: an end that waits on a gate nothing will open would hang)
            let ended = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                encoder.endStream()
                ended.signal()
            }
            try #require(ended.wait(timeout: .now() + 20) == .success, "the stream didn't end")
            let outputs = got.lock.withLock { got.frames }
            #expect(outputs.map(\.index) == Array(0..<n), "outputs out of order")
            if fails {
                #expect(outputs.map { $0.frame != nil } == (0..<n).map { $0 < failing }, "\(outputs.map { $0.frame != nil })")
            } else {
                let frames = outputs.compactMap(\.frame)
                try #require(frames.count == n, "the stream after the failure failed")
                #expect(frames[0].params.frame_type != UInt8(AV1G_FRAME_INTER))
                try Self.expectDecodesExactly(frames[...], width: width, height: height, "the stream after the failure")
            }
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
