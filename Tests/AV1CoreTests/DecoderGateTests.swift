import AV1Core
import AV1CoreTestSupport
import Foundation
import Testing
import libaom

/// av1core's bitstream writer against an independent decoder: every random
/// legal decision record (av1gpu's fuzzer: sizes, partitions, modes, angle
/// deltas, CfL, tx sizes and types, coefficients up to the Golomb range,
/// tiles, delta-q, quantizer matrices, filter intra, edge filter, deblocking,
/// CDEF) must decode in the vendored libaom to exactly the reconstruction
/// av1core computed for it. Every encoder built on av1core predicts from that
/// reconstruction, so it is the ground the Metal port stands on.
@Suite(.enabled(if: glassact_aom_available() != 0, "libaom is arm64 only"))
struct DecoderGateTests {
    /// av1core-internal: cross-check its edge availability against the
    /// decoder's (av1gpu's fuzzer sets it too).
    static let checkEdges: UInt32 = 0x20000

    @Test(arguments: 0..<8)
    func randomRecordsDecodeToTheirReconstruction(chunk: UInt64) throws {
        let perChunk: UInt64 = 25
        for seed in (1 + chunk * perChunk)...((chunk + 1) * perChunk) {
            try Self.check(seed: seed)
        }
    }

    static func check(seed: UInt64) throws {
        let fuzzCase = try #require(av1t_case_make(seed, 300, 2), "seed \(seed): no record")
        defer { av1t_case_free(fuzzCase) }
        let record = try #require(av1t_case_record(fuzzCase))
        var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_FIX_RANGE) | UInt32(AV1G_ENC_TD) | checkEdges,
                                       seq_level_idx: -1)
        var output = av1g_output()
        let rc = av1g_encode(record, &options, &output)
        defer { av1g_output_free(&output) }
        try #require(rc == AV1G_OK, "seed \(seed): encode \(rc): \(message(&output))")

        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var frame = glassact_aom_frame()
        try #require(glassact_aom_dec_decode(decoder, output.obu, output.obu_size, &frame) == 0,
                     "seed \(seed): libaom rejected the stream")
        let fp = record.pointee.fp
        #expect(frame.width == Int32(fp.width) && frame.height == Int32(fp.height), "seed \(seed): size")
        let planes = fp.monochrome != 0 ? 1 : 3
        for p in 0..<planes {
            let (w, h) = (Int(recon(output.recon_w, p)), Int(recon(output.recon_h, p)))
            let ours = try #require(reconPlane(output.recon, p))
            let theirs = try #require(frame.planesTuple(p))
            let stride = Int(frame.stridesTuple(p))
            for y in 0..<h where memcmp(ours + y * w, theirs + y * stride, w) != 0 {
                let x = (0..<w).first { ours[y * w + $0] != theirs[y * stride + $0] } ?? 0
                let where_ = "seed \(seed) \(fp.width)×\(fp.height): plane \(p) differs first at (\(x), \(y))"
                Issue.record("\(where_): av1core \(ours[y * w + x]), libaom \(theirs[y * stride + x])")
                return
            }
        }
    }

    private static func message(_ output: inout av1g_output) -> String {
        withUnsafeBytes(of: &output.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func recon(_ t: (UInt32, UInt32, UInt32), _ p: Int) -> UInt32 {
        p == 0 ? t.0 : p == 1 ? t.1 : t.2
    }

    private static func reconPlane(
        _ t: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?), _ p: Int
    ) -> UnsafeMutablePointer<UInt8>? {
        p == 0 ? t.0 : p == 1 ? t.1 : t.2
    }
}

extension glassact_aom_frame {
    func planesTuple(_ p: Int) -> UnsafePointer<UInt8>? { p == 0 ? planes.0 : p == 1 ? planes.1 : planes.2 }
    func stridesTuple(_ p: Int) -> Int32 { p == 0 ? strides.0 : p == 1 ? strides.1 : strides.2 }
}
