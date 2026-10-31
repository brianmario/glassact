# Third-party dependencies

Dependencies are adopted deliberately: pinned version, recorded provenance,
license review, and a written rationale with the measurements that justified
the exception to the default no-dependencies posture.

## libwebp v1.5.0 (`ThirdParty/libwebp`)

- **Upstream:** https://github.com/webmproject/libwebp, tag `v1.5.0`
  (release tarball sha256 prefix `668c9aba45565e24c27e…`)
- **License:** BSD-3-Clause (`COPYING`); additional patent grant (`PATENTS`).
- **Scope used:** the encoder and decoder, through `WebPTile`
  (`Sources/GlassActCodec/WebPTile.swift`):
  - VP8L lossless: opcode `0x0A WEBPL` tile payloads and striped lossless
    keyframes (`KeyframeCodec` 1);
  - lossy WebP: the striped cold-start first paint (`KeyframeCodec` 3),
    sent ahead of the lossless keyframe in video-less sessions.

  `mux`/`demux`/tools/tests are stripped; `enc`/`dec`/`dsp`/`utils`/
  `sharpyuv` are compiled as a SwiftPM C target. (Window-picker thumbnails
  don't use libwebp: the Host encodes them with ImageIO.)
- **Why:** measured on real capture tile corpora (see BENCHMARKS.md):
  VP8L lossless z4 achieves **379 B/tile on text content — 2× smaller than
  the best system-framework codec (LZBITMAP, 737 B)** — round-trip
  byte-lossless, ~66 MB/s single-core and embarrassingly parallel per tile.
  No system framework offers a WebP encoder (ImageIO is decode-only), and
  every system alternative was measured and dominated.
- **Update procedure:** replace the directory from the upstream release
  tarball, re-strip non-library paths, record the new tag + tarball hash
  here, and re-run `swift test`, the golden replays, and
  `glassact-bench keyframe` plus `glassact-bench replay --mode encode` on a
  named trace (VP8L size and speed). If `COPYING` or `PATENTS` changed,
  update `Apps/Shared/Acknowledgements.txt` to match.
- **Notices in the apps:** the BSD license requires binary distributions to
  reproduce the copyright notice. Both apps bundle
  `Apps/Shared/Acknowledgements.txt` (Glass Act's MIT license, libwebp's
  `COPYING` and `PATENTS`) and show it in their About panel.

## libaom, main at 9ace39e (`ThirdParty/libaom`, arm64 only)

- **Upstream:** https://aomedia.googlesource.com/aom, commit
  `9ace39e02a34992b83fc7f7f2bfbbd2e79348c74` (main, 2026-10-24; recorded
  in `ThirdParty/libaom/glassact/COMMIT`). Main, not a release: the
  latest release, 3.15.2, and 3.15.3-rc1 lack three realtime IntraBC fixes
  (b57fd44, 3ca3bea, fb357ae). With screen content past 2048 px they
  corrupted or drifted frames in Homebrew's 3.15.2 build (BENCHMARKS "AV2
  on screen text"). Move to the first release that has them.
- **License:** BSD-2-Clause (`LICENSE`), plus the Alliance for Open Media
  Patent License 1.0 (`PATENTS`).
- **Scope used:** the AV1 encoder in realtime mode, for video regions a
  Viewer has opted in to (§4.6). The decoder is compiled too, for tests and
  the bench. Swift calls only Glass Act's C API
  (`glassact/include/glassact_aom.h`, `glassact/shim/glassact_aom.c`).
- **Build:** a SwiftPM C target of the files `scripts/vendor-libaom`
  copies: exactly the sources an arm64 build of `libaom.a` compiles
  (realtime only, 8-bit, NEON without the dotprod/i8mm/SVE extensions, no
  CRC32 instructions, no runtime CPU detection) and the files they include.
  The script also generates the config and dispatch headers
  (`glassact/config`), and one wrapper per source (`glassact/wrappers`)
  that compiles it on arm64 only. On Intel the C API reports libaom
  unavailable and the Host doesn't offer AV1: software AV1 at these sizes
  is for Apple silicon.
- **Why:** with screen tools, libaom's realtime AV1 at 5K is 3.6–4× smaller
  than the hardware HEVC encoder at 7–9 dB higher PSNR, at 60 fps on an M4
  Pro (BENCHMARKS "AV2 on screen text"). No Apple chip encodes AV1 in
  hardware, and VideoToolbox has no software AV1 encoder. It's an opt-in
  the Viewer chooses; hardware HEVC stays the default. Statically linked,
  it needs no library-validation exemption (the reason AV1 was retired on
  2026-10-10, when the Host loaded Homebrew's libaom at runtime).
- **Update procedure:** check out the new commit or tag, run
  `scripts/vendor-libaom <checkout>`, and record the commit here. Then run
  `swift test` (`LibaomTests` round-trips screen content through the
  encoder and decoder) and the same check on a real 5K recording:
  `GLASSACT_AOM_Y4M=<file.y4m> swift test --filter LibaomTests`, with
  the y4m from `glassact-bench y4m`. If `LICENSE` or `PATENTS` changed,
  update `Apps/Shared/Acknowledgements.txt`.

## Sparkle 2.10.0 (apps only, through Swift Package Manager)

- **Upstream:** https://github.com/sparkle-project/Sparkle, tag `2.10.0`
  (revision `eef1a539a373c1f1a320624b1130fc5de7b2e100`, published
  2026-09-13). Not vendored: the Xcode project depends on it at that exact
  version, and `Apps/GlassActApps.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  pins it. Its Swift package ships a checksummed binary `Sparkle.xcframework`
  (universal) and the `generate_appcast` / `generate_keys` tools.
- **License:** MIT, plus the licenses of code it bundles (bsdiff, sais-lite,
  an Ed25519 implementation, SUSignatureVerifier). All of it is reproduced
  in `Apps/Shared/Acknowledgements.txt`, shown in both apps' About panels.
- **Scope used:** the Host and Viewer apps only (`Apps/Shared/AppUpdater.swift`);
  the Swift package and the `glassact` CLI don't link it. The Viewer, being
  sandboxed, uses Sparkle's Installer XPC service
  (`SUEnableInstallerLauncherService`, and the `-spks` / `-spki` mach-lookup
  exceptions in `Apps/Shared/Viewer*.entitlements`).
- **Why:** updates for apps distributed outside the App Store. Sparkle
  verifies every update twice: an EdDSA signature from the release key
  (the public half in `SUPublicEDKey`), and Apple's code signature, which
  must match the running app's team. It replaces a running app and relaunches
  it, from a sandboxed app as well. Writing that ourselves is
  security-sensitive work with no upside; there's no system framework for it.
  Chosen by the project owner as the second exception to the
  no-dependencies rule (2026-10-20).
- **Update procedure:** change the version in the Xcode project (the
  `XCRemoteSwiftPackageReference "Sparkle"`), resolve
  (`xcodebuild -resolvePackageDependencies`), and commit the new
  `Package.resolved`. Replace the Sparkle section of
  `Apps/Shared/Acknowledgements.txt` with the new `LICENSE`. Build both apps
  and run the local update test in RELEASING.md before landing.

## av1gpu at a30b4e8 (`Sources/AV1Core`, `Sources/AV1CoreTestSupport`; research)

- **Upstream:** https://github.com/maddog107/av1gpu, commit `a30b4e8`
  (main, 2026-10-30). A CUDA AV1 still-image encoder; its CPU core is
  plain C++.
- **License:** BSD-2-Clause (`Sources/AV1Core/LICENSE`). Parts derive from
  libaom (the range encoder in `entenc.h`, and the `tune=iq` decisions not
  yet ported), under libaom's BSD-2-Clause; see
  `Sources/AV1Core/THIRD_PARTY_NOTICES.md`.
- **Scope used:** a research branch porting it to Metal, owner's decision
  (2026-10-30): still images first, then video. Nothing in the apps links
  it. `AV1Core` is av1gpu's `av1core`: the DecisionRecord interface, the CPU
  bitstream writer with the decoder's exact reconstruction, the AVIF muxer,
  and the spec-mirroring DSP headers that the CPU and the GPU kernels share
  (`include/av1g`). `AV1CoreTestSupport` is its fuzzer's record generator
  and its CPU reference engine, for tests. Their tests ran dav1d and aomdec
  through `system()`; ours decode in-process with the vendored libaom.
- **Changes:** `internal.h` moved into `include/av1g`; module maps expose
  only the C API to Swift; the tests' tool paths, file I/O and JPEG input
  dropped. Files changed beyond include paths say so at the top.
- **Update procedure:** none while it's a fork in progress. Record here
  which upstream commit a change was taken from.
