// swift-tools-version: 6.4
import PackageDescription

// Swift 7-track features, adopted early (Swift 6 language mode stays), and
// warnings as errors for all our Swift code — the tree builds clean on the
// 6.4 toolchain, so a new warning is a build break, not background noise.
// (Vendored C — libwebp — keeps its own warning policy.)
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .treatAllWarnings(as: .error),
]
// Libraries also make every import internal unless declared `public
// import`: what a module re-exposes through its API is then explicit.
let strictLibrary: [SwiftSetting] = strict + [
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "glassact",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "GlassAct", targets: ["GlassActWire", "GlassActCodec", "GlassActCore", "GlassActTransport", "GlassActSession"]),
        .executable(name: "glassact", targets: ["glassact"]),
        .executable(name: "glassact-bench", targets: ["glassact-bench"]),
        .executable(name: "glassact-trace", targets: ["glassact-trace"]),
    ],
    targets: [
        // Wire format: varint, TLV, records, serial arithmetic, checked parser.
        // Stays at normal -O: all parsing is explicitly bounds-checked (INV-6).
        .target(name: "GlassActWire", swiftSettings: strictLibrary + [.strictMemorySafety()]),
        // Vendored libwebp v1.5.0 (VP8L lossless tile codec — see
        // ThirdParty/THIRD_PARTY.md for provenance and rationale).
        .target(
            name: "libwebp",
            path: "ThirdParty/libwebp",
            exclude: ["AUTHORS", "ChangeLog", "CONTRIBUTING.md", "COPYING", "NEWS", "PATENTS", "README.md"],
            sources: ["src/enc", "src/dec", "src/dsp", "src/utils", "sharpyuv"],
            publicHeadersPath: "src/webp",
            cSettings: [
                .headerSearchPath("."),
                // Mutex-guarded one-time DSP init (dsp/cpu.h WEBP_DSP_INIT).
                // Without it the init flag is an unfenced volatile: the
                // host's first concurrentPerform encode can see "initialized"
                // before the function-pointer tables are visible on another
                // core (arm64) and call through NULL.
                .define("WEBP_USE_THREAD"),
            ]
        ),
        // Hot-path codec: xxh64, RAW/LZ4/LZBITMAP/WEBPL tile codecs, arenas.
        // Plain -O: -Ounchecked (§8.4) gains nothing measurable and would
        // strip the bounds preconditions guarding canvas writes (BENCHMARKS
        // "-Ounchecked on GlassActCodec").
        .target(
            name: "GlassActCodec",
            dependencies: ["libwebp"],
            swiftSettings: strictLibrary
        ),
        .target(name: "GlassActCore", dependencies: ["GlassActWire", "GlassActCodec", "GlassActTransport"],
                swiftSettings: strictLibrary),
        .target(name: "GlassActTransport", dependencies: ["GlassActWire"], swiftSettings: strictLibrary),
        // A viewer session without a window, and everything that lets an
        // agent drive one: screenshots, input in agent coordinates, the local
        // agent socket, and the MCP server. Shared by the Viewer app and the
        // `glassact` CLI.
        .target(name: "GlassActSession", dependencies: ["GlassActWire", "GlassActCore", "GlassActTransport"],
                swiftSettings: strictLibrary),
        // `glassact`: drive a remote Mac from a shell or an MCP client —
        // through the Viewer app's live session, or a headless one of its own.
        .executableTarget(
            name: "glassact",
            dependencies: ["GlassActWire", "GlassActCore", "GlassActTransport", "GlassActSession"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "glassact-bench",
            dependencies: ["GlassActWire", "GlassActCodec", "GlassActCore", "GlassActTransport"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "glassact-trace",
            dependencies: ["GlassActCore"],
            swiftSettings: strict
        ),
        // Shared test helpers (one seeded PRNG instead of a copy per target).
        .target(name: "GlassActTestSupport", dependencies: ["GlassActWire"], path: "Tests/GlassActTestSupport",
                swiftSettings: strictLibrary),
        .testTarget(name: "WireTests", dependencies: ["GlassActWire", "GlassActTestSupport"], swiftSettings: strict),
        .testTarget(name: "CodecTests", dependencies: ["GlassActCodec", "GlassActTestSupport"], swiftSettings: strict),
        .testTarget(name: "CoreTests", dependencies: ["GlassActCore", "GlassActTransport", "GlassActWire", "GlassActCodec", "GlassActTestSupport"], swiftSettings: strict),
        .testTarget(name: "SessionTests", dependencies: ["GlassActSession", "GlassActCore", "GlassActTransport", "GlassActWire", "GlassActTestSupport"], swiftSettings: strict),
        .testTarget(name: "TransportTests", dependencies: ["GlassActTransport", "GlassActWire", "GlassActCodec", "GlassActCore", "GlassActTestSupport"], swiftSettings: strict),
    ]
)
