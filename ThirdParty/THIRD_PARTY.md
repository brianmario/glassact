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
  named trace (VP8L size and speed).
