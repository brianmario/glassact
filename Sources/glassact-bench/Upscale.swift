// av1seq --upscale: the scalers a Viewer could show a reduced frame with (a picture coded smaller
// than the stream, decisions.h "Reduced frames"), for --score-rgb to score it at the stream's
// size: bilinear, vImage's Lanczos (3 and 5 lobes), Core Image's Lanczos and MetalFX's spatial
// scaler. Without --upscale the scorer resamples as it always has (vImage, high quality).
import Accelerate
import CoreImage
import Foundation
import Metal
import MetalFX

final class Upscaler {
    enum Kind: String, CaseIterable { case bilinear, lanczos3, lanczos5, ci, metalfx }
    let kind: Kind
    private let device: (any MTLDevice)?, queue: (any MTLCommandQueue)?
    private var scaler: (any MTLFXSpatialScaler)?
    private var input: (any MTLTexture)?, output: (any MTLTexture)?, readback: (any MTLBuffer)?
    private var size: (Int, Int, Int, Int) = (0, 0, 0, 0)
    private lazy var context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    init(_ name: String) throws {
        guard let k = Kind(rawValue: name) else {
            throw BenchError("--upscale \(name): one of \(Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        kind = k
        device = k == .metalfx ? MTLCreateSystemDefaultDevice() : nil
        queue = device?.makeCommandQueue()
        if k == .metalfx, queue == nil { throw BenchError("--upscale metalfx: no Metal device") }
    }

    /// BGRA `fw` × `fh` → BGRA `tw` × `th`.
    func scale(_ from: UnsafeMutableRawBufferPointer, _ fw: Int, _ fh: Int,
               into to: UnsafeMutableRawBufferPointer, _ tw: Int, _ th: Int) throws {
        switch kind {
        case .bilinear: bilinear(from, fw, fh, into: to, tw, th)
        case .lanczos3, .lanczos5:
            var s = vImage_Buffer(data: from.baseAddress!, height: vImagePixelCount(fh), width: vImagePixelCount(fw), rowBytes: fw * 4)
            var d = vImage_Buffer(data: to.baseAddress!, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw * 4)
            let flags = kind == .lanczos5 ? vImage_Flags(kvImageHighQualityResampling) : vImage_Flags(kvImageNoFlags)
            guard vImageScale_ARGB8888(&s, &d, nil, flags) == kvImageNoError else { throw BenchError("vImage: scale failed") }
        case .ci: try coreImage(from, fw, fh, into: to, tw, th)
        case .metalfx: try metalFX(from, fw, fh, into: to, tw, th)
        }
    }

    /// Bilinear at sample centres (as a GPU's linear sampler), edges clamped.
    private func bilinear(_ from: UnsafeMutableRawBufferPointer, _ fw: Int, _ fh: Int,
                          into to: UnsafeMutableRawBufferPointer, _ tw: Int, _ th: Int) {
        struct P: @unchecked Sendable { let s: UnsafeMutablePointer<UInt8>, d: UnsafeMutablePointer<UInt8> }
        let p = P(s: from.baseAddress!.assumingMemoryBound(to: UInt8.self), d: to.baseAddress!.assumingMemoryBound(to: UInt8.self))
        let sx = Float(fw) / Float(tw), sy = Float(fh) / Float(th)
        var x0 = [Int](repeating: 0, count: tw), x1 = x0, wx = [Float](repeating: 0, count: tw)
        for x in 0..<tw {
            let f = max(0, (Float(x) + 0.5) * sx - 0.5)
            let i = min(Int(f), fw - 1)
            (x0[x], x1[x], wx[x]) = (i, min(i + 1, fw - 1), f - Float(i))
        }
        let (cx0, cx1, cwx) = (x0, x1, wx)
        DispatchQueue.concurrentPerform(iterations: th) { y in
            let f = max(0, (Float(y) + 0.5) * sy - 0.5)
            let r0 = min(Int(f), fh - 1), r1 = min(r0 + 1, fh - 1), w = f - Float(r0)
            let a = p.s + r0 * fw * 4, b = p.s + r1 * fw * 4, o = p.d + y * tw * 4
            for x in 0..<tw {
                let (i0, i1, u) = (cx0[x] * 4, cx1[x] * 4, cwx[x])
                for c in 0..<4 {
                    let top = Float(a[i0 + c]) * (1 - u) + Float(a[i1 + c]) * u
                    let bottom = Float(b[i0 + c]) * (1 - u) + Float(b[i1 + c]) * u
                    o[x * 4 + c] = UInt8(min(255, max(0, top * (1 - w) + bottom * w + 0.5)))
                }
            }
        }
    }

    /// CILanczosScaleTransform, on the values as they are (no colour management).
    private func coreImage(_ from: UnsafeMutableRawBufferPointer, _ fw: Int, _ fh: Int,
                           into to: UnsafeMutableRawBufferPointer, _ tw: Int, _ th: Int) throws {
        let data = Data(bytesNoCopy: from.baseAddress!, count: fw * fh * 4, deallocator: .none)
        let image = CIImage(bitmapData: data, bytesPerRow: fw * 4, size: CGSize(width: fw, height: fh), format: .BGRA8, colorSpace: nil)
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { throw BenchError("Core Image: no Lanczos") }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(Double(th) / Double(fh), forKey: kCIInputScaleKey)
        filter.setValue(Double(tw) / Double(fw) * Double(fh) / Double(th), forKey: kCIInputAspectRatioKey)
        guard let out = filter.outputImage else { throw BenchError("Core Image: no output") }
        context.render(out, toBitmap: to.baseAddress!, rowBytes: tw * 4, bounds: CGRect(x: 0, y: 0, width: tw, height: th),
                       format: .BGRA8, colorSpace: nil)
    }

    /// MTLFXSpatialScaler (perceptual: the values are sRGB-encoded).
    private func metalFX(_ from: UnsafeMutableRawBufferPointer, _ fw: Int, _ fh: Int,
                         into to: UnsafeMutableRawBufferPointer, _ tw: Int, _ th: Int) throws {
        guard let device, let queue else { throw BenchError("--upscale metalfx: no Metal device") }
        if size != (fw, fh, tw, th) || scaler == nil {
            let desc = MTLFXSpatialScalerDescriptor()
            (desc.inputWidth, desc.inputHeight, desc.outputWidth, desc.outputHeight) = (fw, fh, tw, th)
            desc.colorTextureFormat = .bgra8Unorm
            desc.outputTextureFormat = .bgra8Unorm
            desc.colorProcessingMode = .perceptual
            guard MTLFXSpatialScalerDescriptor.supportsDevice(device), let s = desc.makeSpatialScaler(device: device)
            else { throw BenchError("MetalFX: no spatial scaler for \(fw)×\(fh) → \(tw)×\(th)") }
            let i = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: fw, height: fh, mipmapped: false)
            i.usage = s.colorTextureUsage
            i.storageMode = .shared
            let o = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: tw, height: th, mipmapped: false)
            o.usage = s.outputTextureUsage
            o.storageMode = .private
            guard let it = device.makeTexture(descriptor: i), let ot = device.makeTexture(descriptor: o),
                  let rb = device.makeBuffer(length: tw * th * 4, options: .storageModeShared)
            else { throw BenchError("MetalFX: no textures") }
            (scaler, input, output, readback, size) = (s, it, ot, rb, (fw, fh, tw, th))
        }
        guard let scaler, let input, let output, let readback, let cb = queue.makeCommandBuffer()
        else { throw BenchError("MetalFX: no command buffer") }
        input.replace(region: MTLRegionMake2D(0, 0, fw, fh), mipmapLevel: 0, withBytes: from.baseAddress!, bytesPerRow: fw * 4)
        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.inputContentWidth = fw
        scaler.inputContentHeight = fh
        scaler.encode(commandBuffer: cb)
        guard let blit = cb.makeBlitCommandEncoder() else { throw BenchError("MetalFX: no blit") }
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: tw, height: th, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: tw * 4, destinationBytesPerImage: tw * th * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw BenchError("MetalFX: \(e)") }
        to.baseAddress!.copyMemory(from: readback.contents(), byteCount: tw * th * 4)
    }
}
