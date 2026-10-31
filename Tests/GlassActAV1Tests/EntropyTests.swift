import AV1Core
import AV1CoreTestSupport
import Foundation
import GlassActAV1
import Metal
import Testing
import libaom

/// The GPU entropy coder against av1core's CPU writer, byte for byte, as
/// av1gpu's own gpu_fuzz_test holds it: every random legal record (sizes,
/// tiles, partitions at the frame edges, modes, CfL, tx sizes and types,
/// coefficients up to the Golomb range, delta-q, filter intra, CDEF indices)
/// and the Metal encoder's own pictures must give the CPU's OBUs exactly.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct EntropyTests {
    @available(macOS 27, *)
    @Test(arguments: 0..<4)
    func randomRecordsCodeAsTheCPUWriterDoes(chunk: UInt64) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let entropy = try AV1MetalEntropy(device: device)
        let perChunk: UInt64 = 50
        for seed in (1 + chunk * perChunk)...((chunk + 1) * perChunk) {
            let fuzzCase = try #require(av1t_case_make(seed, 300, 2), "seed \(seed): no record")
            defer { av1t_case_free(fuzzCase) }
            let record = try #require(av1t_case_record(fuzzCase))
            // FIX_RANGE repairs coefficients in place: the GPU codes the repaired record
            let cpu = try Self.cpuOBUs(record, flags: UInt32(AV1G_ENC_FIX_RANGE))
            let gpu = try entropy.encode(record.pointee)
            let fp = record.pointee.fp
            try #require(gpu == cpu, "seed \(seed) \(fp.width)×\(fp.height): \(Self.difference(gpu, cpu))")
        }
    }

    @available(macOS 27, *)
    @Test(arguments: [(333, 201, 40), (1280, 720, 120)])
    func encodedPicturesCodeAsTheCPUWriterDoes(width: Int, height: Int, qindex: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1MetalEncoder(device: device)
        let entropy = try AV1MetalEntropy(device: device)
        let picture = PartitionTests.Picture(width: width, height: height)
        var encoded = try picture.y.withUnsafeBufferPointer { y in
            try picture.u.withUnsafeBufferPointer { u in
                try picture.v.withUnsafeBufferPointer { v in
                    try encoder.encode(y: y.baseAddress!, u: u.baseAddress!, v: v.baseAddress!,
                                       width: width, height: height, qindex: qindex)
                }
            }
        }
        let (gpu, cpu) = try encoded.withRecord { record in
            (try entropy.encode(record), try Self.cpuOBUs(&record, flags: 0))
        }
        #expect(gpu == cpu, "\(width)×\(height) q\(qindex): \(Self.difference(gpu, cpu))")
    }

    static func cpuOBUs(_ record: UnsafeMutablePointer<av1g_decision_record>, flags: UInt32) throws -> [UInt8] {
        var options = av1g_encode_opts(flags: flags | UInt32(AV1G_ENC_TD) | UInt32(AV1G_ENC_NO_RECON), seq_level_idx: -1)
        var output = av1g_output()
        defer { av1g_output_free(&output) }
        let rc = av1g_encode(record, &options, &output)
        try #require(rc == AV1G_OK, "av1core: \(rc)")
        return Array(UnsafeBufferPointer(start: output.obu, count: output.obu_size))
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> String {
        let first = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        return "GPU \(a.count) B, CPU \(b.count) B, first difference at byte \(first)"
    }
}
