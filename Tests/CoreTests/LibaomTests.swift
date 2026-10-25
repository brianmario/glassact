import Foundation
import Testing
import GlassActTestSupport
import libaom

/// The vendored libaom (arm64): every frame the encoder emits must decode
/// to exactly the encoder's own reconstruction.
///
/// The pictures aim at the realtime IntraBC path where libaom 3.15.2 had
/// bugs (BENCHMARKS "AV2 on screen text"): a block vector of 2048 px or
/// more that the decoder rejects (copies can't cross tiles, so a tall
/// frame, with noise blocks repeated 2168 px apart vertically), and drift
/// with 2+ threads when an inter frame after an IntraBC frame points past
/// the frame edge (the picture scrolls). Those bugs read memory past a
/// table, and with this build's configuration 3.15.2 passed here and on
/// real 5K recordings: the test guards the round trip, it doesn't
/// reproduce them. The vendored commit carries the upstream fixes.
///
/// `aRecordingDecodesToTheEncodersReconstruction` runs the same check on a
/// real recording (GLASSACT_AOM_Y4M), as part of updating libaom.
@Suite(.enabled(if: glassact_aom_available() != 0, "libaom is arm64 only"))
struct LibaomTests {
    static let width = 512
    static let height = 2304

    /// A 4:2:0 picture: a flat background, noise blocks near the top with
    /// the same blocks again 2168 px lower, and glyph-like text between
    /// them; frame n is frame 0 scrolled down 3n px.
    struct Picture {
        var y = [UInt8](repeating: 236, count: LibaomTests.width * LibaomTests.height)
        var u = [UInt8](repeating: 128, count: LibaomTests.width * LibaomTests.height / 4)
        var v = [UInt8](repeating: 128, count: LibaomTests.width * LibaomTests.height / 4)

        init(frame: Int) {
            var rng = SplitMix64(seed: 42)
            let scroll = frame * 3
            for i in 0..<6 {
                let block = (0..<(64 * 64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                let x = 16 + i * 80
                stamp(block, side: 64, x: x, y: 24 + scroll)
                stamp(block, side: 64, x: x, y: 24 + 2168 + scroll)
            }
            for line in 0..<60 {
                for col in 0..<28 {
                    let glyph = (0..<(16 * 16)).map { _ in UInt8(rng.int(0..<4) == 0 ? 30 : 236) }
                    stamp(glyph, side: 16, x: 24 + col * 17, y: 140 + line * 32 + scroll)
                }
            }
            // A coloured bar, so the chroma planes carry something.
            for row in (100 + scroll / 2)..<(160 + scroll / 2) {
                for col in 32..<200 {
                    u[row * LibaomTests.width / 2 + col] = 90
                    v[row * LibaomTests.width / 2 + col] = 200
                }
            }
        }

        private mutating func stamp(_ block: [UInt8], side: Int, x: Int, y: Int) {
            for by in 0..<side where y + by < LibaomTests.height {
                for bx in 0..<side {
                    self.y[(y + by) * LibaomTests.width + x + bx] = block[by * side + bx]
                }
            }
        }
    }

    /// Plane by plane, row by row: does `a` show exactly the same pixels as
    /// `b`?
    static func same(_ a: glassact_aom_frame, _ b: glassact_aom_frame) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let planesA = [a.planes.0, a.planes.1, a.planes.2], planesB = [b.planes.0, b.planes.1, b.planes.2]
        let stridesA = [a.strides.0, a.strides.1, a.strides.2], stridesB = [b.strides.0, b.strides.1, b.strides.2]
        for p in 0..<3 {
            let w = p == 0 ? Int(a.width) : (Int(a.width) + 1) / 2
            let h = p == 0 ? Int(a.height) : (Int(a.height) + 1) / 2
            guard let pa = planesA[p], let pb = planesB[p] else { return false }
            for row in 0..<h where memcmp(pa + row * Int(stridesA[p]), pb + row * Int(stridesB[p]), w) != 0 {
                return false
            }
        }
        return true
    }

    @Test(arguments: [1, 4])
    func everyFrameDecodesToTheEncodersReconstruction(threads: Int32) throws {
        let enc = try #require(glassact_aom_enc_create(Int32(Self.width), Int32(Self.height), threads, 4000))
        defer { glassact_aom_enc_destroy(enc) }
        let dec = try #require(glassact_aom_dec_create(threads))
        defer { glassact_aom_dec_destroy(dec) }

        for frame in 0..<12 {
            let picture = Picture(frame: frame)
            let encoded = picture.y.withUnsafeBufferPointer { y in
                picture.u.withUnsafeBufferPointer { u in
                    picture.v.withUnsafeBufferPointer { v in
                        var input = glassact_aom_frame(
                            planes: (y.baseAddress, u.baseAddress, v.baseAddress),
                            strides: (Int32(Self.width), Int32(Self.width / 2), Int32(Self.width / 2)),
                            width: Int32(Self.width), height: Int32(Self.height))
                        return glassact_aom_enc_encode(enc, &input, Int64(frame) * 16_667, 16_667, frame == 0 ? 1 : 0)
                    }
                }
            }
            try #require(encoded == 0, "frame \(frame): \(String(cString: glassact_aom_enc_error(enc)))")
            var size = 0, isKey: Int32 = 0
            let packet = try #require(glassact_aom_enc_next_packet(enc, &size, &isKey), "frame \(frame): no packet")
            #expect((isKey != 0) == (frame == 0))
            var recon = glassact_aom_frame(), decoded = glassact_aom_frame()
            try #require(glassact_aom_enc_reconstruction(enc, &recon) == 0)
            try #require(glassact_aom_dec_decode(dec, packet, size, &decoded) == 0,
                         "frame \(frame) (\(threads) threads): the decoder rejected it")
            #expect(Self.same(recon, decoded), "frame \(frame) (\(threads) threads): decoded ≠ the encoder's reconstruction")
        }
    }

    /// Local check on a real recording: GLASSACT_AOM_Y4M names a 4:2:0
    /// y4m (`glassact-bench y4m`), encoded with 8 threads.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSACT_AOM_Y4M"] != nil))
    func aRecordingDecodesToTheEncodersReconstruction() throws {
        let path = ProcessInfo.processInfo.environment["GLASSACT_AOM_Y4M"]!
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        let header = String(decoding: data.prefix(while: { $0 != 0x0A }), as: UTF8.self)
        let fields = header.split(separator: " ")
        let w = Int(fields.first { $0.hasPrefix("W") }!.dropFirst())!
        let h = Int(fields.first { $0.hasPrefix("H") }!.dropFirst())!
        let frameBytes = w * h * 3 / 2
        let enc = try #require(glassact_aom_enc_create(Int32(w), Int32(h), 8, 8000))
        defer { glassact_aom_enc_destroy(enc) }
        let dec = try #require(glassact_aom_dec_create(8))
        defer { glassact_aom_dec_destroy(dec) }
        var offset = data.firstIndex(of: 0x0A)! + 1
        var frame = 0
        while offset + 6 + frameBytes <= data.count {
            offset += 6 // "FRAME\n"
            let ok = data.withUnsafeBytes { raw -> Bool in
                let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                var input = glassact_aom_frame(
                    planes: (base, base + w * h, base + w * h + w * h / 4),
                    strides: (Int32(w), Int32(w / 2), Int32(w / 2)), width: Int32(w), height: Int32(h))
                return glassact_aom_enc_encode(enc, &input, Int64(frame) * 16_667, 16_667, frame == 0 ? 1 : 0) == 0
            }
            try #require(ok)
            var size = 0, isKey: Int32 = 0
            let packet = try #require(glassact_aom_enc_next_packet(enc, &size, &isKey))
            var recon = glassact_aom_frame(), decoded = glassact_aom_frame()
            try #require(glassact_aom_enc_reconstruction(enc, &recon) == 0)
            try #require(glassact_aom_dec_decode(dec, packet, size, &decoded) == 0, "frame \(frame): the decoder rejected it")
            #expect(Self.same(recon, decoded), "frame \(frame): decoded ≠ the encoder's reconstruction")
            offset += frameBytes
            frame += 1
        }
    }

    @Test func theSequenceHeaderIsAnOBU() throws {
        let enc = try #require(glassact_aom_enc_create(640, 360, 1, 1000))
        defer { glassact_aom_enc_destroy(enc) }
        var header = [UInt8](repeating: 0, count: 64)
        let length = glassact_aom_enc_sequence_header(enc, &header, header.count)
        try #require(length > 2)
        // OBU type 1 (sequence header) in bits 3–6 of the first byte.
        #expect((header[0] >> 3) & 0xF == 1)
    }
}
