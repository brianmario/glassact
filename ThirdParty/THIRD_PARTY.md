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
