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
    platforms: [.macOS("15.5"), .iOS("27")],
    products: [
        .library(name: "GlassAct", targets: ["GlassActWire", "GlassActCodec", "GlassActCore", "GlassActTransport", "GlassActSession", "GlassActShare"]),
        // What a viewer needs, without the Host's screen capture
        // (GlassActShare, macOS only): the iPad Viewer links this.
        .library(name: "GlassActViewer", targets: ["GlassActWire", "GlassActCodec", "GlassActCore", "GlassActTransport", "GlassActSession"]),
        .executable(name: "glassact", targets: ["glassact"]),
        .executable(name: "glassact-bench", targets: ["glassact-bench"]),
        .executable(name: "glassact-trace", targets: ["glassact-trace"]),
        .executable(name: "glassact-testhost", targets: ["glassact-testhost"]),
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
        // Vendored libaom (AV1), arm64 only — see ThirdParty/THIRD_PARTY.md.
        // `scripts/vendor-libaom` copies the sources and generates the
        // config headers and the per-file wrappers compiled here; Swift
        // sees only Glass Act's C API (glassact/include).
        .target(
            name: "libaom",
            path: "ThirdParty/libaom",
            sources: ["glassact/wrappers", "glassact/shim"],
            publicHeadersPath: "glassact/include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("glassact"),
                // Optimized in debug builds too: unoptimized, libaom is
                // several times slower, and its tests then compete with the
                // timing-sensitive QUIC tests for the CI machine.
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
            ]
        ),
        // The AV1 CPU code's C API (a port of av1gpu, BSD-2, Sources/AV1Core/LICENSE):
        // the DecisionRecord, the bitstream writer with the exact reconstruction,
        // the post-filters. It's implemented in Rust (rust/av1), built by
        // scripts/build-rust into .build/rust/libglassact_av1.a (`just` runs it),
        // and linked here. include/av1g also holds the decoder-mirroring DSP
        // headers the Metal kernels compile. Research for now; nothing in the
        // apps uses it.
        .target(
            name: "AV1Core",
            exclude: ["LICENSE", "THIRD_PARTY_NOTICES.md"],
            linkerSettings: [
                .unsafeFlags(["-L", Context.packageDirectory + "/.build/rust"]),
                .linkedLibrary("glassact_av1"),
            ]
        ),
        // The host half of the Metal encoder and the hybrid encoder's CPU closed
        // loop (also Rust): the structures the host fills for the kernels
        // (include/av1enc/gp.h).
        .target(
            name: "AV1Encoder",
            dependencies: ["AV1Core"]
        ),
        // The Metal port of av1gpu's encoder: kernels compiled at run time
        // from Shaders/ and AV1Core's shared headers.
        .target(
            name: "GlassActAV1",
            dependencies: ["AV1Core", "AV1Encoder"],
            exclude: ["Shaders"],
            swiftSettings: strictLibrary
        ),
        // av1gpu's random legal records and CPU reference engine, for tests (Rust too).
        .target(
            name: "AV1CoreTestSupport",
            dependencies: ["AV1Core"]
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
        .target(name: "GlassActCore", dependencies: ["GlassActWire", "GlassActCodec", "GlassActTransport", "libaom"],
                swiftSettings: strictLibrary),
        .target(name: "GlassActTransport", dependencies: ["GlassActWire"], swiftSettings: strictLibrary),
        // A viewer session without a window, and everything that lets an
        // agent drive one: screenshots, input in agent coordinates, the local
        // agent socket, and the MCP server. Shared by the Viewer app and the
        // `glassact` CLI.
        .target(name: "GlassActSession", dependencies: ["GlassActWire", "GlassActCore", "GlassActTransport"],
                swiftSettings: strictLibrary),
        // Sharing a screen (#42): ScreenCaptureKit capture and its recovery,
        // and in time the rest of what the Host app does to share. Apps add
        // UI on top.
        .target(name: "GlassActShare", dependencies: ["GlassActCore"], swiftSettings: strictLibrary),
        // `glassact`: drive a remote Mac from a shell or an MCP client —
        // through the Viewer app's live session, or a headless one of its own.
        .executableTarget(
            name: "glassact",
            dependencies: ["GlassActWire", "GlassActCore", "GlassActTransport", "GlassActSession"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "glassact-bench",
            dependencies: ["GlassActWire", "GlassActCodec", "GlassActCore", "GlassActTransport",
                           "GlassActAV1", "AV1Core", "libaom"],
            swiftSettings: strict
        ),
        // A Host with a synthetic screen, for developing a viewer (the iPad
        // Viewer in the Simulator) without sharing a real one. Mac only.
        .executableTarget(
            name: "glassact-testhost",
            dependencies: ["GlassActWire", "GlassActCore", "GlassActTransport"],
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
        .testTarget(name: "CoreTests", dependencies: ["GlassActCore", "GlassActTransport", "GlassActWire", "GlassActCodec", "GlassActTestSupport", "libaom"], swiftSettings: strict),
        .testTarget(name: "SessionTests", dependencies: ["GlassActSession", "GlassActCore", "GlassActTransport", "GlassActWire", "GlassActTestSupport"], swiftSettings: strict),
        .testTarget(name: "ShareTests", dependencies: ["GlassActShare", "GlassActCore"], swiftSettings: strict),
        .testTarget(name: "AV1CoreTests", dependencies: ["AV1Core", "AV1CoreTestSupport", "GlassActTestSupport", "libaom"], swiftSettings: strict),
        .testTarget(name: "GlassActAV1Tests", dependencies: ["GlassActAV1", "AV1Core", "AV1CoreTestSupport", "AV1Encoder", "GlassActTestSupport", "libaom"],
                    exclude: ["Shaders"], swiftSettings: strict),
        .testTarget(name: "TransportTests", dependencies: ["GlassActTransport", "GlassActWire", "GlassActCodec", "GlassActCore", "GlassActTestSupport"], swiftSettings: strict),
    ]
)
