import AV1Core
import Foundation
import GlassActAV1
import Metal
import Testing
import libaom

/// Whether this Mac has the Metal toolchain, and a tool's exit status.
enum MetalToolchain {
    static let isInstalled: Bool = (try? run("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"])) == 0

    static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// The Host's build compiles the kernels offline as a check (`scripts/build-rust --xcode
/// --shaders`), from the text the runtime compiles. That check is only worth something if what it
/// compiles is the kernels the Host runs: every function the source has, and the same bytes out
/// of the encoder on them (`AV1Kernels.compiled`). Needs the Metal toolchain (`xcodebuild
/// -downloadComponent MetalToolchain`) and a real GPU, which CI's VMs don't have.
@Suite(.serialized, .enabled(if: AV1ShaderSource.hasCapableGPU && MetalToolchain.isInstalled
                                 && glassact_aom_available() != 0,
                             "needs an Apple-silicon GPU, the Metal toolchain and libaom (arm64)"))
struct CompiledKernelsTests {
    static let names = ["encoder", "entropy", "postfilter"]


    /// The metallibs, built as the app's build phase builds them (once for the suite).
    static let built: Result<URL, any Error> = Result(catching: {
        let directory = FileManager.default.temporaryDirectory.appending(path: "glassact-metallib-\(UInt64.random(in: 0...UInt64.max))")
        let script = AV1ShaderSource.sourceRootForTests.deletingLastPathComponent().appending(path: "scripts/build-rust")
        let status = try MetalToolchain.run("/bin/sh", [script.path, "--metallib", directory.path])
        guard status == 0 else { throw AV1ShaderSource.Failure.compile("build-rust --metallib exited \(status)") }
        return directory
    })

    static var source: AV1Kernels { .source(AV1ShaderSource.sourceRootForTests) }

    @available(macOS 27, *)
    @Test func everyKernelIsThere() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiled = AV1Kernels.compiled(try Self.built.get())
        for name in Self.names {
            let ours = try compiled.library(name, device: device).functionNames.sorted()
            let theirs = try Self.source.library(name, device: device).functionNames.sorted()
            #expect(ours == theirs, "\(name)")
            #expect(!ours.isEmpty, "\(name)")
        }
    }

    /// The encoder on the metallibs gives the bytes it gives on the source: key and inter frames,
    /// a size with partial superblocks, both analysis variants (`compileKernels`).
    @available(macOS 27, *)
    @Test(arguments: [(640, 360, 80), (1000, 562, 120)])
    func theEncoderGivesTheSameBytes(width: Int, height: Int, qindex: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pictures = HybridStreamTests.pictures(8, width: width, height: height, seed: 0xC0DE)
        func stream(_ kernels: AV1Kernels) throws -> [[UInt8]] {
            let encoder = try AV1HybridEncoder(device: device, kernels: kernels)
            try encoder.compileKernels()
            encoder.tiling = (1, 0)
            encoder.interFrames = true
            var obus: [[UInt8]] = []
            try encoder.encode(count: pictures.count, qindex: qindex, picture: { pictures[$0] }, output: { _, f in obus.append(f.obu) })
            return obus
        }
        let ours = try stream(.compiled(try Self.built.get()))
        let theirs = try stream(Self.source)
        #expect(ours.count == pictures.count)
        #expect(ours == theirs, "\(width)×\(height): the metallibs' stream differs")
    }

    /// What the metallibs save: the front end's compile, which the source pays on a cold Metal
    /// cache (a comment no earlier run had makes it cold). Reported, not asserted.
    @available(macOS 27, *)
    @Test func reportTheFrontEndSaved() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let directory = try Self.built.get()
        let main = AV1ShaderSource.sourceRootForTests.appending(path: "GlassActAV1/Shaders/encoder.metal")
        let text = "// \(UInt64.random(in: 0...UInt64.max))\n" + (try AV1ShaderSource.assemble(main))
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.languageVersion = .version4_1
        var t0 = Date()
        _ = try device.makeLibrary(source: text, options: options)
        let fromSource = Date().timeIntervalSince(t0)
        t0 = Date()
        _ = try device.makeLibrary(URL: directory.appending(path: "encoder.metallib"))
        let fromMetallib = Date().timeIntervalSince(t0)
        print(String(format: "encoder library: from source (cold front end) %.2f s, from the metallib %.3f s",
                     fromSource, fromMetallib))
    }
}
