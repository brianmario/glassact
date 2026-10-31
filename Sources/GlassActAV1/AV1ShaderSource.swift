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
/// ## Deviations
/// Compiled at run time from the source tree (`#filePath`), not from a
/// metallib built with the package: this Mac has no Metal toolchain
/// (`xcodebuild -downloadComponent MetalToolchain`), and while the port is
/// research only tests and the bench load it. Shipping it means building a
/// metallib, which also moves compile errors to build time.
public enum AV1ShaderSource {
    /// Where quoted includes are looked up, in order.
    public static let defaultIncludeDirectories: [URL] = [
        sourceRoot.appending(path: "AV1Core/include"),
        sourceRoot.appending(path: "AV1Encoder/include"),
        sourceRoot.appending(path: "GlassActAV1/Shaders"),
    ]

    /// Includes that are made, not read: `#include "av1enc_tables.h"` is the
    /// encoder's derived tables (av1enc_tables_msl).
    public static let generatedIncludes: [String: String] = {
        var length = 0
        guard let text = av1enc_tables_msl(&length) else { return [:] }
        defer { free(text) }
        return ["av1enc_tables.h": String(cString: text)]
    }()

    /// `Sources/`.
    static let sourceRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

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
