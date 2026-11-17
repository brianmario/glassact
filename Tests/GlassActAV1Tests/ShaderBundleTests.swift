import Foundation
import GlassActAV1
import Testing

/// The Host app carries the kernels' sources (`scripts/build-rust --xcode --shaders` copies them
/// into Resources/AV1Shaders), since an installed app has no source tree. What the app assembles
/// from its copy must be what the source tree assembles, line for line (the `#line` markers
/// name the files where they are): a header the copy missed would leave a Host whose kernels
/// don't compile, and so a Host without AV1, which no test on a source tree would see.
@Suite struct ShaderBundleTests {
    static let sources = AV1ShaderSource.sourceRootForTests
    static let mains = ["encoder", "entropy", "postfilter"].map { "GlassActAV1/Shaders/\($0).metal" }

    /// `text` without its `#line` markers.
    static func code(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#line ") }
    }

    @Test func anAppsCopyAssemblesAsTheSourceTreeDoes() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "glassact-shaders-\(UInt64.random(in: 0...UInt64.max)).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let resources = app.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.shaders</string></dict></plist>
            """.utf8).write(to: app.appending(path: "Contents/Info.plist"))

        let copy = Process()
        copy.executableURL = URL(filePath: "/bin/sh")
        copy.arguments = [Self.sources.deletingLastPathComponent().appending(path: "scripts/build-rust").path,
                          "--copy-shaders", resources.appending(path: "AV1Shaders").path]
        try copy.run()
        copy.waitUntilExit()
        #expect(copy.terminationStatus == 0)

        let bundle = try #require(Bundle(url: app))
        let root = try #require(AV1ShaderSource.bundledSourceRoot(in: bundle), "the copy has no encoder.metal")
        #expect(AV1ShaderSource.bundledSourceRoot(in: Bundle(for: BundleMarker.self)) == nil, "a test bundle has none")
        let includes = ["AV1Core/include", "AV1Encoder/include", "GlassActAV1/Shaders"].map { root.appending(path: $0) }
        for main in Self.mains {
            let fromTree = try AV1ShaderSource.assemble(Self.sources.appending(path: main))
            let fromApp = try AV1ShaderSource.assemble(root.appending(path: main), includeDirectories: includes)
            #expect(Self.code(fromApp) == Self.code(fromTree), "\(main)")
            #expect(fromApp.contains(root.standardizedFileURL.path), "\(main) came from the copy")
        }
    }

    final class BundleMarker {}
}
