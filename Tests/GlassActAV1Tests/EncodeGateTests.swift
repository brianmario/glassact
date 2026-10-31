import AV1Core
import Foundation
import GlassActAV1
import Metal
import Testing
import libaom

/// The whole GPU encoder, held to the decoder: on a screen-like picture, at a
/// fine, middle and coarse quantizer,
/// - the record it decides has av1core's tx-block layout;
/// - av1core writes it, and its reconstruction is the GPU's, byte for byte, in
///   every plane: the GPU predicted from exactly what a decoder will have;
/// - libaom decodes the stream to that same picture.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil && glassact_aom_available() != 0,
                "needs a Metal device and libaom (arm64)"))
struct EncodeGateTests {
    @available(macOS 27, *)
    @Test(.serialized, arguments: [(333, 201, 40), (333, 201, 120), (1280, 720, 120), (1280, 720, 200)])
    func gpuReconstructionIsTheDecoders(width: Int, height: Int, qindex: Int) throws {
        try check(width: width, height: height, qindex: qindex, preset: .base, tiling: (-1, -1))
    }

    /// The faster presets prune, subsample and drop tools, and tiles cut the
    /// contexts: the reconstruction must stay the decoder's.
    @available(macOS 27, *)
    @Test(.serialized, arguments: [("slow", 0, 0), ("faster", 1, 0), ("turbo", 1, 1), ("turbo3", 2, 1)])
    func presetsAndTilesStayExact(preset: String, columnsLog2: Int, rowsLog2: Int) throws {
        try check(width: 1280, height: 720, qindex: 120, preset: try #require(AV1MetalEncoder.Preset(rawValue: preset)),
                  tiling: (columnsLog2, rowsLog2))
    }

    @available(macOS 27, *)
    func check(width: Int, height: Int, qindex: Int, preset: AV1MetalEncoder.Preset, tiling: (Int, Int)) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder: AV1MetalEncoder
        do { encoder = try AV1MetalEncoder(device: device) } catch {
            Issue.record("\(error)")
            return
        }
        encoder.preset = preset
        encoder.tiling = tiling
        let picture = PartitionTests.Picture(width: width, height: height)
        var encoded = try picture.y.withUnsafeBufferPointer { y in
            try picture.u.withUnsafeBufferPointer { u in
                try picture.v.withUnsafeBufferPointer { v in
                    try encoder.encode(y: y.baseAddress!, u: u.baseAddress!, v: v.baseAddress!,
                                       width: width, height: height, qindex: qindex)
                }
            }
        }
        let label = "\(width)×\(height) q\(qindex) \(preset) tiles \(tiling)"

        // 1. av1core's layout of these blocks is the GPU's
        let gpuTxb = encoded.txb, gpuBlockTxb = encoded.blockTxb
        let layoutOK = encoded.withRecord { record -> Bool in
            var layout = [av1g_txb](repeating: av1g_txb(), count: gpuTxb.count)
            var blockTxb = [UInt32](repeating: 0, count: gpuBlockTxb.count)
            var copy = record
            return layout.withUnsafeMutableBufferPointer { lp in
                blockTxb.withUnsafeMutableBufferPointer { bp in
                    copy.txb = lp.baseAddress
                    copy.block_txb = bp.baseAddress
                    guard av1g_layout(&copy, UInt32(gpuTxb.count), copy.n_coeffs) == AV1G_OK else { return false }
                    let same = zip(lp, gpuTxb).allSatisfy {
                        $0.x4 == $1.x4 && $0.y4 == $1.y4 && $0.plane == $1.plane && $0.tx_size == $1.tx_size
                            && $0.coeff_off == $1.coeff_off
                    }
                    return same && Array(bp) == gpuBlockTxb && copy.n_txb == UInt32(gpuTxb.count)
                }
            }
        }
        try #require(layoutOK, "\(label): the GPU's tx-block layout isn't av1core's")

        // 2./3. av1core writes it; its reconstruction is the GPU's
        var output = av1g_output()
        defer { av1g_output_free(&output) }
        let rc = encoded.withRecord { record -> Int32 in
            var options = av1g_encode_opts(flags: UInt32(AV1G_ENC_TD), seq_level_idx: -1)
            return av1g_encode(&record, &options, &output)
        }
        let message = withUnsafeBytes(of: &output.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        try #require(rc == AV1G_OK, "\(label): av1core rejected the record (\(rc)): \(message)")
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        let sizes = [(width, height), (cw, ch), (cw, ch)]
        let av1core = [output.recon.0, output.recon.1, output.recon.2]
        for p in 0..<3 {
            let (w, h) = sizes[p]
            let planeCPU = try #require(av1core[p])
            let differing = (0..<(w * h)).filter { planeCPU[$0] != encoded.reconstruction[p][$0] }
            if let first = differing.first {
                let at = "(\(first % w), \(first / w))", values = "GPU \(encoded.reconstruction[p][first]), av1core \(planeCPU[first])"
                Issue.record("\(label): plane \(p): \(differing.count) samples differ, first at \(at): \(values)")
            }
        }

        // 4. libaom decodes that picture
        let decoder = try #require(glassact_aom_dec_create(1))
        defer { glassact_aom_dec_destroy(decoder) }
        var frame = glassact_aom_frame()
        try #require(glassact_aom_dec_decode(decoder, output.obu, output.obu_size, &frame) == 0, "\(label): libaom")
        for p in 0..<3 {
            let (w, h) = sizes[p]
            let theirs = try #require(frame.planesTuple(p))
            let stride = Int(frame.stridesTuple(p))
            let rows = (0..<h).filter { r in (0..<w).contains { encoded.reconstruction[p][r * w + $0] != theirs[r * stride + $0] } }
            #expect(rows.isEmpty, "\(label): plane \(p) differs from libaom on \(rows.count) rows")
        }

        // and it is an encoding of the picture
        var sse = 0
        for i in 0..<(width * height) {
            let d = Int(picture.y[i]) - Int(encoded.reconstruction[0][i])
            sse += d * d
        }
        let psnr = 10 * log10(255.0 * 255.0 * Double(width * height) / max(1, Double(sse)))
        #expect(psnr > (qindex <= 40 ? 40 : qindex <= 120 ? 30 : 24), "\(label): \(psnr) dB, \(output.obu_size) B")
    }
}

extension EncodeGateTests {
    /// The same picture encodes to the same decisions every time: the goldens
    /// Glass Act keeps are byte-exact, so the GPU's scheduling mustn't show.
    @available(macOS 27, *)
    @Test func encodingIsDeterministic() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let encoder = try AV1MetalEncoder(device: device)
        let picture = PartitionTests.Picture(width: 333, height: 201)
        func encode() throws -> AV1MetalEncoder.Encoded {
            try picture.y.withUnsafeBufferPointer { y in
                try picture.u.withUnsafeBufferPointer { u in
                    try picture.v.withUnsafeBufferPointer { v in
                        try encoder.encode(y: y.baseAddress!, u: u.baseAddress!, v: v.baseAddress!, width: 333, height: 201, qindex: 40)
                    }
                }
            }
        }
        let first = try encode()
        for _ in 0..<3 {
            let again = try encode()
            let sameBlocks = first.blocks.count == again.blocks.count
                && first.blocks.withUnsafeBytes { a in again.blocks.withUnsafeBytes { b in memcmp(a.baseAddress, b.baseAddress, a.count) == 0 } }
            #expect(sameBlocks && first.coeffs == again.coeffs && first.reconstruction == again.reconstruction)
        }
    }
}

extension glassact_aom_frame {
    func planesTuple(_ p: Int) -> UnsafePointer<UInt8>? { p == 0 ? planes.0 : p == 1 ? planes.1 : planes.2 }
    func stridesTuple(_ p: Int) -> Int32 { p == 0 ? strides.0 : p == 1 ? strides.1 : strides.2 }
}
