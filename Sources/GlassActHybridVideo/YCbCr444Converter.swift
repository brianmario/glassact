import Foundation
import Accelerate

/// BGRA → 8-bit YCbCr 4:4:4, three tight planes of width × height, full range, BT.709's matrix: what
/// a 4:4:4 hybrid stream's sequence header signals (`matrix_coefficients` 1, `color_range` 1) and
/// how our decoder (`OwnAV1RegionDecoder`) shows it. vImage converts to interleaved AYpCbCr
/// (`kvImage444AYpCbCr8`; it has no planar 4:4:4), which is then split into the planes.
///
/// Not thread-safe: its scratch (the interleaved picture, the alpha plane) is reused from call to
/// call, kept at the largest size converted.
public final class YCbCr444Converter {
    private var conversion = vImage_ARGBToYpCbCr()
    private var permuteMap: [UInt8] = [3, 2, 1, 0]  // BGRA in memory → ARGB
    private var interleaved: UnsafeMutableRawBufferPointer?
    private var alpha: UnsafeMutableRawBufferPointer?

    public init?() {
        var range = vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
                                            YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        let (kr, kb) = (0.2126, 0.0722)
        let kg = 1 - kr - kb
        var matrix = vImage_ARGBToYpCbCrMatrix(
            R_Yp: Float(kr), G_Yp: Float(kg), B_Yp: Float(kb),
            R_Cb: Float(-kr / (2 * (1 - kb))), G_Cb: Float(-kg / (2 * (1 - kb))),
            B_Cb_R_Cr: 0.5, G_Cr: Float(-kg / (2 * (1 - kr))), B_Cr: Float(-kb / (2 * (1 - kr))))
        guard vImageConvert_ARGBToYpCbCr_GenerateConversion(
            &matrix, &range, &conversion, kvImageARGB8888, kvImage444AYpCbCr8,
            vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
    }

    deinit {
        interleaved?.deallocate()
        alpha?.deallocate()
    }

    /// A tightly packed BGRA picture (stride width × 4) into tight planes, each width × height.
    public func convert(bgra: UnsafeRawBufferPointer, width: Int, height: Int, y: UnsafeMutableRawPointer,
                        u: UnsafeMutableRawPointer, v: UnsafeMutableRawPointer) -> Bool {
        guard width > 0, height > 0, bgra.count >= width * height * 4 else { return false }
        let n = width * height
        if (interleaved?.count ?? 0) < 4 * n {
            interleaved?.deallocate()
            alpha?.deallocate()
            interleaved = .allocate(byteCount: 4 * n, alignment: 64)
            alpha = .allocate(byteCount: n, alignment: 64)
        }
        guard let interleaved, let alpha else { return false }
        let (h, w) = (vImagePixelCount(height), vImagePixelCount(width))
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bgra.baseAddress), height: h, width: w, rowBytes: width * 4)
        var ayuv = vImage_Buffer(data: interleaved.baseAddress, height: h, width: w, rowBytes: width * 4)
        guard vImageConvert_ARGB8888To444AYpCbCr8(&src, &ayuv, &conversion, &permuteMap,
                                                   vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
        var a = vImage_Buffer(data: alpha.baseAddress, height: h, width: w, rowBytes: width)
        var yp = vImage_Buffer(data: y, height: h, width: w, rowBytes: width)
        var cb = vImage_Buffer(data: u, height: h, width: w, rowBytes: width)
        var cr = vImage_Buffer(data: v, height: h, width: w, rowBytes: width)
        return vImageConvert_ARGB8888toPlanar8(&ayuv, &a, &yp, &cb, &cr, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
}
