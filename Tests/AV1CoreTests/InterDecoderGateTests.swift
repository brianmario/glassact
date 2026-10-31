import AV1Core
import AV1CoreTestSupport
import Foundation
import Testing
import libaom

/// av1core's inter frames against an independent decoder: random legal inter
/// sequences (a key frame, then mostly inter frames: inter and intra blocks,
/// motion vectors of every precision near and far outside the picture, skip and
/// var-tx, random coefficients, reference slots and refresh flags, the
/// post-filters, monochrome and odd sizes) are encoded frame by frame, each
/// predicting from the reconstructions av1core returned for the frames that
/// last refreshed its slots. The vendored libaom decodes the stream, and every
/// frame must decode to exactly av1core's reconstruction of it: the ground an
/// inter encoder on av1core stands on.
@Suite(.enabled(if: glassact_aom_available() != 0, "libaom is arm64 only"))
struct InterDecoderGateTests {
    static let framesPerSequence: Int32 = 8

    @Test(arguments: 0..<8)
    func randomSequencesDecodeToTheirReconstructions(chunk: UInt64) throws {
        let perChunk: UInt64 = 12
        for seed in (1 + chunk * perChunk)...((chunk + 1) * perChunk) {
            try Self.check(seed: seed)
        }
    }

    static func check(seed: UInt64) throws {
        let sequence = try #require(av1t_inter_case_make(seed, 240, framesPerSequence), "seed \(seed): no sequence")
        defer { av1t_inter_case_free(sequence) }
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var outputs: [av1g_output] = []
        defer {
            for i in outputs.indices { av1g_output_free(&outputs[i]) }
        }
        var slots = [Int](repeating: -1, count: 8) // the frame each reference slot holds
        for k in 0..<Int(av1t_inter_case_frames(sequence)) {
            let record = try #require(av1t_inter_case_record(sequence, Int32(k)))
            let fp = record.pointee.fp
            var refs = [av1g_ref_planes](repeating: av1g_ref_planes(), count: 8)
            for (s, f) in slots.enumerated() where f >= 0 {
                let o = outputs[f]
                refs[s].plane = (UnsafePointer(o.recon.0), UnsafePointer(o.recon.1), UnsafePointer(o.recon.2))
                refs[s].stride = (Int32(o.recon_w.0), Int32(o.recon_w.1), Int32(o.recon_w.2))
                refs[s].cdfs = UnsafeRawPointer(o.cdfs)
            }
            var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_FIX_RANGE) | UInt32(AV1G_ENC_TD), seq_level_idx: -1)
            var output = av1g_output()
            let rc = av1g_encode_ex(record, &options, refs, &output)
            outputs.append(output)
            try #require(rc == AV1G_OK, "seed \(seed) frame \(k): encode \(rc): \(message(&outputs[k]))")

            var frame = glassact_aom_frame()
            try #require(glassact_aom_dec_decode(decoder, output.obu, output.obu_size, &frame) == 0,
                         "seed \(seed) frame \(k): libaom rejected the stream")
            #expect(frame.width == Int32(fp.width) && frame.height == Int32(fp.height), "seed \(seed): size")
            let kind = fp.frame_type == AV1G_FRAME_KEY ? "key" : "inter"
            for p in 0..<(fp.monochrome != 0 ? 1 : 3) {
                let (w, h) = (Int(recon(output.recon_w, p)), Int(recon(output.recon_h, p)))
                let ours = try #require(reconPlane(output.recon, p))
                let theirs = try #require(frame.planesTuple(p))
                let stride = Int(frame.stridesTuple(p))
                for y in 0..<h where memcmp(ours + y * w, theirs + y * stride, w) != 0 {
                    let x = (0..<w).first { ours[y * w + $0] != theirs[y * stride + $0] } ?? 0
                    let where_ = "seed \(seed) \(fp.width)×\(fp.height) frame \(k) (\(kind)): plane \(p) differs first at (\(x), \(y))"
                    Issue.record("\(where_): av1core \(ours[y * w + x]), libaom \(theirs[y * stride + x])")
                    return
                }
            }
            let refresh = fp.frame_type == AV1G_FRAME_KEY ? 0xFF : Int(fp.refresh_frame_flags)
            for s in 0..<8 where refresh >> s & 1 != 0 {
                slots[s] = k
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
