internal import AV1Encoder
public import Foundation
public import Metal

/// The Metal Shading Language source of the AV1 kernels, put together for
/// `MTLDevice.makeLibrary(source:)`.
///
/// The kernels share av1core's headers (`Sources/AV1Core/include/av1g`) with
/// the CPU writer, so both compute the same thing from one text (`hd.h` says
/// how). The runtime compiler can't search include paths, so the quoted
/// includes are inlined here, each file once, with `#line` markers so a
/// compile error names the header it's in. System includes are dropped:
/// `metal_stdlib` has the fixed-width integer types.
///
/// MSL 4.1 (macOS 27, iPadOS 27) is required: it infers the address space
/// of an unqualified pointer from its use, which is what lets av1core's C++
/// compile as MSL nearly unchanged. Earlier versions (MSL 3.2 is the most
/// macOS 15 has) need `thread`, `threadgroup` or `device` written on every
/// pointer of the shared headers. The GPU encoder is therefore macOS 27+;
/// older Hosts keep HEVC (DESIGN §4.6).
///
/// The app's build also compiles them offline into metallibs, as a check: `scripts/build-rust
/// --xcode --shaders`, with the same text, language version and math mode, where the Metal
/// toolchain is installed (`xcodebuild -downloadComponent MetalToolchain`; CI's app builds have
/// it), so a kernel that doesn't compile fails the build. `CompiledKernelsTests` holds the
/// metallibs to the source (`AV1Kernels.compiled`).
///
/// ## Deviations
/// Compiled at run time from source, not from the metallibs: they're 13.5 MB (8.5 MB in the
/// Host's download, against ~10 MB for the rest) for 5.5 s of a cold start once per install
/// (BENCHMARKS "The AV1 kernels compiled with the app", 2026-11-18). The source is the app's
/// copy where there is one (Resources/AV1Shaders, laid out as under `Sources/`), else the source
/// tree (`#filePath`: tests, the bench).
public enum AV1ShaderSource {
    /// Where quoted includes are looked up, in order.
    public static let defaultIncludeDirectories: [URL] = includeDirectories(in: sourceRoot)

    /// The include directories of a tree laid out as `Sources/` (`root`).
    public static func includeDirectories(in root: URL) -> [URL] {
        [root.appending(path: "AV1Core/include"), root.appending(path: "AV1Encoder/include"),
         root.appending(path: "GlassActAV1/Shaders")]
    }

    /// Includes that are made, not read: `#include "av1enc_tables.h"` is the
    /// encoder's derived tables (av1enc_tables_msl).
    public static let generatedIncludes: [String: String] = {
        var length = 0
        guard let text = av1enc_tables_msl(&length) else { return [:] }
        defer { free(text) }
        return ["av1enc_tables.h": String(cString: text)]
    }()

    /// `Sources/`, for tests that compile a shader of the package.
    public static var sourceRootForTests: URL { sourceRoot }

    /// Whether this Mac's GPU runs the kernels: an Apple-silicon GPU, not a virtual machine's
    /// paravirtual one. CI's hosted runners are VMs: the encoder's library doesn't compile there,
    /// and kernels that do compile don't compute exactly, so the GPU tests need real hardware.
    public static var hasCapableGPU: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple7) && !device.name.localizedCaseInsensitiveContains("paravirtual")
    }

    /// `Sources/`, or the app's copy of the kernels' part of it.
    static let sourceRoot = bundledSourceRoot(in: Bundle.main) ?? sourceTreeRoot

    /// The source tree's `Sources/`.
    static let sourceTreeRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The kernels' sources an app carries (Resources/AV1Shaders), nil for none.
    public static func bundledSourceRoot(in bundle: Bundle) -> URL? {
        guard let root = bundle.resourceURL?.appending(path: "AV1Shaders", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: root.appending(path: "GlassActAV1/Shaders/encoder.metal").path)
        else { return nil }
        return root
    }

    public enum Failure: Error, CustomStringConvertible {
        case missingInclude(String, from: String)
        case compile(String)

        public var description: String {
            switch self {
            case let .missingInclude(name, file): "\(file): can't find \"\(name)\""
            case let .compile(message): message
            }
        }
    }

    /// `main`'s source with every quoted include inlined.
    public static func assemble(_ main: URL, includeDirectories: [URL] = defaultIncludeDirectories) throws -> String {
        var seen = Set<String>()
        var out = "#include <metal_stdlib>\nusing namespace metal;\n#define NULL nullptr\n"
        try inline(main, includeDirectories: includeDirectories, seen: &seen, into: &out)
        return out
    }

    /// A library of `main`'s kernels, compiled for `device`.
    @available(macOS 27, iOS 27, *)
    public static func library(
        _ main: URL, device: any MTLDevice, includeDirectories: [URL] = defaultIncludeDirectories
    ) throws -> any MTLLibrary {
        let source = try assemble(main, includeDirectories: includeDirectories)
        let options = MTLCompileOptions()
        options.mathMode = .safe  // the AV1 math is integer, but nothing here may be reassociated
        options.languageVersion = .version4_1
        do {
            return try device.makeLibrary(source: source, options: options)
        } catch {
            throw Failure.compile(String(describing: error))
        }
    }

    private static func inline(_ file: URL, includeDirectories: [URL], seen: inout Set<String>,
                               into out: inout String) throws {
        let path = file.standardizedFileURL.path
        guard seen.insert(path).inserted else { return }
        let text = try String(contentsOf: file, encoding: .utf8)
        out += "#line 1 \"\(path)\"\n"
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.hasPrefix("#include") || trimmed.hasPrefix("# include") else {
                out += line
                out += "\n"
                continue
            }
            if let name = quotedName(trimmed), let generated = generatedIncludes[name] {
                if seen.insert("generated:" + name).inserted {
                    out += "#line 1 \"\(name)\"\n"
                    out += generated
                }
            } else if let name = quotedName(trimmed) {
                let candidates = [file.deletingLastPathComponent()] + includeDirectories
                guard let found = candidates.map({ $0.appending(path: name) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) })
                else { throw Failure.missingInclude(name, from: path) }
                try inline(found, includeDirectories: includeDirectories, seen: &seen, into: &out)
            }
            // System includes (<stdint.h>, …) are dropped.
            out += "#line \(lineNumber + 1) \"\(path)\"\n"
        }
    }

    private static func quotedName(_ directive: Substring) -> String? {
        guard let open = directive.firstIndex(of: "\""),
              let close = directive[directive.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return String(directive[directive.index(after: open)..<close])
    }
}

/// Where the AV1 kernels come from: their sources, compiled when the encoder starts
/// (`AV1ShaderSource`), or metallibs (`scripts/build-rust --metallib`: tests, the bench).
public enum AV1Kernels: Sendable, Equatable {
    /// `<name>.metallib` in this directory.
    case compiled(URL)
    /// Sources laid out as under `Sources/`, compiled at run time.
    case source(URL)

    /// What the Host runs: the sources, the app's copy or the tree's. With GLASSACT_AV1_METALLIB
    /// set to a directory, its metallibs instead (`scripts/build-rust --metallib-debug`: the same
    /// kernels with line tables and sources, for Xcode's per-line shader profiling).
    public static let shipped: AV1Kernels = {
        if let dir = ProcessInfo.processInfo.environment["GLASSACT_AV1_METALLIB"], !dir.isEmpty {
            return .compiled(URL(filePath: dir, directoryHint: .isDirectory))
        }
        return .source(AV1ShaderSource.sourceRoot)
    }()

    /// The library of `name`'s kernels (encoder, entropy, postfilter) for `device`.
    @available(macOS 27, iOS 27, *)
    public func library(_ name: String, device: any MTLDevice) throws -> any MTLLibrary {
        switch self {
        case let .compiled(directory):
            do {
                return try device.makeLibrary(URL: directory.appending(path: "\(name).metallib"))
            } catch {
                throw AV1ShaderSource.Failure.compile("\(name).metallib: \(error)")
            }
        case let .source(root):
            return try AV1ShaderSource.library(root.appending(path: "GlassActAV1/Shaders/\(name).metal"), device: device,
                                               includeDirectories: AV1ShaderSource.includeDirectories(in: root))
        }
    }
}
