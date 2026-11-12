# Glass Act benchmarks

This file is the project's measurement record (DESIGN §12). Every change
that affects performance or loss behaviour gets an entry with before/after
numbers, and so does every experiment that was measured and rejected.
**Check [Decisions and rejected experiments](#decisions-and-rejected-experiments)
before re-trying an idea.**

Layout:
- [Current reference numbers](#current-reference-numbers): the latest
  figure for each headline metric.
- [§10.1 acceptance status](#101-acceptance-status): the original v1 bars.
- [Reference traces](#reference-traces): which recordings the numbers come
  from, and how to measure on your own.
- [Decisions and rejected experiments](#decisions-and-rejected-experiments):
  one line per idea, with its verdict.
- [Removed bench commands](#removed-bench-commands): experiment tools that
  were removed, and why.
- [Log](#log): every entry, newest first.

Conventions:
- **Machine:** Apple M4 Pro (macOS 26.5.2 for the August 2026 baselines;
  the 2026-10-10 VideoToolbox entry ran on macOS 27). Two-machine entries
  use a MacBook Air as the Viewer.
- **Capture geometry:** 5120×2880 (5K) unless noted. DESIGN's reference
  geometry is 4K (3840×2160 = 2040 tiles); 5K is 3600 tiles, so
  tile-proportional numbers run ~1.76× the 4K assumptions.
- **Replay modes:** `encode` runs the host engine with instant ACKs, which
  isolates encode cost. `loop` runs host → InProc seeded faults → viewer
  over virtual time.
- **Standard fault mix:** 5 % drop, 1 % dup, 10 % reorder, 20–80 ms
  jitter. The standard golden run is
  `glassact-bench replay --trace t.scap --mode loop --drop 5 --dup 1 --reorder 10 --latency 20-80 --golden`.
- All numbers come from release `glassact-bench` builds on real `.scap`
  captures unless an entry says otherwise. A regression over 10 % needs a
  written reason.
- **P-numbers** (P2–P8) are the phases of the original v1 roadmap
  (DESIGN §11); primes (P3′, P3″, P2′) are follow-ups to a phase.
- Older entries name a few flags that no longer exist: `--pinned` (pinned
  full-screen video is now the only mode, so `--video vt` is pinned),
  `--video av1`, `--no-throttle`, and the env flags `GLASSACT_AV1_NO_SIZE_GATE`
  and `GLASSACT_PIXEL_STREAMS`.

## Current reference numbers

The latest measurement of each headline metric. They were taken before the
2026-10-13 cleanup (wire v3), which removed code paths these runs didn't
exercise (partial-screen regions, the codec ladder, the throttle band, the
pixel-streams prototype), so no change is expected; re-run one before
quoting it against a change.

| metric | value | trace | date |
|---|---|---|---|
| Typing, steady bandwidth (byte-exact) | 2.2 KB/s (17.6 kbit/s) | typing-cc, encode replay | 2026-08-07 |
| Typing, encode p95 per batch | 2.33 ms | typing-cc, encode replay at 22 Mbit | 2026-09-27 |
| Cold-start tick (full 5K keyframe) | 191 ms | typing-cc, effort policy | 2026-09-27 |
| Encode CPU per trace (effort policy, 22 Mbit) | typing-cc 2.62 s · cursor-drag 19.7 s · scroll v3 48.7 s · scroll-win 68 s | encode replay | 2026-09-27 |
| Full 5K diff scan (3,600 tiles, parallel) | p50 875 µs / p95 1080 µs | `synth --kind fullscan` | 2026-08-05 |
| xxh64, one core | 11.5 GB/s (3,600 tiles in 5.1 ms) | one 5K frame | 2026-09-26 |
| Idle | 0 datagrams after settle; 25.2 s with no frames and no datagrams | idle | 2026-08-05 |
| Glass-to-glass, loopback | p50 34.6 ms / p95 67.7 ms (n = 5000) | live 5K loopback session | 2026-08-05 |
| Full 5K present blit | 4.1 ms | `SurfacePresenterTests` | 2026-09-27 |
| Full loop, pinned HEVC + per-tile handoff, standard faults (total bytes, all settled byte-exact) | typing-cc 8.85 MB · cursor-drag 16.81 MB · scroll-win 18.40 MB · photos 38.19 MB | loop replay `--video vt` | 2026-10-10 |
| Faulted golden, tiles only | 45.98 MB, settled byte-exact at 21.1 s | scroll v3 | 2026-09-30 |
| Golden status | byte-identical ×3 seeds under the standard faults on every reference trace | all | 2026-08-05 onward |
| Video on a 3 Mbit/s bottleneck | steady p95 one-way delay 59–64 ms | relay rig (`VideoSendGateTests`) | 2026-09-30 |
| Video quality at 1 Mbit/s (capture-time PTS, QP 34 floor) | typing-cc min SSIM 0.926; SSIMULACRA2 mean 63.1 / p5 49.8 / min 28.1 | `vquality`, 2940-wide | 2026-10-18 |
| Tile governor on a thin link | 224 KB/s on a 250 KB/s link; worst backlog 268 ms in the last three rounds | `GovernorTests` rig | 2026-10-22 |
| 5K trace over a 2 Mbit/s link, 2 s buffer (time from the last frame to exact) | typing-cc 53.4 s · scroll-win 24.4 s · cursor-drag 52.3 s; queue p95 1.999 s | loop replay, tiles only, `--link-mbit 2` | 2026-10-22 |
| Loopback QUIC, 2048² noise, 6 full-frame rounds | ~11 s; 0 lost, 0 redundant datagrams | `QUICSustainedSessionTests` scenario | 2026-09-27 |

## §10.1 acceptance status

The v1 bars from DESIGN §10.1, with the latest evidence. The original run
is "v1 acceptance run (2026-08-05)" in the log.

| criterion | status |
|---|---|
| invariant, property and fuzz tests green | ✅ every `INV_*` test keeps passing (a failing one blocks landing); the suite is also run under ASan (`just test-asan`) |
| goldens byte-exact at 5 %/1 %/10 %, 3 seeds | ✅ synthetic traces and every real reference trace |
| typing: encode p95 ≤ 300 µs/batch | ⚠️ not met: 2.15 ms on typing-cc at 5K (2026-08-07), 2.33 ms under the effort policy (2026-09-27). The bar assumed 4K and tight dirty rects; at 5K a full diff scan alone is ~0.9 ms (p50 875 µs) |
| typing: sustained ≤ 120 KB/s | ✅ 2.2 KB/s steady on typing-cc (2026-08-07). The 2026-08-05 reading (514 KB/s) was on a trace later found to include the recorder's own menu ("Typing trace autopsy") |
| idle: 0 datagrams after settle | ✅ 2026-08-05: only genuine macOS UI changes (menu-bar clock, a Dock reveal) shipped, and only their tiles |
| scroll (4K): no capture starvation at 60 Hz | ✅ at acceptance: 0 dropped captures at ~53 fps, encode p95 8.11 ms on full-screen 5K scroll (2026-08-05). Since P2′, heavy scroll ticks run p95 ~29 ms (scroll v3, 2026-09-27), so INV-4 drops captures on full-screen tile scrolls by design (accepted in P2′); live, sustained full-screen motion goes to video |
| loopback glass-to-glass p50 ≤ 35 ms at 60 Hz | ✅ 34.6 ms p50 / 67.7 ms p95 (2026-08-05) |

## Reference traces

The `.scap` traces named in this file are private screen recordings on the
owner's machine. They aren't distributed (each is a full-screen 5K capture,
gigabytes in size), so their numbers are comparable only on that machine.

To measure a change yourself:
1. Record traces of your own: Host › Developer › **Record Trace** (or
   **Record 30 Seconds**, which starts after 5 s so the menu stays out of
   the capture). Files land in `~/Library/Application Support/Glass Act/traces/`.
2. Run `just bench replay --trace <file> --mode encode` before and after the
   change, and the standard golden run above. `just bench help` lists the
   other commands; `glassact-bench synth` makes synthetic traces anyone can
   regenerate.
3. Add a log entry naming the trace's content, its geometry and your
   machine.

Recordings are named `glassact-<unix time>.scap`. The traces most entries use:

| name in entries | file | content |
|---|---|---|
| typing-cc | `glassact-1786116323.scap` | a Claude Code session in Ghostty: typing, streamed reply, tool output (31.2 s) |
| scroll-win | `glassact-1786116475.scap` | GitHub source scrolled in a browser window (30.9 s) |
| photos | `glassact-1786116654.scap` | Photos.app full-screen browsing (29.4 s) |
| cursor-drag | `glassact-1786116861.scap` | pointer sweeps and dragging an opaque terminal window (31.8 s) |
| scroll v3 | `glassact-1785962837.scap` | full-screen markdown in Zed, steady wheel scroll (20.4 s) |
| typing (2026-08-05) | `glassact-1785961372.scap` | Terminal.app at ~5 cps; includes the recorder's own menu |
| idle | `glassact-1785961857.scap` | static screen, hands off (67.5 s) |
| live 5K session | `glassact-1785995222.scap` | browser video, 87.5 s |
| movie | `glassact-1793736335.scap` | a film full screen in VLC, 24 frames a second (30.0 s) |
| app-switch | `glassact-1793737268.scap` | Cmd-Tab between apps and back, resting on each (27.5 s) |
| tabs | `glassact-1794265876.scap` | a Safari window's tabs switched in turn, twice round (30.0 s) |
| window-open-close | `glassact-1794271260.scap` | Finder windows opened, moved and closed over other windows (29.9 s) |
| ide | `glassact-1794283848.scap` | Zed full screen on Rust source: typing, scrolling, switching files (29.3 s) |
| maps | `glassact-1794284096.scap` | Maps.app full screen, panned and zoomed (30.1 s) |
| images-scroll | `glassact-1794284419.scap` | image search results in Chrome full screen, scrolled down and back (30.0 s) |

Details: "Reference traces v3" (2026-11-09), "Reference traces v2" (2026-08-07) and
"Reference traces" (2026-08-05) in the log.

## Decisions and rejected experiments

One line per idea that was built, measured or removed. Follow the link for
the numbers and the reasoning.

**Tile codecs**

| idea | verdict | key number | entry |
|---|---|---|---|
| LZBITMAP tile codec (0x09) | kept, for Mac-only peers | typing 514 → 313 KB/s at adoption; dropping it now costs 1–11 % of tile bytes and saves ~20 % encode CPU. For non-Apple peers a platform-agnostic codec (zlib or Brotli) would replace it, with VP8L routing re-tuned | [adoption](#codec-evaluation--lzbitmap-baseline-2026-08-05), [re-check](#lzbitmap-is-the-apple-only-codec-worth-keeping-2026-10-06) |
| VP8L tiles (vendored libwebp, 0x0A) | kept | scroll 14.6 → 9.83 MB/s, typing 313 → 159 KB/s | [entry](#vp8l-tile-codec-vendored-libwebp-opcode-0x0a--in-house-exploration-2026-08-05) |
| In-house spatial predictors + LZBITMAP | rejected | 0 % on the text corpus (728 → 728 B/tile) | [entry](#vp8l-tile-codec-vendored-libwebp-opcode-0x0a--in-house-exploration-2026-08-05) |
| Palette + rANS (v1 roadmap P2) | not built | palette + left prediction wins zero bytes over the best-of (VP8L already does both) | [entry](#p2--hash-pinned-delta-records-2026-08-06) |
| JPEG XL lossless tiles | rejected | 449 vs VP8L's 379 B/tile, at a quarter of the speed | [entry](#codec-frontier-survey--cache-measurement-2026-08-05) |
| AVIF lossless (settle, keyframes) | rejected | VP8L 20 % smaller on text, 33 % on photos | [entry](#vp8l-vs-avif-lossless--vp8l-wins-both-content-types-2026-08-07) |
| AVIF lossless per 64×64 tile | rejected (re-measured 2026-10-31) | AV1 data alone 1.26–2.6× VP8L z4's bytes | [entry](#tiles-as-av1-lossless-and-lossy-avif-and-the-metal-encoder-against-vp8l-2026-10-31) |
| Lossy WebP / AVIF tiles | rejected | on text, lossless VP8L is smaller than WebP q90 (398 vs 423 B/tile on typing-cc) | [entry](#lossy-webp--avif-for-tiles--measured-and-rejected-2026-08-10) |
| Route codecs by cheap signals (LZ4 size) | rejected | gating VP8L at LZ4 ≤ 12 KB costs +18.6 % bytes | [entry](#codec-routing-measurement-glassact-bench-routescan-2026-08-05) |
| VP8L positional routing memory | kept | 96 % of probes avoided on churn, 0 % on text (zero regret) | [entry](#vp8l-routing-memory-positional-outcome-memory-2026-08-05) |
| VP8L effort policy (4 on small ticks, 1 on bursts; keyframes 0/1) | kept | typing-cc encode CPU 5.74 → 2.62 s, cold tick 707 → 191 ms, ≤ +1.6 % steady bytes | [entry](#vp8l-effort-sweep--tick-size--rate-policy-2026-09-27) |
| Coalesce tiles into larger VP8L blocks | rejected | 3–9 % smaller for 10–40 % more encode | [entry](#settle-coalescing-vp8l-block-size-sweep-2026-08-10) |
| Widen the VP8L budget while draining a settle | kept | −9.3 % of datagram bytes on photos | [entry](#settle-coalescing-vp8l-block-size-sweep-2026-08-10) |

**Scroll, cache, DELTA and keyframes**

| idea | verdict | key number | entry |
|---|---|---|---|
| SCROLL as a control op (P3) | kept | full-screen scroll 53.6 → 15.45 MB/s | [entry](#p3--scroll-pipeline-wire-v2-2026-08-05) |
| Window-scoped and horizontal scroll (P3′) | kept | 34 ops, 19,823 tiles satisfied on scroll-win | [entry](#p3--window-scoped--horizontal-scroll-2026-08-06) |
| 2-D drag/shift detection (P3″) | kept | scroll-win −57 %, photos −47 %, cursor-drag −25 % | [entry](#p3--2-d-dragshift-detection-2026-08-07) |
| Session tile cache (P3b, 0x07) | kept | typing 159 → 134.6 KB/s; 67 % of changed scroll tiles are repeats | [entry](#p3b--session-tile-cache-opcode-0x07-2026-08-05) |
| Try CACHE REF before DELTA | kept | −1.7 % bytes; REFs 16k → 50k | [entry](#cache-ref-now-beats-delta-2026-09-27) |
| Hash-pinned DELTA records (P2′, 0x0B) | kept | typing 134.6 → 102.7 KB/s, scroll 9.17 → 5.49 MB/s | [entry](#p2--hash-pinned-delta-records-2026-08-06) |
| DELTA_NACK: NACK received-but-unapplied records | kept | photos loop: 18–47 divergent tiles → byte-identical | [entry](#delta_nack--the-first-real-divergence-found-and-fixed-2026-08-07) |
| Verified scroll promotion (SCROLL_ACK digest) | kept | closes the last optimistic-belief hole; honest digests never false-fire | [entry](#p6d--region-formation-for-paging--verified-scroll-promotion-2026-08-07) |
| Timeout sends tiles cold (`ackedHash = 0`) | kept | the first typing golden failed with 1 divergent tile without it | [entry](#golden-divergence-baselines-replay---mode-loop---golden-standard-faults-seeds-13-2026-08-05) |
| Striped VP8L keyframes (P7) | kept, for video-less cold starts | typing cold start 21.0 → 10.4 MB | [entry](#p7--lossless-region-keyframes-2026-08-06) |
| Lossy q90 first paint (P7b) | kept, as a transient | ~60–90 ms encode vs ~550 ms for the lossless keyframe | [entry](#p7b--lossy-first-paint-cold-start-2026-08-06) |
| REFINE: lossless residual against the lossy video frame (P4) | rejected | the residual is larger than full lossless (9.35 vs 6.96 MB) | [entry](#refine-settle--definitive-diff-is-larger-than-full-lossless-2026-08-07-corrected) |

**Video**

| idea | verdict | key number | entry |
|---|---|---|---|
| Video regions over hardware HEVC (P6) | kept | ~60× on a churning region (40.8 MB/s lossless → ~4.5 Mbit/s) | [entry](#p6--video-regions-over-hardware-hevc-2026-08-05) |
| Software AV1 (libaom) for regions (P6b) | retired 2026-10-10; revisit with hardware AV1 | −34 % bytes vs HEVC on photos at 5K, but no Apple chip through M6 encodes AV1, and loading libaom forced `disable-library-validation` | [feasibility](#av1-software-encode-feasibility-on-m4-2026-08-05), [re-check](#av1-encoder-re-check-libaom-3151-vs-svt-av1-420-2026-10-10) |
| SVT-AV1 | rejected | ~14 fps low-delay at 5K; screen tools off at fast presets | [entry](#av1-encoder-re-check-libaom-3151-vs-svt-av1-420-2026-10-10) |
| SVC layering (K-SVC) | not built | a purely droppable enhancement layer costs 135× | [entry](#svc-exploration--k-svc-feasibility-measured-2026-08-07) |
| Partial-screen (hot-map) regions | removed 2026-10-13, superseded by pinned full-screen | photos loop 571 → 63 Mbit after tuning; 17.1 Mbit once regions snapped full-screen | [P6d](#p6d--region-formation-for-paging--verified-scroll-promotion-2026-08-07), [P6e](#p6e--global-send-governor--full-screen-region-snap-2026-08-07) |
| Codec demote/promote ladder (AV1 ⇄ HEVC on CPU pressure) | removed 2026-10-13, with AV1 | quality barely moves AV1 encode speed (57–64 fps across cq) | [P6b](#p6b--av1-regions-shipped-adaptive-hevc-fallback-2026-08-05), [cq lever](#quality-vs-speed-vs-bandwidth-at-5k--the-cq-lever-is-bandwidth-not-framerate-2026-08-07) |
| Pinned full-screen video (P8) | kept, the only mode | first live run (AV1 then): 0.3–15 Mbit moving, 5–35 KB/s calm | [entry](#p8-pinned-mode--first-live-session-2026-08-07) |
| Per-tile handoff inside a live region | kept | cursor-drag video coverage 90.1 → 41.5 % for +0.5 % bytes | [entry](#per-tile-handoff-inside-a-live-video-region-2026-10-10) |
| Ungated record handoffs | rejected | photos 38 → 95 MB, host encode p95 5 → 20 ms | [entry](#per-tile-handoff-inside-a-live-video-region-2026-10-10) |
| Occlusion throttle at 1–29 Hz (REFRESH_HINT) | replaced by PAUSE_HINT 2026-10-13 | the viewer only ever sent 0 or 60 | [entry](#p6c--refresh_hint-occlusion-aware-sync-throttling-2026-08-05) |
| Capture-time PTS for the encoder | kept | typing-cc at 1 Mbit/s: SSIM 0.892 → 0.967 | [entry](#soft-video-for-minutes-capture-time-pts-qp-34-floor-re-sharpen-2026-10-10) |
| QP 34 frame-QP floor | kept (default since 2026-10-10) | typing-cc at 1 Mbit/s: min SSIM 0.757 → 0.926, same bytes | [entry](#soft-video-for-minutes-capture-time-pts-qp-34-floor-re-sharpen-2026-10-10) |
| Re-sharpen keyframe once a region goes quiet | kept | SSIM 0.879 → 0.975–0.985 | [entry](#soft-video-for-minutes-capture-time-pts-qp-34-floor-re-sharpen-2026-10-10) |
| …but not for a region counting down to its dissolve | kept | 6 Mbit/s thin link: −4 to −7 % bytes on traces that re-sharpen, keyframe bytes halved, all byte-exact | [entry](#no-re-sharpen-for-a-dying-region-2026-10-22) |
| Prefer sharpness: QP 28 ceiling when the link has headroom | kept (opt-in, 2026-10-19) | worst-frame SSIMULACRA2 50–60 → 69–75 on text at 6 Mbit/s, same average bytes; photos +26 % | [entry](#prefer-sharpness-a-qp-28-ceiling-on-a-link-with-headroom-2026-10-19) |
| HEVC Main 4:4:4 (full-resolution chroma) for video regions | rejected | at equal bytes 4:2:0 scores higher (typing-cc 0.57 Mbit/s: 77.2 vs 67.8 SSIMULACRA2); 4:4:4 costs 5–35 % more bits | [entry](#hevc-main-444-for-video-regions-rejected-2026-10-25) |
| Software AV1 (vendored libaom) as a Viewer opt-in | kept, opt-in; hardware HEVC stays the default | not a bandwidth saving: at equal bytes HEVC is 3–6 SSIMULACRA2 better on text and wins photos; AV1 wins scrolling and reaches sharper text at higher rates; aiming at 40 % of the link it delivers more frames than HEVC on 10 Mbit/s; encode 2–10 ms vs ~13 ms | [entry](#av1-back-as-a-viewer-opt-in-2026-10-25) |
| AV2 (AVM reference encoder) for video; AV1 speed and decode re-measured | measured, not actionable | at 60 dB on typing-cc 38 KB vs 141 KB AV1 vs 233 KB x265 vs >647 KB hardware HEVC; but 0.09 fps at 1080p and no hardware or VideoToolbox support | [entry](#av2-on-screen-text-avm-research-v1500-2026-10-25) |
| Intra block copy in key frames (`metal-av1`, on by default) | kept | 5K BD-rate typing −18 %, cursor-drag −14 %, scroll −7 %; photos and 720p unchanged (a frame copies only when copies cover ≥ 6 % of its non-flat 8×8s: no filters then); ~10 ms of search per 5K key frame | [entry](#metal-av1-intra-block-copy-in-key-frames-2026-11-01) |
| Lossy intra block copies; inter blocks' tx types searched (`metal-av1`) | kept | key frames also copy where a near copy's residual is ≤ 0.005 × 1.5 × step² per sample: 5K BD-rate typing −2.3 %, scroll −1.7 %, drag −3.2 % (1080p terminal crop's key frame −11 %); inter tx types: −0.1 to −2.4 % more (720p photos), 2–5 % slower on most points (one 5K point 25 %); split transforms in copies and 4×4 copies measured, not worth it | [entry](#metal-av1-lossy-intra-block-copies-and-inter-blocks-tx-types-2026-11-01) |
| AV2's 3.7× on text, attributed (AVM, each tool off in turn) | measured; intra block copy is next for `metal-av1` | intra block copy alone is 3.4× on typing; libaom at speed 2 with it gets within ~15 % of AV2 (typing 60 dB: 43 vs 37 KB, 131 KB without); key frames 2.9× smaller at ~45 dB | [entry](#av2s-gain-on-text-attributed-intra-block-copy-which-av1-has-too-2026-11-01) |
| Prefer smooth motion: frame-QP ceiling 38 while the link has no room (Viewer opt-in) | kept, opt-in | 2M photos 20 → 48 frames, 3M scroll-win queue p95 423 → 344 ms; text p5 SSIMULACRA2 −5 to −18 at caps ≤ 1 Mbit/s, about even above | [entry](#how-low-can-video-go-ratequality-knees-looser-floors-prefer-smooth-motion-2026-10-25) |
| Frame-QP ceiling 42 on thin links | rejected | photos frames 4–8× but SSIMULACRA2 near zero | [entry](#how-low-can-video-go-ratequality-knees-looser-floors-prefer-smooth-motion-2026-10-25) |
| A minimum encoder cap (2–3 Mbit/s) for sharper text on thin links | rejected | 1M scroll-win 98 → 51 frames; 2M cursor-drag 326 → 286 | [entry](#how-low-can-video-go-ratequality-knees-looser-floors-prefer-smooth-motion-2026-10-25) |
| AV1 only while the link has room (delivered ≥ 6 Mbit/s on, queued < 4 off; at the next region) | kept | 2–3 Mbit/s: HEVC's frames and latency (2M cursor-drag 326 · 641 ms vs AV1 alone 283 · 1183 ms); 10 Mbit/s: AV1 | [entry](#av1-only-while-the-link-has-room-2026-10-25) |
| Switch a live region's codec in place | rejected | 6 Mbit/s photos 68 frames vs HEVC 165 | [entry](#av1-only-while-the-link-has-room-2026-10-25) |
| Fixed grid of video cells (an encoder per cell) instead of one full-screen region | rejected | 4×4 HEVC: 48–69 % of the bytes on typing but 110–145 % on drag, scroll and photos; motion crossing cell edges loses prediction | [entry](#video-cells-instead-of-one-full-screen-region-rejected-2026-10-25) |
| Slower libaom speeds (8 and below) | rejected | ≤ +0.7 SSIMULACRA2 for 38–57 % more encode time; 7, 6 and 5 identical | [entry](#real-time-av1-slower-libaom-speeds-and-svt-av1-at-session-size-2026-10-25) |
| VP9 (libvpx real-time) instead of AV1 | rejected | ~2 dB worse on text at equal bytes, 2.5× the bytes on scrolling, frame sizes no steadier; no Apple hardware decode | [entry](#real-time-av1-slower-libaom-speeds-and-svt-av1-at-session-size-2026-10-25) |
| SVT-AV1 real-time at session size (2900 px) | rejected | fast now (157–204 fps) but ~10 dB worse than libaom at similar size | [entry](#real-time-av1-slower-libaom-speeds-and-svt-av1-at-session-size-2026-10-25) |
| SVT-AV1 4.2 and rav1e 0.8 as live encoders, quality allowed to drop | rejected | at 2900 px 24–60 fps (SVT preset 7–13) and 24–32 fps (rav1e) on 14 cores, against libaom's 2.4–7 ms per frame; libaom speed 9 needs the fewest bytes too (0.40–0.84 of HEVC's for its quality) | [entry](#live-av1-encoders-and-a-looser-av1-ceiling-on-thin-links-2026-10-27) |
| AV1 quantizer ceiling 60 on thin links | measured, not acted on | 2M scroll-win 408 frames · 369 ms queue p95 vs HEVC's 170 · 651, but motion SSIMULACRA2 56 vs 72 (photos −1 vs 42) | [entry](#live-av1-encoders-and-a-looser-av1-ceiling-on-thin-links-2026-10-27) |
| AV1 ceiling 60 with a higher rate aim (60–100 % of the cap) | aim 60 kept for smooth motion; 80 and 100 rejected | aim 100 matches HEVC 34 on scrolling (74 vs 72) but delivers fewer frames than HEVC 38; aim 60 keeps more frames than HEVC 38 on all but one run, with motion 64 / 75 / 10 (scroll / drag / photos) against HEVC 38's 70 / 72 / 32 | [entry](#av1-at-ceiling-60-a-higher-rate-aim-2026-10-28) |
| Prefer smooth motion on AV1 (opt-in): AV1 allowed on a thin link, at quantizer ceiling 60 aiming at 60 % | kept, opt-in | against HEVC 38: 2M scroll-win 227 → 358 frames, 3M photos 60 → 271; 6M cursor-drag 411 → 382 | [entry](#prefer-smooth-motion-runs-av1-on-a-thin-link-2026-10-28) |
| VT low-latency rate control | rejected | overshoots 20–100 % (9× on photos), no latency gain | [entry](#video-layer-quality-low-latency-rc-and-half-res-encode-measured-2026-09-29) |
| Half-resolution encode, upscaled | rejected | text tops out near SSIM 0.93; full res passes it at 1 Mbit/s | [entry](#video-layer-quality-low-latency-rc-and-half-res-encode-measured-2026-09-29) |
| VT constant quality factor (macOS 27) | rejected | byte-identical while a bitrate is set; Apple's preset adds ~130 ms of lookahead | [entry](#macos-27-videotoolbox-constant-quality-and-super-resolution--neither-usable-2026-10-10) |
| VT low-latency super-resolution | rejected | input capped at 1280 px; nothing screen-sized fits | [entry](#macos-27-videotoolbox-constant-quality-and-super-resolution--neither-usable-2026-10-10) |
| The Metal AV1 filters' CDEF preset search on the GPU (`metal-av1`) | kept | one command buffer a picture instead of 2–3: +3–18 % inter frames a second, streams unchanged | [entry](#metal-av1-the-filters-preset-search-on-the-gpu-one-command-buffer-a-picture-2026-11-01) |
| Palette blocks in the Metal AV1 encoder (`metal-av1`) | writer and parser support kept; decisions not taken; **reopened for inter frames at 5K** (libaom's palette + residual halves its intra coding of new text there; a first proxy-chosen prototype saved nothing) | exact palettes' best case ≤ 0.05 % of a key frame's bits (DCT codes few-colour blocks in ~11 bits); lossy ones 0.1–0.7 % at q20, 1–5 % at q40; libaom realtime's palette costs 6–34 % BD-rate | [measured](#metal-av1-palette-decisions-measured-not-taken-2026-11-01), [libaom](#metal-av1-palette-blocks-in-the-writer-and-parser-libaoms-palette-measured-2026-11-01) |
| Learned pruning of the analysis (`metal-av1`): a network per 8×8 cell picks the likely tree levels, one per node the likely luma modes, one per leaf the likely chroma modes | kept, on at 900 superblocks (1440p) and up since its one-pass statistics (2,000 before) | 5K key frames 35–39 % faster on screen content (photos 15 %), BD −0.6 to 0.0 % against none; 1440p's GPU analysis −8 to −22 % at ±0.3 %; 720p only loses (photos streams −23 %, before the one-pass statistics); a first version, a yes/no per node, cost +2–6 % because its skips compound; `scripts/train-pruner` retrains both; **weights retrained on eleven traces installed 2026-11-12** (stream BD −1.2 % app switching, −0.9 % tabs, +0.4 % dragging, +0.25 % video, the rest within ±0.05 %) | [entry](#metal-av1-learned-pruning-of-the-analysis-offline-feasibility-2026-11-02), [retrained](#metal-av1-learned-prunings-weights-retrained-on-eleven-traces-installed-2026-11-12) |
| Angle deltas only where a picture changes in places (`metal-av1`) | kept (half the superblocks) | 5K full-screen change or key frame 150–170 → 105–127 ms for +0.3–1.7 % of its bytes; whole streams ≤ +0.3 %; turbo2 / turbo3 cost +11–45 % on text | [entry](#metal-av1-every-superblock-changing-at-5k-where-the-time-goes-and-angle-deltas-gated-2026-11-02) |
| Reduced frames (coded smaller, shown at the stream's size) for full-screen change at 5K (`metal-av1`) | writer and parser support kept; not used | half size: 35 ms a picture, HEVC's latency, but 5K quality caps near 30 dB, below HEVC at any rate; 3/4 size 76–90 ms, caps at 34–36 dB; VideoToolbox decodes scaled references and superres exactly | [entry](#metal-av1-reduced-frames-for-full-screen-change-at-5k-measured-2026-11-02) |
| RDOQ in the closed loop (`metal-av1`), only in tx blocks whose source spans ≥ 40 values | kept, on | BD-rate by SSIMULACRA2: 5K key frames −0.7 to −2.1 %, 5K streams −0.6 to −1.9 %, 720p streams −2.6 to +0.2 %; 5K key frame +0–2.7 % picture time. Ungated, it banded flat areas (photos +1.5 %); a distinct-values gate was worse; RDOQ in the tx type trials saves less for 9–22 ms more | [entry](#metal-av1-rdoq-in-the-closed-loop-where-the-source-has-contrast-2026-11-02) |
| The closed loop without its tile coding, which the writer redid (`metal-av1`); learned pruning's buffers kept | kept | 5K key frames' closed loop −27 to −32 %, their pictures −3.4 to −8.6 ms, 720p key frames −1 to −2.8 ms; the same bytes. The next analysis set up a picture earlier, kept: no faster today (the GPU bounds a 5K key frame of text), up to 3–4 ms once the GPU catches up | [entry](#metal-av1-the-closed-loop-stops-coding-its-tiles-learned-prunings-buffers-kept-2026-11-02) |
| Flat blocks with flat edges skip their analysis search (`metal-av1`) | kept | the same results; 720p scroll-win's analysis 7.4 → 6.9 ms, 5K ±noise (learned pruning already leaves few flat blocks to the search) | [entry](#metal-av1-flat-blocks-with-flat-edges-skip-their-search-results-unchanged-2026-11-02) |
| Learned pruning's statistics in one pass per SB from whole-number sums (`metal-av1`) | kept | 3.85 → 2.02 ms of GPU a 5K picture; key frames −0.4 to −1.9 ms; BD 0.0 % (8x8 and 16x16 features bit-identical) | [entry](#metal-av1-learned-prunings-statistics-in-one-pass-per-sb-from-whole-number-sums-2026-11-02) |
| One warp a threadgroup for the analysis's 16x32, 32x16, 32x32, their inter search, and the leaves (`metal-av1`) | kept | the same results; 5K key frames' GPU −5.7 to −7.4 ms (typing-cc picture 58.8 → 52.7, photos 89.9 → 82.0); 16x16 and smaller keep 4 warps (1 is slower there) | [entry](#metal-av1-one-warp-a-threadgroup-for-the-analysiss-16x32-32x16-and-32x32-their-inter-search-and-the-leaves-2026-11-02) |
| A key frame's intra block copy hashes taken while its analysis runs (`metal-av1`) | kept | the copy search's stage −1.5 to −1.6 ms a 5K key frame; the same streams | [entry](#metal-av1-a-key-frames-intra-block-copy-hashes-taken-while-its-analysis-runs-2026-11-02) |
| The inter gate: no motion windows or inter RD where nothing beats 2 x the mean's SAD, in pictures mostly new (`metal-av1`) | kept, on | full-screen change at 5K 14.3 → 19.1 inter frames a second (motion search 13.7 → 4.3 ms, inter candidates 16.7 → 7.8); BD −0.2 to +0.1 %; in every picture it cost 720p scroll-win 0.5 % | [entry](#metal-av1-full-screen-change-inside-a-stream-and-the-inter-gate-2026-11-02) |
| An inter frame's 8x8, 8x16 and 16x8 on the thread-per-block kernel where most of the picture is new (`metal-av1`) | kept | the same streams; the full-change mixes' GPU analysis −1.5 to −10 ms at 5K (photos+drag 81.6 → 71.6) | [entry](#metal-av1-full-screen-change-inside-a-stream-and-the-inter-gate-2026-11-02) |
| A block on several SIMD-groups for the analysis's 16x32, 32x16 (64 threads), 32x32 and 64x64 (128) (`metal-av1`) | kept | the same streams; 5K key frames' GPU −5.7 to −10.4 ms (64x64 9.5 → 4.0), full-change mixes +7–12 % inter frames a second | [entry](#metal-av1-a-block-on-several-simd-groups-for-the-analysiss-big-shapes-2026-11-02) |
| GOLDEN_FRAME: inter frames also copy the picture before the latest mostly new one (`metal-av1`) | kept, on | two screens in turn at 5K: inter frames 317 → 14 KB (typing+scroll) and 735 → 76 KB (photos+drag), 21 → 128 and 14 → 48 a second; BD-rate against libaom −87 to −91 % (+24 to +30 % before); single traces byte-identical | [entry](#metal-av1-golden_frame-and-where-libaom-beat-us-on-a-full-screen-change-2026-11-02) |
| Fewer analysis shapes in mostly new inter pictures (`metal-av1`, `newPictureShapeMask`) | squares on (the owner's choice, 2026-11-03; `--new-shapes off`) | a 5K picture of new content: no 8x16/16x8 +0.4 % bytes for −8 ms of GPU analysis; squares, 4x8 and 8x4 +1.0 % for −13 ms; squares +1.6 % for −17 ms (43 → 26 ms, 18 → 24 a second). Learned pruning's eps and the turbo2 preset cost 5–10× more bytes for the same time | [entry](#metal-av1-what-buys-speed-on-a-picture-of-new-content-at-what-bytes-2026-11-03) |
| The closed loop's forward DCTs by their butterflies (`metal-av1`) | rejected | byte-identical streams (BD 0.00 %), but slower than the register-blocked matrices at every size (32x32 1.7 → 2.5 µs); a fast one could save at most ~7 % of the closed loop | [entry](#metal-av1-the-closed-loops-forward-dcts-by-their-butterflies-measured-not-kept-2026-11-03) |
| RDOQ off, or gated harder, on new pictures (`metal-av1`) | rejected | off +0.54 % / +2.69 % (PSNR / SSIMULACRA2), span ≥ 80 +0.33 / +1.04 %, ≥ 120 +0.47 / +1.48 %; no speed difference outside the noise | [entry](#metal-av1-rdoq-on-pictures-of-new-content-re-measured-2026-11-03) |
| The closed loop's tx types: DCT_DCT, IDTX, V_DCT, H_DCT only (`metal-av1`, `txTypes`) | on (the owner's choice, 2026-11-03; `--tx-types FFFFFFFF` for all) | +0.49 % / +0.11 % (PSNR / SSIMULACRA2) for ~+6 % pictures a second on new 5K pictures; DCT and IDTX alone +3.5 % / +1.9 % | [entry](#metal-av1-the-closed-loops-tx-types-2026-11-03) |
| A picture's write beside the next closed loop, handed on from the writer's thread (`metal-av1`; the owner's choice) | kept | the same streams; 5K new pictures 23.65 → 26.2 inter frames a second (the writer wait 6.6 → 0.5 ms, the closed loop 15.1 → 20.8 sharing the cores) | [entry](#metal-av1-a-pictures-write-beside-the-next-closed-loop-handed-on-from-the-writers-thread-2026-11-03) |
| The analysis's screening: lanes summed before one atomic add, and a row a lane (`metal-av1`) | kept | the same streams; a 5K picture of new content's shapes of 16x16 and up 17.5 → 13.9 ms of GPU, 17.0 → 17.75 a second | [entry](#metal-av1-the-analysiss-screening-without-atomic-contention-or-divergence-2026-11-03) |
| The closed loop's quantizer (NEON f64), rate proxy (raster order) and shared first forward products (`metal-av1`) | kept | the same streams; a 5K picture of new content's closed loop 18.5 → 15.9 ms, its work −15 % | [entry](#metal-av1-the-closed-loops-work-not-its-dependencies-cheaper-tx-trials-2026-11-03) |
| Quick tx trials: transform-domain distortion, and stopping where DCT_DCT codes nothing (`metal-av1`, `quickTxTrials`) | kept, on (the owner's choice, 2026-11-03) | BD-neutral (+0.24 % / −0.08 %); closed loop −1 to −2 ms, −9 % of its work | [entry](#metal-av1-the-closed-loops-work-not-its-dependencies-cheaper-tx-trials-2026-11-03) |
| A time context for the learned models (the previous picture's choice at the same place) | rejected | a changed cell keeps its level no more often than the most common level predicts (photos 30–35 % vs 32–34 %) | [entry](#metal-av1-learned-prunings-statistics-in-one-pass-per-sb-from-whole-number-sums-2026-11-02) |
| A leaf a thread where its chroma is 4x4 or none; a SIMD-group a leaf for the rest (`metal-av1`, `k_leaf_small`) | kept | the same streams; the leaf stage of a 5K picture of new content 4.5 → 2.9 ms of GPU, GPU analysis 26.3 → 23.5 ms (provisional: the Mac in use) | [entry](#metal-av1-a-leaf-a-thread-where-its-chroma-is-4x4-or-none-2026-11-09) |
| The analysis's SIMD-group kernel: an exact prediction's RD without the transform, and the learned pruning's check ahead of a block's set-up (`metal-av1`) | kept | the same streams; a 5K picture of new content's analysis 11.7 → 11.3 ms of GPU (provisional: the Mac in use) | [entry](#metal-av1-where-the-gpu-analysis-goes-on-a-picture-of-new-content-kernel-by-kernel-2026-11-09) |
| The exact-prediction shortcut in the analysis's thread kernel; skipping the screening where one mode is left; `k_ml_stats`'s `atan2` by comparisons (`metal-av1`) | measured, not kept | no difference (threads run as SIMD-groups); the `atan2` has at most 0.1 ms to give | [entry](#metal-av1-where-the-gpu-analysis-goes-on-a-picture-of-new-content-kernel-by-kernel-2026-11-09) |
| The filters' GPU kernels: a thread a 4x4 (4x2 of chroma) in CDEF and its strength search, zero-strength taps unread, deblocking's wide filter by a sliding sum called with constant sizes, `AV1G_UNROLL` on the direction search (`metal-av1`) | kept | the same streams; the filters' search alone on a 5K key frame 10.6 → 4.9 ms of GPU (`p_deblock` 2.6 → 0.58, `p_cdef_dir` 0.71 → 0.06, `p_cdef` 3.0 → 1.5, `l_cdef_sse` 3.7 → 2.5); in the rotation the filters' GPU beside the analysis 8.0 → 3.7 ms (provisional: the Mac was in use) | [entry](#metal-av1-the-filters-gpu-kernels-the-same-streams-in-under-half-the-time-2026-11-09) |
| The strength search reusing direction 0's sums; `p_cdef` storing words; word loads in the direction search; `p_cdef` at other threadgroup shapes (`metal-av1`) | measured, not kept | no faster | [entry](#metal-av1-the-filters-gpu-kernels-the-same-streams-in-under-half-the-time-2026-11-09) |
| The analysis's thread kernel screening each mode as a constant (`pred_cand0`); `k_ml_stats` taking a sample's levels from its thread's (`metal-av1`) | kept | the same streams; a 5K picture of new content's 8x8s 2.03 → 1.93 ms of GPU, its learned pruning 2.00 → 1.95 (provisional: the Mac in use) | [entry](#metal-av1-the-analysiss-thread-kernel-and-the-learned-prunings-statistics-by-parts-2026-11-09) |
| Unrolled loops in the thread kernel's flat check, SATD and mode loop (without constants) and in `k_ml_stats`; `k_ml_stats`'s seams summed a thread before one atomic add (`metal-av1`) | measured, not kept | no faster (the SATD's sub-blocks unrolled: slower at 8x8) | [entry](#metal-av1-the-analysiss-thread-kernel-and-the-learned-prunings-statistics-by-parts-2026-11-09) |
| The thread kernel's blocks listed by learned mode mask, so a SIMD-group screens the same modes (`metal-av1`) | not built | at most 0.5 ms of a 5K picture of new content's 23 ms (every lane given its group's first mask: 4x4 1.50 → 1.33, 8x8 1.95 → 1.63), before the cost of sorting the list | [entry](#metal-av1-the-analysiss-thread-kernel-and-the-learned-prunings-statistics-by-parts-2026-11-09) |
| A mostly-new picture in two steps: coded coarsely, then refined by the next frame (`metal-av1`, `av1seq --two-steps`) | measured, not adopted | both steps are 9–20 % more bytes than the picture coded once at the same quality (the rotation at 5K; after a q50 first step of 118 KB the second step at q20 is 484 KB against 508 KB); a coarse q alone leaves the first step's GPU stages at 21–22 ms of 23.0, and without the motion search it is 14.8 ms | [entry](#metal-av1-a-picture-in-two-steps-coarse-then-refined-measured-2026-11-10) |
| k_inter's candidates side by side and the source read once (`metal-av1`) | kept | inter candidates 3.82 → 2.59 ms on new 5K pictures, the same streams | [entry](#metal-av1-reviewers-ideas-measured-inter-candidates-side-by-side-kept-2026-11-11) |
| k_leaf without the luma tx search's threadgroup memory; no mode screening where learned pruning leaves one mode (`metal-av1`) | measured, not kept | the same streams and no measurable time: leaves 2.87 → 2.82 ms within run-to-run noise of ±0.1, 32x32 and 64x64 analysis unchanged | [entry](#metal-av1-reviewers-ideas-measured-inter-candidates-side-by-side-kept-2026-11-11) |
| Learned pruning's 32x32s and 64x64s decided per node (cells' mean or quantile, per-level thresholds, a small node network trained on the tree's cost) instead of any cell (`metal-av1`, offline) | measured, not adopted | held out on the training dumps, within ±0.02 ms of today’s GPU of the any-cell rule at eps 0.02 and ≈ 0.1 ms better at eps 0.05; the network loses; an oracle that knows the nodes' costs would skip ≈ 1.6 ms more, which the cells' statistics can't find | [entry](#metal-av1-reviewers-ideas-measured-inter-candidates-side-by-side-kept-2026-11-11) |
| Byte-identical speedups from the reviewers' lists (`metal-av1`): the analysis kernels compiled for the hybrid's settings; the motion projections' strips summed once a picture; no transform for a residual that provably quantizes to nothing | kept | the same streams; analysis 11.3 → 10.3 ms, motion search 2.90 → 2.46; the closed loop's tx-block hook −12 % of its CPU (wall within noise); the GPU stages on a new 5K picture ≈ 21.8 → 20.4 ms. Not kept, no measurable time: CDEF's strength search from threadgroup memory, the writer's threads capped, k_leaf compiled for the hybrid | [entry](#metal-av1-byte-identical-speedups-analysis-kernels-for-the-hybrid-projections-once-a-picture-2026-11-11) |
| The hybrid's partition read as its analysis ends, and the analysis gated behind the filters two pictures before (`metal-av1`) | kept; the next closed loop starting before the filters end not built (≤ 3.5 ms, then GPU-bound) | the same streams; from the filters' end to the next closed loop 3.0 → 0.25 ms; all-new 5K 33.1 → 35.0 inter frames a second (provisional, a loaded Mac). Found and fixed on the way: without CDEF (qindex ≤ 32) a stream coded without its pictures predicted from a reference its closed loop had overwritten | [entry](#metal-av1-the-partition-read-as-its-analysis-ends-the-analysis-behind-the-filters-a-reference-the-closed-loop-overwrote-2026-11-12) |
| A mostly-new picture coded fast at a qindex of its own (`metal-av1`, `newPictureEffort`, `av1seq --fast`) | **level 1 on by default at Δ+7, every mostly-new picture** (looser learned pruning, no RDOQ, no CDEF); levels 2 (no motion search where no shift is proposed: +22–26 % on two text screens) and 3 (no tx type search: bytes swing with content) options | bytes −0.8 to −6.8 % on every content measured, quality −0.2 to −0.9 dB (the most on video, while it plays); a new 5K picture's GPU stages 18.1 → 15.9 ms, filters' GPU ≈ 4.4 → 0.8, closed loop −13 core-ms, 36 → 43 inter frames a second | [entry](#metal-av1-a-mostly-new-picture-coded-fast-and-paid-for-in-quality-level-1-on-by-default-2026-11-12) |
| The analysis's threadgroup scratch by shape, the DCT matrix from a device buffer, 16x16 and 64x64 on the matrix units, 32 4x4s a lane each (`metal-av1`) | kept; 64x64 on 256 threads not (faster, the reference streams unchanged, but its float sums would split differently) | the same streams; a new 5K picture's analysis 10.2 → 9.6 ms | [entry](#metal-av1-the-analysiss-scratch-by-shape-16x16-and-64x64-on-the-matrix-units-2026-11-12) |
| The motion search's and inter candidates' kernels: candidates and gate centres across the SIMD-group, `k_inter` with its own scratch and several blocks a SIMD-group up to the gate, the sub-sample steps from a window (`metal-av1`) | kept; three `k_proj` variants and two `k_me` ones not (no gain or slower) | the same streams; a new 5K picture's motion search 2.54 → 2.19 ms and inter candidates 2.73 → 1.33 (video 8.17 → 7.52 and 5.94 → 4.47; scrolling images 8.95 → 8.48 and 3.54 → 1.87); the GPU stages ≈ 18.7 ms | [entry](#metal-av1-the-motion-search-and-inter-candidates-the-same-bytes-in-two-thirds-of-the-time-2026-11-12) |
| The closed loop's reconstruction in 32x32 groups, handed on as the plan walks (`metal-av1`) | kept; single-block and 64x64 groups not (longer critical paths) | the same streams; a new 5K picture's tasks from ≈ 100 thousand of 2 µs to groups; critical path 9.3–11.2 → 5.6–7.1 ms of thread CPU; the bench's user CPU −21 ms a picture; the wall unmeasurable on the day's loaded Mac | [entry](#metal-av1-the-closed-loops-reconstruction-in-32x32-groups-handed-on-as-the-plan-walks-2026-11-12) |
| The closed loop's RDOQ contexts by tx class with neighbours read once, the residual pass with the source span in NEON, `build_edges` in fixed-size pieces (`metal-av1`) | kept; an RDOQ early exit by a bits bound not kept (+4.6 % in the encoder though faster alone) | the same streams; the blocks' thread CPU on a new 5K picture 148.0 → 136.9 core-ms (−7.5 %), RDOQ 16.8 → 12.9 % of the loop | [entry](#metal-av1-the-closed-loops-rdoq-contexts-residual-pass-and-edges-the-same-bytes-2026-11-12) |
| RDOQ off on 4x4 tx blocks (`metal-av1`, `rdoqMinCoefficients`, `av1seq --rdoq-coeffs 17`) | kept as an option, off | within ±0.2 % on six contents, +0.4 % / +0.7 % on an IDE; the closed loop's work on new 5K pictures −2.0 % (q14), −2.5 % (q20), −9.8 % (q26) | [entry](#metal-av1-rdoq-off-on-4x4-tx-blocks-re-measured-kept-off-2026-11-12) |
| The closed loop's CPU by function on new pictures, and byte-identical cuts in the tx hook (`metal-av1`) | kept: RDOQ's span check on need, its level map per thread, the distortion sum skipping zero groups, energy in u32. Trades not taken (the owner's): no RDOQ on 4x4 (−0.2 % / −0.3 % / +0.4 %, −2 to −8 % work) | the blocks' thread CPU 160.2 → 154.6 core-ms a new 5K picture (−3.5 %); no hot spot (the tx hook 53 % in five parts); 10 ms needs ≈ −35 % work, byte-identical headroom ≈ 10–15 % more | [entry](#metal-av1-the-closed-loops-cpu-on-new-pictures-by-function-byte-identical-cuts-2026-11-12) |
| The analysis's 32x32 forward DCT on the SIMD-group matrix units, behind a start-up exactness check; k_ml_stats in less threadgroup memory; a changed search's deblocking in 8×8 threadgroups (`metal-av1`) | kept | the same streams; 32x32 2.94 → 2.43 ms, learned pruning 1.93 → 1.75, the deblocking pass ≈ 0.59 → 0.35; inter frames a second unchanged (the period is the CPU chain: closed loop → filters → partition). Matrix units for 16x16 (1.94 → 2.56) and 64x64 (2.33 → 4.26) slower, not kept | [entry](#metal-av1-matrix-units-for-the-32x32-dct-less-threadgroup-memory-for-the-pruning-and-where-the-period-goes-2026-11-11) |
| Key frames at a finer qindex than inter frames (`metal-av1`, `keyFrameQindexDelta`, `av1seq --key-delta`) | kept, **−16 by default in streams since 2026-11-12** (the owner's choice; −16: the rotation −7.5 % / −9.6 %, one screen −10.0 % / −13.4 %, the key frame ≈ 1.14× at q20) | at −32 (q − 8): the rotation −13.5 % / −15.9 %, one screen −16.7 % / −23.0 %, typing and scrolling −7.9 % / −10.9 %, photos and dragging (whose inter frames never copy the key frame) +1.6 % / +0.2 %; the key frame ≈ 1.3× today's at q20 (323 → 430 KB), still under libaom's 645 | [entry](#metal-av1-key-frames-at-a-finer-qindex-2026-11-11) |
| No motion search after frames whose search found nothing, re-checked every M frames (`metal-av1`, `motionSkip`, `av1seq --motion-skip <share>,<every>`, `off`) | kept as an option, **off by default** (on at 0.2,8 for a day, 2026-11-12: after a switch from two screens in turn it costs +4–6 % on video and +148 % on scrolling images over the next 12 frames; [entry](#metal-av1-the-motion-search-skip-after-a-switch-measured-off-by-default-again-2026-11-12)) | at 0.2,8: the default rotation at 5K skips 11 of 15 inter frames at the same bytes (141.6 KB, 46.39 dB), −5.7 ms of GPU a skipped picture; two screens in turn −0.15 %; scrolling, dragging, video, scrolling images and app switching skip nothing (streams unchanged); every picture new without long-term references +2.4 % | [entry](#metal-av1-no-motion-search-after-frames-whose-search-found-nothing-2026-11-11) |
| The shipped level model's 0.6 dB loss at q20 with `--ml-eps 0.05`, explained (`metal-av1`) | measured; not a bug | the model is confidently wrong (p(64) = 0.986) on 64x64s whose top rows hold one edge across a two-value area; for q18–20 only, every cell of such a 64x64 lands above 0.95, so at 0.05 it is searched as a 64x64 alone and rings (q19: 46.76 → 45.98 dB at the same bytes); the retrained weights don't (5K: −0.04 % / −0.09 % at 0.02, +0.24 % at 0.05 against +1.80 %); check any eps change with a q scan in steps of 1 | [entry](#metal-av1-the-level-models-q20-loss-at-eps-005-explained-2026-11-11) |
| Long-term references: up to N scenes' last pictures kept, GOLDEN_FRAME the one that matches best each frame (`metal-av1`, `longTermReferences`, `av1seq --long-term`) | kept, on (N = 4) | against N = 1 (today's rule): four traces in turn −49 % (2900) and −70 % (5K); app switching −33 %; tabs −0.9 %, windows −1.5 %, two screens in turn 0; finder time no higher (5K rotation 19.5 → 8–11 ms); +44 MB a slot at 5K | [entry](#metal-av1-long-term-references-golden_frame-the-stored-picture-that-matches-best-2026-11-11) |
| Where libaom's lead at q26–40 on the four-trace rotation at 2900 comes from (`metal-av1`, per-block counts) | measured; a reference policy is the lever | libaom keeps its key frame as GOLDEN_FRAME for the whole run and the rotation returns to its first trace every 4th picture; our GOLDEN is the picture before last; with GOLDEN kept on the key frame (a test) ours is −21.8 % against libaom at q20–40, and on the pictures libaom codes without GOLDEN ours is −20 % at every q | [entry](#metal-av1-where-libaoms-lead-at-low-rates-comes-from-its-long-term-reference-2026-11-11) |
| Palette blocks with a residual, chosen by real cost before the closed loop (`metal-av1`, branch `palette-residual`, `av1seq --palette`) | measured, not adopted; the owner's choice | −0.1 to −0.9 % BD-rate (2900 and 5K) for 4–7 ms more CPU a 2900 picture (inter frames a second 64–81 → 45–60 on new content); libaom's lead at q26–40 on new pictures is untouched (q40: 109.1 KB, 33.95 dB against its 124.4 KB, 35.55 dB) and so isn't its palette | [entry](#metal-av1-palette-with-a-residual-by-real-cost-measured-not-adopted-2026-11-11) |
| No motion search in inter frames that code more than a share of their 64x64s (`metal-av1`, branch `motion-rule`) | measured, not adopted | coded share doesn't tell new pictures from motion: at 0.5 the rotation saves ≈ 5.6 ms for +3.1 % (as with no motion search at all), but video codes > 97 % of its 64x64s every frame (+17 % / +21 %) and scrolling images ≈ 80 % (+426 %, 87 → 528 KB at q20); at 0.9 nothing is saved anywhere | [entry](#metal-av1-no-motion-search-on-mostly-new-pictures-by-coded-share-measured-not-adopted-2026-11-11) |
| Bytes for GPU time on new 5K pictures: no motion search; the learned pruning's thresholds; no 4x4s (`metal-av1`) | measured; the owner's choice, open | no motion search +3.1 % for 23.0 → 16.1 ms; `--ml-mode-eps` 0.05 / 0.10 +0.13 / +0.36 % for −0.7 / −1.3 ms; `--ml-eps` 0.05 +1.85 % (shipped weights) or +0.24 % (retrained) for −1.2 ms; no 4x4s +7.7 % for −2.1 ms | [entry](#metal-av1-the-analysiss-thread-kernel-and-the-learned-prunings-statistics-by-parts-2026-11-09) |

**Rate control and transport**

| idea | verdict | key number | entry |
|---|---|---|---|
| Global send governor (P6e) | kept | photos loop 63 → 17.1 Mbit | [entry](#p6e--global-send-governor--full-screen-region-snap-2026-08-07) |
| Auto send rate instead of a fixed 25 Mbit cap | kept | loopback rounds 2.35–3.98 s → 0.74–0.77 s | [entry](#auto-send-rate-replaces-the-fixed-25-mbit-ladder-2026-09-27) |
| Auto bounded by encode duty | kept | scroll v3 on a fast link: 392 → 62 MB, 220 → 51 s encode CPU | [entry](#auto-bounded-by-encode-headroom-2026-09-27) |
| Slow start, late-ACK delay samples, 32 KB/s floor | kept | thin-link rig: 8.4 MB/s → 224–350 KB/s on a 250 KB/s link | [entry](#tile-governor-on-thin-links-late-acks-loss-slow-start-2026-09-28) |
| RTT-aware tile start, smaller minimum burst, feedback-paced growth | kept | 2 Mbit/s, 175 ms RTT rig: first-round queue 1,986 → 529 ms, drops 27 → 0; LAN golden unchanged | [entry](#tile-governor-high-rtt-start-and-feedback-cadence-2026-10-22) |
| Pin the tile delay baseline while congested | rejected | full replay queue p95 still 1,999 ms; a 175 → 700 ms route change stays a false 525 ms queue | [entry](#tile-governor-high-rtt-start-and-feedback-cadence-2026-10-22) |
| Fresh tiles before owed tiles | kept | keystrokes no longer queue behind a dissolve repaint (live spikes were 0.6–1.8 s) | [entry](#fresh-before-owed-admission-video-cap-on-an-unmeasured-queue-2026-09-29) |
| Datagram pacing, then adaptive pace | kept | 6 loopback rounds ~28 s → ~11 s with 0 lost | [pacing](#datagram-pacing-burst-loss-at-the-viewers-receive-buffer-2026-09-27), [adaptive](#adaptive-datagram-pacing-2026-09-27), [cold start](#cold-start-phantom-loss-stale-send-stamps--pacer-overflow-2026-09-27) |
| Video send gate in time at the drain rate | kept | 3 Mbit/s relay: p50 1,900 → 53 ms | [entry](#video-send-gate-time-at-the-drain-rate-not-bytes-2026-09-28) |
| CUBIC-style video cap recovery | kept | back to 70 % in 2.0 s instead of 9.25 s | [entry](#video-cap-cubic-style-recovery-after-a-hiccup-2026-09-29) |
| 3 Mbit/s video cap until the link is measured | kept | p95 from connect 574–755 → 145–673 ms | [entry](#video-startup-3-mbits-cap-until-the-link-is-measured-2026-09-30) |
| Video gate cuts on a fresh PING queue reading too (growth on the smoothed one) | kept | 3M photos 9 → 58 frames; typing unchanged | [entry](#link-estimate-from-the-viewer-a-fresh-queue-and-a-capacity-ceiling-2026-10-25) |
| Viewer RECEIVED reports; video ≤ 0.9 × capacity from queued spans | kept | 10M photos 193 → 276 frames, queue p95 258 → 244 ms | [entry](#link-estimate-from-the-viewer-a-fresh-queue-and-a-capacity-ceiling-2026-10-25) |
| Capacity ceiling from every span (not only queued ones) | rejected | best latency on 30 s traces, but ratchets video to the floor on long video-only stretches | [entry](#link-estimate-from-the-viewer-a-fresh-queue-and-a-capacity-ceiling-2026-10-25) |
| Repaints yield to fresh tiles; cut video only for its own queue; bound by host-side delivery | rejected | little or no change; repaints yielding always raised typing-cc's q95 (3M 365 → 422 ms) | [entry](#link-estimate-from-the-viewer-a-fresh-queue-and-a-capacity-ceiling-2026-10-25) |
| Input → update latency measured on the Host | kept (diagnostic) | plane Wi-Fi: 11–94 ms per window against a 632–821 ms round trip | [entry](#input--update-latency-on-plane-wi-fi-the-link-not-the-host-2026-10-26) |
| Auto-scale on the viewer-reported link capacity | kept | lounge Wi-Fi at ~0.3 Mbit/s: neither older rule fired in 61 s; loop cursor-drag 17.2 → 7.2 s | [entry](#auto-scale-from-the-viewers-link-reports-2026-10-26) |
| Auto-scale on a thin measured video drain | kept | plane Wi-Fi: capture halved 45 s after connect; the video rule fires after 5 s of evidence | [entry](#auto-scale-from-the-video-drain-too-2026-10-22) |
| Tile records over QUIC streams | prototype removed 2026-10-13; issue #10 | no round converged within 30 s at 1–3 % loss | [entry](#prototype-tile-records-over-quic-streams-2026-09-27) |
| `NetworkConnection<QUIC>` (one tunnel) | not adopted 2026-09; issue #10 | async-only sends, no batch; datagram frame size read 0 | [entry](#networkconnectionquic-spike--not-adopted-2026-09-27) |

**Engine and build**

| idea | verdict | key number | entry |
|---|---|---|---|
| `-Ounchecked` on GlassActCodec | removed | within run-to-run noise (≤ 1 % p50) | [entry](#-ounchecked-on-glassactcodec--measured-dropped-2026-09-26) |
| In-place scroll, ACK walk, xxh64 fast path | kept | viewer scroll CPU 3224 → 1922 ms | [entry](#review-pass-section-5-performance-2026-09-26) |
| Present blit off the main thread | kept | Viewer main blocked 89–92 % → 0 % | [blit](#present-blit-off-the-main-thread-2026-09-27), [A/B](#live-ab-viewer-main-thread-same-machine-loopback-2026-09-27) |
| Carry skipped captures' damage forward | kept | fixes tiles left stale until touched; bytes unchanged | [entry](#stale-tiles-damage-from-skipped-captures-is-carried-forward-2026-09-30) |
| Hot-map churn keyed on hash changes, not "un-ACKed" | kept | 1 s RTT sessions converge; photos loop 14 → 9 regions | [entry](#high-rtt-convergence-hot-map-read-un-acked-as-churn-2026-08-10) |
| Allocation-free scroll path (preallocated signatures, votes, probe buffers; pooled marks) | kept | `maybeEmitScroll` 779–2,097 → 2 allocations per tick (the SCROLL `Data`); timing unchanged | [entry](#allocation-free-scroll-ticks-2026-10-18) |

## Removed bench commands

Experiment commands leave `glassact-bench` once their question is
answered; each result stays in the log.

- **2026-09-27:** `lossyscan`, `blockscan`, `svc` (with the libaom K-SVC
  shim in `ThirdParty/CAom`), `p2scan`, and the AVIF (`avifenc`) and
  JPEG XL (`cjxl`) branches of `keyframe`: their questions were answered
  (each tool's entry has the verdict), and they depended on a third-party
  shim and external encoders the product doesn't use.
- **2026-10-10:** the AV1 region encoder and decoder (the libaom shim),
  the AV1 size gate and `--video av1`, with AV1 itself: software AV1 needed
  a library-validation exemption in the Host, and hardware HEVC covers the
  role.
- **2026-10-13:** `routescan`, `analyze`, `scrollscan`, `cachescan`, the
  in-house predictor pass of `codecs`, `keyframe --lossy`, and
  `vquality --quality` and `--pts index` (with the encoder's `qualityHint`
  and its untimed `encode`): their questions were answered, and several
  exercised code paths that no longer exist (partial-screen regions, the
  codec ladder).

## Log

Newest first. Entries keep the names and numbers of their day: a later
entry may supersede an earlier one, and the decisions table above says
which.

### Metal AV1: a mostly-new picture coded fast and paid for in quality; level 1 on by default (2026-11-12)

The owner's order since today: speed (60 fps at 5K on a full-screen change) and bytes first;
quality is what can give, because a still screen settles to lossless tiles. So a lever that
costs BD-rate is paid in quality at the default's bytes, on the pictures that need the speed.
`AV1HybridEncoder.newPictureEffort` (`av1seq --fast <levers>|level=<n>|off`): an inter frame
coding more than half its 64x64s takes its own levers and qindex + Δ. The GPU's levers go to
that picture's analysis alone, the closed loop's are set for its closed loop and restored, and
"no CDEF" signals one all-zero preset. A stream that switches levers frame by frame decodes
exactly (`newPictureEffortMixesFastAndNormalPicturesExactly`).

**The frontier** (the rotation at 5K without long-term references, 15 mostly-new inter frames;
quality at the default's bytes, q 14 / 20 / 26 / 32; GPU from `--profile`'s stages, default
20.4 ms; CPU from `GA_CRIT`, default 148–160 core-ms):

| lever | GPU saved (ms) | CPU saved (core-ms) | ΔPSNR at equal bytes (dB) | BD-rate PSNR / SSIMULACRA2 |
|---|---|---|---|---|
| mode eps 0.05 | 0.9 | | −0.01 to −0.02 | +0.11 % / +0.02 % |
| level eps 0.05 | 1.0 | | 0.00 to −0.09 | +0.20 % / +0.11 % |
| mode eps 0.10 | 1.4 | | −0.03 to −0.06 | +0.39 % / +0.26 % |
| no motion search | 5.3 | ≈ 0 | −0.27 to −0.31 | +3.3 % / +3.2 % |
| no CDEF | the filters' 4.9 → 0.8 | | −0.20 to −0.25 | +2.6 % / +1.5 % |
| level eps 0.10 | 1.8 | | −0.27 to −0.50 | +4.5 % / +3.4 % |
| no 4x4s | 1.8 | 33 | −0.72 to −0.85 | +8.9 % / +6.7 % |
| no RDOQ | | 18 | −0.03 to −0.06 | +0.5 % / +2.1 % |
| no tx type search | | 33 | −0.64 to −0.69 | +7.6 % / +5.8 % |

Turbo2 and turbo3 change nothing in these pictures; whole-sample motion is free at 5K but costs
+243 % on scrolling images scaled to 2900; no 4x4s with no tx type search is +35 %.

**What the bytes do across content decides the level.** The motion search off is free on a
switch to video, scrolling images or app switching but +27 % on a switch between two text
screens (the search finds a sixth of the picture), and 13–35× at the start of a scroll unless
gated on the copy finder proposing no shift. No tx type search needs anything from +1 to +17 of
qindex to hold its bytes, by content. Level 1 is the levers whose bytes don't depend on the
content: level eps 0.05, mode eps 0.10, no RDOQ, no CDEF. Levels 2 (and no motion search where
no shift is proposed) and 3 (and no tx type search) stay as options.

**Level 1 by Δ and by how long a run takes it** (bytes / RGB PSNR / SSIMULACRA2 against the
mode off, over q 14–32; a run is mostly-new pictures in a row):

| content | every one, Δ+3 | every one, Δ+5 | every one, Δ+7 | a run's first only, Δ+3 |
|---|---|---|---|---|
| video, 2900 | −0.1 to +1.4 % · −0.55 to −0.62 dB | −2.5 to −0.3 % · −0.66 to −0.78 | −4.8 to −2.1 % · −0.74 to −0.94 dB · −1.7 to −4.9 | 0 % · −0.01 dB |
| scrolling images, 2900 | 0 to +3.8 % · −0.11 to −0.22 | −3.6 to +1.0 % · −0.25 to −0.35 | −6.8 to −1.5 % · −0.34 to −0.54 · −0.6 to −1.5 | 0 % · 0.00 |
| the rotation, 5K, all new | −0.5 to +1.6 % · −0.22 to −0.31 | −2.1 to −0.5 % · −0.33 to −0.50 | −3.7 to −1.6 % · −0.44 to −0.73 · −0.9 to −2.7 | 0 % · −0.02 to −0.04 |
| the rotation, 5K | −0.3 to +1.6 % · −0.14 to −0.21 | −1.4 to −0.1 % · −0.21 to −0.33 | −2.6 to −1.0 % · −0.27 to −0.50 · −0.4 to −1.3 | +0.1 % · −0.07 to −0.15 |
| two screens → scrolling images | +0.4 to +2.9 % · −0.04 to −0.11 | −2.0 to +1.0 % · −0.12 to −0.23 | −4.4 to −0.8 % · −0.19 to −0.34 · −0.4 to −1.6 | −0.1 to +0.8 % · −0.01 to −0.06 |
| typing → video | −0.7 to +0.6 % · −0.16 to −0.19 | −2.4 to −0.6 % · −0.19 to −0.24 | −4.1 to −2.0 % · −0.22 to −0.30 · −0.6 to −1.7 | −0.5 to 0 % · −0.01 |
| app switching, 5K | no mostly-new picture: the same stream | | | |

A soft picture stays soft in the stream: every return to its screen copies it exactly, and only
the tiles repair it. On video nothing does while it plays.

**The default: level 1 at Δ+7 on every mostly-new picture.** Δ+7 is the offset at which no
content measured costs more bytes than without the mode (−0.8 to −6.8 %); at +3 the bytes match
on average but rise up to 3.8 %. Every picture, not a run's first, because the speed is wanted
on each frame of a full-screen change that lasts, and by the owner's order quality gives first:
−0.2 to −0.9 dB, the most on video (`runLimit` would spare it). A new 5K picture at q20, the mode
off → on (two runs each, with `GA_CRIT`, the Mac at load 9): the GPU's stages 18.1 → 15.9 ms
(analysis 9.6 → 7.5: 16x16 1.79 → 1.15, 32x32 2.46 → 1.96, 64x64 2.35 → 1.78), the filters' GPU
4.1–4.7 → 0.7–0.9, the closed loop's blocks 120–122 → 106–109 core-ms, and 35.4–36.0 → 42.9–43.3
inter frames a second. Not measured: the picture after a fast one filters the whole picture and
rebuilds the analysis cache (its qindex differs).

The reference digests (the rotation, `--tiles 3x0 --inter --no-planes`), with `--fast off` → the
default now: 5K q20 24 frames `--no-golden` `5e1030c7429bc420` → `cf4d6ebc3490e6b3`; 5K q20 8
frames `ab40bdf3a13fcbad` → `39d5541a9eae08a5`; 2900 q32 `33c3d884c3d0ca8c` →
`f129f7f2b94391bd`; 5K q8 `eba158d3c2d7881f` → `1fd80abca3e35c82`; 1280 q20 `862da50b8c92dbed`
→ `be5861165c862b42` (each the same with its pictures decoded).

### Metal AV1: the analysis's scratch by shape, 16x16 and 64x64 on the matrix units (2026-11-12)

GPU stage times, alternated against the previous build; the same streams (the five digests, key
frames at q14 and at q32 with turbo2, video and an IDE at 2900, scrolling images at 5K).

**Where the analysis's time was** (a new 5K picture; by stage switched off): 16x16 2.16 ms =
screening 0.93 + the one candidate's RD 0.65 + set-up, edges and exits ≈ 0.3; 32x32 2.62 = 1.13
+ 0.91 + ≈ 0.5; 64x64 2.43 = 1.34 + 0.66 + ≈ 0.35. Every shape carried the 64x64's 160-byte
edges and the edge filter's prepared edges, and 32x32 a 4 KB copy of the DCT matrix. Learned
pruning 1.77: `k_ml_stats` ≈ 0.88, `k_ml_mode` ≈ 0.45, cells and tree ≈ 0.25, the lists ≈ 0.2.
Leaves 3.06: `k_leaf_small` ≈ 1.08, `k_leaf` ≈ 1.97, of which the chroma modes' screening ≈ 1.45.

**Kept:**
- **Each shape's scratch holds only what it uses** (`fa9d344`): edges as long as the shape reads,
  the levels written over the residual where a side is 32 or 64, the DCT matrix read from a
  device buffer filled once an encoder. Threadgroup memory: 4x4 4480 → 2256 bytes, 8x8 6080 →
  3984, 16x16 12352 → 5248, 32x32 13392 → 6912, 64x64 19536 → 17168. 16x16 2.16 → 1.96 ms.
- **16x16 and 64x64 forward DCTs on the matrix units too** (`7697e01`), now that the matrix
  isn't a threadgroup copy (that made them slower on 2026-11-11). The start-up check runs all
  three sizes against the passes each shape would otherwise use; all match or none is used.
  16x16 1.96 → 1.87, 64x64 2.43 → 2.35.
- **Screening a candidate of exactly 32 4x4s a lane a 4x4** (`f18fcd7`): 32x32 2.55 → 2.47.
- **`k_analysis_16x16` with two SIMD-groups a threadgroup, not four** (`ae846dc`): 1.87 → 1.79.

A new 5K picture: analysis 10.2 → 9.5–9.6 ms (16x16 2.16 → 1.79, 32x32 2.62 → 2.46, 64x64 2.42
→ 2.36); 5K key frames (`--no-reuse`) 26.1 → 24.8; a 2900 stream 4.1 → 4.0.

**Measured, not kept:** `warp_screen`'s subsampling as a template parameter (−0.02 to −0.03); a
lane a 4x4 for 64x64's 128 (2.35 → 2.39); `k_leaf` reading each chroma 4x4 once for all its
modes (3.06 → 3.18) or with no threadgroup memory (3.09); the learned pruning's passes in
threadgroups of 32 (no change); 32x32 on 256 threads (2.46 → 3.53). **64x64 on 256 threads** is
2.35 → 2.08 with the reference digests unchanged, but its float sums then split over 256
threads, so a near tie could fall the other way on other content: not kept. Screening on 256 and
the RD on 128 would keep the sums.

### Metal AV1: the motion search and inter candidates, the same bytes in two thirds of the time (2026-11-12)

GPU stage times (`--profile`, best of 10, each run under the timing lock; they held to ±0.05 ms
on a loaded Mac), alternated against the previous build. The same streams: the five digests,
and video, scrolling images, dragging and app switching at 2900 (q14, q26, and `--no-subpel`)
and at 5K, against the previous build's.

**Where the time was** (the rotation's new 5K picture, each kernel in its own command buffer).
Motion search 2.50 ms: `k_proj_sums` 0.10, `k_proj` 0.66, `k_me` 1.24 (0.58 even when every cell
stops at its gate), `k_inter_sad` 0.50. Inter candidates 2.70: the four squares, 8x8 1.05, 16x16
0.53, 32x32 0.70, 64x64 0.46, and with every block stopped at the gate still 1.79: a SIMD-group
a block waiting on a chain of dependent table reads, and the 128-thread shapes' barriers. The RD
itself was ≈ 0.9. On moving content the cost is `k_me`: 5.1 ms on video, 7.5 on scrolling images
(its sub-sample steps ≈ 2.7 there).

**Kept:**
- `k_inter_sad`'s distinct candidates listed on 32 lanes, not one thread (`5140250`): 0.50 → 0.42.
- `k_me`'s gate centres each measured across the SIMD-group (`7af6e37`): 1.24 → 0.99.
- `k_inter` with a threadgroup scratch of its own, not the analysis's (`43e4563`): 8x8 6.1 →
  2.4 KB a threadgroup, 32x32 13.4 → 8.4; 16x16 0.52 → 0.42, 32x32 0.70 → 0.60.
- `k_inter`'s shapes up to 16x16 several blocks a SIMD-group up to the gate (8 for 8x8, 4 for
  the others), the blocks that pass then on the whole SIMD-group as before (`b5c4c95`): 8x8
  1.05 → 0.33, 16x16 0.42 → 0.28.
- Its larger shapes a block a SIMD-group up to the gate, without barriers, then the RD on all
  the threads with the same float sums (`4a04470`): 32x32 0.60 → 0.45, 64x64 0.46 → 0.39.
- `k_me`'s sub-sample steps read the reference from an 18x18 window in threadgroup memory
  (`b6fa0bf`): video 5.10 → 4.88, scrolling images 7.46 → 7.14.

| a new 5K picture (medians of 3 alternated pairs) | motion search | inter candidates |
|---|---|---|
| the rotation, `--no-golden` | 2.54 → 2.19 | 2.73 → 1.33 |
| video, 30 frames | 8.17 → 7.52 | 5.94 → 4.47 |
| scrolling images, 30 frames | 8.95 → 8.48 | 3.54 → 1.87 |

Checked on the merged head: the rotation 2.51–2.53 → 2.16–2.18 and 2.70–2.78 → 1.31–1.35; video
(16 frames) 6.31 → 5.78 and 5.23 → 3.75; scrolling images 9.52 → 9.12 and 3.40 → 1.75. The GPU
stages on a new 5K picture now: motion search 2.17, inter candidates 1.34, analysis 10.2,
partition 0.2, leaves 3.05, learned pruning 1.77, ≈ 18.7 ms (≈ 20.5 that morning; the analysis
is 0.5 above the day before with the retrained weights), and the filters' ≈ 4.

**Measured, not kept:** `k_proj`'s candidate SADs across the SIMD-group (0.666 → 0.673), its
strips summed on all 256 threads (0.71), three projection offsets a thread (0.74, and other
bytes: its float costs differ); `k_me`'s window search stopping a lane that can't make the best
two (no change), unaligned packed loads of the reference (7.46 → 8.59 on scrolling images).

**A trade, measured:** whole-sample vectors only (`--no-subpel`) take ≈ 2.5 ms off the motion
search on moving content at 5K (video 7.5 → 5.0, scrolling images 8.5 → 6.0) for +0.5–0.6 % of
video's bytes at the same PSNR and nothing on scrolling images (three q, PSNR only).

Left: on moving content `k_me`'s window search (≈ 4.4 ms on scrolling images) and sub-sample
steps (≈ 2.4); `k_proj` (0.66), which resisted three tries.

### Metal AV1: the closed loop's reconstruction in 32x32 groups, handed on as the plan walks (2026-11-12)

The closed loop's scheduler, on the all-new stream (the rotation at 5K q20, `--no-golden`). The
Mac was in use and oversubscribed throughout (load 20–50; tasks' wall 1.5× their thread CPU), so
the wall figures say little and the structure's are in thread CPU.

**What the ready queue looked like** (`GA_CRIT` with queue tracing added): a new 5K picture was
64–121 thousand single-block tasks of ≈ 2 µs through one shared queue, so the per-task overhead
rivalled the work (≈ 36 ms of CPU a picture inside the loop but outside tasks and idling; the
tracing's own ≈ 250 ns a task is in that). The queue was rarely empty (20–10,000 ready in
mid-picture) with ≈ 11.5 of 14 threads running; for the first 10–15 % of the wall only the 8
plans ran; and on 2 pictures of 3 the loop's threads joined 3–8 ms late, held by the pool's
earlier job, the overlapped writer's tile coding.

**Kept** (`7a89b44`): a task is the blocks of one 32x32 (or one larger block), run in walk order
on one thread, waiting only for the earlier groups its blocks read; and the plan hands each group
on as its walk closes it, not after the whole tile (a tile the plan could reject still waits for
its walk). The same streams: the five digests, a 60-frame stream, `--tiles 2x2`, and video,
scrolling images and app switching at 2900 against the previous build, each two or three times;
`split_schedules_are_the_walks_under_stress` compares the outputs with the one-pass walk over
2–32 threads and groups from one block to 128x128. Rust tests 62, with the oracle 132; AV1 31.
ThreadSanitizer was not run (the nightly's build-std fails here).

| group, by `GA_CRIT`, 3 runs | critical path in thread CPU (ms) |
|---|---|
| one block, the plan first (as before, under the new locks) | 9.3–11.2 |
| 64x64, the plan first | 8.5–10.5 |
| 64x64, handed on as walked | 7.7–8.9 |
| **32x32, handed on as walked** | **5.6–7.1** |

Six alternated pairs with `GA_CRIT` (which overstates the old tasks' cost): the closed loop's
wall 26.0 (19.6–34.0) → 18.7 (16.6–29.6) ms, busy cores 6.9 → 8.45, the blocks' thread CPU
130.0 → 108.9 core-ms, all workers 172.9 → 131.0. Without it: the whole bench's user CPU 9.29 →
8.77 s over 24 frames in each of 4 pairs (≈ −21 ms of CPU a picture), and the closed loop's wall
and the frames a second inside the day's noise (22.3 → 23.9 ms over 10 pairs; my own 5 pairs at
load 53: 14–30 → 12–35 inter frames a second, meaningless). The structure now allows ≈ 6.5 ms
of critical path over ≈ 110–125 core-ms of work, 8–9 ms on 14 cores; what the wall is on a quiet
Mac is to be measured.

**Not done:** a spin-then-park idle policy (with 25× fewer queue operations the old result,
yield beats sleep, may change; `GA_IDLE` is there to measure it), and the pool's order: the
loop's late threads are workers the writer's tile coding holds, so a priority for the closed
loop's job moves wall time from the loop to the writer.

### Metal AV1: the closed loop's RDOQ contexts, residual pass and edges, the same bytes (2026-11-12)

The second round on the closed loop's CPU (the profile is two entries below). Thread CPU a
picture (`GA_CRIT`), the all-new stream's 23 inter frames (the rotation at 5K q20,
`--no-golden`), binaries alternated; the Mac was in use, so no wall times. The same streams
(today's five digests, a 60-frame stream, and two with their pictures decoded); Rust tests 61,
with the oracle 131; AV1 tests 31; the crate still checks for x86_64.

**Kept:**
- **RDOQ's contexts with the tx class a constant, each neighbour read once** (`8edc4e4`).
  `optimize` is specialised by class; the magnitude context's 3 offsets are the first 3 of the
  significance context's 5 in every class, and the level map already holds min(|level|, 15), so
  a coefficient's neighbours are read once for both. Cost rows are sliced once a block, and the
  end of block is found from the back. The old function stays as `optimize_ref`, and
  `optimize_matches_the_reference` compares them on 60 k random blocks of every size, type,
  plane, quantizer, gain and lambda. Per call: 4x4 97 → 61 ns, 8x8 270 → 153, 16x16 676 → 348,
  32x32 2234 → 1226. The blocks' CPU 147.0 → 138.1 core-ms a picture (per frame ×0.946).
- **A tx block's residual, energy and source span in one NEON pass** (`ba6ed1a`): the span RDOQ's
  check read in a second pass comes from the residual's, and `skip_if_cheaper` reuses the energy
  (the same integer). Scalar reference kept (the path off aarch64), compared on 20 k random
  blocks. 4x4 7.3 → 4.0 ns, 8x8 22 → 11, 16x16 81 → 34, 32x32 unchanged.
- **`build_edges`' copies and fills in fixed-size pieces** (`c0879ce`): two fixed-size copies
  that may overlap instead of a memmove or memset call (16x16 21.1 → 15.1 ns, 32x32 34.0 → 20.8,
  4x4 unchanged). In the encoder its share didn't move (small blocks dominate, and the left
  column's strided reads are the cost); kept as the same bytes for less work at the large sizes.

Together, 4 alternated rounds: the blocks' CPU 148.0 (144.0–153.0) → 136.9 (134.9–139.6)
core-ms a picture, −7.5 % (per frame ×0.915); all workers 197.1 → 190.5 (idle threads spin
more). Checked on the merged head, three runs each, not alternated: 138.7 / 148.8 / 150.1 →
139.8 / 140.9 / 142.3.

**Measured, not kept:** RDOQ skipping a coefficient whose added distortion is at least λ times
a bound on the bits lowering it could save. The same bytes, and 4x4 119 → 50 ns in isolation,
but in the encoder the blocks' CPU rose 4.6–4.7 % per frame, twice.

The profile after (≈ 186 core-ms of workers): forward transform 27.3, RDOQ 24.0 (16.8 → 12.9 %),
intra prediction 21.6, reconstruction 16.7, plan and walk 16.4, spinning 15.4, `on_txb` 13.8,
the quantizer 12.5, yielding 9.4, `trial` 9.2. Next by size: the scheduler's ≈ 25 core-ms of
spin and yield (the plan handing blocks on as it walks, not ≈ 3 ms a tile up front), RDOQ's
level-map clear and division, the left column's gather in intra prediction, zero rows and
columns in the inverse transform.

### Metal AV1: the motion-search skip after a switch, measured; off by default again (2026-11-12)

`av1seq --then <trace>[:<frames>[:<skip>]][,...]` (`60eb233`) continues a stream with another
trace's pictures, so a change of content can be measured: the case the entry of 2026-11-11 left
open. At 2900, `--tiles 3x0 --inter`, 24 pictures, then 12 of the next content.

- **Typing never makes 0.2,8 skip** (its search finds 62–100 % of its small coded area), so
  typing → video, scrolling images or dragging are the streams of `off`, byte for byte, at q
  14–32; so are tabs, an IDE, maps and photos alone. The quiet stretches where it skips are
  whole-screen switches: two screens in turn, and the rotation.
- **Two screens in turn → video**: it skips 6 of the first 7 frames after the switch. The 12
  frames, off → 0.2,8: q14 1174.6 → 1219.4 KB (+3.8 %), q20 892.9 → 933.1 (+4.5 %), q26 677.6 →
  713.6 (+5.3 %), q32 480.7 → 510.7 (+6.2 %), at the same quality within 0.1 dB.
- **Two screens in turn → scrolling images, q14**: 1902 → 4720 KB over the 12 frames (+148 %).
  Frames 25–28 and 30 skip the search and cost 664–666 KB each against 71–136: nothing but the
  search finds a scroll of new images at a fraction of a 64x64.

And where it skips, it saves little: the search's cost follows the coded share, and the frames
it skips on the rotation (83 % of 64x64s copied) and on two screens (97 %) code little. The
5.7 ms of the earlier entry is an all-new picture's, and the all-new content measured (the
rotation without long-term references, video, scrolling images) finds motion worth its bytes.

**`motionSkip` is nil by default again** (the owner had it on at 0.2,8 from 21e60fc, on my
summary that it lost nothing; it loses +2.4 % without long-term references and the above). The
reference digests, with it on → the default now: 5K q20 24 frames `--no-golden`
`a61cee2cbf8df351` → `5e1030c7429bc420`; 5K q20 8 frames `384e81d2e4ff2b62` →
`ab40bdf3a13fcbad`; 2900 q32 `68beb6c1416c3fa9` → `33c3d884c3d0ca8c`; 5K q8 `6336ccaac1b0e59c`
→ `eba158d3c2d7881f`; 1280 q20 `2b2204ec80f2134d` → `862da50b8c92dbed`. `--motion-skip 0.2,8`
gives the left ones.

**A probe instead of a blind skip, built, not merged** (branch `motion-probe`, `2b77801`,
`6a7e557`): a skipped frame searches a moving 1-in-8 sample of its coded 64x64s; the signal is
the share of the picture motion predicts (not of the coded area, which reads 84–100 % on typing);
a frame coding at most 1/16 of its 64x64s searches them all. A searched 64x64's results don't
depend on which others search, and the sample estimates the full share within a point on the
rotation (video 25.5 against 34.4 at worst). At 0.02: the rotation −0.04 to −0.07 %, the
rotation without long-term references, two screens, scrolling, dragging, video, scrolling images
and app switching identical to off. A 1/8 probe of an all-new 5K picture costs 1.68 ms of the
search's 5.2 (k_inter still runs over every coded 64x64: ≈ 0.7 if it took the list). But it
probes only 2–3 of the rotation's 15 frames, and the frames where the search is dear are ones no
lossless rule should probe. Its transitions were not finished. The search's cost on new
pictures has to come from the search, not from skipping it.

### Metal AV1: RDOQ off on 4x4 tx blocks, re-measured, kept off (2026-11-12)

`AV1HybridEncoder.rdoqMinCoefficients` (0, the default: every tx block; 17: not the 4x4s),
`av1seq --rdoq-coeffs <n>`. The trade from the closed loop's profile below, measured again on
today's defaults (the retrained weights, the motion-search skip, key frames −16) and on more
content. BD-rate of 17 against 0, q 8–32, RGB PSNR / SSIMULACRA2 (every 3rd frame):

| content | BD-rate | at q20: bytes a frame · PSNR · SSIMULACRA2 |
|---|---|---|
| the rotation, 5K, 12 frames | −0.15 % / +0.22 % | 178.0 → 178.5 KB · 45.07 → 45.11 · 77.82 → 77.83 |
| the rotation, every picture new (`--no-golden`) | −0.20 % / +0.22 % | 558.1 → 559.5 KB · 44.74 → 44.78 · 77.37 → 77.36 |
| two screens in turn, 2900, 30 frames | −0.16 % / −0.17 % | 17.8 → 17.8 KB · 43.93 → 43.97 · 78.01 → 78.00 |
| an IDE, 2900 | +0.39 % / +0.66 % | 8.0 → 8.1 KB · 47.66 → 47.70 · 79.63 → 79.69 |
| browser tabs, 2900 | −0.17 % / −0.03 % | 16.8 → 16.8 KB · 45.18 → 45.21 · 78.61 → 78.76 |
| video, 2900 | −0.11 % / 0.00 % | 66.0 → 66.0 KB · 46.77 → 46.77 · 75.66 → 75.61 |
| scrolling images, 2900 | +0.06 % / +0.19 % | 87.7 → 87.7 KB · 38.78 → 38.78 · 75.42 → 75.43 |

The closed loop's thread CPU a picture (`GA_CRIT`'s plan + blocks, the inter frames' median, 3
alternated runs), every picture new at 5K: q14 189.3 → 185.6 core-ms (−2.0 %), q20 185.0 → 180.3
(−2.5 %), q26 180.7 → 163.0 (−9.8 %).

Within ±0.2 % on six contents, but +0.4 % / +0.7 % on the IDE (small text, where 4x4s carry
the most), for 2.5 % of the closed loop's work at q20: about half a millisecond of the period.
The owner asked for both bytes and speed, so it stays off, and the work goes into RDOQ's own
cost with the same levels (its contexts are ≈ 28 core-ms a picture).

### Metal AV1: learned pruning's weights retrained on eleven traces, installed (2026-11-12)

The weights of 2026-11-09's retraining (`scripts/train-pruner`, the eleven traces of
`scripts/pruner-traces.txt`; the shipped ones knew the first four), installed on the owner's
word. They are the ones whose level model doesn't narrow an edge over a two-value area to 64x64s
alone (the q18–20 loss at eps 0.05, below). `scripts/train-pruner compare` at `21e60fc` (today's
defaults), each trace's test frames (0–109), BD-rate over q 8–32 by RGB PSNR, new against
shipped:

| trace | key frames | stream | key ms shipped → new | inter frames a second shipped → new |
|---|---|---|---|---|
| typing-cc | −0.11 % | 0.00 % | 61.1 → 47.7 | 349 → 368 |
| scroll-win | −0.06 % | −0.01 % | 45.6 → 46.7 | 289 → 273 |
| photos | +0.02 % | +0.02 % | 78.3 → 75.6 | 110 → 106 |
| cursor-drag | +0.07 % | +0.43 % | 45.3 → 47.8 | 366 → 319 |
| movie | +0.90 % | +0.25 % | 42.4 → 43.4 | 36 → 37 |
| app-switch | −1.31 % | −1.20 % | 36.9 → 37.2 | 338 → 336 |
| tabs | −0.70 % | −0.88 % | 42.6 → 42.5 | 364 → 359 |
| window-open-close | −0.04 % | +0.04 % | 48.9 → 49.0 | 333 → 206 |
| ide | +0.09 % | +0.02 % | 39.4 → 37.0 | 311 → 306 |
| maps | +0.16 % | −0.03 % | 77.2 → 70.7 | 260 → 220 |
| images-scroll | +0.03 % | +0.03 % | 75.6 → 75.8 | 240 → 238 |

The speed columns were taken with the Mac in use and loaded (the script's wait for a locked
screen bypassed, each run under the builders' timing lock), so they say nothing: the same binary
varied more than these differences that day. The earlier measurement stands until a quiet run:
at eps 0.02 the new weights keep more 16x16s and up, GPU analysis 23.0 → 23.8 ms on a new 5K
picture (2026-11-11). The tx type model's weights (off by default) were installed with them.

The reference digests (the rotation, `--tiles 3x0 --inter --no-planes`), before → now: 5K q20 24
frames `--no-golden` `fd2a0aa931bf1402` → `a61cee2cbf8df351`; 5K q20 8 frames `0ebbbcdad618169b`
→ `384e81d2e4ff2b62`; 2900 q32 `6ebac49593108b54` → `68beb6c1416c3fa9`; 5K q8
`0138e10a56d8cc66` → `6336ccaac1b0e59c`; 1280 q20 `2b2204ec80f2134d`, unchanged (no learned
pruning under 900 superblocks). AV1 tests 31, Rust 58.

### Metal AV1: the partition read as its analysis ends, the analysis behind the filters; a reference the closed loop overwrote (2026-11-12)

The all-new stream (the rotation at 5K q20, `--no-golden`, 24 frames, `--motion-skip off
--key-delta 0`). Timings are provisional: the Mac was in use and loaded throughout (the same
binary's closed loop read 15–40 ms a picture between runs), so they are alternated runs' medians.

**The waits** (`GA_TIMELINE`). Picture N+1's analysis finished on the GPU about 10 ms before the
encoder's thread read it, after picture N's filters; the read (2.5–3 ms) was on the chain; and
picture N+2's analysis waited for that read (`readEvent` protects the analysis cache's shared
results and the learned pruning's scratch, which the read takes on the CPU and the next analysis
overwrites), so it started at the next closed loop's start and ran into the filters' turn.

**Kept, the same streams** (the five digests and 60-picture streams with and without long-term
references, repeated; AV1 tests 31):
- **Each partition is read on a thread of its own as soon as its analysis ends**, in order, and
  **picture k's analysis also waits on the GPU for picture k − 2's filters**
  (`AV1MetalEncoder.gate`, `e2051e2`). One commit: the read alone moves the next analysis ahead
  of the filters on the GPU and is slower than before (31.1 against 32.2 inter frames a second,
  the filters' wall 6.5 → 7.5–8.4 ms). A stream that stops opens the gate before it waits for
  its readers; `aStreamThatStopsEarlyLeavesTheEncoderAsNew` checks it ends promptly.
- **An inter frame's motion applied by the partition's reader**, and **a long-term picture
  copied out beside the closed loop**, not between it and the filters (`8c2e94d`): 0.5–0.6 ms
  and 0.5–2 ms off the chain.

| 6 alternated runs | inter frames a second, median | range |
|---|---|---|
| before | 33.1 | 32.4–34.6 |
| the read and the gate | 34.5 | 33.4–35.4 |
| and the motion and the copy | 35.0 | 34.3–35.4 |

`GA_TIMELINE` medians, before → after: from the filters' end to the next closed loop 3.0 →
0.25 ms; the period 31.2 → 29.5; the closed loop 18.4 → 20.6 (the reader's ≈ 3 ms of a core and
the copy now run beside it; the reader's QoS, userInitiated against userInteractive, made no
difference: 34.9 against 35.0); the filters' wall 6.5, the analysis's GPU span 20.7, unchanged.
The GPU is busy 24.7 ms a picture and idle ≈ 4.6 (6.2 before). On the merged head in two
quieter runs: 34.4 → 36.9–37.2 inter frames a second, and 40.5 with today's defaults (the
motion search skipped in 18 of 23 frames of this stream, at its +2.4 %).

**Not built: the next closed loop starting before the filters end.** The closed loop is a
per-block task graph, so blocks that predict from LAST could wait on a "LAST is filtered" signal
while intra blocks and GOLDEN_FRAME's run. It needs the record's lifetime split, the filters'
reconstruction buffers alternating, and the CDF-from-reference decision kept in order. It would
recover the ≈ 5.5 ms the closed loop's threads idle through the filters, but the GPU's 24.7 ms
a picture bounds it at ≈ 3.5 ms: ≈ 35 → ≈ 40 inter frames a second, GPU-bound from there.

**A reference the closed loop overwrote, fixed** (`fb70023`; found by this work, older than it).
At qindex 32 and under there is no CDEF, so the filters' output is the buffers they deblocked in
place, the ones the next inter frame is reconstructed into. A stream coded without its pictures
handed back (`returnsPlanes` off, `av1seq --no-planes`, which isn't decode-checked) reads its
reference there: its closed loop predicted from samples it had overwritten, and the long-term
slot kept afterwards held the new picture. The 5K q8 digest used as a reference since 2026-11-11
(`c941eb17e507be34`) was such a stream. The closed loop now takes a copy first where the buffers
coincide; that stream has the bytes of the decode-checked one, `3cb48e1107bd8f63` (today's
defaults: `0138e10a56d8cc66`, with and without planes), and no other digest moved.
`aStreamWithoutItsPicturesHasTheSameBytes` codes two screens in turn both ways at qindex 24 and
fails without the fix. Byte checks at q8 and under before this used a wrong stream; nothing at
q above 8 was affected, except that a key frame coded finer than qindex 33 (today's −16 at q 9–12)
would have met it.

### Metal AV1: the closed loop's CPU on new pictures, by function; byte-identical cuts (2026-11-12)

The all-new stream (the rotation at 5K q20, `--no-golden`, 24 frames, before the defaults of the
entry below), the writer overlapped. The Mac was heavily loaded throughout (load 37–56), so the
measure is thread CPU a picture (`GA_CRIT=1` now prints a `cpu:` line, `3614d03`), and wall times
are provisional.

**Where it goes**, per picture: the tile plan 16.5 core-ms, the blocks ≈ 160, all workers ≈ 215
(the other ≈ 38 is the ready queue spinning and yielding). About 8.3 cores do work over a
≈ 20.5 ms wall, 1.8 more spin or yield, of 14. The critical path is 8.7–9.9 ms (the plan 3.1 of
it) against the 19–20 ms wall: work-bound today, but at 10 ms the path would bind too. By
`sample` (25.7 k samples, scaled to 215 core-ms):

| stage | share | core-ms |
|---|---|---|
| tx hook: RDOQ | 12.8 % | 27.6 |
| tx hook: forward transform | 12.4 % | 26.7 |
| tx hook: `on_txb` (residual, energy, span check, search loop, copies) | 11.4 % | 24.5 |
| intra prediction (`build_edges` and its copies ≈ 5 %, predictors, CfL) | 9.4 % | 20.1 |
| tx hook: `trial` (bounds, transform-domain distortion) | 9.1 % | 19.6 |
| scheduling: yield | 8.6 % | 18.4 |
| reconstruction (dequantize, inverse, add) | 7.7 % | 16.5 |
| scheduling: spin | 7.2 % | 15.4 |
| plan and walk (syntax, partition, tx blocks) | 6.6 % | 14.3 |
| tx hook: quantizer | 5.7 % | 12.3 |
| reconstruction bookkeeping | 3.1 % | 6.6 |
| inter prediction, walk levels, rate proxy, other | ≈ 6 % | ≈ 13 |

No single hot spot: the hook is 53 %, in five parts.

**Kept, the same streams** (the five digests with `--motion-skip off --key-delta 0`, and the
defaults' five; Rust tests 58, with the oracle 128; AV1 tests 29):
- RDOQ's source span checked only where RDOQ would run, and never for all-zero levels (`33dd4d9`).
- RDOQ's level map kept per thread, only the block's rows and padding cleared: a 4x4 clears 64
  bytes, not 1.3 KB (`7a15aec`).
- The transform-domain distortion's sum skips all-zero groups of 8 levels (`06c6d60`). A zero
  level adds exactly +0 and the sum is never −0, so it is the same float sum in the same order;
  `td_taken_matches_the_reference` checks it bit for bit. 16 coefficients 9.1 → 4.4 ns, 64:
  29.1 → 17.6, 256: 89 → 66 (1024 at uniform density 348 → 365). `trial`'s own share 10.5 → 4.6 %.
- A tx block's residual energy summed in u32 (at most 64 × 64 × 255² < 2²⁸), so NEON adds 4 lanes
  (`5be370d`).

Together, 4 alternated pairs: the blocks' thread CPU 160.2 (158.4–162.5) → 154.6 (153.5–155.9)
core-ms a picture, −3.5 %, the ranges apart; the closed loop's wall 21.1 → 20.6 ms, inside the
noise of a loaded Mac.

**Measured, not kept (same bytes):** a tighter all-zero bound for IDTX, V_DCT and H_DCT (blocks
159.1 → 163.4: IDTX's transform is one multiply already); the quantizer by reciprocal multiply
with an exact fallback (4x4 12 → 17 ns, 32x32 659 → 1155: the f64 divide is cheap here); the
ready queue's idle loop without its yield (blocks 155.4 → 159.2, wall 20.8 → 22.2).

**Trades, measured for the owner, not taken** (24 frames, q 14 / 20 / 26 / 32, BD-rate PSNR-Y /
RGB / SSIMULACRA2 against the switch off; one run a point, the core-ms ± 5 %):

| trade | BD-rate | plan + blocks, core-ms at each q |
|---|---|---|
| no RDOQ on 4x4 tx blocks | −0.18 % / −0.28 % / +0.40 % | 182 / 173 / 161 / 150 → 167 / 163 / 158 / 147 |
| no RDOQ below 256 coefficients | −0.13 % / −0.14 % / +0.84 % | → 159 / 158 / 136 / 145 |
| no tx type search on 4x4 tx blocks | +6.4 % (PSNR-Y) | → 170 / 160 / 150 / 140 |

**What 10 ms needs.** The work is ≈ 171 core-ms a picture. Byte-identical headroom looks like
another 10–15 % (NEON for RDOQ's contexts, `build_edges`' copies, the residual and span passes,
the walk's bookkeeping): ≈ 140–150 core-ms, 12.5–13.5 ms on 13 cores. 10 ms is ≈ 110 core-ms,
−35 %: trials traded away (`--no-tx-search` alone was 18.5 → 10.9 ms at +8.9 %), or RDOQ's scope.
The plan (≈ 3 ms on the critical path before any of its blocks start) would also have to hand
blocks on while it walks.

### Metal AV1: the motion-search skip and finer key frames on by default (2026-11-12)

The owner's choices on the two entries of 2026-11-11 below. Nothing new is measured here beyond
the digests.
- (Reverted the same day: see "the motion-search skip after a switch" above.)
  `AV1HybridEncoder.motionSkip` defaults to (0.2, every 8th). `av1seq --motion-skip off` gives
  every inter frame its search back. Its one measured cost stands: +2.4 % where every picture is
  new and nothing is copied (the rotation with `--no-golden`), for −5.7 ms of GPU on a skipped
  picture; no bytes on the default rotation, two screens, scrolling, dragging, video, scrolling
  images or app switching.
- `keyFrameQindexDelta` defaults to −16, and now applies to a stream's key frames only (with
  `interFrames`): a picture coded alone takes the qindex given, since nothing copies it, so key
  frame benchmarks keep their q. −16 over −32 because −32 clamps to qindex 1 at q8 (a 2.6× key
  frame, above libaom's) and a key frame's size is latency on a start or a repair; −16 keeps
  1.1–1.4× and over half of −32's gain. `av1seq --key-delta 0` is the old behaviour.

The reference digests (the rotation, `--tiles 3x0 --inter --no-planes`), old → new; the old ones
reproduce with `--motion-skip off --key-delta 0`:

| run | before | default now |
|---|---|---|
| 5K q20, 24 frames, `--no-golden` | `c2b0b3bda5f8a1fd` | `fd2a0aa931bf1402` |
| 5K q20, 8 frames | `7c17df5c516aab0d` | `0ebbbcdad618169b` |
| 2900 q32, 8 frames | `043b6b1e2c0a51cc` | `6ebac49593108b54` |
| 5K q8, 8 frames | `c941eb17e507be34` | `4f0de8dd64aa48d9` (both from streams the entry above found wrong: `3cb48e1107bd8f63` and `0138e10a56d8cc66` since) |
| 1280 q20, 8 frames | `2dd0679554ec9fee` | `2b2204ec80f2134d` |

### Metal AV1: matrix units for the 32x32 DCT, less threadgroup memory for the pruning, and where the period goes (2026-11-11)

Measured with nobody connected (screen locked), every timed run serialized by a lock. The
all-new stream is the four-trace rotation at 5K q20 with `--no-golden`, 24 frames, so each
picture is new against the one before it. Streams unchanged: `c2b0b3bda5f8a1fd` (that stream),
`7c17df5c516aab0d` (5K q20), `043b6b1e2c0a51cc` (2900 q32), `c941eb17e507be34` (5K q8),
`2dd0679554ec9fee` (1280 q20). The AV1 tests (29) and AV1Core tests pass.

**Where the period goes on all-new pictures** (`GA_TIMELINE=1`, medians over 14 pictures, builds
running beside it): 30 ms a picture = the closed loop 19.5 + the filters 6.5 (wall, waiting
behind the next analysis on the GPU) + about 3 to read the analysis and run the partition. The
next picture's GPU analysis (20 ms) runs beside the closed loop. So the period is the serial
chain closed loop → filters → partition → closed loop, not the GPU's throughput: GPU time saved
shows up only where the analysis ran past the closed loop into the filters' turn. The filters'
`(GPU x)` figure (7.1 ms) is a command buffer's span that includes analysis work; their own
passes add up to 3.5–4 ms (CDEF strength search ≈ 1.05, CDEF ≈ 0.75, deblocking ≈ 0.5–0.9, the
change marks 0.2–0.7). End to end, 34.6–36 inter frames a second (26–29 on 2026-11-03).

**Kept:**
- **The analysis's 32x32 forward DCT on the matrix units** (`d75d997`, `de638ca`). The RD
  transform is float32: each output is an fma chain over k in order from +0, with non-integer
  coefficients, so only the same order gives the same bits. On the M4 Pro, chained
  `simdgroup_multiply_accumulate` over 8-blocks of k equalled the sequential fma on 2,097,152 of
  2,097,152 outputs (unfused multiply-add: 35 %; fma per block then summed: 18 %). Metal doesn't
  promise that order, so `AV1MetalEncoder.forwardMMAIsExact` runs both transforms on 96 fixed
  residuals at start-up (once a device), compares all 98,304 outputs bit for bit, and sets the
  function constant `ga_mma` only if they all match. Otherwise, and on GPUs without matrix units
  (`__HAVE_SIMDGROUP_MATRIX__` unset), the old passes run. `--profile` says which ran.
  - 32x32 2.94 → 2.43 ms (3 alternated pairs, then 3 more on the merged head), analysis
    10.2 → 9.7. The 32x32 kernel's four SIMD-groups now share the tiles (the old passes ran on
    one while three waited).
  - Not kept: the same for 16x16 (1.94 → 2.56) and 64x64 (2.33 → 4.26), likely from the
    threadgroup copy of the matrix lowering occupancy (64x64's is 8 KB).
  - The fallback still declares the 4 KB copy (a threadgroup array can't follow a function
    constant); untimed, since this Mac passes the check.
- **k_ml_stats keeps less threadgroup memory** (`ecfceb5`): a node's record drops the quadrant
  sums a parent never reads back (its quadrants are its children's own sums), and the SB's own
  record isn't stored, 11.4 → 8.6 KB a threadgroup. Learned pruning 1.93 → 1.75 ms. Its passes
  now: statistics ≈ 0.97, the mode network ≈ 0.38 (beside the cells'), the tree ≈ 0.15.
- **A changed search's deblocking in 8×8 threadgroups** (`f09ff6d`), as `p_deblock` already
  was, not 16×4 strips: that pass ≈ 0.59 → 0.35 ms (per-pass timing; the filters' total swings
  ±1 ms and can't show it).

Merged head against a 43f811d build, 3 alternated pairs: analysis 10.2 → 9.7, learned pruning
1.93–1.94 → 1.75, inter frames a second 35.9–36.0 against 34.9–36.2 (unchanged, as the period
says).

**Measured, not kept (same bytes, no gain):** `p_mark` a thread per row of a block;
k_ml_stats's bits and orientation bins in threadgroup memory (1.94 → 2.03), or updated by
constant indices; its 16x16s from SIMD shuffles (threadgroup memory 2.7 KB, 1.75 → 1.74); the
networks' loops unrolled; their weights in `constant` memory.

### Metal AV1: byte-identical speedups: analysis kernels for the hybrid, projections once a picture (2026-11-11)

Five ideas from the reviewers' lists, one at a time, each against a baseline build with
alternated runs. The streams were unchanged after each: `7c17df5c516aab0d`, `e6d1c15a33d8ee99`
and `19a454f8604df9eb` at 5K q20, plus `043b6b1e2c0a51cc` at 2900 q32 and `c941eb17e507be34` at
5K q8. The AV1, Postfilter, AV1Core and Rust tests pass, including the oracle differential run.
Timings are `--profile` best of 10 on the rotation at 5K q20, provisional (the Mac in use).

**Kept:**
- **The analysis kernels compiled for the hybrid's settings** (`696c1ce`). A function constant,
  `ga_fixed`, in k_analysis.h and k_analysis_small.h fixes K = 1, no tx-type search, no edge
  filter, no quantization matrices and no external screener. `Run.analysisIsFixed` picks those
  pipelines only when the params match. Each set compiles on first use, so an encoder compiles
  one.
  - Analysis 11.2–11.3 → 10.2–10.3 ms: 4x4 1.51 → 1.20, 8x8 1.92 → 1.75, 16x16 2.18 → 1.94,
    32x32 3.12 → 2.93, 64x64 2.44 → 2.33.
  - Checked again against the previous head: 11.2–11.3 → 10.3–10.6.
- **The motion projections' reference strips summed once a picture** (`f4b863b`). `k_proj_sums`
  sums every SB's 64 rows and columns of the previous picture into a table kept between
  pictures, and `k_proj` reads its ranges from it. When fewer than 1/8 of the SBs are searched,
  `k_proj` sums the strips itself as before. The integer sums, scoring and ties are the same.
  - Motion search 2.89–2.90 → 2.45–2.46 ms; checked again: 2.88–2.91 → 2.44–2.48.
- **No transform for a residual that quantizes to nothing** (`186e2da`, rust/av1). Each
  coefficient is a row of the column matrix times the residual times a row of the row matrix. By
  Cauchy-Schwarz it is at most scale × the largest kept rows' norms × √energy, with 1.001 for
  float rounding. When that is under the quantizer's zero region at the smaller step (no
  quantization matrix), the levels are zero with no transform. Nothing reads the coefficients
  then, and the trial costs the block by its energy as before. `coeff_bound_holds` tests the
  bound against both forward transforms (NEON and scalar).
  - It fires on 26 % of the trials at 5K q20 (48 % of DCT_DCT trials, 71 % of those that
    quantize to zero), 28 % at 2900 q32 and 18 % at 5K q8.
  - The tx-block hook's CPU went 392–398 → 347–349 ms over 600 k blocks. The closed loop's wall
    time moved −0.15 ms a frame on average, within noise. Kept as a byte-neutral gain off the
    critical path.

**Not kept, no measurable time:**
- **CDEF's strength search with each block's neighbourhood in threadgroup memory.** `l_cdef_sse`
  alone went from 1.372 / 2.175 / 1.275 to 1.348 / 2.146 / 1.266 ms, as with `p_cdef` before. The
  identity candidate already reads no taps.
- **The writer's threads capped at 3, 4, 6, 8 or 10.** The same frames a second and closed loop
  as 14, within noise (63–68 fps, 4.5–5.7 ms at 32 frames).
- **k_leaf compiled for the hybrid.** Leaves 2.89 → 2.82, under the 0.1 ms bar.

The GPU stages on a new 5K picture, after these: motion search 2.46, inter candidates 2.62,
analysis 10.3, partition 0.2, leaves 2.88, learned pruning 1.94, ≈ 20.4 ms (≈ 21.8 before).

### Metal AV1: key frames at a finer qindex (2026-11-11)

`AV1HybridEncoder.keyFrameQindexDelta` (0, the default: as before; negative: finer), clamped to
1…255. `av1seq --key-delta <n>` is in qindex units, and `--per-frame` prints each frame's bytes and
scores. `89865f2`.
- **What it covers.** A stream's key frame, and every picture when inter frames are off. The GPU
  analysis, the closed loop and the filters all take the key frame's own qindex. The first step
  of `--two-steps` takes it too.
- **One cost.** With a delta, the first inter frame after a key frame analyzes every 64x64,
  because kept analysis is keyed by qindex. That costs time, not bytes.
- **Exactness.** At 0 the digest is unchanged. A test checks each frame's base_q_idx and that
  every frame decodes exactly.

The earlier entry's test, before long-term references, gave −3.9 % against libaom at q − 12.
Measured now on today's default (long-term references on). BD-rate against delta 0, RGB PSNR /
SSIMULACRA2, q 8–40, 2900 px, the whole stream and [the inter frames alone]:

| content | −16 | −32 | −48 | +16 |
|---|---|---|---|---|
| four traces in turn | −7.5 % / −9.6 % [−8.4 / −10.1] | −13.5 % / −15.9 % [−15.4 / −17.1] | −17.9 % / −19.0 % [−20.8 / −20.8] | +8.8 % / +12.7 % |
| typing and scrolling in turn | −4.6 / −6.4 [−7.7 / −9.0] | −7.9 / −10.9 [−14.0 / −16.2] | −9.7 / −12.6 [−18.9 / −20.6] | +5.6 / +7.6 |
| photos and dragging in turn | +0.6 / −0.2 [0.0 / −0.1] | +1.6 / +0.2 [0.0 / −0.1] | +2.8 / +1.0 [0.0 / 0.0] | −0.4 / +0.7 |
| app switching | −2.4 / −2.3 [−4.9 / −4.6] | −2.9 / −1.8 [−8.6 / −6.9] | −2.4 / −0.5 [−11.3 / −8.3] | +3.6 / +4.0 |
| one screen (scrolling), 40 frames | −10.0 / −13.4 [−15.8 / −20.3] | −16.7 / −23.0 [−27.2 / −34.5] | −20.6 / −27.8 [−34.9 / −42.2] | +12.8 / +17.6 |

Most of the gain is inherited: the inter frames gain more than the whole stream wherever they
copy the key frame. Photos and dragging never copy it again (its slot is superseded by frame 2),
so there the bigger key frame is pure cost.

Against libaom realtime (its streams the same in every run), the whole stream:
- the rotation goes from −49.9 % / −53.6 % at 0 to −56.7 % / −60.6 % at −32;
- the single screen goes from −8.1 % / −8.1 % to −23.4 % / −29.8 %. Its inter frames alone were
  behind libaom at 0 (+7.9 % / +12.3 %); −16 already reverses that (−8.2 % / −9.3 %).

The key frame, KB / RGB PSNR, the rotation's first picture (`−32` and `−48` both clamp to qindex
1 at q8):

| delta | q8 | q20 | q32 | q40 |
|---|---|---|---|---|
| 0 | 525 / 46.5 | 323 / 42.1 | 206 / 37.6 | 140 / 34.1 |
| −16 | 715 / 48.7 | 367 / 43.3 | 244 / 39.3 | 171 / 35.9 |
| −32 | 1378 / 50.9 | 430 / 44.8 | 289 / 41.0 | 206 / 37.6 |
| −48 | 1378 / 50.9 | 525 / 46.5 | 323 / 42.1 | 244 / 39.3 |
| libaom | 854 / 46.2 | 645 / 42.8 | 492 / 40.4 | 390 / 38.5 |

A key frame's size is latency on a session start or a repair, and BD-rate over a stream with one
key frame favours big key frames, so this is the owner's choice. −16 to −32 keeps the key frame
at 1.1–1.4× today's from q14 up, under libaom's. An option not measured: a normal key frame, then
later frames refining what it left, to get the inherited gain without the latency.

### Metal AV1: no motion search after frames whose search found nothing (2026-11-11)

This is the follow-up to the coded-share rule (below, not adopted).
`AV1HybridEncoder.motionSkip: (threshold, recheckEvery)?` (nil by default) with
`motionSkipLookback` (K = 2), and `av1seq --motion-skip <share>,<every>[,<k>]`, `e07c072`.
- **The signal**, `Timing.motionFound`: in a frame that searched, the area where an inter block
  won the partition's decision, as a share of the coded (not copied) 64x64s.
- **The rule.** A frame skips the search when the last K frames that searched were each below
  the threshold. After `every − 1` skips in a row one frame searches again, and a key frame or a
  size change clears the history.
- **The lag.** Picture i + 2's search is decided when picture i's partition is read, so the
  signal is two pictures late.
- **The plumbing** comes from `d2146af`: the decision travels with the frame to the header's
  `mv_precision`, and `Timing.searchedMotion` reports it.
- **Exactness.** Off, the digests are unchanged. A test that mixes searched and skipped frames
  decodes exactly.

The signal at q20 with the rule off, per frame, as a share of the coded area: the rotation 0–17 %
mostly, with occasional 49 % and 91 %; two screens in turn 0–16 %; scrolling 76–100 %, dragging
27–88 %, video 23–59 %, scrolling images 95–98 %, app switching 95–100 %.

BD-rate against off (RGB PSNR / SSIMULACRA2, q 8–32), with the inter frames skipped (the same at
every q):

| content | 0.05, 4 | 0.1, 4 | 0.2, 8 |
|---|---|---|---|
| the rotation, 5K, 16 frames | 0, 2 of 15 | −0.01 %, 4 of 15 | 0, 11 of 15 |
| the rotation without long-term references (`--no-golden`: every picture new) | 0 of 15 | 0 of 15 | +2.44 % / +2.47 %, 11 of 15 |
| two screens in turn, 2900 | −0.15 % / −0.13 %, 19 of 29 | the same | −0.15 % / −0.12 %, 23 of 29 |
| scrolling, dragging, video, scrolling images, app switching (2900, 30 frames each) | none skipped | none | none |

Checked again: video's stream is identical at 0.2,8 (none skipped), and the rotation skips 11 of
15 at the same 141.6 KB and 46.39 dB. The earlier rule's +17 % on video and +426 % on scrolling
images are gone. GPU stages on an all-new 5K picture, skipped against searched (provisional, the
Mac in use, ±0.03 ms over 3 alternated runs): 21.9 → 16.2 ms, the motion search (2.93) and inter
candidates (2.65) gone. The first 4 inter frames always search (K = 2 and the lag). On pure noise
inter wins ≈ 96 % of the area, so the signal can read high on noise; screen content didn't show
it. Off by default, because it trades bytes for time where every picture is new and nothing is
copied.

### Metal AV1: the level model's q20 loss at eps 0.05, explained (2026-11-11)

The levers table of 2026-11-09 left one point open. With the shipped level model at
`--ml-eps 0.05`, the rotation at 5K lost 0.6 dB at q20 at the same bytes. It still does at
today's default (long-term references): 44.51 → 43.89 dB, BD-rate +1.80 % / +1.15 % over q 8–32.
At 2900 it doesn't appear (+0.08 % / +0.19 %).

**Where it is.** Six of the 12 frames carry it: the key frame (−1.43 dB), and every later picture
of the same two traces (−1.38, −1.41 dB), each lost again by its own analysis, not inherited. In
each, about 70 of 3600 64x64s hold 96–99 % of the extra error, in two adjacent rows of 64x64s. Each
has one horizontal edge in its top 8 rows across a two-value area. At 0.05 all 64 cells keep only
the 64 level, so the analysis offers nothing but a 64x64 block, which rings down its whole height:
≈ 100 K of squared error against 576. At 0.02 the cells also keep the 32 level (32x16 and 32x32
blocks), and the full search splits the edge into 8x4s and 8x8s.

**Why.** The model is confidently wrong on the edge's cell (p(64) = 0.986), and the flat cells
below it give 0.95–0.97. A level is searched where any cell keeps it, and in every one of these
64x64s the least sure cell sits at 1 − p(64) = 0.049. The features scale with the quantizer
(log(1 + v / step²)), so those probabilities drift with q, and all of a 64x64's cells are over
0.95 only for q18–20. All 70 64x64s have the same pattern, so they cross together. Mean PSNR at
eps 0.05 against 0.02, by q:

| q | 17 | 18 | 19 | 20 | 21 | 22 | 23 |
|---|---|---|---|---|---|---|---|
| change (dB) | −0.04 | −0.69 | −0.66 | −0.62 | −0.04 | −0.03 | −0.03 |

Checked again at the default: q19 46.76 → 45.98 dB, and q22 45.85 → 45.80, at the same bytes.
`k_ml_tree`'s repair plays no part (nothing below needs repairing), and neither do the quantizer
tables (the probabilities move smoothly).

**The retrained weights** (eleven traces, not installed) give the edge's cell p(32) of 0.10–0.17 at
every q, so none of these 64x64s is narrowed to 64x64s alone. BD-rate on the rotation, 12 frames,
q 8–32, against the shipped weights at 0.02:

| | retrained at 0.02 | retrained at 0.05 | shipped at 0.05 |
|---|---|---|---|
| 5K, `--long-term 1` | +0.01 % / +0.04 % | +0.24 % / +0.26 % | +1.85 % / +1.31 % |
| 5K, today's default | −0.04 % / −0.09 % | +0.24 % / +0.19 % | +1.80 % / +1.15 % |
| 2900, today's default | −0.02 % / +0.07 % | −0.02 % / +0.07 % | +0.08 % / +0.19 % |

The retrained model's own least sure cell in these 64x64s is at 0.054–0.116, so a window like this
could exist for it on other content. Any eps above 0.02 should be checked with a q scan in steps
of 1. A guard independent of the model, never a 64x64 alone where one of its cells isn't flat,
would change bytes only where it fires; it isn't built. From the levers table, the retrained
weights cost GPU time at 0.02 (23.0 → 23.8 ms, keeping more 16x16s and up) and save some at 0.05
(22.6). Installing them is a speed choice.

### Metal AV1: long-term references, GOLDEN_FRAME the stored picture that matches best (2026-11-11)

`AV1HybridEncoder.longTermReferences` (1…7, default 4; `av1seq --long-term n`), `1a97d19`. The
previous entry's lever.
- **What is kept.** A mostly new picture, as before most of whose 64x64s don't copy the picture
  before it, keeps that picture, the end of the scene it leaves, as a long-term picture in its own
  AV1 slot. Each slot holds the source and the decoded planes.
- **Where the new picture goes.** It takes the slot of the long-term picture it returns to (an
  older state of its own scene), otherwise a free slot, otherwise the least recently used one.
  With more than one slot, the key frame is the first.
- **Which one is GOLDEN.** Each inter frame's GOLDEN_FRAME is the long-term picture that most of
  its 64x64s not copying LAST_FRAME match at no shift, by a sample of their luma rows
  (`av1enc_motion_classify_multi`). Then the copies are classified against that one only. A
  temporary build that classified fully against every slot coded the same bytes.
- **Exactness.** N = 1 is the previous rule, byte for byte: with `--long-term 1` the digests
  `93c5d5eeb49fd481`, `7778330ab6d28ff0` and `c888ff4c1a3e2826` are unchanged. At the default the
  5K rotation's digest is now `7c17df5c516aab0d`. Every frame of every run decoded exactly, and a
  test cycles four synthetic screens.

BD-rate by RGB PSNR / SSIMULACRA2 (`--ssimulacra2-every 3`), q 8–40, 2900 px, 40–60 coded
frames. The single traces use `--step` to spread 60 frames over their switches; their first
150 frames don't switch.

| content | N = 4 vs N = 1 | N = 1 vs libaom | N = 4 vs libaom | copied from GOLDEN at q20, N = 1 → 4 |
|---|---|---|---|---|
| four traces in turn | −49.0 % / −50.6 % | −2.9 % / −6.8 % | −49.9 % / −53.6 % | 4.1 → 55.8 % of 64x64s |
| four traces in turn, 5K, q 8–32 | −70.3 % / −70.1 % | −12.4 % / −12.5 % | −74.0 % / −73.8 % | 4.2 → 65.4 % |
| app switching | −33.2 % / −33.3 % | −30.8 % / −31.9 % | −53.8 % / −54.6 % | 0.1 → 3.9 % |
| tabs | −0.9 % / −0.9 % | −28.1 % / −29.1 % | −28.8 % / −29.8 % | 1.0 → 2.7 % |
| windows opening and closing | −1.5 % / −1.6 % | −23.7 % / −26.7 % | −24.7 % / −27.8 % | 0.0 → 0.7 % |
| two screens in turn (both mixes) | 0 | −78 % and −46 % | the same | unchanged |

N = 2 gives the rotation −17.7 %, and N = 6 codes as N = 4. Windows opening and closing never make
a picture mostly new, so the rule rarely runs there. The copy finder's time at 5K is provisional:
the rotation went from 19.4–19.5 to 8.2–10.6 ms (more 64x64s copy early), and two screens from
5.5–6.2 to 5.6–7.5 ms.

**Memory.** A slot costs 3 bytes a pixel, 44 MB at 5K, so N = 4 is +132 MB on the Host. A decoder
holds up to N + 1 frames instead of 2. Two leaks were found and fixed along the way:
- The hybrid's picture loop now drains an autorelease pool per picture. Metal command buffers had
  kept what they held for the whole stream; the product's encoder loop needs the same.
- av1seq reads each trace frame in a pool of its own. FileHandle's autoreleased reads built up
  until exit.

The 2900 rotation's peak footprint at 60 frames went from 12.6 to 2.2 GB, and app switching at
60 frames peaks at 1.6 GB with 1 or 4 slots.

**For live use.** A long-term slot outlives many frames: if the Viewer loses the frame that
filled it, every return copies the damage until the slot is replaced. A key frame (repair, or a
size change) clears every long-term picture on both sides, so repair stays correct but drops the
gain. The fix is long-term pictures only from acknowledged frames, once references are
acknowledged.

### Metal AV1: where libaom's lead at low rates comes from: its long-term reference (2026-11-11)

This supersedes the reading of the first row of "Metal AV1 against libaom at session size (2900
px)". That row's "every picture new" is not every picture new to libaom.

**Method.** A temporary decoder-side patch to the vendored libaom (not kept) counted both
encoders' streams the same way: each frame's header, and each block's bits by part (partition,
mode info, palette map, tx size, Y/U/V coefficients) with its decisions. `av1seq --dump-sse`
(new, off by default; the streams unchanged) gave each 4x4's squared error. The run was the
rotation at 2900, 40 pictures from 100, q 20–40.

**The frame headers match.** base_q_idx is 80 / 128 / 160 at q20 / 32 / 40 in both encoders,
key frames included. Neither uses delta-q, delta-lf, quantization matrices, chroma delta-q,
superres or loop restoration. libaom's cyclic-refresh segmentation was on at q20 for frames 1–10
with a zero q offset.

The tools differ:

| | ours | libaom |
|---|---|---|
| tx_mode | LARGEST | SELECT |
| tx types | DCT, IDTX, V_DCT, H_DCT | DCT and IDTX |
| blocks | 4x4 and up | 16x16 and up, with 8x8 transforms inside |
| filter strengths at q40 | loop filter 20, sharpness 1; CDEF 21/21, 1/21 | loop filter 16, sharpness 0; CDEF 8/4, 0/0 |
| references | LAST, and GOLDEN = the picture before last | LAST, and GOLDEN = the key frame, for all 40 pictures |

**The cause.** The rotation returns to its first trace every 4th picture, and those pictures are
nearly that trace's key frame. libaom codes them from GOLDEN in 6.3 KB at 38.3 dB, against our
85.3 KB at 35.4. Its 4th trace takes 37 % of its area from the key frame too. Inter frames 1–39
at q40:
- GOLDEN-coded: libaom 20 % of the area for 11 % of its bits; ours 3 % of the area.
- The 64x64s more than half GOLDEN in libaom: 17.5 % of them, but +322 % of the total ΔJ.
- The 64x64s with no GOLDEN at all: 71 % of them, −192 % of ΔJ, so we win there.

The rest is libaom's key frame. At the same qindex it spends 2.8× our bytes: 390 KB at 40.1 dB
against our 140 KB at 35.5, while ours at q20 is 323 KB at 43.8 dB. So it sits higher on a curve
that is no better, and its quality carries into everything later pictures copy: a third of the
q40 squared-error gap is in 64x64s both encoders copy.

By picture in the cycle, q40, KB and PSNR-Y, with the BD-rate ours vs libaom over q20–40:

| picture | ours | libaom | BD-rate |
|---|---|---|---|
| the first trace's (libaom 43 % GOLDEN, 84 % skip) | 85.3 KB, 35.36 | 6.3 KB, 38.33 | libaom ≈ 5 % of our bytes |
| the second's | 96.3 KB, 36.33 | 119.4 KB, 37.89 | −13.9 % |
| the third's | 149.5 KB, 33.44 | 230.6 KB, 34.02 | −23.9 % |
| the fourth's (libaom 37 % GOLDEN) | 101.3 KB, 35.93 | 102.7 KB, 37.23 | +5.5 % |
| the second's and third's together | | | −20.6 % (also at q32–40) |

**Tests** (temporary switches, reverted), the whole stream with its key frame, PSNR-Y, BD-rate
against libaom:

| ours | q40 | q20–40 | q32–40 |
|---|---|---|---|
| as is | 109.5 KB, 35.27 dB | +1.0 % | +5.0 % |
| GOLDEN kept on the key frame | 84.3 KB, 35.32 dB | −21.8 % | −19.1 % |
| key frame at q − 12 only | 112.1 KB, 35.95 dB | −3.9 % | −0.9 % |
| both | 86.7 KB, 37.49 dB | −35.8 % | −35.0 % |

**What it means.**
- On new content at low rates we're ahead. The lever is a reference policy: a long-term
  reference such as the key frame, or GOLDEN chosen by what matches, instead of always the picture
  before last. That rule is what wins two screens in turn (2026-11-02), and keeping GOLDEN on the
  key frame wasn't measured on those mixes.
- Palette wasn't the cause.
- `--ssimulacra2-every 4` on a 4-trace rotation scores only the first trace's pictures, the ones
  libaom codes from its key frame, so the 35.2 against 43.3 SSIMULACRA2 at q40 was mostly
  key-frame quality. Use a period coprime with the rotation (3 or 5).

### Metal AV1: palette with a residual, by real cost, measured, not adopted (2026-11-11)

Built on branch `palette-residual` (`bf5437e`, `a583dec`, not merged), behind
`AV1HybridEncoder.palette` / `av1seq --palette` (off, the streams unchanged). A pass before the
closed loop runs at the GPU's partition, on the closed loop's threads. Each intra luma block that
AV1 allows a palette (8–64 each way, and 4x16 and 16x4), that isn't flat and that has at least
half its samples within ±2 of its 8 commonest values, gets two open-loop costs on the source:
- its GPU mode, predicted from source edges;
- palettes of 2–8 colours (k-means on its histogram).

Both residuals go through the closed loop's own tx-type search, trial and rates
(`QuantHook::intra_luma_j`). The palette's side bits count its colours as the writer codes them
(the colour cache, literals, deltas) and its index map with its real colour contexts. The lower
cost wins; luma only. Key frames turn on `allow_screen_content_tools` when a palette is chosen.
Every frame decoded exactly, and a test covers key frames, inter frames and picture edges.

At 2900 px, 40 pictures from 100, q 8–40, against the run without palette (the logs of "Metal
AV1 against libaom at session size"), BD-rate by RGB PSNR / SSIMULACRA2:

| content | palette vs off | q 8–20 | q 20–40 | vs libaom, q 20–40 (off: as before) | palette blocks: share of eligible blocks / of bits |
|---|---|---|---|---|---|
| every picture new | −0.35 % / −0.37 % | −0.23 % / −0.39 % | −0.42 % / −0.37 % | +0.5 % / −1.1 % (+0.9 % / −0.8 %) | 2.8–5.1 % / 4–6 % |
| typing and scrolling in turn | −0.72 % / −0.70 % | −0.58 % / −0.48 % | −0.80 % / −0.74 % | −76.3 % / −77.9 % | 3.3–7.5 % / 5–11 % |
| photos and dragging in turn | −0.10 % / −0.11 % | −0.01 % / +0.02 % | −0.16 % / −0.13 % | −46.9 % / −44.3 % | 0.8–2.5 % / 1.6–2.9 % |

At 5K (the first mix, 12 frames, q 8–32) palette is −0.90 % / −0.67 %. The palettes average 2.2
colours. The decision costs 4.4–7.0 ms a 2900 picture (9–18 ms at 5K; provisional), mostly the
two tx searches per tried block, since ≈ 80 % of eligible blocks pass the gate. The closed loop
goes from ≈ 8 to 14–15 ms, and new pictures go from 64–81 to 45–60 inter frames a second.

Why it's small: our intra already codes this text well, with IDTX and the 1-D transforms, angle
deltas and RDOQ. In the 2026-11-02 count, libaom without palette spent 570–600 KB where we spent
319, so its palette makes up for its own intra. Diagnostics on short runs:
- Open-loop J_intra matched the closed loop's (ratio ≈ 1.0).
- The map's estimate is ≈ 6 % above the bits written.
- Four 8x8 children against their 16x16 as one palette: the palette wins in 4–6 % of quads, for
  0.3–0.5 % of their cost.
- Tilting the choice toward palettes (15–30 % worse J allowed, or map bits × 0.6) moved q32–40 by
  ≤ 0.5 %, trading bytes for dB.

libaom's lead at q26–40 on new pictures is in luma too, as PSNR-Y in YUV: at q40 it gets
36.91 dB for 124.4 KB against our 35.27 for 109.5. It isn't palette; where it comes from is open.

### Metal AV1: no motion search on mostly-new pictures, by coded share, measured, not adopted (2026-11-11)

`AV1HybridEncoder.skipsMotionSearchOver` / `av1seq --no-motion-over <share>` (branch
`motion-rule`, `d2146af`, not merged). It codes an inter frame without the motion search when it
codes, rather than copies, more than the share of its 64x64s. The copy finder knows that before
the GPU work, and the decision travels with the frame to the header's `mv_precision`. Off, the
streams were unchanged; at 0 they were `--no-motion-search`'s, and at 1 today's. Every frame
decoded exactly, and a test mixing searched and unsearched frames passes. BD-rate against today,
by RGB PSNR / SSIMULACRA2, at q 8–32:

| content | 0.5 | 0.9 | inter frames skipped at 0.5 / 0.9 |
|---|---|---|---|
| the rotation, 5K, 12 frames | +3.07 % / +3.02 % | −0.05 % / −0.15 % | 11 / 3 of 11 |
| typing and scrolling in turn, 2900 | +6.8 % / +6.7 % | 0 | 1 / 0 of 29 |
| scrolling, dragging, switching apps, 2900 | 0 | 0 | 0 |
| video, 2900 | +16.9 % / +21.3 % | the same | 29 / 29 of 29 |
| scrolling images, 2900 | +426 % / +554 % | 0 | 29 / 0 of 29 |

GPU stages at 0.5 on the rotation (provisional): 21.8 → 16.2 ms, the motion search and inter
candidates gone. Coded share is the wrong signal. Copies are exact matches only: resampled
scrolling copies ≈ 20 % of its 64x64s, yet motion covers 79 % of the picture, and video codes over
97 % of its 64x64s, more than any rotation picture. In the typing-and-scrolling pair, the one frame
skipped was a whole-picture switch the search still found much in (160 → 203 KB). A rule would
need a signal of whether the search finds anything, such as the share of blocks motion won in
recent pictures, with periodic re-checks.

### Metal AV1: reviewers' ideas measured, inter candidates side by side kept (2026-11-11)

codex and agy each proposed ideas from reading the code; four were taken up. Timings are on the
rotation (four traces in turn, every picture new) at 5K, q20, `--profile` (best of 10 a run),
alternating runs of an unchanged build and the change. The Mac was in use, so the numbers are
provisional, but each pair ran back to back.

**Kept: k_inter's candidates side by side** (`k_inter.h`). k_inter summed each candidate's 8x8
SADs in turn, a threadgroup reduction per candidate: up to 33 for a 64x64, and for an 8x8 one
working lane in 32. Now each candidate has its own run of 1–8 lanes, sized per shape so that all
fit in one pass. The lanes sum with vector loads and a SIMD-group shuffle. The winner is the
ordered minimum of (cost, candidate), which is the first candidate with the smallest cost, as
before. The block's source is read once into registers, for the gate's mean, its SAD to the
mean, and the residual. Inter candidates went from 3.82–3.84 to 2.59–2.61 ms over three
alternated pairs, a saving of 1.2 ms. The stream digests matched on seven settings (the four
mixes at 5K and 2900, with `--no-subpel`, `--inter-gate 0`, and single traces), and in a run that
checked every block's choice against the old loop. The AV1 tests pass. What's left of the stage:
≈ 0.7 ms is the 14 dispatches' fixed cost, ≈ 0.7 ms the candidate pick and per-block setup, and
≈ 1.2 ms the RD.

**Not kept, the same streams and no measurable time:**
- k_leaf without the luma tx search's threadgroup memory. With the search off (the hybrid's
  default), chroma reads only the edges, 1.7 of the threadgroup's 3.8 KB. A second kernel without
  the rest measured leaves 2.87 → 2.82 ms (best of 4), inside the run-to-run noise (2.82–3.02).
- No mode screening in the analysis's 32x32s and 64x64s when learned pruning leaves one mode: that
  mode is the top-K whatever it screens at. 32x32 stayed at 3.12 ms and 64x64 at 2.44: few nodes
  have one mode left.

**Offline, not adopted: learned pruning's large nodes decided per node.** `k_ml_tree` keeps a
32x32 or 64x64 if any of its cells keeps that level; on new 5K pictures those keep ≈ 75 % of their
nodes and cost ≈ 5.6 ms. Measured on the training dumps (330 pictures, held out as prune_train
holds out: each trace scored by models trained on the others), with the 8x8/16x16 levels as they
are. ΔJ is the open-loop RD cost of the analysis's DP over the dumped node costs, a proxy for
bytes, not a BD-rate. Skipped work is in today's GPU ms on 5K pictures, scaled from
`LEVEL_MS`, whose 32 and 64 levels are ≈ 7× today's.

| rule for 32x32s and 64x64s | at eps 0.02, against any cell | at eps 0.05 |
|---|---|---|
| any cell (today) | — | — |
| cells' mean or 75th percentile over a threshold, one or per level | within ±0.02 ms | ≈ +0.1 ms at equal ΔJ; nothing once each SB's added J is capped at its own J |
| a small network per node (16 hidden), labels the tree's ΔJ for skipping it | −0.2 ms (loses) | −0.3 ms (loses) |
| oracle: per SB, the large nodes chosen knowing their costs | +1.6 ms at equal ΔJ | +1.4 ms |

The cells' probabilities carry little about whether a whole node is needed. At eps 0.05 the
thresholds' gain comes from avoiding a few SBs whose J the skips more than double. The oracle's
headroom needs information the cells don't have, such as costs from a coarse pass. The scorer
(`MODEL=nodes` in `rust/av1/examples/prune_train.rs`) is on branch `prune-nodes`, `35601e3`.

### Metal AV1 against libaom at session size (2900 px) (2026-11-11)

Whether the hybrid could stand in for libaom at the size sessions run at. Both encoders ran on
the same pictures in the same run: `av1seq --width 2900 --skip 100 --frames 40 --tiles 3x0
--inter --score-rgb --ssimulacra2-every 4 --aom-speed 9 --aom-inter`, at q 8, 14, 20, 26, 32
and 40. The hybrid used its defaults at `6961431`. libaom was realtime speed 9 with inter frames
and 8 threads; its shim sets 8 tile columns at this width. The pictures were 2900×1630, and the
mixes were those of 2026-11-02. BD-rate is by RGB PSNR / SSIMULACRA2, and every frame of every
stream decoded exactly. The Mac was in use, so the speeds are provisional; they come from the same
process, one encoder after the other. Bytes and quality don't depend on load.

| content | BD-rate vs libaom | q 8–20 | q 20–40 | inter frames a second at q20: hybrid / libaom |
|---|---|---|---|---|
| every picture new (four traces in turn) | −2.9 % / −1.7 % | −8.3 % / −5.7 % | +0.9 % / −0.8 % | 69 / 52 |
| typing and scrolling in turn | −78.0 % / −78.1 % | −80.6 % / −80.4 % | −76.1 % / −77.7 % | 178 / 68 |
| photos and dragging in turn | −46.4 % / −43.9 % | −45.6 % / −42.8 % | −46.9 % / −44.2 % | 34 / 40 |

At 5K (2026-11-03) the first row was −4.5 % / −9.6 %. On new pictures, the hybrid's lead is at
high rates. From q26 up, libaom keeps more quality for its bytes: at q40 it spends 124 KB a
picture for 35.6 dB and 43.3 SSIMULACRA2, against the hybrid's 110 KB, 33.9 dB and 35.2. That
range is inside what the live AV1 path's quantizer ceiling (42) allows on a thin link. On two
screens in turn the hybrid still leads by far, but by less than at 5K (−87 to −90 % there). Photos and dragging are the one
mix where libaom codes more inter frames a second.

### Metal AV1: a picture in two steps, coarse then refined, measured (2026-11-10)

The cheap test, inside AV1, of making time the thing that gives: code a mostly-new picture
coarsely and fast, and refine it in the next frame, so a frame always leaves on time and the
quality follows. `av1seq --two-steps <q>` (`AV1HybridEncoder.encodeTwoSteps`, a measurement and
not a mode anything ships) puts each picture in the stream twice: at the coarse q as any picture
is coded, then at `--q` as an inter frame against the first step's decoded picture. The second
step copies in place what the first copied, codes the rest with the motion search started from
no shift, and its GPU analysis is given the first step's decoded luma as its reference (the
analysis otherwise reads the previous picture's source, which here is the same picture), so one
frame finishes before the next begins. Every frame of every stream decodes in libaom to the
encoder's picture. The default path is untouched (the rotation's stream digest `93c5d5eeb49fd481`).

The rotation at 5K (typing-cc, then scroll-win, photos and cursor-drag mixed in), 12 pictures,
`--score-rgb --ssimulacra2-every 3`, the second step at q 8, 14, 20, 26 and 32. **BD-rate of both
steps' bytes at the second step's quality, against the one-step streams** of
[the levers' table](#metal-av1-the-analysiss-thread-kernel-and-the-learned-prunings-statistics-by-parts-2026-11-09)
(q20: 508.5 KB a picture, PSNR 44.55 dB, SSIMULACRA2 76.47). GPU stages as there (8 pictures at
q20, the last picture's two steps, best of 10; provisional: the Mac was in use).

| first step | BD-rate (PSNR / SSIMULACRA2) | first step: KB · PSNR · SSIMULACRA2 | second step at q20, KB | both at q20: KB · PSNR · SSIMULACRA2 | second step's blocks coded inter | GPU stages, first / second (ms) |
|---|---|---|---|---|---|---|
| q32 (second step q 8–26) | +14.9 % / +7.3 % | 314.5 · 40.92 · 64.5 | 187.6 | 502.0 · 43.06 · 75.17 | 64 % | 22.2 / 32.3 |
| q40 | +18.6 % / +14.8 % | 207.5 · 37.59 · 46.7 | 366.7 | 574.2 · 44.07 · 75.67 | 52 % | 21.5 / 32.6 |
| q50 | +20.3 % / +20.6 % | 117.6 · 32.91 · 16.5 | 483.7 | 601.3 · 44.42 · 76.23 | 42 % | 21.4 / 33.1 |
| q63 | +9.3 % / +10.3 % | 30.9 · 25.27 · −46.4 | 522.0 | 552.9 · 44.55 · 76.36 | 20 % | 19.3 / 32.3 |

With the first step's search lightened (`--no-motion-search` applies to the first step only;
the mode threshold and the shapes to both):

| first step | BD-rate (PSNR / SSIMULACRA2) | first step: KB · PSNR · SSIMULACRA2 | both at q20: KB · PSNR · SSIMULACRA2 | GPU stages, first / second (ms) |
|---|---|---|---|---|
| q50, `--no-motion-search` | +24.9 % / +25.6 % | 121.9 · 32.65 · 14.4 | 622.6 · 44.40 · 76.10 | **14.8** / 32.9 |
| q63, `--no-motion-search` | +13.6 % / +16.5 % | 32.0 · 25.07 · −48.7 | 570.6 · 44.50 · 75.85 | **12.7** / 32.3 |
| q50, `--no-motion-search --ml-mode-eps 0.10 --new-shapes 1248` | +31.6 % / +30.3 % | 117.3 · 31.91 · 13.7 | 636.4 · 44.15 · 75.79 | **12.2** / 30.0 |
| q63, the same three | +28.6 % / +28.0 % | 31.6 · 25.05 · −48.7 | 622.6 · 44.19 · 75.65 | **10.9** / 28.7 |
| q50, the second step without subpel (`--no-subpel`) | +19.9 % / +20.3 % | 117.5 · 32.91 · 16.5 | 600.5 · 44.45 · 76.22 | 21.1 / 29.9 |

**What this says:**

- **AV1 doesn't refine: it codes the picture again.** After a q50 first step the second step at
  q20 is 484 KB against the one-step picture's 508 KB, so the first step's 118 KB bought 25 KB;
  after q63 the second step is larger than the one-step picture (522 KB). What the second step
  predicts from is the first step's quantization error, which is as costly as the detail it
  stands in for, and the coarser the first step the less of the picture the second codes from
  it at all (inter in 64 % of it after q32, 20 % after q63). The whole is 9–20 % more bytes for
  the same quality; q63's 9 % is a first step nobody could look at, and q32's second step
  leaves the picture 1.5 dB under the one-step stream at q20, because an error smaller than the
  quantizer's step is kept.
- **A coarse q is not what makes the first step fast.** Its GPU stages are 21–22 ms at q32–q50
  against the defaults' 23.0 (19.3 at q63). The search levers are: without the motion search
  the first step is 14.8 ms at q50, for 3.6 % more bytes and 0.26 dB less at that q
  (121.9 KB · 32.65 dB against 117.6 KB · 32.91 dB), about what the lever costs at q 8–32.
  No 4x4s and the mode threshold at 0.10 take it to 12.2 ms and cost another 0.7 dB.
- **The second step as built is the slowest frame** (30–33 ms of GPU stages): all of the
  picture is motion-searched (motion search 9 ms, inter candidates 7.6). Whole-sample vectors
  change nothing in bytes or quality and take 3 ms off its motion search.
- So in this encoder a frame that has to leave on time is a matter of q and the search levers
  on that one frame, and what follows it should be coded as the next picture is, not as a
  correction. A second step that costs nothing needs the first step's coefficients refined in
  place (the same transform, finer steps), which AV1's syntax has no way to say: that is the
  coarse-to-fine design in `docs/GPU-CODEC.md` on `gpu-codec`, and this is the number it has to
  beat (a second step under 20 % of overhead, towards none).

### Metal AV1: the analysis's thread kernel and the learned pruning's statistics, by parts (2026-11-09)

The rest of [where the GPU analysis goes](#metal-av1-where-the-gpu-analysis-goes-on-a-picture-of-new-content-kernel-by-kernel-2026-11-09),
with the filters' lesson in hand (a loop the compiler doesn't unroll, around a local array). The
rotation at 5K (typing-cc, then scroll-win, photos and cursor-drag mixed in; q20, squares,
`--profile` at 8 frames: one inter frame, each stage's best of 10). **Provisional levels:** the
Mac was in use; the same build repeats to 0.02 ms.

**By parts** (a part compiled out or the kernel left early, the stream no longer valid; ms):

| kernel | 4x4 | 8x8 | 16x16 | 32x32 | 64x64 |
|---|---|---|---|---|---|
| | thread | thread | SIMD-group | threadgroup | threadgroup |
| to the learned pruning's exit, and set-up | 0.08 | 0.04 | 0.13 | 0.13 | 0.03 |
| edges, DC, the flat check | | | 0.16 | 0.21 | 0.27 |
| screening the modes | 0.78 | 1.07 | 0.92 | 1.19 | 1.31 |
| the one candidate's RD | 0.66 | 0.91 | 0.9 | 1.57 | 0.82 |
| whole | 1.51 | 2.03 | 2.18 | 3.13 | 2.43 |

Screening is 5.3 ms and the one candidate's RD 4.9 across the levels; the tx search in the
kernels is off in this preset. The learned pruning's 2.0 ms, by leaving each pass at its top:
`k_ml_stats` 1.22 · `k_ml_mode` 0.36 · `k_ml_cell` 0.16 · `k_ml_tree` 0.15 · `k_ml_list` 0.14.
Inside `k_ml_stats`: the samples' orientations 0.53 (the `atan2` 0.12 of it), the neighbour
differences 0.25, the cells' features 0.19, the levels above the cells 0.07; everything a
sample does is 0.65, and the rest is 3,600 threadgroups of 64 and their barriers.

**The learned mode mask saves the thread kernel nothing because a SIMD-group's 32 lanes hold
32 blocks with different masks**, so every lane waits through every mode some lane kept. With
every lane given its group's first block's mask (the wrong streams, for the time only): 4x4
1.50 → 1.33, 8x8 1.95 → 1.63. Listing the blocks by mask therefore has at most 0.5 ms to give
before the sort's own cost. Not built.

**Kept, the same streams:**
- the thread kernel screens its 13 modes with the mode a constant (`pred_cand0`, the loop
  unrolled), so each mode's predictor is compiled for itself instead of chosen a sample at a
  time: 8x8 2.03 → **1.93**, 4x4 1.51 → 1.50;
- `k_ml_stats` takes the level of a sample's pairs and of its orientation from its thread's
  cell (only a cell's border samples are above level 0) instead of working it out a sample at
  a time: learned pruning 2.00 → **1.95**.

The rotation's digest (`93c5d5eeb49fd481`), the 18 settings of the entry below against a build
of `6b6fa1c`, and the Swift AV1 tests.

**Measured, not kept** (the same streams, no faster):
- `#pragma unroll` on the thread kernel's flat check, and on its mode loop without the
  constants; its SATD's sub-blocks unrolled (slower at 8x8);
- `k_ml_stats`'s seams summed in the thread and added to the threadgroup's atomics once a cell
  instead of once a sample (1.98 against 1.95: the atomics aren't the cost); its column loop
  unrolled (1.96).

**What this says:** the analysis has no kernel out of line and no loop like the filters' had.
What is left to take without changing a byte is a few percent of a kernel at a time. Bringing
a new picture's 23 ms of GPU analysis under the 13 ms that 60 a second leaves beside the
filters means analysing fewer blocks or fewer candidates, which moves bytes.

**The levers that move bytes, measured for the owner's choice.** The same rotation, 12 frames
at q 8, 14, 20, 26 and 32 (`--score-rgb --ssimulacra2-every 3`): BD-rate against the defaults
by PSNR and by SSIMULACRA2, and the GPU stages' sum at q20 (motion search, inter candidates,
analysis, partition, leaves, learned pruning; 8 frames, provisional as above).

| lever | BD-rate (PSNR / SSIMULACRA2) | GPU stages (ms) | what moved |
|---|---|---|---|
| the defaults | | 23.0 | |
| `--no-motion-search` (copies only) | +3.07 % / +3.02 % | **16.1** | motion search 2.89 and inter candidates 3.85 → 0 |
| `--ml-mode-eps 0.05` (default 0.02) | +0.13 % / +0.22 % | 22.3 | analysis 11.2 → 10.5 (16x16 and up) |
| `--ml-mode-eps 0.10` | +0.36 % / +0.37 % | 21.7 | analysis 11.2 → 9.9 |
| `--ml-eps 0.05` (default 0.02) | +1.85 % / +1.31 % | 21.8 | analysis 11.2 → 10.0 |
| `--ml-eps 0.10` | +9.54 % / +10.12 % | 21.5 | analysis 11.2 → 9.5 |
| `--new-shapes 1248` (no 4x4s) | +7.67 % / +5.85 % | 20.9 | analysis 11.2 → 9.8, leaves 2.9 → 2.4 |
| the retrained weights (`--ml-prune`, eleven traces; not installed) | +0.01 % / +0.04 % | 23.8 | analysis 11.2 → 11.8: they keep more 16x16s and up here |
| the retrained weights at `--ml-eps 0.05` | +0.24 % / +0.26 % | 22.6 | analysis 10.6 |
| the retrained weights at `--ml-eps 0.10` | +4.72 % / +4.31 % | 21.5 | analysis 9.6 |

- **The motion search is the only large one:** 6.7 of 23 ms for 3 % of bytes, on a rotation
  where every picture is mostly new (12 % of each is motion-searched).
- The mode model's threshold is cheap in bytes and only pays in the kernels of 16x16 and up,
  where a SIMD-group screens one candidate; the thread kernel's lanes wait for each other
  (above).
- The shipped level model's +1.85 % at 0.05 is one point: at q20 the stream loses 0.6 dB at
  the same bytes (PSNR 44.55 → 43.93, SSIMULACRA2 76.47 → 75.45) and at the other four q
  0.03 dB or less. Not looked into; a frame-by-frame look comes before anyone raises it. The
  retrained model at 0.05 has no such point (its worst is −0.07 dB at q32).
- No motion search, the mode threshold at 0.10 and the retrained level model at 0.05 would
  come to about 14 ms together if their savings add, for about 3.7 %: not measured together.
- Subsampled screening is already on in this preset (`screenSub` 2 at 16x16 and up).

### Metal AV1: the filters' GPU kernels, the same streams in under half the time (2026-11-09)

A picture's period on new content is bound by the GPU: the next picture's analysis beside this
picture's filters. The filters' search alone on a 5K key frame (q20; photos / typing-cc; each
stage committed alone, best of 12 to 20; ms), a step at a time. **Provisional levels:** the Mac
was in use and the pruner's training was on the GPU; the steps were timed minutes apart on the
same load, and every one leaves the streams' bytes as they were.

| step | whole | `l_cdef_sse` | `p_cdef` | `p_deblock` | `p_cdef_dir` |
|---|---|---|---|---|---|
| before (`4bce8e1`) | 10.59 / 10.69 | 3.75 / 3.64 | 3.00 / 3.00 | 2.55 / 2.68 | 0.71 / 0.62 |
| CDEF: a strength of 0 leaves its taps unread | 9.86 / 9.83 | | 2.37 / 2.31 | | |
| strength search: direction 0's primary taps unread; the clamp only where both sets are read | 9.46 / 9.34 | 3.46 / 3.39 | | | |
| strength search: samples two or more from the frame's edges skip the taps' bounds checks | 8.80 / 8.72 | 2.80 / 2.77 | | | |
| CDEF: the same | 8.86 / 8.64 | | 2.29 / 2.23 | | |
| strength search: a thread a 4x4 of luma or a 4x2 of chroma, its 8x8's parameters read once | 8.48 / 8.37 | 2.57 / 2.50 | | | |
| CDEF: the same threads (8 x 8 a threadgroup) | 7.90 / 7.82 | | 1.70 / 1.68 | | |
| strength search: a SIMD-group takes a 32x16 | 7.81 / 7.82 | 2.51 / 2.50 | | | |
| deblocking's wide filter: the samples read once, each output's sum slid from the last | 7.10 / 7.05 | | | 1.86 / 1.93 | |
| deblocking's wide filter: called by size with constants | 5.83 / 5.69 | | | 0.58 / 0.57 | |
| CDEF: the directions a table of the file, the tap weights by arithmetic | 5.76 / 5.61 | | 1.61 / 1.59 | | |
| `AV1G_UNROLL` on the direction search's 8 x 8 samples and CDEF's taps | 5.17 / 5.06 | | 1.50 / 1.48 | | 0.22 / 0.20 |
| strength search: the candidates' damping once a block | 5.12 / 5.02 | 2.46 / 2.46 | | | |
| `AV1G_UNROLL` on the direction search's other loops | **4.94 / 4.89** | 2.47 / 2.45 | 1.51 / 1.48 | 0.58 / 0.57 | **0.06 / 0.05** |

(`l_select` 0.27 throughout; the rest under 0.1.) In the rotation at 5K (typing-cc, then
scroll-win, photos and cursor-drag mixed in; q20, squares, `--profile`), a picture's filters went
10.6 → **8.1 ms**, and their GPU beside the next analysis 8.0 → **3.7 ms**.

**The same streams:** the rotation's digest (`93c5d5eeb49fd481`, 8 frames), the digests of 18 settings (key and inter frames; 1728, 2560 and
5120 wide; the three presets; with and without the learned pruning, the new shapes, the chroma
model, the leaf tx search, deltas and the quality map) against a build of `6b6fa1c`, the
key frames' sizes (1014.3 KB, 525.2 KB) with libaom's decode equal to the GPU's picture, the
Swift AV1 tests, and the Rust crate's tests against the C++ oracle (which includes the shared
header, so the CPU's filters took the same changes).

**What was slow, and it is the lesson for the analysis kernels: a loop the Metal compiler
doesn't unroll, around a local array.** The array stays in memory and the loop reads and writes
it a trip at a time.
- Deblocking's wide filter was the spec's loop: for each of 2n outputs, 2n + 1 taps, n one of 6,
  3 and 2 at run time, the samples loaded inside it and the outputs kept in `F[12]`. That was
  ~2.2 of `p_deblock`'s 2.6 ms (timed with parts removed: the threads alone ≤ 0.14, the maps
  0.26, the loads and masks 0.39, everything but the wide filter 0.45). Now `av1g_lf_wide`
  reads the samples once and slides a sum, and is called with constants so its loops unroll:
  the same whole-number sums.
- The direction search's loop over its 8 x 8 samples has a constant count, and the compiler kept
  it anyway, with `partial[8][15]` in memory. `#pragma clang loop unroll(full)` (hd.h's
  `AV1G_UNROLL`, empty outside Metal) took it 0.71 → 0.06 ms with no other change. Its loads
  weren't the cost: word loads of the rows changed nothing.
- A constant table declared inside a function (CDEF's directions) is built by every call on the
  GPU; at file scope (`AV1G_TABLE`) it isn't.

**Also kept:** a thread a block instead of a thread a sample. The block's 8x8 decides the
strengths and the direction, so 16 (or 8) samples share one read of them, and the test for the
frame's edges. A zero strength's taps add nothing and can't make the clamp bind (the argument is
in `av1g_cdef_pixel`), so a candidate without a primary strength reads 8 taps, not 12.

**Measured, not kept (no faster):**
- The strength search reusing the block direction's secondary sums where that direction is 0
  (3.51 / 3.37 against 3.46 / 3.39: a branch a thread).
- `p_cdef` storing a row of outputs as a word (1.70 / 1.67).
- `AV1G_UNROLL` on the strength search's small loops and on its sample loop, and on a deblocking
  edge's four lines: the compiler already had the small ones, and the others don't index an
  array across trips.
- `p_cdef`'s threadgroup at other shapes: 8 x 8 1.70 / 1.68 · 8 x 4, 8 x 16, 4 x 4 the same ·
  4 x 8 1.74 / 1.80 · 16 x 4 and 16 x 8 1.96 / 1.76 · 32 x 2 2.32 / 1.94. (Empty threads are
  nearly free: two passes of 2.7 M that return at once are 0.14 ms.)

**What is left** is the strength search (2.5 ms: ~22 loads a sample for four candidates) and
CDEF itself (1.5). A block's taps overlap, so loading its neighbourhood once would cut the
loads, but a direction chosen at run time then indexes a local array: the slow pattern above.
Not tried.

### Metal AV1: where the GPU analysis goes on a picture of new content, kernel by kernel (2026-11-09)

After the leaf stage, the rest of the GPU analysis of the rotation at 5K (typing-cc, then
scroll-win, photos and cursor-drag mixed in; q20, squares, `--profile`: one inter frame, each
stage's best of 10). **Provisional throughout:** the Mac was in use and the pruner's dumps were
on the GPU, so read the shares and the differences, not the levels.

| stage (ms) | | its kernels |
|---|---|---|
| motion search | 2.9 | `k_proj` 1.21 · `k_me` 1.21 · `k_inter_sad` 0.47 |
| inter candidates | 3.9 | `k_inter` 8x8 1.10 · 16x16 0.80 · 32x32 0.93 · 64x64 1.12 |
| learned pruning | 2.0 | `k_ml_stats` 1.11 · `k_ml_mode` 0.44 · `k_ml_cell` 0.22 · `k_ml_tree` 0.06 · `k_ml_list` 0.19 |
| analysis | 11.7 | 4x4 1.53 · 8x8 2.03 · 16x16 2.27 · 32x32 3.30 · 64x64 2.55 |
| partition · leaves | 0.2 · 2.9 | |

**The analysis, block by block.** Counters in the kernels, for the profiled picture (the copied
superblocks, 14 % of this stream's on average, leave before the first count):

| level | in the picture | past the pruning | of those, not flat | ms | ns a block past the pruning |
|---|---|---|---|---|---|
| 4x4 | 921,600 | 220,928 | 176,681 | 1.53 | 6.9 |
| 8x8 | 230,400 | 55,232 | 49,410 | 2.03 | 37 |
| 16x16 | 57,600 | 25,879 | 23,391 | 2.27 | 88 |
| 32x32 | 14,400 | 10,766 | 9,826 | 3.30 | 306 |
| 64x64 | 3,600 | 2,750 | 2,330 | 2.55 | 924 |

(4x4 and 8x8 share a level of the learned pruning, so the 4x4s are four times the 8x8s. The
stream's other inter pictures run from 22,000 8x8s and 571 64x64s past the pruning to 101,000
and 2,000.) A level costs 0.23 to 0.57 ns a sample: the work is spread evenly, with no kernel
out of line. Past the copies and the learned pruning are 24 % of the picture's 8x8s and 4x4s
and 45 % of its 16x16s, but three quarters of its 32x32s and 64x64s, which are half the stage
(5.9 of 11.7 ms). How many of the missing quarter are copies wasn't counted for this picture;
if most are, the level model drops few of the large blocks it is shown, and that is where a
better one would pay.

By parts, from ablations (a part compiled out, the stream no longer valid) and from running a
part twice:
- visiting the blocks and the set-up before the screening: 0.6 ms;
- screening the modes, and the edges: 5.9 ms;
- the one candidate's RD: 5.1 ms (4x4 0.66 · 8x8 0.90 · 16x16 0.95 · 32x32 1.68 · 64x64 0.90);
  in the SIMD-group kernel its residual 0.13 / 0.25 / 0.19, forward transform 0.18 / 0.87 / –,
  quantizer and rate 0.12 / 0.38 / 0.16 (16x16 / 32x32 / 64x64; the 64x64 transform's
  difference wasn't credible).

The chosen candidate's residual is all zero (the prediction exact: stripes, a repeated row or
column) for 1.5 to 29 % of the 4x4s that aren't flat across the stream's inter pictures, 0.9 to
19 % of 8x8s, 1.7 to 20 % of 16x16s, 5 to 36 % of 32x32s and 2 to 36 % of 64x64s.

**Kept, the same streams** (`k_analysis`, the SIMD-group kernel: 16x16 and up on new pictures):
- an exact prediction's RD without the transform and the quantizer: no distortion and an
  all-zero block's bits (`base_bits(e, 0)`), which is what they arrive at;
- the learned pruning's check ahead of the rest of a block's set-up (the tile box, the edges'
  availability, the costs), since most blocks of a level stop there.

| GPU stage (ms) | before | after |
|---|---|---|
| analysis | 11.7 | **11.3** |
| 16x16 · 32x32 · 64x64 | 2.27 · 3.30 · 2.55 | 2.18 · 3.13 · 2.44 |
| 4x4 · 8x8 (the thread kernel, untouched) | 1.53 · 2.03 | 1.52 · 2.02 |

Every stream is the same (`--digest`) as the commit before's, over 18 settings: the rotation
(`93c5d5eeb49fd481` for 8 frames); 5K key frames; `--chroma-angles`; `--no-ml-chroma`;
`--leaf-tx 256`; `--leaf-tx 64 --no-tx-search`; `--q 45 --ml-chroma-eps 0.2`;
`--new-shapes off`; `--no-ml-prune`; `--intra-everywhere`; `--q 32 --dq text:16`;
`--inter-gate 0 --no-deltas`; 2560 wide at q30, and at q55 with
`--no-tx-search --exact-tx-trials`; 1728 wide at q12 with `--tiles 1x1`; and the `fast`,
`base` and `slow` presets (2560, 2560 and 1728 wide).

**Measured, not kept** (no difference):
- the exact-prediction shortcut in the thread kernel (4x4 1.53, 8x8 2.02 to 2.06): threads run
  as SIMD-groups, so a branch saves nothing unless a whole group takes it;
- skipping the screening where the learned mode mask leaves one mode;
- `k_ml_stats`'s `atan2` (the gradient's orientation bin, a sample): with the bin faked the pass
  goes 1.11 → 1.00 ms, so an exact binning by comparisons has at most 0.1 ms to give.

**Not built:** a fold of the analysis's forward DCT into its even and odd halves (not
bit-identical to the matrix form in floats: it would need the digests, and BD where they
move); skipping the transform's zero rows.

### Metal AV1: a leaf a thread, where its chroma is 4x4 or none (2026-11-09)

The leaf stage (`k_leaf`: each leaf's chroma mode and CfL) gave every leaf a SIMD-group of 32
lanes. Most leaves give those lanes nothing to do. A 5K key frame of the rotation (typing-cc,
then scroll-win, photos and cursor-drag mixed in; q20) has about 96,000 leaves:

| leaves | | what the stage does for one |
|---|---|---|
| 46,080 | no chroma (three of an 8x8's four 4x4s, and the like) | writes defaults |
| 36,290 | chroma 4x4 | the model, 7 modes screened, CfL: 16 samples a plane |
| 2,053 | chroma of 32 samples (4x8, 8x4) | |
| 5,657 | 64 samples (8x8, 4x16, 16x4) | |
| 1,830 | 128 samples | |
| 2,370 | 256 samples (16x16) | |
| 1,794 | 1024 samples (32x32) | |

(The rotation's other pictures leave 8,857 to 24,124 leaves in the last five rows.)

**Kept, the same streams:** `k_leaf_small` takes a leaf a thread (threadgroups of 32). It decides
the first two rows alone, and lists the others for `k_leaf`, a SIMD-group each as before (an
indirect dispatch sized by the list). A thread's decision has to match the SIMD-group's bit for
bit, and its float sums are where it could differ. Two probes on this GPU (M4 Pro, SIMD width
32, MSL 4.1, `mathMode = .safe`) say what the SIMD-group computes:
- `simd_sum` of floats adds the lanes as a tree of adjacent pairs: 2,048 of 2,048 random inputs
  matched `((l0 + l1) + (l2 + l3)) + …` bit for bit, with 16 lanes nonzero and with 32;
- products aren't contracted into fused multiply-adds: the model's output layer on 524,288
  inputs was the same from the SIMD kernel, from a thread's `b + tree16(w * h)`, and from the CPU
  without fma.

For a 4x4 chroma block that leaves little to emulate. Each of the 16 samples, and each (mode,
plane), has a lane of its own, so a mode's cost is its U lane's plus its V lane's; the model's
feature sums and CfL's are of whole numbers of 64ths below 2^24, exact in any order; the output
layer's sum over 16 hidden units is the tree, written out (`leaf_tree16`). The model's pieces
(features, hidden unit, keep rule) are shared by both kernels.

`--profile`, the rotation at 5K, 8 frames, ms a frame. **Provisional:** the Mac was in use and
the pruner's dumps were running on the GPU throughout, so read the differences, not the levels.

| | before | after |
|---|---|---|
| leaves (GPU stage) | 4.5 | **2.9** |
| GPU analysis | 26.3 | **23.5** |
| closed loop · filters · writer | 18.0 · 12.6 · 12.9 | 16.5 · 10.8 · 9.7 (the CPU's share of a busy Mac, not this change) |
| inter frames a second | 28.6 | 31.4 |

Every stream is the same (`--digest`): the rotation (`93c5d5eeb49fd481` for 8 frames), 5K key
frames, and against the commit before with `--chroma-angles`, `--no-ml-chroma`, `--leaf-tx 256`,
`--leaf-tx 64 --no-tx-search`, `--q 45 --ml-chroma-eps 0.2`, 2560 wide at q30, and 1728 wide at
q12 with `--tiles 1x1`.

**What's left of the stage** (2.9 ms; by having one class write defaults instead of deciding):
the scan, the thread kernel and the dispatches 1.1; the SIMD-group kernel 1.8, of which the
64-sample class 0.6, 16x16 0.4, 32x32 0.9, and the 32- and 128-sample classes nothing
measurable.

**Not built: bigger chroma blocks on a thread.** It would need the lanes emulated: 32
accumulators a sum (item p into accumulator p mod 32, in p's order), then the 32-leaf tree; and
from 8x8 up the model's sum of squared luma means passes 2^24 (64 × 255² in 16ths), so its
order matters too. A thread does no more work than a SIMD-group does in total, but a SIMD-group
of threads waits for its slowest, so the leaves would also want listing by class. On 32x32 the
SIMD-group kernel already fills its lanes (896 items, 28 full passes). At most the 64-sample
class's 0.6 ms is there to take.

### Reference traces v3 (2026-11-09)

Seven more traces of the owner's 5K display (5120×2880), recorded raw (the entry below) with
`glassact-bench record --seconds 30 --delay 5`, for what the earlier sets lack: video, where the
motion search decides, and content that comes back after something covered it (GOLDEN_FRAME,
long-term references). Recorded on 2026-11-03 (the first two) and
2026-11-09. **Not measured yet:** no encoder has run on them. The content is each recording's
script, with one frame of each looked at.

| name | file | content | frames | seconds | the recorder's drops |
|---|---|---|---|---|---|
| movie | `glassact-1793736335.scap` | a film full screen in VLC | 720 | 30.0 | 0 (slowest write 10.5 ms); 24.0 a second, the film's rate |
| app-switch | `glassact-1793737268.scap` | Cmd-Tab between apps (Safari on a results page, Photos among them) and back, ~2 s on each | 1367 | 27.5 | 2 (slowest write 49 ms) |
| tabs | `glassact-1794265876.scap` | a Safari window over other windows, its tabs switched in turn, twice round, then two of them back and forth | 1731 | 30.0 | not noted; no gap over 33 ms between frames |
| window-open-close | `glassact-1794271260.scap` | Finder windows opened, moved and closed over other apps' windows | 1378 | 29.9 | 35 (one write of 640 ms) |
| ide | `glassact-1794283848.scap` | Zed full screen on Rust source: typing, scrolling, switching files, an overlay opened and dismissed | 947 | 29.3 | 0 (slowest write 10.5 ms) |
| maps | `glassact-1794284096.scap` | Maps.app full screen: panning, zooming, another map style | 1509 | 30.1 | 48 (one write of 359 ms) |
| images-scroll | `glassact-1794284419.scap` | image search results in Chrome full screen: scrolled down, flicked, back up | 1478 | 30.0 | 22 (slowest write 65 ms) |

A trace holds a frame only when the screen changed, so the counts fall short of 60 a second
where the content rested (app-switch's longest rest is 2.3 s). Two of the eight runs
had one slow raw write each (640 and 359 ms, both on busy content, against a median
of 5.5 ms): a jump of that length in window-open-close and in maps. Unexplained so far.

Deleted on 2026-11-09 as superseded (64 GB): an earlier take of app-switch
(`glassact-1793737105.scap`, 1470 frames, 30.1 s, 17 dropped), and two recordings of the film
from before the raw recorder, at ~15 frames a second (`glassact-1793733277.scap`, which the
entry below measured, and `glassact-1793734530.scap`, 473 frames in 32.2 s), which movie
replaces. Frames sampled across `glassact-1793733277.scap` were all full screen, so it held no
video in a window.

Still wanted: switching Spaces and back, video in a window, and captures at other display sizes
(a MacBook's, a 4K display).

### The trace recorder: raw to disk, compressed afterwards (2026-11-03)

A full-screen movie recorded by the Host (`glassact-1793733277.scap`, VLC, window then full screen,
53.7 s) kept 793 frames, ~15 a second, of a ~24 fps picture (a later 30 s run: 120 frames kept for
~80 superseded in each 8.3 s). Replaying its frames through the recorder's steps, per 5K frame: the
copy 1–3 ms, **LZ4 53–58 ms**, the write 4–6 ms (59–67 ms in all, 15–17 fps), all on the queue
that takes captured frames, so the latest-frame slot dropped what arrived meanwhile. The frames it
kept are exact; it was only the rate.

Now the recorder writes raw (`ScapRawWriter`, past the page cache) and compresses when it stops
(`ScapRaw.finish`, every core), in the Host and in the new `glassact-bench record`. Its `.scap` is byte
for byte what `ScapWriter` makes (`ScapTests`). 41 GB of 5K frames to this Mac's disk, uncached:
6.6 GB/s, 112 frames a second; a frame's write median 8.7 ms, slowest 21. A 5 s test: 274 frames in
5.00 s (4.0 GB after 4.3 s of compressing). A 5K trace takes ~59 MB a frame while raw (3.5 GB/s at 60 fps).
A capture stops itself when the disk couldn't hold its compressed copy beside it, with 10 GB to spare.

### Metal AV1 against libaom and hardware HEVC, after the day's speed work (2026-11-03)

The hybrid at 077d14e (squares on new pictures, four tx types, quick trials, the writer
overlapped; `--tiles 3x0`) against the same pictures' stored libaom speed 9 (inter frames) and
VideoToolbox HEVC (`vquality --qp`, 18–42) runs of 2026-11-02: 5120×2880, 40 pictures, q 8–40.
BD-rate by RGB PSNR / SSIMULACRA2. The hybrid's run wasn't gated on a locked screen, so its speeds
may read a little low; bytes and quality don't depend on that.

| content | against libaom | against HEVC | hybrid, inter frames a second | libaom | HEVC, by one picture's latency |
|---|---|---|---|---|---|
| every picture new (four traces in turn) | −4.5 % / −9.6 % | −42.8 % / −21.2 % | 26–29 | 20–25 | 26–30 |
| typing and scrolling in turn | −90.2 % / −90.5 % | −95.7 % / −93.8 % | 140–172 | 27–36 | 27–30 |
| photos and dragging in turn | −87.1 % / −86.8 % | −90.8 % / −87.9 % | 52–60 | 13–18 | 26–29 |

The day's byte trades show on the first row (−7 % / −11 % and −44 % / −23 % before them). HEVC's
column is one picture at a time; with several in the encoder at once it reached 58–59 a second
on 2026-08-07's traces (not on these), so it's still ahead on throughput on new pictures. At q20
on new pictures the stages are GPU analysis 24.5, closed loop 16.4, filters 15.7 (GPU 8.7), writer
10.8 ms. Single traces weren't re-measured here.

### Metal AV1: the closed loop's forward DCTs by their butterflies, measured, not kept (2026-11-03)

The forward matrices (the exact inverse of AV1's integer inverse transforms) keep the DCT's
even/odd symmetry exactly at every level of the folding (F[k][m - 1 - j] = ±F[k][j] over the
first m = n >> l columns of the rows k = 0 mod 2^l; checked for 4 to 64 points), so a partial
butterfly with the matrices' own entries is the same transform rounded in another order: the
input folded into sums and differences, the odd frequencies from the differences (a half-size
product), the same again on the sums. Built for the DCT passes of 16 points and up (NEON, 4
signals a vector, the odd outputs 8 at a time; a scalar reference step for step), behind a
switch.

- **Bytes:** 65 % of the coefficients differ in their last bits (`forward_f`'s test cases), and
  no level moved: the rotation's streams byte-identical (`--digest`), BD-rate 0.00 % / 0.00 % at
  q 8–40.
- **Speed:** slower than the matrices at every size (16x16 230 → 630 ns, 32x32 1665 → 2460,
  64x64 4750 → 5530; a first version with one accumulator an output, 32x32 2550). The matrix
  kernel keeps 4 x 16 outputs in registers on float4 loads; the butterfly's intermediates go
  through memory. Below 16 points the matrices win outright.
- **What a fast one could save at most:** forward transforms by tx size on new 5K pictures (12
  pictures): 4x4 2.56 M, 8x8 696 k, 16x16 187 k, 32x32 65 k, 64x64 17 k, the rest under 17 k
  each; at the matrix's cost ~25 core-ms a picture, 77 % of it at 16x16 and up. A butterfly 2.5x
  faster there would save ~11 core-ms of the closed loop's ~170 (~7 %, ~1 ms of its wall time):
  days of hand-scheduled kernels (libaom's NEON fdct style) for that. Not kept (reverted; this
  entry describes it).

### Metal AV1: RDOQ on pictures of new content, re-measured (2026-11-03)

With the four tx types (the default since the entry below), the rotation at 5K, q 14–32,
against RDOQ as it is (tx blocks whose source spans >= 40 values; BD-rate by RGB PSNR /
SSIMULACRA2; inter frames a second at q 14 / 20 / 26 / 32, the Mac in use):

| | BD-rate | inter frames a second |
|---|---|---|
| RDOQ, span >= 40 (today) | — | 25.8 / 26.6 / 27.6 / 29.1 |
| no RDOQ (`--no-rdoq`) | +0.54 % / **+2.69 %** | 27.2 / 26.5 / 28.2 / 29.5 |
| span >= 80 | +0.33 % / +1.04 % | 25.4 / 25.0 / 27.2 / 29.3 |
| span >= 120 | +0.47 % / +1.48 % | 24.8 / 26.6 / 28.4 / 29.1 |

RDOQ earns 2.7 % by SSIMULACRA2 on such pictures for a speed difference inside the noise: kept
as it is. The four tx types took the closed loop's work from ~199 to ~170 core-ms a picture
(`GA_CRIT`, q20). **Measured, not kept:** RDOQ's level contexts in a per-thread scratch with only
a block's rows zeroed (instead of a 1.3 KB array a call): the same streams, closed loop 16.5 /
16.9 → 15.7 / 16.5 ms, noise.

### Metal AV1: the closed loop's tx types (2026-11-03)

Where the closed loop's time goes now (`sample`, the rotation at 5K, squares, the writer
overlapped; the closed loop's ~12.6 k samples): the forward transforms ~25 %, RDOQ ~12 %, the
trials' own work ~15 %, the residual's setup ~13 %, the quantizer ~10 %, the plan's walk ~7 %,
prediction and the final reconstruction ~8 %. Most of it scales with the tx types each block
tries (intra 4x4 and 8x8: 7, 16x16: 5, inter up to 16). The final writer's coefficient coding
(`Walk::coeffs`, ~3 k samples) now shares the cores.

**Which types earn the search** (BD-rate against all, the rotation, q 14–32, RGB PSNR /
SSIMULACRA2; inter frames a second at q 14 / 20 / 26 / 32, the Mac in use):

| types (`av1seq --tx-types`) | BD-rate | inter frames a second |
|---|---|---|
| all | — | 24.8 / 23.2 / 26.3 / 25.7 |
| DCT_DCT, IDTX (libaom realtime's screen set; `201`) | +3.50 % / +1.92 % | 25.6 / 26.4 / 27.0 / 28.2 |
| DCT_DCT, IDTX, the ADSTs (`20F`) | +2.48 % / +1.74 % | 24.8 / 25.8 / 26.7 / 27.4 |
| **DCT_DCT, IDTX, V_DCT, H_DCT** (`E01`) | **+0.49 % / +0.11 %** | **25.5 / 25.3 / 27.3 / 28.4** |

On screen content the 1-D transforms earn nearly all of the search; the ADSTs add ~0.4 %.
`AV1HybridEncoder.txTypes` (`screenTxTypes` = `E01`), built, all types by default: a bytes
trade, the owner's choice: on since the same day. The streams with every type are unchanged.

### Metal AV1: the filters ahead of the next analysis on the GPU, measured, not kept (2026-11-03)

The owner asked for it after the timeline showed one picture in four's filters starting only
when the next picture's analysis ends. The analysis committed in three command buffers (after
the inter candidates, after the shapes; a temporary `GA_SPLIT`) so the filters' (another queue)
can run between them: those pictures' filters 24–26 → 20–22 ms, but the period unchanged (mean
39.5 → 40.1 ms; 26.2 / 25.6 against 27.1 / 26.0 inter frames a second, noise). The next closed
loop needs the next picture's analysis as well as these filters, and the GPU is busy through
both: letting the filters in first reorders the same work. Not kept. What would help there is
less GPU work a new picture (the analysis's ~25 ms, the filters' ~9), or a cheaper closed loop
now that the writer shares its cores.

### Metal AV1: a picture's write beside the next closed loop, handed on from the writer's thread (2026-11-03)

The owner's choice, in the latency-neutral form. The write's state (its own `Writer`, its
output, the reference slots' saved CDFs) is a `WriteSide` that a `WriteJob` takes with the
picture's record (`av1enc_hybrid_write_begin`), codes on the writer's thread
(`av1enc_write_job_run`) while the next picture's closed loop runs, and gives back
(`av1enc_hybrid_write_end`) once that picture's filters are chosen, before its own write begins.
The closed loop decides cdf_from_ref from the slots the writes begun so far will have CDFs for
(it codes nothing, so it needn't read them). Inter frames always overlap: they keep no tile, and
what a write notes for the next picture's tiles the next closed loop drops. A frame with kept
tiles (a still screen's key frames) is written in begin, as before. `encode(count:written:)` hands
each frame on from the writer's thread as soon as it's coded; `output` still gets it on the
encoder's thread. The same streams (`--digest` as before).

The rotation at 5K, q20, squares, `--no-planes`, interleaved twice: **23.4 / 23.9 → 26.0 / 26.4
inter frames a second**; typing-cc's stream 336.5 → 339.2. The timeline: the wait for the last
write 6.6 → 0.5 ms (median), but the closed loop 15.1 → 20.8, the writer now on its cores at the
same time. A first version wrote every frame synchronously in begin (every closed loop marks its
tiles valid): 22.5, slower than before.

### Metal AV1: where a new picture's period goes, and why the filters stay on the GPU (2026-11-03)

`GA_TIMELINE=1` (new: each picture's stages and the GPU's command buffers, stamped, on stderr),
the rotation at 5K, q20, squares on new pictures, `--no-planes`, 20 pictures: 23.9 inter frames
a second; per picture (from its analysis being read to the next's), median and range:

| | ms |
|---|---|
| waiting for the previous picture's writer (the closed loop shares its CPU state) | 6.6 (3.7–14.8) |
| the closed loop | 15.1 (12.9–28.2) |
| the filters (GPU 8.6–10.4 of them) | 10.8 (5.6–22.7) |
| reading the next analysis | 2.3 |
| the period | 43.9 (28.2–47.7) |

The four traces repeat: once in four pictures the filters wait ~10 ms behind the next picture's
analysis on the GPU (their command buffer starts when the analysis's ends), once the closed loop
takes ~27 ms (sharing the cores with the copy finder's and the next set-up's work), once the
writer wait is ~14 ms.

**The filters on the CPU don't pay** (the owner asked for them; measured before building):
deblocking takes 1.9 ms and a CDEF pass 5.6 ms of one core on a dense 1080p picture
(`bench_postfilter`), so ~13.5 and ~40 core-ms at 5K; the search filters every 64x64 with three
more candidate strengths a plane type, then CDEF is applied: ~150–175 core-ms a picture, 11–13
ms on all 14 cores at best, against the GPU's ~10.8 ms on the chain, and taken from the closed
loop and the copy finder, which already share the CPU. The architecture note's plan assumed idle
cores (corrected in "the closed loop's work, not its dependencies").

What the timeline says would shorten the period instead: the writer overlapped with the next
closed loop (~8 ms a picture on average: the latency-neutral form, delivering from the writer's
thread, is the owner's call), and the filters ahead of the next analysis on the GPU (~2.5 ms
on average, the one picture in four).

### Metal AV1: the analysis's forward transform, a lane's outputs split (2026-11-03)

The SIMD-group analysis's forward transform gives each lane a whole column, then a whole row, of
outputs: 32x32 and 64x64 on 128 threads run their row pass on 32 lanes, 2048 multiply-adds each.
`warp_fwd_ct` spreads a column's (row's) outputs over the idle lanes; each output still
accumulates over k in the same order, so the same streams (`--digest`, as below).

5K, the rotation, q20, per shape (ms, three interleaved runs each): 16x32 2.88 → 2.70, 32x16 2.78
→ 2.61, 64x64 2.68 → 2.55, but 16x16 2.26 → 2.55 and 32x32 3.30 → 5.8 (the compiler's registers,
presumably). Kept for the rectangles and 64x64 only (`warp_eval`), which `k_inter` shares.
End to end within noise (GPU 41.5 → 41.0 ms).

**Measured, not kept:** the thread-per-block kernel's threadgroup at 64, 256, 512 and 1024
threads instead of 128 (level or slower: 8x16 3.7 → 4.2 at 512).

**What's left, for the record** (a 5K picture of new content, ms of GPU): the thread-per-block
kernel 14.3 (screening ~9.6, its RD ~5.8; its private arrays' computed indices, apparently: edges
in threadgroup memory and unrolled loops were slower), the SIMD-group shapes ~13.5, inter
candidates ~7 (0.75–1.2 a shape: the new-content gate's two passes), leaves 4.4 (a SIMD-group a
leaf, most of its lanes idle on 4x4 chroma; float sums whose order a restructure would change),
motion search 3.1, learned pruning 2.2.

### Metal AV1: the analysis's screening without atomic contention or divergence (2026-11-03)

Where a 5K picture of new content's GPU analysis goes (`--profile`, the rotation, q20; by
switching stages off in the shader, which the source tree compiles at runtime): the shapes of
16x16 and up 17.5 ms, of which the SATD screening of the 13 modes 9.2, the RD of the best 5.9,
the rest (edges, flat check, residual) 2.4; the thread-per-block kernel's shapes (4x4 to 16x8 in
such pictures) 14.3 ms, of which screening ~9.6, RD ~5.8. Inter candidates 6.9 ms (0.75–1.2 a
shape, mostly the new-content gate's passes), leaves 4.4, motion search 3.1, learned pruning 2.2.

**Kept, the same streams** (`--digest`: the rotation, typing-cc's stream and key frames at 5K,
720p):
- each 4x4's SATD summed in registers by the lanes sharing a candidate before one atomic add a
  group (every lane added to the same threadgroup address before: up to 128-way). Each SATD is a
  multiple of 0.25 and a candidate's total stays below 2^22, so any order sums exactly;
- shapes with 8 or more 4x4s screened: four lanes a 4x4, a row each (its prediction and the
  Hadamard's row pass; the column pass by shuffles across the four), so a SIMD-group takes one
  candidate at a time instead of four with different prediction branches.

Per shape (ms): 16x16 2.75 → 2.26, 16x32 3.35 → 2.87, 32x16 3.22 → 2.78, 32x32 3.89 → 3.29, 64x64
4.31 → 2.71. End to end (interleaved, the Mac in use): GPU analysis 45.7 → 43.0 ms, 17.0 → 17.75
inter frames a second.

**Measured, not kept:** 8x8, 8x16 and 16x8 back on the SIMD-group kernel in such pictures (8x8
2.0 → 5.0 ms, the rectangles level); the thread-per-block kernel's screening loops unrolled
(8x16 3.7 → 4.3, 16x8 3.6 → 5.4: registers), its edges in threadgroup memory (8x16 → 4.5), and a
row's prediction work hoisted (no change: the compiler does it).

### Metal AV1: the closed loop's work, not its dependencies; cheaper tx trials (2026-11-03)

**The closed loop is bound by its work.** `GA_CRIT=1` (new: each split picture's task times on
stderr) on the four-trace rotation at 5K, q20: its wall time ~15 ms, its work ~185 core-ms (12–13
of 14 cores busy), its critical path (a tile's plan, then its longest chain of blocks by the
samples they read) 5–14 ms. Scheduling the critical path first can't buy anything; only cheaper
blocks can. (The architecture note's "~4–5 cores busy" was an estimate from `sample`'s average
over the whole period, waits included.)

**Where its work goes** (`sample`, the quantizer and the rate proxy out of line): the forward
transform 28 %, the quantizer 21 %, the inverse transforms and dequantization of the compared
trials ~12 %, RDOQ ~9 %, the residual's setup 9 %, the trials' SSE 7 %, the rate proxy 6 %.

**Byte-identical** (`--digest` the same; the oracle's differential tests pass):
- the quantizer's exact path two lanes at a time (NEON f64: the same multiply, divide, add and
  floor as the scalar code): ~2x on dense blocks;
- the rate proxy in raster order (each coefficient's scan position gives the last nonzero), a
  loop LLVM vectorizes: ~2.5x;
- the forward transform's first product shared by the types of a search with the same column
  kind and row flip (`Stage1Cache`): a column flip only reverses the order its rows are read in.
  An intra search's 7 types need 3 first products, an inter search's 16 need 4.

Rotation, q20, 24 pictures, interleaved: closed loop 18.5 → 15.9 ms (work 232 → 199 core-ms,
−15 %). Pictures a second unchanged (18.4–18.5): the GPU bounds them (42 ms of analysis, ~10 of
filters).

**Two decision changes, measured** (BD-rate against exact trials, rotation, q 14–32, RGB PSNR /
SSIMULACRA2):

| | BD-rate | closed loop |
|---|---|---|
| distortion in the transform domain (libaom's `tx_domain_dist`: the residual's energy less what the coded coefficients take of it, at the transform's gain per size and type) | 0.00 % / +0.02 % | −0.5 to −1 ms |
| the search stops at DCT_DCT when it codes nothing | +0.17 % / −0.15 % | −1 ms, −9 % of its work |
| both (`AV1HybridEncoder.quickTxTrials`, `av1seq --quick-tx-trials`; q 14–26) | +0.24 % / −0.08 % | −1 to −2 ms (noisy: runs paused and resumed) |

Built off: BD-neutral, but they change the streams, so the owner's call. On since (the owner chose it the same day; `av1seq --exact-tx-trials` turns it off).

### Metal AV1: what buys speed on a picture of new content, at what bytes (2026-11-03)

A 5K picture new against both references (the four-trace rotation, q20) takes ~55 ms: the GPU
bounds it, ~42 ms of analysis beside ~15 ms of filters (the filters' wall time on a GPU the next
picture's analysis shares: `av1seq` now prints it). Stage by stage (`--profile`): analysis 32.4 ms
spread over every shape (4x4 1.5 · 4x8 1.7 · 8x4 1.7 · 8x8 2.0 · 8x16 3.7 · 16x8 3.6 · 16x16 2.8 ·
16x32 3.4 · 32x16 3.2 · 32x32 3.9 · 64x64 4.4), inter candidates 6.9, leaves 4.4, motion search
3.0, learned pruning 2.2. The closed loop takes ~19 ms of CPU, the write ~8 (on its thread).

Three levers, each only in pictures coding more than half their 64x64s, measured on the rotation
(24 pictures, q 14–32; BD-rate by RGB PSNR / SSIMULACRA2 against today's; inter frames a second;
the GPU's analysis a picture):

| | BD-rate | inter frames a second | GPU analysis (ms) |
|---|---|---|---|
| today | — | 17.7–19.1 | 40.7–43.5 |
| **shapes: no 8x16 / 16x8** (`--new-shapes 13CF`) | +0.45 % / +0.42 % | 19.3–22.4 | 33.7–36.1 |
| shapes: no 16x32 / 32x16 (`127F`) | +0.37 % / +0.64 % | 18.8–21.5 | 35.5–38.1 |
| **shapes: squares, 4x8, 8x4** (`124F`) | +0.95 % / +1.08 % | 20.8–24.2 | 28.0–30.8 |
| **shapes: squares** (`1249`) | +1.58 % / +1.66 % | 22.1–25.5 | 24.8–26.7 |
| shapes: squares from 8x8 (`1248`) | +10.1 % / +7.8 % | 23.0–25.5 | 23.3–24.0 |
| learned pruning, eps 0.05 (levels, modes, chroma) | +2.2 % / +1.9 % | 17.8–20.8 | 36.7–38.7 |
| learned pruning, eps 0.2 | +8.4 % / +9.2 % | 20.1–23.0 | 29.6–32.0 |
| learned pruning, eps 0.35 | +16.4 % / +27.1 % | 20.9–24.5 | 26.2–28.5 |
| preset turbo2 (= turbo3 here: angle deltas are off in such pictures) | +8.8 % / +6.1 % | 20.0–21.6 | 35.8–37.7 |
| turbo2 and eps 0.2 | +17.7 % / +16.4 % | 22.0–25.3 | 25.8–27.6 |
| tiles 3x1 instead of 3x0 | +0.6 % / +0.2 % | 18.0–19.3 | 40.8–44.3 |

The shapes win: rectangles cost 43 % of the analysis and buy ~1.5 % of a new picture's bytes.
`AV1HybridEncoder.newPictureShapeMask` (`av1seq --new-shapes`), off: a bytes trade, the owner's
choice. With it set, the single traces are byte-identical (no picture of theirs is mostly new)
and the two-screen mixes +0.1 % (their first inter frame, before GOLDEN_FRAME has a picture).

The motion search in such pictures saves 3.9 % of their bytes (q20: 497 → 478 KB) for ~10 ms of
GPU (`--no-motion-search`: 41.5 → 31.1 ms). Squares and no motion search together: the GPU's
analysis 17.8 ms, +3.8 % bytes, but only 25.5 inter frames a second, because the period is no
longer the GPU's. Each picture's closed loop (~17 ms) predicts from the previous picture's filtered
output, so it waits for those filters (~9–11 ms of GPU): closed loop, filters, closed loop is a
serial chain of ~28 ms a picture, plus ~12 ms of reading the analysis, applying copies and
waiting on the last write.

None of these reaches 60 a second: at best ~25, where that chain bounds it.

**The rest of the levers** (the rotation, 24 pictures, q 14–32, against today's; q20's stages):

| | BD-rate | inter frames a second | at q20: closed loop / filters' GPU / writer (ms) |
|---|---|---|---|
| tiles 4x0 / 4x1 / 5x1 | +0.8/+0.2, +1.4/+0.4, +1.8/+0.6 % | unchanged (18–20) | the closed loop unchanged (~18.5; it is block-parallel already); writer 8.4 → 6.9 / 5.5 / 5.1 |
| no tx type search (`--no-tx-search`) | +8.9 % / +6.8 % | unchanged | closed loop 18.5 → 10.9 |
| only 8x8 and 16x16 (`--new-shapes 0048`, no motion search) | +30 % / +33 % | 13.8–14.5 (slower) | closed loop 43: the CPU's cost follows the number of blocks |

**Everything cheap at once** (squares, no motion search, no tx type search, tiles 4x1; 40
pictures, q 8–40): **30–35 inter frames a second** on pictures that are all new, for +15.3 % /
+11.9 % bytes against today's; against libaom +7.7 % / −0.7 %, against hardware HEVC −35.8 % /
−13.8 % (BD-rate by PSNR / SSIMULACRA2). At q20: GPU analysis 18.8 ms, closed loop 10.2, filters
14.3 (their GPU 11.3), writer 6.3. The all-GPU encoder (av1gpu's closed loop on the GPU, 98
dependent wavefront steps) takes 749 ms for one such picture, against the hybrid's ~100
(`av1still --hybrid`, scroll-win, q20).

**Decisions without RD:** the CPU's open-loop proxy (`Decider::node`, the reference engine's:
squares, NONE vs SPLIT and the mode by the Hadamard-domain proxy, blocks up to 32x32) in place of
the GPU's partition for the coded 64x64s of mostly new pictures (a temporary switch, not kept):
**+76.0 % / +64.5 %** against today's (no motion search in both), +66.1 % / +46.2 % against
libaom, −0.9 % / +27.2 % against HEVC; 5 pictures a second (the proxy on the CPU). With 64x64
blocks allowed it lost 10 dB at q8: a 64x64 transform codes only its 32x32 lowest frequencies,
which the proxy doesn't see. The RD search is what earns the bytes (squares through it: +1.6 %).

**The Rust post-filters at 5K:** deblocking and CDEF of a dense picture (8x8 and 16x16 coded
blocks, random samples, 8 CDEF presets) take ~70 ms on one thread (`postfilter`, a scratch
example). Rows in parallel on 14 cores would be ~5–7 ms.

**The CPU's work a picture** of the rotation: a `sample` of 6 s while encoding finds ~3 of the 14
cores busy on average, ~165 core-ms a picture at 18 a second; of the busy time the closed loop's
tx trials, quantizer and RDOQ 42 %, libaom's decode check (the bench's) 15 %, the closed loop's
reconstruction 11 %, the writer 9 %, the copy decisions 7 %, memmove 5 %, the bench's trace
handling 4 %. **The encoder's ~135 core-ms fits the ~233 that 60 a second allows on 14 cores: the
CPU is idle ~80 % of the time, waiting in the chain.** (A first estimate from user + system time,
~480, counted the bench reading and converting the traces up front.) `docs/AV1-ENCODER-ARCHITECTURE.md`
proposes what to do about all this. No hardware AV1 encoder here (VideoToolbox on the M4 Pro lists HEVC, H.264,
ProRes and JPEG). Not kept: copying GOLDEN_FRAME's planes beside the closed loop instead of after
it (~0.7 ms of CPU; no difference in pictures a second, which the GPU bounds).

### Metal AV1: GOLDEN_FRAME, and where libaom beat us on a full-screen change (2026-11-02)

**The comparison** (5K, 40 pictures from 100; the hybrid and libaom realtime speed 9 at q 8–40,
hardware HEVC at fixed QP 18–42 (`vquality --qp` and `--mix`, new), all scored the same way
(`--score-rgb` now follows `--mix`: RGB luma PSNR, and SSIMULACRA2 on every 4th picture); bytes are
the average picture's, the key frame included). Before this change, BD-rate of the hybrid:

| mix | vs libaom, by PSNR / SSIMULACRA2 | vs HEVC | inter frames a second: hybrid / libaom |
|---|---|---|---|
| typing+scroll | +29.7 % / +24.3 % | −43.3 % / −20.7 % | 20–22 / 27–36 |
| photos+drag | −6.9 % / −4.3 % | −34.9 % / −13.7 % | 13–15 / 13–18 |

(HEVC's encode latency is 34–37 ms a picture.) On the single traces the hybrid was already 33–58 %
under libaom (the 2026-11-01 re-baseline); the mixes were the gap.

**Where libaom's lead came from**, counted in its bitstream writer (bits per block by kind and by
reference; a temporary patch, not kept), q20, KB a picture:

| picture | ours | libaom | libaom, palette off |
|---|---|---|---|
| typing (after a scroll picture) | 275 | 170: 51 % of its area from GOLDEN_FRAME, its key frame | 130 |
| scroll (after a typing picture) | 319 | 290: 227 of it in 16x16 palette blocks | 570–600 |

- **Its second reference, three quarters of the gap.** libaom's realtime mode keeps the key frame
  as GOLDEN_FRAME, and each typing picture copies the typing picture before from it. (libaom limited
  to LAST_FRAME by `AOM_EFLAG_NO_REF_*` gave identical bytes, because its realtime reference
  structure ignores those flags: the count by reference showed it.)
- **Palette, the rest.** On new content libaom's palette (the colours as the prediction, a DCT
  residual on top) halves its intra coding, which without it is far worse than ours (570–600 vs
  319 KB); with it libaom is 10 % under us there. This reopens the 2026-11-01 palette decision for
  inter frames at 5K: that measurement scored lossy palettes without a residual, and libaom's at
  720p. A first prototype of ours (k-means of 8x8 to 32x32 intra nodes, chosen by the Hadamard
  proxy) chose palettes everywhere and saved nothing (1.4–1.5 bits a pixel in them): not kept.
- Identity transforms (libaom's `use_idtx_nonrd`) moved it ±2 %.

**GOLDEN_FRAME.** Inter frames copy an older picture too: GOLDEN_FRAME's, the last one before the
latest picture that was mostly new.
- Writer (Rust): `fp.golden_slot` (GOLDEN_FRAME's slot + 1, in the reserved byte; 0 as before),
  `is_inter` 4 for a GOLDEN_FRAME block. read_ref_frames with count_refs' contexts (single_ref
  p1/p3/p5), the MV stack for either reference (its extra search takes either), each block's
  prediction from its own, and the loop filter's GOLDEN_FRAME delta at −63 like LAST_FRAME's. The
  parser reads them; random sequences with GOLDEN_FRAME blocks (a stream of their own in
  `inter_gen`) round-trip and decode exactly in dav1d, aomdec and the vendored libaom.
- Copies (`Motion::classify_ex`): the 64x64s that don't copy the previous picture are tested
  against GOLDEN_FRAME's source, unchanged or at a shift (the neighbours' shifts and its own row
  and column candidates); they skip the analysis as copies do.
- Slots: a picture most of whose 64x64s don't copy the previous one swaps them: it goes into
  GOLDEN_FRAME's slot, and the previous picture becomes GOLDEN_FRAME (its decoded planes copied out
  of the filters' buffers before this picture's filters overwrite them). Switching back to what
  was on screen copies it. On by default (`AV1HybridEncoder.goldenFrames`, `av1seq --no-golden`).

The single traces never swap: byte-identical streams, speed within noise. The mixes, q20:

| | inter frames | inter frames a second | 64x64s copied from GOLDEN_FRAME |
|---|---|---|---|
| typing+scroll | 317 → **14.1 KB** | 21 → **128** | 79 % |
| photos+drag | 735 → **76.4 KB** | 14 → **48** | 89 % |

BD-rate with it (libaom and HEVC as above):

| mix | vs libaom, by PSNR / SSIMULACRA2 | vs HEVC | inter frames a second: hybrid / libaom |
|---|---|---|---|
| typing+scroll | **−90.3 % / −90.5 %** | −95.8 % / −93.9 % | 124–150 / 27–36 |
| photos+drag | **−87.3 % / −86.8 %** | −90.9 % / −88.0 % | 47–52 / 13–18 |

These mixes are two screens in turn, the best case for a second reference (libaom keeps only its
key frame there; we keep whichever screen came before). A picture new against both references is
the worst case: `--mix` now takes several traces in turn for it. **Four traces in turn** (typing,
scroll, photos, drag; 21 % of 64x64s still copy, the shared wallpaper and menu bar, 4 % of them
GOLDEN_FRAME's):

| | vs libaom, by PSNR / SSIMULACRA2 | vs HEVC | inter frames a second: hybrid / libaom / HEVC |
|---|---|---|---|
| typing, scroll, photos, drag | **−6.7 % / −11.3 %** | **−44.2 % / −22.8 %** | 18–20 / 20–25 / ~28 (34–37 ms latency) |

The bytes beat both everywhere now; the speed doesn't. A 5K picture of new content, q20: GPU
analysis ~42 ms, closed loop ~19, filters ~24, write ~8 (the GPU bounds the period).

### Metal AV1: a block on several SIMD-groups for the analysis's big shapes (2026-11-02)

The analysis kernel (k_analysis.h) gave each block one SIMD-group: a 64x64's 4,096 samples, 13
modes' screening and its candidates' 64-point transforms on 32 threads, ~20 KB of scratch held
the whole time. It now takes NT threads to a block (a template parameter, default 32: the
SIMD-group code as it was): the loops stride by NT, `__syncwarp` becomes a threadgroup barrier,
and the sums (screening's, the residual's energy, distortion, bits, the eob's maximum) are
SIMD-group sums then the SIMD-groups' partials in a fixed order (`ga_sum`, `ga_max`, dev_tx.h).
The transform's columns and rows stay one thread each, so its outputs don't change. NT per shape,
`--profile` 5K key frames (typing-cc / photos, ms; NT 32 = one SIMD-group a block as before):

| | 16x16 | 16x32 | 32x16 | 32x32 | 64x64 |
|---|---|---|---|---|---|
| 32 | 2.84 / 3.89 | 3.70 / 4.65 | 3.55 / 4.58 | 5.80 / 7.44 | 9.5 / 10.2 |
| 64 | 3.94 / 5.75 | **3.17 / 3.89** | **3.06 / 3.89** | 3.80 / 4.74 | 5.48 / 5.97 |
| 128 | | 4.60 / 5.46 | 4.40 / 5.38 | **3.67 / 4.43** | **3.97 / 4.26** |
| 256 | | | | 5.70 / 6.68 | 4.08 / 4.33 |

Taken: 64 for 16x32 and 32x16, 128 for 32x32 and 64x64 (`GA_ANALYSIS_T`, kernels named
`_w1t<NT>`); 16x16 and smaller keep four one-SIMD-group blocks a threadgroup. **Every stream is
byte for byte the same** (`--digest`, the four traces' key frames and streams at q8, q20 and q32):
the sums' new order changed no decision. (The scratch's reduction slots pushed the unused 16x64
and 64x16 from 4 to 3 blocks a threadgroup.)

Median of 2 runs alternated with the commit before (30 key frames; 60-frame streams):

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K key frame, GPU (ms) | 47.2 → **38.5** | 38.5 → **32.8** | 63.6 → **53.2** | 46.2 → **37.5** |
| 5K key frame, picture (ms) | 52.0 → 50.8 | 49.8 → 50.1 | 81.9 → **77.7** | 50.4 → 49.8 |
| 1440p key frame, GPU (ms) | 17.4 → 15.1 | 17.1 → 14.8 | 19.4 → 17.2 | 16.6 → 15.9 |
| 720p stream, inter frames a second | 1137 → 1252 | 392 → 405 | 174 → 193 | 710 → 944 |

Full-change mixes (inter frames a second, GPU ms): 5K typing+scroll 19.3 → **20.6** (44.2 → 38.8),
photos+drag 11.9 → **13.3** (71.5 → 62.1); 1440p 55.6 → 60.9 and 38.0 → 41.6. 5K streams at three
runs each: typing-cc 363 → 364, scroll-win 256 → 264, cursor-drag 330 → 340. A 5K key frame of text
is bound by the CPU again (its finish ~49 ms against the GPU's ~39).

**The inter candidates likewise** (k_inter, NT 64 for 16x32 and 32x16, 128 for 32x32 and 64x64;
its SAD sums `ga_sumu`). `--profile`, 5K full-change mixes: inter candidates 7.8 → **6.05 ms**
(typing+scroll), 9.05 → **6.87** (photos+drag). The same streams on every trace and on the mixes
but photos+drag at q8 (a decision the sums' order moved: BD 0.00 % by PSNR-Y, q 8–32). Median of
2, against the commit before: 5K mixes 20.7 → **21.4** and 13.3 → **13.8** inter frames a second
(GPU 38.9 → 37.0, 62.5 → 59.3 ms); 1440p and ordinary streams within noise.

### Metal AV1: full-screen change inside a stream, and the inter gate (2026-11-02)

**A benchmark for it.** A key frame isn't what a stream codes when the whole screen changes (a
switch of Spaces, apps or windows): that's an inter frame, with no intra block copy, filtered and
written on the writer's thread. `av1seq --mix <trace>` (new) alternates the pictures with another
trace's, so every superblock changes from picture to picture (scoring with `--score-rgb` compares
against the first trace only, so for a mix the hybrid's own PSNR-Y counts). 5K, typing-cc mixed with
scroll-win, q20: 14.3 inter frames a second; the GPU's analysis 64 ms and the filters (waiting on
the GPU beside the next analysis) 43 ms. Stage by stage (`--profile`): **the motion search 13.7 ms**
(k_proj 1.0, k_me 10.9, k_inter_sad 2.0) and **the inter candidates 16.7 ms**, beside the intra
analysis's 22.7: half the GPU spent looking for motion in new content.

- No better: k_me and k_inter at other threadgroup sizes; k_me's windows loaded into threadgroup
  memory (13.7 → 17.4 ms: its lanes' reads were already neighbours).

**The inter gate** (`AV1HybridEncoder.interGate`, `av1seq --inter-gate`, GpParams.interGate): in a
picture that codes more than half its superblocks, a 16x16 whose search windows' centres (no
motion, each candidate) all predict worse than 2 x its SAD to its own mean doesn't search the
windows (k_me), and a block whose best candidate does worse than that costs no inter RD (k_inter:
no inter result). Motion search 13.7 → **4.3 ms**, inter candidates 16.7 → **7.8 ms**.

BD-rate by SSIMULACRA2 (PSNR) against off, 60 frames from 100, q 8–32:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K streams, gate 2 | 0.0 % | −0.1 % | −0.1 % | 0.0 % |
| 720p streams, gate 2 (in any picture) | 0.0 % | +0.5 % | 0.0 % | 0.0 % |
| 720p streams, gate 2, pictures coding > 0.5 (taken) | 0.0 % | −0.2 % | +0.1 % | 0.0 % |
| 720p streams, gate 1 (in any picture) | 0.0 % | +1.1 % | +2.4 % | 0.0 % |

The mixes by the hybrid's PSNR-Y: typing+scroll −0.1 % (5K) / −0.2 % (720p), photos+drag −0.2 % /
0.0 %. Gate 3 and 4 kept 720p scroll-win at +0.5 % in any picture: the cost was inter RD skipped
on a resampled scroll (inter still wins there at a high SAD), hence only where most is new.

Taken, on by default (2). Inter frames a second, median of 2 alternated runs (60 frames, q20):

| | typing+scroll mix | photos+drag mix | scroll-win | photos |
|---|---|---|---|---|
| 5K | 14.3 → **19.1** | 9.3 → **11.1** | 248 → 251 | 101 → 101 |
| 1440p | 46.0 → **55.5** | 30.9 → **35.4** | 347 → 322 | 153 → 151 |

(the 5K mixes' GPU analysis 65.4 → 47.2 and 100.5 → 82.5 ms; sizes −0.1 to −0.2 %.)

**Where a full change's period goes now** (5K, typing+scroll mix, a per-picture timeline): ~50 ms,
bound by the GPU (the next picture's analysis, ~41 ms, beside this one's filters, ~11). The CPU's
path is ~2 ms reading the analysis, ~4 ms waiting for the last picture's write, ~17 ms of closed
loop, then waiting on the filters.

- **Not taken: the write overlapped with the next closed loop.** Byte-identical, but it would need a
  second writer, the tiles' memory split (the write's payloads apart from the closed loop's tile
  state, with a generation per tile in place of payload_valid), the CDEF indices and
  cdf_from_ref decided at write time, and the record shared with the write thread. And frames go to
  `output` on the encoding thread, which would be in the next closed loop when a write finished:
  each frame's bytes up to a closed loop later (~17–20 ms at 5K). Latency matters more than
  throughput here; the owner's choice. Done again, it would want frames delivered from the writer's
  thread.
- **Not possible: CDEF applying its strength search's outputs** instead of filtering again (p_cdef,
  ~3 ms of a 5K picture's ~11 ms of filters). The search's arithmetic is the spec's, but from
  qindex 33 to 220 (tuneiq's CDEF_ADAPTIVE, libaom's) the presets signal half the searched
  strengths, so the filter applied is never one the search measured.
- **Not taken: a faster intra block copy search split finer than tiles.** Exact parallelism inside a
  tile isn't possible (a block's choice depends on the tile's earlier copies), so it would be a
  bytes trade, for key frames only.

**Then: an inter frame's 8x8s on the thread-per-block kernel where most of the picture is new.**
Inter frames give the SIMD-group kernel every shape of 64 samples and up, because where inter
prediction leaves nothing to code a block skips its intra search and a thread-per-block SIMD-group
waits on its slowest block. In a picture mostly new few blocks skip: there the 8x8s' analysis
takes 3.16 → **1.96 ms** at 5K on the thread kernel (8x16 and 16x8: no better, so they stay). The
same streams (`--digest`; BD 0.0 % on every trace and both mixes). The mixes, median of 2:

| | typing+scroll mix, GPU (ms) / inter frames a second | photos+drag mix |
|---|---|---|
| 5K | 46.4 → 45.2 / 18.6 → 19.1 | 81.6 → **76.1** / 10.9 → 11.3 |
| 1440p | 16.5 → 15.9 / 53.1 → 55.6 | 25.6 → 24.3 / 34.6 → 36.1 |

And 8x16 and 16x8 likewise (no better on the typing+scroll mix, but photos+drag's 5.30 → 3.68 and
5.35 → 3.55 ms): the same streams again. Median of 2, against the 8x8s alone:

| | typing+scroll mix, GPU (ms) / inter frames a second | photos+drag mix |
|---|---|---|
| 5K | 45.5 → 44.6 / 19.4 → 19.7 | 76.9 → **71.6** / 11.4 → 12.0 |
| 1440p | 15.8 → 15.4 / 55.4 → 55.9 | 24.4 → **22.9** / 36.1 → 38.0 |

### Metal AV1: a key frame's intra block copy hashes taken while its analysis runs (2026-11-02)

The copy search hashes the luma 8x8 at every even position before it looks for copies (5K: 3.7 M
hashes, ~17 ms of CPU threads, ~1.5 ms of the picture's finish). They read only the source, so they
are now taken in `begin`, on its thread while the GPU analyzes (`av1enc_ibc_hashes_compute`, from
the picture as the hybrid pads it: its last row and column repeated), and swapped into the hybrid
right before the closed loop (`av1enc_hybrid_use_ibc_hashes`, no copy), whose search then skips them.
A Rust test holds them to the search's own on every test picture (333 x 517 among them) and the
search given them to the search alone. Every stream is the same (`--digest`).

5K key frames, 30 frames, two runs alternated with the commit before (ms):

| | typing-cc | scroll-win | cursor-drag |
|---|---|---|---|
| the copy search's stage ("CPU chroma") | 18.6 → **17.0** | 16.9 → **15.4** | 17.5 → **16.0** |
| picture | 52.8 → 51.8 | 50.0 → 48.7 | 50.6 → 50.5 |

### Metal AV1: one warp a threadgroup for the analysis's 16x32, 32x16 and 32x32, their inter search, and the leaves (2026-11-02)

The analysis kernels put NW warps in a threadgroup, each on its own block: av1gpu's 4, or fewer
where their scratch passes 32 KB (32x32: 3, 64x64: 1). Run with one warp a threadgroup (the same
results: each block is still one warp's), the big shapes got much faster, not slower. `--profile`,
5K key frames, ms (typing-cc / scroll-win / photos), NW as before → 1:

| | 16x16 | 16x32 | 32x16 | 32x32 | leaves (k_leaf, LEAF_NW 4 → 1) |
|---|---|---|---|---|---|
| before | 2.89 / 2.53 / 4.03 | 4.78 / 3.39 / 6.12 | 3.63 / 2.76 / 5.19 | 8.65 / 6.23 / 11.38 | 6.6 / 7.0 / 6.9 |
| one warp | 3.05 / 2.60 / 4.53 | **3.68 / 2.46 / 4.63** | **3.35 / 2.28 / 4.34** | **5.80 / 3.85 / 7.44** | **4.7 / – / 5.8** |

Two warps sat between. Taken: 1 for 16x32, 32x16 and 32x32 (and their inter candidate search,
k_inter: photos' inter frames 2.43 → 1.96 ms), and for the leaves; 16x16 and the smaller shapes
keep 4, 64x64 had 1. Unchanged at one warp: the motion search (k_me). Why it pays isn't measured: a
threadgroup holds its warps' scratch (to ~27 KB) until its slowest block is done, and smaller
groups pack the cores more freely.

Every stream is the same (`--digest`). Median of 2 runs alternated with the commit before, q20:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K key frame, GPU (ms, 30 frames) | 53.1 → **47.0** | 44.3 → **38.3** | 71.3 → **63.9** | 51.9 → **46.2** |
| 5K key frame, picture (ms) | 58.8 → **52.7** | 51.3 → 51.5 | 89.9 → **82.0** | 56.1 → **53.1** |
| 5K stream, inter frames a second | 262 → 363 | 239 → 270 | 97.0 → 107 | 361 → 356 |
| 1440p key frame, GPU (ms) | 19.0 → 17.2 | 16.8 → 16.1 | 22.1 → 19.8 | 18.4 → 16.5 |
| 720p key frame, GPU (ms) | 8.4 → 7.5 | 7.9 → 7.3 | 8.1 → 7.9 | 8.4 → 7.2 |
| 720p stream, inter frames a second | 985 → 1133 | 506 → 538 | 217 → 228 | 773 → 737 |

A 5K key frame of scroll-win is now bound by the CPU (its GPU dropped 6 ms, its picture didn't).
(The 5K typing-cc stream's 262 is a slow first run of the commit before; the other read 363.)

**The other kernels, swept the same way** (5K photos key frames, each stage of the filters' search
committed alone; ms). The filters' search is ~10.9 ms of GPU alone (~16 ms beside the next
picture's analysis), and photos' key frames are bound by the GPU (analysis ~64 + filters):
l_cdef_sse 3.85, p_cdef 3.09, p_deblock 2.92, p_cdef_dir 0.73, l_select 0.28, the rest < 0.1.
- **Taken: p_deblock's threadgroups 8 x 8** (32 x 4 before): 2.92 → **2.59 ms** (4 x 16, 8 x 16,
  8 x 4 about as good; 16 x 8 and 2 x 16 no better). The same streams.
- No better: p_cdef and p_cdef_dir at any of 64x1 … 16x16 (their 32 x 8 and 16 x 8 are best);
  l_cdef_sse at 64 or 128 threads (256: 3.89, 128: 3.91, 64: 3.96); the thread-per-block analysis
  kernel at 32 … 256 threads (128 stays); the motion search (k_me) at one warp.

### Metal AV1: learned pruning's statistics in one pass per SB, from whole-number sums (2026-11-02)

The node statistics were 3.1 of learned pruning's ~3.9 ms on a 5K picture: a thread per node per
level, each walking all its node's samples (4,096, twice, for a 64x64), with neighbouring threads
far apart in memory. Every statistic but the variance is a sum of whole numbers that a node's four
children add up to: the sums and the quadrants' (its children's), the values held and their range,
the neighbour differences (with the pairs across its middle row and column), and the orientation
bins of its interior (with the samples on those middle rows and columns). **Now one threadgroup of
64 per SB visits each sample once:** a thread per 8x8 cell takes its samples; a pair of neighbours
goes to the smallest node holding both, and a sample's orientation to the smallest node it's inside
the border of (by threadgroup atomics above the cells: whole numbers, so their order doesn't
matter); a node above the cells is its children's sums with its seams'.

- The 8x8 and 16x16 nodes' features are bit-identical (compared on scroll-win and photos: all
  288,000 nodes). At 32x32 and 64x64 the variance features differ (log variance at both, the
  quadrants' least and greatest at 64x64; up to 0.02): the sum of squares is now exact, where a
  float sum rounded past 2^24 (closer to the trainer's f64 features than before).
- 2 of 16 checked streams changed; BD-rate over q 8–32, 5K key frames and streams, every trace:
  **0.0 %** by PSNR and SSIMULACRA2, every point the same size to the reported precision.
- `--profile`, typing-cc 5K: learned pruning 3.85 → **2.02 ms**. A 5K key frame over 30 frames,
  median of 2 alternated runs: typing-cc 58.6 → **56.8**, scroll-win 50.4 → 50.0, photos 89.5 →
  **87.7**, cursor-drag 57.0 → **55.3** ms.
- A first version, a threadgroup per SB with one thread per node climbing the levels (16, 4, then
  1 thread doing a 64x64's seams), was slower (6.6 ms): too few threads up top, and its
  threadgroup memory capped occupancy.

**The floor, measured again** (`av1seq --ml-min-sbs`, new): with the statistics this cheap, below
2,000 superblocks. The GPU's analysis per key frame, models off → on (20 frames, q20), and BD-rate
by SSIMULACRA2 over q 8–32 (key frames / streams):

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 1440p (920 SBs), GPU (ms) | 23.5 → **19.0** | 21.0 → **16.7** | 23.9 → 22.1 | 23.4 → **18.4** |
| 1440p, BD | −0.2 / −0.1 % | +0.2 / 0.0 % | +0.3 / 0.0 % | 0.0 / 0.0 % |
| 1080p (510 SBs), GPU (ms) | 14.3 → 14.3 | 13.2 → 13.4 | 15.6 → 13.9 | 16.1 → 13.8 |
| 1080p, BD | +0.4 / +0.3 % | +0.5 / +0.7 % | +0.1 / 0.0 % | +0.1 / +0.1 % |
| 720p (240 SBs), GPU (ms) | 9.1 → 8.2 | 8.3 → 8.1 | 8.6 → 9.2 | 8.9 → 8.2 |
| 720p, BD | +0.1 / −0.2 % | 0.0 / 0.0 % | +0.3 / −0.2 % | +0.2 / −0.2 % |

**The owner's choice: the floor down to 900 superblocks**, 1440p and up (`learnedPruneMinSuperblocks`).
At 1080p the models cost up to 0.7 % of bytes for a GPU saving on two traces of four, and 720p's
moves are within noise; both stay off. Pictures at these sizes are bound by the CPU, so the
pictures' times don't move yet: what's saved is the GPU's.

**The passes over the stale SBs only.** With kept analysis, each pass now skips kept SBs and is
dispatched over the stale list (`B.sbList`), so its cost follows what changed: the statistics a
threadgroup per stale SB, the cells' network 64 threads a stale SB, the tree one, the modes their
level's nodes in a stale SB, the lists its blocks. The same streams (`--digest`). It changes
nothing on these traces' measurements (their pictures that run the models analyze every SB).

**Measured, not taken: the models on every picture of a stream** (`--ml-over 0`, against the share
of 0.5), with the passes over the stale SBs only. The GPU's analysis per inter frame, 100 frames,
q20, two runs:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K (ms) | 1.3 → 1.5–1.6 | 2.6 → **2.1** | 9.0 → **8.0** (25.7 → 25.9 KB a frame) | 1.5 → 1.4 |
| 1440p (ms) | 0.8 → 0.9–1.0 | 1.6 → **1.4** | 5.2 → 5.6–5.7 | 1.0 → 0.8–0.9 |

A small change can't carry the passes' cost (typing-cc), and photos pay 0.8 % of bytes at 5K and
lose time at 1440p.

**Rejected: the passes fused into one kernel** (`k_ml_sb`, a threadgroup of 64 per SB doing the
statistics, both networks, the tree and the lists in turn between threadgroup barriers; the same
models and the same streams). Learned pruning at 5K 2.02 → **3.95 ms**, and no better on streams
with the models on every picture (typing-cc 5K 1.4 → 1.6 ms, as unfused). Apart, each pass fills
the GPU (230 k cells, ~300 k nodes, up to ~2 M blocks for the lists); together they run in 64-thread
groups holding ~11.5 KB of threadgroup memory each (fewer resident at once), and every SB pays its
own chain of serial points (the tree on one thread, two rounds of mode nodes). The barriers it
saved were tenths of a millisecond, and a few SBs' cost is each SB's own chain of work, which
fusing lengthens.

**Measured, not taken: the models in pictures coding at least N superblocks** (`--ml-min-coded`,
new; besides the share rule). The GPU's analysis per inter frame (100 frames, q20):

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K, share rule → ≥ 50 SBs (ms) | 1.3 → 1.3 | 2.6 → **2.0** | 8.9 → 7.9 (25.7 → 25.9 KB) | 1.5 → 1.5 |
| 1440p, share rule → ≥ 50 SBs (ms) | 0.7 → 0.7 | 1.5 → **1.3** | 5.1 → 5.7 | 1.0 → 1.0 |

Typing-cc's and cursor-drag's pictures code fewer; scroll-win gains; photos (mostly video, which the
models weren't trained on) pays bytes at 5K and time at 1440p. **The owner's choice: the share rule
stays** until video traces (on the wanted list) can teach the models video.

**Measured and rejected, a time context for the models** (the transformer question's cheap
version): in a stream, what the search chose at the same place in the previous picture. On pairs of
consecutive frames (5K q20, four pairs a trace, every picture analyzed whole), a changed 8x8 cell
keeps its level no more often than the most common level alone would predict it: photos 30–35 %
against 32–34 %, cursor-drag 46 % against 44 %, scroll-win 51 % against 58 %. The level model
misses 2–3 %. Changed content isn't the content that was there.

### Metal AV1: flat blocks with flat edges skip their search, results unchanged (2026-11-02)

A block whose source is one value, with the edges it predicts from (above and above-right, left
and below-left, the corner) that value too, is predicted exactly by every intra mode: each
candidate screens at SATD 0, and its RD is an all-zero block's (distortion 0, the txb_skip bits,
whatever the mode or tx type, so the tx type search can't beat DCT_DCT). Both analysis kernels
(k_analysis.h, k_analysis_small.h) now compute exactly that without the predictions and
transforms. Every stream is the same (`--digest`, four traces).

Share of such blocks at 5K, of all positions (8x8 / 16x16 / 32x32 / 64x64): typing-cc 30 / 22 /
13 / 6 %, scroll-win 52 / 43 / 33 / 26 %, photos 35 / 28 / 19 / 8 %, cursor-drag 31 / 22 / 12 / 4 %.
Fewer reach the kernels: with learned pruning (5K), flat areas keep only their large level, so
the small shapes' lists hardly hold any, and most of a large shape's time is its other blocks.

`--profile`, the GPU's analysis (ms), before → after:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K | 44.3 → 44.6 | 36.0 → 35.6 (64x64 6.76 → 6.38) | 60.9 → 61.5 | 43.8 → 44.2 |
| 720p (no learned pruning) | 7.4 → 7.3 | 7.4 → **6.9** | 6.6 → 6.7 | |

Kept: a small, byte-identical gain where screens are flat (scroll-win 720p −7 %), nothing lost
elsewhere.

### Metal AV1: the closed loop stops coding its tiles; learned pruning's buffers kept (2026-11-02)

**Where a 5K key frame's time went** after RDOQ (typing-cc, `sample` and a per-picture timeline):
the pipeline's period is about 59 ms, the CPU's `finish` (copy search 18, closed loop 29, writer 9
inline: a key frame with copies has no filters) against the next picture's setup (4 ms) and GPU
analysis (54 ms). The workers are only 40–47 % busy, so the CPU stages are bound by their chains
and not by cores. Per tile, the closed loop's three phases (the plan's walk, the blocks on every
thread, then the tile's coding walk) showed what bound it: **each tile's coding came last on its
critical path, 4–8 ms on typing-cc and 4–13 ms on photos, and its symbols are discarded.** The
hybrid codes the frame again in `write_ex` once the filters are chosen. (An earlier measurement
on inter frames called that coding negligible; on key frames it isn't.)

**What changed:**
- **The closed loop doesn't code** (`ENC_NO_CODE`, internal to the writer). With the blocks
  reconstructed on several threads, a tile's coding task finishes without coding: no payload,
  saved CDFs or symbols, none of which the hybrid reads from the closed loop. A tile that the plan
  rejects is still reconstructed in its coding walk, as before.
- **Learned pruning's buffers are kept** by the encoder from picture to picture, uncleared. The
  ML kernels write every entry they read: node statistics, modes, cells' keeps, the skip mask and
  the block lists, whose counts the GPU clears. Before, each picture made and zeroed 29 MB
  (statistics 19.6 MB, lists 9.7 MB), about 1 ms of a 5K picture's setup.

Every stream is the same (`--digest`, four traces: key frames with and without kept analysis, 5K
and 720p streams). Median of 2 runs, alternated with the commit before, q20, disconnected:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K key frame, closed loop (ms) | 29.5 → **21.4** | 29.5 → **20.6** | 42.8 → **29.2** | 28.6 → **19.6** |
| 5K key frame, picture (ms, 10 frames) | 65.3 → **61.4** | 63.1 → **54.5** | 99.5 → **96.1** | 63.8 → **60.2** |
| 5K stream, inter frames a second | 347 → 346 | 219 → 241 | 84.7 → 89.0 | 318 → 357 |
| 720p key frame, picture (ms) | 13.0 → **10.9** | 12.1 → **11.1** | 15.7 → **12.9** | 13.2 → **11.2** |
| 720p stream, inter frames a second | 1038 → 1157 | 469 → 521 | 201 → 214 | 788 → 895 |

(One run of 5K typing-cc's stream read 214; its repeat read 346, as the commit before.) Over 30
key frames, which spreads the first picture's unpipelined latency thinner, the period is typing-cc
57.9, scroll-win 50.7 and photos 90.5 ms. What RDOQ added to key frames (0–2.7 %) is more than made up.

**Now the GPU bounds a 5K key frame of text:** its analysis (~55.5 ms), then the CPU's reading of
its results (`leafBlocks`, ~1.2 ms) before the next picture's analysis may start (`readEvent`),
then ~0.7 ms of event latency.

- **Kept: setting picture i + 1's analysis up while picture i − 1 is finished** (it waits on the
  GPU for picture i's results to be read, as before), so its GPU work starts the moment they are.
  The same bytes, and no faster today (typing-cc 58.1 → 58.4 ms, scroll-win 51.1 → 51.0, photos
  90.6 → 90.0, over 30 frames): with the CPU's finish (~49 ms) shorter than the GPU's analysis,
  the setup (3–4 ms at 5K) already fits inside the wait. It pays once the GPU's analysis comes
  within the setup's time of the CPU's finish, which is where the GPU work is going: up to the
  setup's 3–4 ms a picture then, nothing left to find later.
- **The GPU's 55 ms** (`--profile`, typing-cc / photos): the shapes' analysis 44.3 / 60.9 ms
  (64x64 9.4 / 10.2, 32x32 8.5 / 11.2), leaves 6.6 / 7.0, learned pruning ~3.9, partition 0.3.
  Learned pruning pass by pass: the node statistics 3.1 ms, the mode network 0.4–0.5, the cells'
  network 0.2, the tree 0.06, the lists ~0.2. **Fusing the passes into fewer dispatches would
  save at most their barriers** (a few tenths of a millisecond); the statistics are the cost.
- **Rejected: each sample's gradient orientation once** (a pass before the statistics, which then
  sum the bins of their interior samples: the same bytes, as the magnitudes are whole numbers),
  instead of an `atan2` per sample per level. The statistics stayed at 3.15 ms: the cost is the
  per-node loops, one thread walking all of a node's samples (4,096 twice for a 64x64) with
  neighbouring threads far apart in memory, not the trigonometry. Threads sharing a node, with
  integer sums, would change the features' low bits (not the same bytes; a BD check).

### Metal AV1: RDOQ in the closed loop, where the source has contrast (2026-11-02)

**RDOQ** (`rust/av1/src/hybrid/rdoq.rs`; libaom's greedy `av1_optimize_txb` in outline): after the
dead-zone quantizer, each nonzero level is tried one lower in reverse scan order, with the writer's
own base and BR contexts and costs from the frame's coefficient CDFs. The closed loop reconstructs
apart from coding, so the tile's adapted CDFs aren't at hand, and it uses the defaults for the
frame's quantizer. Then a trailing level of 1 is dropped while that pays. Distortion is the
transform domain's, scaled to samples by a per-size gain; λ is the closed loop's (0.12 step²).
Unlike the light RDOQ rejected on 2026-11-01, the rates are the coder's, not a proxy. libaom's
own trellis on its realtime path, as a reference: typing +0.1 %, photos −2.9 %.

**Judged by SSIMULACRA2** (`av1seq --score-rgb --ssimulacra2-every`), as delta-q was: by PSNR,
RDOQ everywhere looked like a gain (5K key frames −0.7 to −1.5 %), but SSIMULACRA2 showed that
photos lost (+1.5 %) and 720p SSIM was 0.7–1.4 % worse. The loss is in flat areas (sky, shading),
whose small coefficients RDOQ drops, banding the gradients. A gate on the tx block's source pixels
fixes it: RDOQ only where they span at least 40 values (max − min), which is text and UI edges,
and not flat gradients. Gating on the count of distinct values instead was worse than no gate
(photos +0.9 to +2.4 %), because the blocks with few values are the flat ones.

BD-rate by SSIMULACRA2 against no RDOQ, q 8–32 (PSNR's in parentheses; negative: smaller). 5K key
frames are 10 frames after the first 100; streams are the first 100 frames, inter, `--tiles 3x0`
at 5K and `2x0` at 720p:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| **range ≥ 40 (taken): 5K key frames** | **−1.4 % (+0.1)** | **−0.7 % (+0.2)** | **−2.1 % (0.0)** | **−1.2 % (+0.1)** |
| **range ≥ 40: 5K streams** | **−1.8 % (−0.3)** | **−0.9 % (+0.1)** | **−1.9 % (+0.1)** | **−0.6 % (+0.6)** |
| **range ≥ 40: 720p streams** | **−1.4 % (−0.3)** | **−1.0 % (−0.5)** | **−2.6 % (−0.8)** | **+0.2 % (+0.9)** |
| every block: 5K key frames | −1.4 % (−1.5) | | +1.5 % (−0.9) | |
| every block: 720p streams | −0.9 % (−0.9) | | +0.4 % (−0.7) | |
| in the tx type trials: 5K key frames | −1.5 % (−1.6) | 0.0 % (−0.9) | −0.4 % (−1.2) | −1.5 % (−1.4) |
| in the tx type trials: 5K streams | −1.0 % (−1.2) | +0.5 % (−0.1) | −0.3 % (−1.1) | −1.0 % (−1.1) |
| in the tx type trials: 720p streams | −0.6 % (−1.1) | +0.5 % (−0.6) | −0.6 % (−1.0) | −1.4 % (−1.1) |
| in the trials, with the tx model (eps 0.05): 5K key frames | −1.6 % (−1.3) | | +1.4 % (−1.1) | |

Thresholds on 5K key frames (typing-cc / photos): range ≥ 24 −1.4 / −1.4 %, **40 −1.4 / −2.1 %**,
64 −1.0 / −2.2 %, 96 −0.5 / −1.7 %, 128 −0.3 / −1.1 %, 192 0.0 / −0.1 %.

**Its cost.** At first RDOQ redid the forward transform of the type it optimized, and computed each
level's contexts twice, once for the level and once for one lower: +5–7 ms of closed loop on a 5K
key frame. Now the type search keeps the best trial's coefficients beside its levels, and the
contexts are computed once; it codes the same bytes. Median of 2 runs, q20, disconnected:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K key frame, closed loop (ms) | 29.1 → 29.4 | 27.9 → 29.5 | 39.3 → 43.1 | 28.2 → 29.8 |
| 5K key frame, picture (ms) | 65.1 → 65.2 | 61.3 → 63.0 | 98.8 → 100.1 | 64.0 → 65.2 |
| 5K stream, inter frames a second | 340 → 317 | 231 → 230 | 87 → 88 | 334 → 329 |
| 720p key frame, picture (ms) | 12.9 → 13.1 | 11.8 → 12.1 | 15.5 → 16.0 | 12.9 → 12.2 |
| 720p stream, inter frames a second | 1183 → 1062 | 482 → 463 | 204 → 204 | 777 → 843 |

RDOQ in the trials costs much more (5K key frames: typing-cc closed loop 38.4 ms, photos 64.7 ms)
and saves less.

- **Taken, on by default:** `AV1HybridEncoder.usesRDOQ` and `rdoqMinRange` (40), C API
  `av1enc_hybrid_set_rdoq(h, on, trials, min_range)`, `av1seq --no-rdoq` / `--rdoq-range` /
  `--rdoq-trials`. The Rust `Hybrid` keeps it off, as the C++ reference hybrid it's tested
  against has none. `HybridEncoderTests.rdoqKeepsStreamsExact` decodes each form with libaom.
- **Kept, off:** RDOQ in the tx type trials (`rdoqInTrials`).

### Metal AV1: learned pruning of the analysis, offline feasibility (2026-11-02)

Could a small model tell the GPU which block shapes to skip, as libaom's neural nets prune its
partition search? Offline only, nothing in the encoder yet. 32 pictures at 5120×2880, q20, 8 spread
over each of typing-cc, scroll-win, photos and cursor-drag, each dumped with the full search's
leaves (`av1seq --dump-partition`: turbo, no variance prune, no angle deltas). For every square
node (8, 16, 32, 64; 9.8 M nodes) the label is whether the search picked one of the node's own
shapes (NONE, HORZ, VERT; 4×4 counts at 8), and 13 cheap features of its luma: log variance against
the quantizer step², its quadrants' least, greatest and mean variance, its parent's, mean |dx| and
|dy|, distinct values, the commonest value's share, range, and the gradients' balance. A node
predicted unneeded skips its shapes; what that saves is the node's share of its level's 5K stage
time (8: 23.2 ms, 16: 21.1, 32: 28.6, 64: 12.9, from the entry below). "Miss": the share of the
search's chosen area whose node was skipped. Each trace is scored by models trained on the other
three (a model per level).

| | skip / miss, small MLP (13-16-1), p < 0.05 | p < 0.1 | today's variance rule (32 and up, var > 4 step²) | a perfect oracle skips |
|---|---|---|---|---|
| typing-cc | 54 % / 1.8 % | 61 % / 3.6 % | 13.5 % / 6.1 % | 77 % |
| scroll-win | 63 % / 1.9 % | 67 % / 4.0 % | 14.2 % / 5.0 % | 78 % |
| cursor-drag | 53 % / 2.1 % | 60 % / 3.7 % | 12.3 % / 5.7 % | 78 % |
| photos | 67 % / 25.7 % | 71 % / 29.0 % | 20.4 % / 9.9 % | 75 % |

A logistic model on the same features reaches 37–41 % at 3 % misses on the screen traces.
- **On screen content it skips ~4× what the variance rule does at a third of its misses**, and the
  variance rule's misses cost at most 0.4 % of bytes (the runner-up shape is nearly as good). If
  that holds, a 5K full-change picture's ~86 ms of shape stages would lose ~45–50 ms.
- **Photos, unseen in training, it gets wrong**: a model trained on three screen traces doesn't
  generalize to a fourth kind of content. More, and more varied, traces are the first need.
- Not yet measured: bytes, which only the encoder with the pruning on can tell, and the model's
  cost on the GPU (13 features and 16 tanh units a node: small beside the search).

**On the GPU (first version, kept off).** `k_ml.h`: one thread per node and level computes the
features (the commonest-value share dropped: it needs a histogram, and the model barely uses it)
and the network, writing a skip byte per 8×8 cell and level; a fix-up keeps a cell's 8 node when its
16, 32 and 64 are all skipped, so every area keeps a partition. The analysis skips a shape whose
node is flagged (`prune_flat`), and the variance rule stands aside. `AV1MetalEncoder.learnedPrune`,
`av1seq --ml-prune <weights> --ml-threshold <p>`; only in pictures coding more than half their
superblocks. Weights trained on 120 other pictures (frames 120 on, so none the test uses): the four
traces at q8 / q20 / q32, 5K and 720p. Threshold 0 is byte-identical to the variance rule off, and
every picture decodes exactly. The network costs 2.0 ms a 5K picture.

5K key frames analyzed whole (10 from frame 100, q 8–32), BD-rate and speed against today's default:

| threshold | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 0.005 | +2.2 % (×1.19) | +4.7 % (×1.13) | +0.8 % (×1.01) | +2.0 % (×1.15) |
| 0.01 | +2.7 % (×1.21) | +5.6 % (×1.21) | +1.3 % (×1.05) | +2.7 % (×1.18) |
| 0.02 | +6.4 % (×1.25) | +11.0 % (×1.25) | +3.1 % (×1.07) | +5.9 % (×1.21) |

Not worth its bytes (angle deltas gated: ×1.3–1.4 for 0.3–1.7 %). Why it falls short of the offline
numbers:
- **Misses cost more than the variance rule's.** That rule skips big shapes in busy areas, where
  they rarely win anyway; the network also skips small shapes along text, where the runner-up is
  much worse. "Did the search pick it" is the wrong label: what a skip costs (the J lost) is.
- **Skips save less than their share.** Shapes up to 128 samples (4×4 to 16×8, ~37 ms of the 86)
  run a block per thread, 32 along a row in lockstep: a skip saves nothing unless its 31 neighbours
  skip too. The 16×16 stage, a SIMD group per block, fell 51 % at threshold 0.05; 4×4 only 35 %.
A second version would need both: labels weighted by the cost a skip adds (the analysis's J per
shape, dumped), and the surviving blocks compacted into a list before the small shapes' dispatch.

**Second version: kept, on in the hybrid at 2,000 superblocks and up** (`AV1MetalEncoder.learnedPrune`,
`AV1PrunerWeights.cellV1`, eps 0.02; `av1seq --no-ml-prune` for the variance rule).
- **Costs, not choices.** `k_dp` can write each node's best own partition and its SPLIT (with
  partition bits) and each SB's λ (`GpBatch.dpDebug`, `--dump-partition`), so what a skip adds is
  the DP again without it. Per node, the first version's skips cost little one at a time (0.2–0.4 %
  of the pictures' J at 42–49 % skipped) but much more together (scroll 5 %, photos 14 %): a node
  whose runner-up is its children looks cheap, and so do the children.
- **A level per cell instead.** A network per 8×8 cell (8 statistics of each of its four nested
  nodes, 33-24-4) says which level the search will choose there; the cell keeps its likeliest
  levels until all but eps of the probability is kept, and a node's own shapes are searched where
  any of its cells keeps that level. A repair per SB (`k_ml_tree`) keeps each cell's levels
  reachable: where a cell below needs a node to split, every child without a complete partition of
  its own keeps its shapes (without it, text next to a cell that wanted 64×64 became one 64×64
  block: typing −2.8 dB at eps 0.05).
- **Compacted small shapes.** `k_ml_list` front-packs the blocks of the thread-per-block shapes
  that are still analyzed (writing the pruned result for the rest), so their SIMD-groups stay full.
- Trained on 120 pictures not among the test frames (the four traces from frame 120 on, at q8, q20
  and q32, 5K and 720p): `rust/av1/examples/prune_train.rs`, whose export reproduces the shipped
  weights exactly. Offline, each trace scored by models trained on the other three, at eps 0.02:
  31–45 % of the shape stages skipped for 0.01–0.02 % of the J.

On the GPU (q 8–32; key frames: 10 from frame 100 analyzed whole; streams: first 100, `--inter`):

| BD-rate against the variance rule | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K key frames, eps 0.01 / 0.02 / 0.03 | −0.5 / −0.5 / −0.5 % | −0.3 / −0.3 / −0.3 % | 0.0 % | −0.6 / −0.6 / −0.6 % |
| 5K streams, eps 0.02 | 0.0 % | −0.1 % | 0.0 % | −0.7 % |
| 720p key frames, eps 0.02 | 0.0 % | +0.4 % | 0.0 % | 0.0 % |

| Speed, median of 3 interleaved runs, variance rule → eps 0.02 | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K key frame (ms) | 107.9 → **81.2** | 105.2 → **71.5** | 126.3 → 114.7 | 105.5 → **78.9** |
| 5K stream (inter frames a second) | 334 → 336 | 212 → 224 | 89.9 → 90.1 | 341 → 343 |
| 720p key frame (ms) | 13.8 → 13.9 | 11.8 → 12.5 | 15.5 → 16.4 | 14.1 → 13.1 |
| 720p stream (inter frames a second) | 1097 → 1175 | 483 → 465 | **207 → 159** | 812 → 809 |

- At 5K a full-screen change codes **25–32 % faster on screen content** (photos 9 %), for slightly
  fewer bytes than the variance rule it replaces. Together with the angle-delta gate, a 5K key
  frame of typing went from ~154 ms this morning to ~81.
- Small pictures only lose: the passes (2 ms at 5K) lengthen a GPU chain that's already the limit,
  and 720p photos codes 23 % slower. Hence the floor of 2,000 superblocks (4K and up). At 1080p,
  1440p and 4K (the 5K traces resampled, which the model wasn't trained on) it made ±2 %; native
  captures at those sizes are untested.
- eps 0.05 still costs typing 1.3 dB though the offline DP calls it nearly free: the open-loop J
  understates what a forced big block costs on text. Stay at 0.02 or below without new data.
- More varied training traces (video, maps, image-heavy pages, IDEs) are the next lever.

**Third version: a mode model too, and retraining tooling (2026-11-02, evening).**
- **Where the time went next.** Inside the shapes the level model keeps, every block screens all 13
  luma modes. Screening only DC, V, H and D45 (an experiment) took typing's analysis from 56 to 26
  ms and its picture from 82 to 63 ms for 1–2 % of bytes: the screening is most of the work.
- **The model.** Per whole node, its 8 statistics, 8 bins of its gradients' orientations (central
  differences, the angle mod π, weighted by magnitude) and its level give a softmax over the 13
  modes (21-24-13); the node keeps its likeliest until all but eps is kept, and its own blocks
  screen only those (no angle deltas where a mask applies; full-change pictures have none
  anyway). Labels: every analyzed block's best mode (the dumps' MODE section). Each trace scored by
  a model trained on the others, eps 0.02: 3.7–6.0 modes screened, 1.9–3.6 % of chosen leaves'
  modes dropped (their runner-up then codes them).
- **A NaN.** The first sweep had +11 % on typing: at q8 1–6 % of nodes kept no mode at all, so
  their blocks screened nothing. Metal's fast-math tanh overflows to NaN (∞/∞) for large
  arguments, which q8's statistics reach; it's now clamped, in both networks, and an empty set
  falls back to everything.

BD-rate against no learned pruning (5K, q 8–32, as the second version's), and speed (median of 2
interleaved runs; the typing stream's outlier re-run three times):

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| key frames, levels only | −0.5 % | −0.3 % | 0.0 % | −0.6 % |
| key frames, levels and modes (eps 0.02) | −0.3 % | −0.2 % | 0.0 % | −0.6 % |
| key frames, modes at eps 0.05 | −0.4 % | 0.0 % | +0.1 % | −0.6 % |
| streams, levels and modes | 0.0 % | −0.1 % | 0.0 % | −0.8 % |
| key frame ms: none / levels / both | 108.3 / 80.8 / **70.9** | 105.7 / 72.4 / **64.6** | 126.3 / 115.8 / 107.8 | 106.5 / 79.2 / **68.3** |
| stream, inter frames a second: none / both | 350 / 352 | 229 / 230 | 89.5 / 89.8 | 331 / 337 |

Kept, eps 0.02 (`AV1PrunerWeights.modeV1`; `av1seq --no-ml-modes`, `--ml-mode-eps`). A 5K
full-screen change of text now codes in ~65–71 ms, from ~154 this morning.

**A chroma model, measured and kept off** (`av1seq --ml-chroma`). Per leaf with chroma, for U and
V its log variance, gradients and squared correlation with luma (what CfL exploits), the chroma
block's size and the leaf's luma mode's family give a softmax over k_leaf's 7 plain chroma modes and
CfL (16-16-8, computed by the leaf's lanes together); the leaf screens only the kept ones. Each
trace scored by a model trained on the others, eps 0.02: 4.0–5.1 modes screened, CfL tried on
17–41 % of leaves, 0.7–1.9 % of leaves' choices dropped. On the GPU (5K key frames, 8 from frame
100): the leaf stage 7.6 → 6.6 ms on typing-cc and 7.8 → 7.5 on photos, the picture 65.9 → 65.5 and
98.7 → 98.6 ms (noise), bytes +0.05 %. Its features cost about what it saves, as the leaf stage's
split predicted (entry above). The dumps carry chroma (CHRO) and the trainer exports chromaV1, so
it can be re-measured on more data.

**Then turned on** (the owner: keep work removed even when the other side is the limit). BD-rate
against off, 5K, q 8–32: key frames 0.0 / 0.0 / +0.1 / 0.0 %, streams 0.0 / 0.0 / 0.0 / 0.0 %
(typing-cc / scroll-win / photos / cursor-drag). Median of 2 interleaved runs: the leaf stage 7.6 →
6.6, 8.2 → 7.2, 8.0 → 7.9, 6.7 → 5.9 ms; key frames 64.5 → 63.8, 60.8 → 60.8, 97.5 → 97.2, 62.8 →
62.2 ms. `av1seq --no-ml-chroma` for off.

**Retraining.** `scripts/pruner-traces.txt` lists the traces with their training and test frames;
`scripts/train-pruner` dumps the training pictures (to ~/Library/Caches/Glass Act/pruner: screen
content stays out of the repo), scores both models leave-one-trace-out, trains and exports them,
and compares new weights with the shipped ones on the test frames (BD-rate and speed, waiting while
anyone is connected); `install` puts the new weights in Sources. From the manifest as committed,
`dump` then `export` reproduces the shipped AV1PrunerWeights.swift byte for byte. The dumps are
tagged sections (PICT, LEAF, NODE, MODE), so a new model's data is a new section that older
readers skip.

### Metal AV1: the closed loop's tx type search, and a learned model to prune it (2026-11-02)

**Where the CPU goes on a 5K key frame** (`sample` of typing-cc, after learned pruning): the closed
loop's tx type trials (`QuantHook::trial`: forward transform, quantizer, and for a compared type
the exact inverse, SSE and rate proxy) lead, then the writer's coefficient coding, then the intra
block copy search (its lossy search, the 8x8 hashes, its exact lookups). `av1seq --no-tx-search`
(new; DCT_DCT, or the analysis's types) shows what the search is worth: typing-cc's closed loop
31.0 → 21.5 ms, photos 43.7 → 27.7 ms, for +3 % bytes and −0.6 dB on typing-cc. 527 k compared
trials a 5K typing key frame, against 48 k without the search.

**A model of the tx type** (`rust/av1/src/hybrid/tx_model.rs`, CPU, in the closed loop): from the
residual, its energy share in 4 column and 4 row bands, horizontal and vertical neighbour
correlation, log energy against the step, the tx block's size and whether inter (15-16-16);
the search tries the likeliest types of the block's set until all but eps, and DCT_DCT. Samples
from the closed loop itself (GA_TX_SAMPLES; the model is off while recording), 3.5 M tx blocks of
the training frames at q8 / q20 / q32, 5K and 720p, key frames and inter streams; `prune_train`
MODEL=tx, EXPORT_TX writes `tx_weights.rs`. Each trace scored by a model trained on the others,
eps 0.05: 2.9–4.2 of 6.9–8.3 allowed types tried, 2.0–2.3 % of chosen types dropped.
- A first keep rule left DCT_DCT's probability out of the total kept, so it kept nearly everything.
- With libm's tanh and exp the model cost what it saved (527 k → 301 k trials, closed loop ~flat);
  approximated (a rational tanh, exp from the float's bits), it pays, 4x4s included.

BD-rate against the full search, q 8–32, and the closed loop (5K key frames, median of 2 runs):

| eps | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 0.05: 5K key frames / streams | +0.3 / +0.3 % | +0.2 / +0.3 % | 0.0 / +0.1 % | +0.1 / +0.2 % |
| 0.05: 720p key frames / streams | +0.1 / +0.1 % | +0.2 / −0.7 % | +0.1 / +1.3 % | 0.0 / +0.1 % |
| 0.1: 5K key frames / streams | +0.5 / +0.6 % | +0.3 / +0.5 % | 0.0 / +0.2 % | +0.3 / +0.4 % |
| closed loop, ms: full / 0.05 / 0.1 | 27.2 / 25.1 / 24.6 | 27.4 / 25.9 / 25.4 | 37.6 / 35.6 / 33.2 | 26.4 / 24.6 / 24.1 |

**Kept, off** (`AV1HybridEncoder.txModelEps`, `av1seq --tx-model-eps`): ~2 ms of CPU a 5K key
frame, nothing on streams (their closed loop is 1.6–4 ms), for 0.1–0.3 % of bytes (1.3 % on 720p
photos streams): a bytes trade, not a free gain. `scripts/train-pruner` records and exports it with
the other models.

### Metal AV1: a qindex per 64x64 (delta-q) by a hand rule, judged by SSIMULACRA2 (2026-11-02)

Before training a model to spend bits where they show, a hand rule to see if there's a gain:
`AV1HybridEncoder.sbQindex` (each 64x64's qindex; the GPU's λ and the closed loop's quantizer
follow it, coded with delta_q_present) with `av1seq --dq text:n`: n finer where a 64x64 has few
distinct values (2–64) and strong edges (a 2 % share of steps over 48), text or UI; n coarser where
it has over 160 (a photo); the frame's elsewhere. Scored by SSIMULACRA2 (`--ssimulacra2-every`,
the `ssimulacra2` binary; key frames: 5 of 10 frames, streams: 10 of 100) and PSNR. 5K, q 8–32,
BD-rate against the frame's qindex everywhere:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| key frames, text:12, by SSIMULACRA2 (PSNR) | −0.5 % (+0.1) | 0.0 % (0.0) | −2.1 % (+0.7) | −0.5 % (+0.1) |
| key frames, text:24 | −0.6 % (+0.5) | +0.1 % (+0.6) | −2.2 % (+2.7) | −0.6 % (+0.4) |
| streams, text:12 / text:24 | 0.0 / 0.0 % | 0.0 / +0.1 % | 0.0 / +0.1 % | 0.0 / 0.0 % |

- The gain is the photo areas made coarser (photos' key frames −11 % bytes for 1–4 points of
  SSIMULACRA2), not text made finer: text is already sharp at these quantizers, its repeats copied.
- Streams don't move: their inter frames are mostly copies, which a quantizer doesn't touch.
- **Not taken, and no model trained:** 0.5–2 % on key frames and nothing on streams is too little
  to learn a map for (and SSIMULACRA2 scores a picture, which makes per-64x64 labels hard). The
  path stays, off (a test holds delta-q streams to libaom and kept analysis to fresh).

### Metal AV1: the leaves' luma tx search dropped, unused (2026-11-02)

Timing the leaf stage (`k_leaf`, 13–15 ms of a 5K key frame after learned pruning): half of it was
each leaf's luma tx type search, whose result nothing keeps. The closed loop searches every luma tx
type itself (`Hybrid::search_luma_tx`, on since it measured 1.1–1.5 % smaller; only the C++
comparison tests keep the analysis's), and the analysis's types otherwise only key tile reuse,
which they don't change. With the search off (`leafTxSearchPixels` 0) the streams are
byte-identical (`--digest`: 5K typing key frames at q8 and q32, 5K photos and scroll, 720p typing
and drag streams). Interleaved, 3 runs each:

| | search on (128) | off |
|---|---|---|
| 5K key frame, typing-cc | 68.7–68.9 ms | **64.6–65.3 ms** |
| 5K key frame, photos | 105.8–107.9 ms | **97.1–99.0 ms** |
| 720p typing-cc stream (inter frames a second) | 972–1277 | **1303–1358** |
| 720p photos stream | 190–200 | **198–204** |

What's left of the stage is chroma (7 modes screened per leaf, then CfL): 7.4 ms on typing, of
which the modes are ~3.3 (DC only: 4.1 ms, +1.2 % bytes) and CfL ~2 (none: 5.4 ms, +2.2 %). A
learned chroma model could save at most ~3 ms of GPU and under 2 of the picture: **not built.**

**Where a 5K full-change picture goes now** (typing-cc key frames, overlapped 66.7 ms): the GPU
analysis 54.9 ms; on the CPU, 18.4 ms before the closed loop (almost all the intra block copy
search: 1.5 ms without it, though without copies the picture is 547 KB, not 412, and needs 33 ms of
filters), the closed loop 27.3, the writer 9.4. The two sides are even, ~55 ms each, so further
gains need both: the GPU's analysis and the CPU's copy search and closed loop.

**More tiles, to spread the CPU side** (5K key frames, 8 from frame 100; tiles as log2 columns x rows):

| | 3x0 (8 x 1, as now) | 3x1 (8 x 2) | 4x0, 4x1, 3x2 (16+ columns or 32 tiles) |
|---|---|---|---|
| typing-cc: ms / bytes | 68.7 / 412 KB | 65.6 / 420 KB (+1.9 %) | ~79 / ~552 KB (+34 %: no intra block copies) |
| typing-cc CPU: copy search / closed loop / writer | 19.0 / 27.3 / 9.7 | 13.4 / 23.1 / 6.9 | — |
| photos: ms / bytes | 102.6 / 1.02 MB | 99.5 / 1.02 MB | 98.6–100.5 / 1.02–1.03 MB |

8 x 2 frees ~12 ms of CPU but the picture only ~3 ms: the GPU (55 ms) is then the limit. Not
taken (+1.9 % on text); with 16 tile columns and more, key frames stop copying (not looked into).
With the GPU the limit (3x1), the chroma model does pay: 65.1–66.0 → 64.2–64.3 ms over three
interleaved pairs, +0.05 % of bytes; it stays off while the CPU side is the limit.


### Metal AV1: reduced frames for full-screen change at 5K, measured (2026-11-02)

Following the entry below: a picture coded smaller than its stream and shown scaled up to it (AV1's
`frame_size_override_flag` with the stream's render size; decisions.h "Reduced frames",
`av1seq --stream-width`), to bring a full-screen change at 5K near hardware HEVC's latency.

**Decoders.** libaom streams with random frame sizes (`--resize-mode=2`) and random superres
(`--superres-mode=2`): VideoToolbox (through ffmpeg) decodes every superres frame exactly as dav1d
does, and the full-size inter frames predicted from reduced references exactly too (scaled
prediction works). A reduced frame comes out of VideoToolbox already scaled up to the render
size, so the Viewer's decoder, which expects full-size buffers, gets one. (Frames of odd width or
height also differ, the known odd-size mismatch.) The writer's reduced key and inter frames decode
exactly in dav1d and aomdec (`decoders`, a third of its sequences reduced).

**Speed and the quality ceiling** (`--no-reuse --no-deltas` key frames, 8 frames; the ceiling is
q2, the reduced stream decoded and scaled up with vImage, scored at 5120×2880 as `vquality`
scores):

| coded at | photos | typing-cc | ceiling at 5K, PSNR (SSIM) |
|---|---|---|---|
| 5120×2880 | 127.7 ms · 1.03 MB | 109.6 ms · 420 KB | — (q20: 43.3 / 47.3 dB) |
| 3840×2160 | 75.9 ms · 702 KB | 90.0 ms · 437 KB | photos 34.1 dB (0.973), typing 36.2 (0.988) |
| 2560×1440 | **35.4 ms** · 378 KB | **34.8 ms** · 286 KB | photos 29.8 (0.931), typing 30.0 (0.966), scroll 30.3 (0.972) |

- **Half size reaches HEVC's latency** (35–47 ms a picture, entry below) and inter frames run at
  80–300 a second, but scaling Retina content down 2× and back loses more than any quantizer: about
  30 dB at best. Hardware HEVC's lowest point on photos (7.9 Mbit/s) is 32.5 dB (SSIM 0.925), and on
  typing 35–42 dB at 0.3–0.7 Mbit/s. So HEVC is better than a half-size AV1 stream at any rate.
- **3/4 size** is slower than HEVC and still below it (34–36 dB). On typing it saves little time
  and no bytes: text no longer repeats on whole samples, so fewer intra block copies.
- Kept: the writer's and parser's reduced frames (tested, unused); `av1seq --stream-width` and
  `--ivf`.

### Metal AV1, every superblock changing at 5K: where the time goes, and angle deltas gated (2026-11-02)

**Where the time goes.** typing-cc at 5120×2880, 10 key frames analyzed whole (`--no-reuse`):
153.8 ms a picture, of which the GPU analysis is 143.4 ms. The CPU's chroma (18.7), closed loop
(24.5) and writer (7.2) overlap it. The analysis's stages (`--profile`, ms):

| | 4×4 | 4×8 | 8×4 | 8×8 | 8×16 | 16×8 | 16×16 | 16×32 | 32×16 | 32×32 | 64×64 | leaves | all |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| turbo | 5.2 | 5.7 | 5.6 | 12.5 | 13.3 | 13.0 | 9.1 | 13.7 | 10.1 | 21.1 | 22.6 | 12.8 | 145 |
| no angle deltas | 5.1 | 5.7 | 5.6 | 6.8 | 7.4 | 6.9 | 6.8 | 9.1 | 6.6 | 12.9 | 12.9 | 12.9 | 99 |

**The faster presets, on the same key frames** (8 frames, q20; typing-cc / photos):

| | ms a picture | bytes a picture | PSNR-Y |
|---|---|---|---|
| turbo (default) | 154.5 / 170.2 | 416.5 KB / 1.01 MB | 47.21 / 43.26 |
| turbo2 (no 4×4, 4×8, 8×4) | 131.5 / 145.1 | 465.2 KB / 1.02 MB | 46.62 / 43.16 |
| turbo3 (turbo2 without angle deltas) | 87.0 / 101.1 | 472.4 KB / 1.04 MB | 46.64 / 43.14 |
| turbo, `--prune 1` | 146.0 / 162.1 | 419.8 KB / 1.01 MB | 47.20 / 43.26 |
| turbo, no angle deltas | 109.5 / 127.1 | 420.3 KB / 1.03 MB | 47.26 / 43.26 |

The small shapes earn their time on text; the angle deltas mostly don't.

**BD-rate against angle deltas always on** (q 8–32, RGB luma PSNR as `vquality` scores; whole
streams: first 100 frames `--inter`; key frames: 10 from frame 100, `--no-reuse`; libaom's tiling):

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K stream, deltas off | +0.1 % | −0.2 % | +1.1 % | +0.1 % |
| 5K stream, deltas only up to half the picture | +0.1 % | −0.2 % | **+0.3 %** | +0.1 % |
| 5K key frames, either | +0.4 % | +0.6 % | +1.7 % | +0.3 % |
| 720p stream, deltas off / gated | −0.1 / −0.1 % | −0.2 / −0.2 % | +0.3 / +0.2 % | −0.2 / −0.2 % |
| 720p key frames, either | −0.2 % | −0.2 % | +0.8 % | −0.3 % |
| 5K stream, turbo3 | +45.2 % | +17.3 % | +3.2 % | +12.4 % |

**Speed** (q20, no scoring, median of 3 interleaved runs; inter frames a second, and ms a key
frame analyzed whole), always / off / gated:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K stream | 326 / 336 / 346 | 224 / 242 / 230 | 87 / 98 / 88 | 335 / 336 / 336 |
| 5K key frames | 154.4 / 109.6 / 109.4 | 147.1 / 105.4 / 105.1 | 169.8 / 127.7 / 125.2 | 150.1 / 106.1 / 106.2 |
| 720p key frames | 14.8 / 13.0 / 13.1 | 15.0 / 12.6 / 12.4 | 16.3 / 15.5 / 15.4 | 15.3 / 12.8 / 12.8 |

At 720p typing, four interleaved runs more: always 1007–1331, gated 1268–1323, off 1409–1437
inter frames a second. The gate's streams are byte-identical to always-on's there.

**Kept: deltas only in an inter frame that codes at most half its superblocks** (the rest copies;
key frames count as all coded; `AV1MetalEncoder.angleDeltasUpToShare` 0.5). A full-screen change or
key frame at 5K codes ~30 % faster (150–170 → 105–127 ms) for 0.3–1.7 % more of its bytes; whole
streams lose at most 0.3 %. Off everywhere would also speed partial inter frames by 7–13 % (5K
photos, 720p), which already run far above 60 a second, for photos' +1.1 %: not taken, bitrate
first. Superblocks kept from an earlier picture keep the analysis they had, so a big change doesn't
reset the cache. A first version gated on the share the cache left to analyze; that made a reusing
encoder code differently from a fresh one (`regionFilteringStaysExactAcrossPresetChanges`), so the
gate reads the copy mask, which both see. Its streams are byte-identical to the measured ones
(`--digest`, 720p typing and photos, 5K photos).

### Hardware HEVC's per-picture latency at 5K, against AV1 when every superblock changes (2026-11-02)

`vquality` (VideoToolbox HEVC as the Host configures it: max frame QP 34, realtime), 5120×2880,
24 Mbit/s target, first 100 frames, each picture waited for before the next is handed in, session
disconnected:

| | encode latency p50 / p95 | first frame (key) | achieved | PSNR-Y |
|---|---|---|---|---|
| photos | 35.2 / 54.0 ms | 1.06 MB | 24.4 Mbit/s | 37.3 dB |
| typing-cc | 47.0 / 61.8 ms | 595 KB | 2.3 Mbit/s | 46.8 dB |

- **One 5K picture is 35–47 ms, not ~17.** The 58–59 fps of "Quality vs speed vs bandwidth at 5K"
  (2026-08-07) is throughput, with several pictures in the encoder at once. The latency includes
  handing VideoToolbox the BGRA picture. Typing's is the longer, probably the encoder clocking down
  between mostly-empty pictures (not checked).
- **Against AV1 when nothing can be reused** (the 2026-11-01 `av1seq` runs: key frames, and inter
  frames with every superblock forced changed): the hybrid takes ~148 ms a key frame (6.7–6.8 fps,
  ~425 KB with intra block copies, 47.3 dB on typing-cc) and ~171 ms a fully-changed inter frame;
  libaom speed 9 takes 151–163 ms a key frame on 8 threads (~1.03 MB, 47.6 dB). So a full-screen
  change costs either AV1 encoder 3–4× HEVC's latency, and sustained full-screen motion runs ~6–7
  fps against HEVC's ~58, for 68–84 % fewer bytes than HEVC at equal quality (the 2026-11-01
  re-baseline).

### Metal AV1: the next picture's analysis committed while the last one runs (2026-11-01)

Following up the entry below with a Metal System Trace of 720p typing-cc: between two pictures'
analyses the GPU sat idle ~270–320 µs (under the trace), because picture i + 1's analysis was only
set up once picture i's had finished: padding and comparing its source, making its buffers (~120
µs at 720p, ~1.2 ms at 5K), encoding and committing, plus two thread hand-offs.

Now (`AV1HybridEncoder.encode(count:)`, `AV1MetalEncoder.readEvent`) picture i + 1's analysis is
set up and committed on its thread before the main thread waits for picture i's. Its command buffer
waits on the GPU (an `MTLSharedEvent`) until the CPU has read picture i's results, which it would
overwrite in the cache's buffers. The cache's keep and stale lists are two of each, alternating; the
motion search's reference is the last source set up, not the last waited on; the source pool takes
a lock. The streams are byte-identical (`--digest`, all 8 below).

Inter frames a second at q20 (`--no-planes`), median of 4 runs interleaved with the commit before:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 720p | 1141 → **1279 (+12 %)** | 501 → 505 (+1 %) | 173 → 184 (+7 %) | 893 → **988 (+11 %)** |
| 5K | 340 → 336 (−1 %) | 208 → 216 (+3 %) | 83.6 → 87.0 (+4 %) | 312 → 323 (+4 %) |

Run to run the spread narrowed too (720p typing 953–1176 before, 1246–1330 after).

What's left, from the main loop's own clock at 720p typing: each picture the main thread waits
~0.48 ms for the analysis, then finishes the picture before (closed loop and filters) in ~0.77 ms,
while the next analysis runs on the GPU beside the filters. The analysis is still the longer: its
chain of dependent stages, each a block's serial work. At 5K the finish is the limit (2.7 ms typing,
4.1 ms scroll), so this change can't help there.

Measured and dropped:
- **Copying each picture's leaves out on the GPU** (a `k_leaf_out` kernel after `k_leaf`, into
  buffers of the picture's own, so the next analysis needn't wait for the CPU to read the cache):
  same bytes, no gain at 720p, and 5K scroll −12 % (it copied every superblock's leaves).
- **A superblock analyzed end to end in one threadgroup** (the entry below's idea): looked at again,
  it would be slower. Each stage already runs every block of every changed superblock at once across
  the GPU; one threadgroup per superblock would run its ~680 blocks about 32 at a time.

### Metal AV1 at 720p: why libaom is faster on inter frames (2026-11-01)

At 720p libaom realtime speed 9 codes typing-cc's inter frames at ~2000 a second and ours at
~900–1200 (runs on this machine vary by ±20 % here). Measured with `av1seq --inter --no-planes`,
q20:

- **It's the GPU analysis, nothing else.** Our inter frames run at 1 / (GPU analysis time): 1.0,
  1.6 and 4.8 ms a frame for typing, scroll and photos (906, 524, 176 frames a second). Without
  filters it's the same (920, 489, 180): they overlap it.
- **The rest of the pipeline is as fast as libaom.** With every 64×64 forced to a copy (an
  experiment: no analysis at all), the same pipeline runs typing and scroll at ~1930 frames a
  second with filters and 1830–2590 without, against libaom's 2030 and 969.
- **For a few superblocks the analysis is latency, not work.** Typing analyzes ~2 % of its
  superblocks (about 5) a frame and still takes ~1 ms of GPU: a chain of dependent stages
  (projection and motion search 0.10 ms, inter candidates 0.12, the intra shapes 0.02–0.16 each,
  partition, leaf decisions 0.1, each timed alone), each a block's serial work on one SIMD-group.
  Photos analyzes 68 % of its superblocks: that 4.8 ms is throughput.
- **Not the GPU's clock:** with a 5K photos encode running beside it, typing's analysis took the
  same 1.0 ms.
- **Not the preset:** inter frames at turbo, turbo2, turbo3 or faster were within the run-to-run
  noise on typing and scroll (photos: turbo3 and faster slower).

Considered and not built:
- **Deciding a few changed superblocks on the CPU instead** (`hybrid::Decider`, the reference
  engine's open-loop search): about 0.6 ms of CPU per 64×64 (720p screen picture, 37 ms for 240
  superblocks on 4 threads), with no motion search and weaker decisions. With ~5 superblocks on as
  many threads, that's ~0.6 ms against the GPU's ~1.0: at best ~1.4× on typing, short of libaom,
  and costing bytes; on scroll (~24 superblocks) no faster.
- What would close the gap is the GPU analysis's latency on few superblocks, not more search.
  At 720p we're already 15–20× past 60 fps, so this matters for latency and power, not frame rate.
  (Followed up in the entry above: the CPU's setup of each analysis moved off the GPU's critical path,
  +7–12 % at 720p; one threadgroup per superblock would be slower.)

### Metal AV1 re-baselined after intra block copy (2026-11-01, evening)

The morning's re-baseline (entry below, same script) on the encoder with exact and lossy intra block
copies, the rounding offset 0.45, and luma tx types searched for intra and inter blocks. The AV1
runs (ours and libaom realtime speed 9 with inter frames, in the same runs) were re-run; the
hardware HEVC points are the morning's (VideoToolbox as the Host configures it: unchanged). First
100 frames, RGB luma PSNR as `vquality` scores it, q 8–32; BD-rate, negative = ours smaller:

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K: ours vs HEVC | **−70 %** (morning −60 %) | −76 % by SSIM (−74 %; by PSNR no overlap) | **−84 %** (−83 %) | **−68 %** (−60 %) |
| 5K: ours vs libaom | **−58 %** (−46 %) | −33 % (−24 %) | −35 % (−34 %) | **−56 %** (−46 %) |
| 720p: ours vs HEVC | −47 % (−45 %) | −42 % (−40 %) | −7 % (−2 %) | −44 % (−42 %) |
| 720p: ours vs libaom | −32 % (−30 %) | −6 % (−1 %) | −16 % (−13 %) | −32 % (−30 %) |

By SSIM: 720p scroll vs libaom +9 % (morning +16 %), 720p photos vs HEVC +10 % (+16 %).

At q20 the 5K streams are 0.30 / 1.18 / 6.66 / 0.64 Mbit/s at the traces' timing (typing / scroll
/ photos / drag), 720p 0.08 / 0.48 / 2.36 / 0.16.

Speed, inter frames a second at q20 (`--no-planes`, no scoring; ours alone, and ours beside libaom
in the same process with libaom's own figure):

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K, ours alone | 357 | 229 | 87 | 340 |
| 5K, ours / libaom s9 | 356 / 233 | 229 / 174 | 87 / 93 | 343 / 233 |
| 720p, ours alone | 1252 | 523 | 180 | 886 |
| 720p, ours / libaom s9 | 1263 / 2030 | 518 / 969 | 181 / 508 | 957 / 2040 |

Against the morning (ours alone after the CDEF move: 346 / 220 / 84 / 336 and 1184 / 490 / 183 /
879) the inter tx type search costs nothing measurable here; run to run, these move by ±5–10 %.
Beside libaom ours ran as fast as alone this time (the morning's table had ours slower beside it).

### Metal AV1: lossy intra block copies, and inter blocks' tx types (2026-11-01)

Where the bytes went after exact intra block copies (an experiment, not kept: every block's bits
from `ENC_BLOCK_BITS`, and for each block that didn't copy, the least residual of any copy the
search could find), on the 1080p crop of typing-cc's terminal at q20 (42.8 KB):

- **12.4 % of the bits were in 4×4-ish blocks whose 8×8 had a near-exact copy** (residual SSE under
  0.05 × 1.5 × step² per sample: glyphs whose antialiasing or colour differs a little, chroma at an
  odd displacement), and 2.6 % in larger blocks like that.
- **Small blocks with an exact 4×4 luma copy** held 5.8 % of the crop's bits but only 1.2 % at
  5K, of which a copy would save only part (its displacement costs bits too, and chroma of an 8×8
  then comes from its bottom-right 4×4's copy). Not built: the writer's sub-8×8 chroma rules for
  ~0.5 % at 5K.

So the search now copies lossily too (`hybrid::intrabc`): a block, or a node the analysis split,
with no exact copy copies where a near copy's residual SSE (luma and chroma, against the source's
own copy) is at most `NEAR_SHARE` = 0.005 × 1.5 × step² per luma sample, and the closed loop codes
the residual. Candidates are the tile's 16 most recent displacements and those of exact matches of
the block's first four non-flat 8×8s (at each parity); the cheapest by SSE + λ × displacement bits
wins. Only exact copies count toward a frame's decision to copy (≥ 6 % of its non-flat 8×8s):
counting lossy ones made 720p frames at q26–32 copy (and lose their filters) for −0.2 dB and no
bytes.

Key frames alone (q 8–32, RGB-scored at 5K and 720p; the crop PSNR-Y), BD-rate against exact
copies only:

| threshold | crop | 5K typing | 5K scroll | 5K drag | 5K photos, 720p |
|---|---|---|---|---|---|
| 0.005, blocks and split nodes | **−11.3 %** | **−2.9 %** | **−3.9 %** | **−4.2 %** | 0.0 % |
| 0.01, blocks and split 8×8s only | −9.8 % | −2.4 % | −3.2 % | −3.2 % | 0.0 % |
| 0.01, blocks and split nodes | −11.5 % | −2.8 % | −3.9 % | −4.2 % | 0.0 % |
| 0.02, blocks and split nodes | −11.3 % | −2.2 % | −3.6 % | −3.7 % | 0.0 % |
| 0.25, split 8×8s only (lossy counted toward the 6 %) | −6.6 % | +2.7 % | +5.0 % | +3.2 % | +1.4 to +6.8 % |

Whole streams (100 frames, RGB-scored, q 8–32), against exact copies only: 5K typing **−2.3 %**,
scroll **−1.7 %**, cursor-drag **−3.2 %**; photos and 720p byte-identical. At q20 the 5K key frames
copy 29–32 % of their pictures (19–24 % exactly): typing 428.0 → 413.7 KB, scroll 388.4 → 372.6 KB,
drag 410.7 → 394.8 KB, at −0.01 to −0.03 dB. The search costs ~5–10 ms more per 5K key frame.

**Inter blocks' luma tx types are searched now** (`Hybrid::search_inter_tx`, in the quantization
hook: every type of the block's inter set, as intra's), not DCT_DCT only. A copy's residual and an
inter frame's motion-searched blocks both use it. Whole streams, against the above:

| | typing | scroll | photos | drag |
|---|---|---|---|---|
| 5K | −0.4 % | −0.7 % | −0.1 % | −0.2 % |
| 720p | −0.2 % | −1.2 % | **−2.4 %** | −0.2 % |

It costs 2–5 % of throughput on most points (one point, 5K typing at q32, 25 %).

Measured and dropped:
- **Split transforms in copies** (tx_depth 1–2; key frames then need tx_mode_select, which costs
  every intra block a symbol): +2 % bytes on the crop and 5K typing for at most +0.09 dB.
- **Larger thresholds:** the closed loop codes a copy's residual with one transform the block's size
  and skips it where that's cheaper, so a poor copy loses quality the bytes don't buy back.

Tested: the hybrid's key frames with lossy copies (a test picture with repeats nudged by 3 in a
sample per 16×16) decode exactly in dav1d and in Apple's hardware decoder (VideoToolbox through
ffmpeg); the Rust tests, the oracle tests against the C++ (which keeps DCT_DCT for inter blocks:
`Hybrid::as_cpp`), and the Swift AV1 suites pass.

### Metal AV1: intra block copy in key frames (2026-11-01)

The AV2 attribution (entry below) found intra block copy carrying AV2's gain on text, and AV1 has it
in key frames. Now the writer codes it (use_intrabc, the DV prediction from find_mv_stack for
INTRA_FRAME, MV_INTRABC_CONTEXT, no loop filter, CDEF or delta-LF syntax in the frame), and the
hybrid encoder's closed loop searches for it (`hybrid::intrabc`, on by default in
`AV1HybridEncoder.intraBlockCopy`):

- **Exact copies, at the analysis's partition.** A block, or a square node the analysis split into
  several (then one block: the copies of whole nodes, down to an 8×8 in place of its 4×4s, are most
  of the gain), copies where its luma and chroma repeat exactly at a whole-sample displacement that
  is_mv_valid allows (in the tile, 256 samples behind). Odd displacements too: 4:2:0 chroma is then
  the decoder's bilinear average, and the writer also asks that the 2 samples it reads beyond the
  source be valid.
- **Found by hashing** every non-flat 8×8 at even positions, per tile on every thread, added as the
  search passes them (nearest rows first, the superblock row's own once 256 samples behind). The
  previous copy's displacement is tried first (the stack's: cheapest to code).
- **Only where it pays.** A frame with copies has no deblocking or CDEF (the format turns them
  off), so it copies only when its copies cover at least 6 % of its non-flat 8×8s; otherwise it is
  coded exactly as before.
- Tiles whose source, blocks and copies are unchanged are kept, as for other key frames.

Tested: random key frames with copies (odd and even displacements) in the inter sequences round-trip
through the parser and decode exactly in dav1d, aomdec and the vendored libaom (3,200 frames, 3,000+
copies); the hybrid's pictures with copies decode exactly in dav1d and libaom; Apple's hardware
AV1 decoder (VideoToolbox, through ffmpeg) decodes them exactly too. (An odd-sized picture's last
row and column decode differently there, with or without copies: a separate issue.)

BD-rate against intra block copy off, same sweep as the rounding entry (RGB-scored PSNR, q 8–32,
100 frames: a key frame, then inter frames):

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K | **−18.3 %** (key frame −18.4 %) | **−6.7 %** (−12.7 %) | 0.0 % | **−14.3 %** (−14.7 %) |
| 720p | 0.0 % | 0.0 % | 0.0 % | 0.0 % |

- At 5K, 18–24 % of the key frame copies. At q20 the typing key frame is 539 → 428 KB.
- **At 720p nothing repeats exactly enough:** the trace is downscaled from 5K, so the same glyph
  lands at different sub-sample phases. Before the 6 % rule, copying 0.6–5 % of their non-flat
  8×8s, 720p frames lost +0.3–1.0 % to the missing filters, and photos at 5K (1.1 %) +0.1 %; with it
  they are coded as before, byte for byte.
- On the 1080p crop of typing-cc's terminal that AV2 and libaom were measured on: 98.1 → 43.4 KB at
  q20 (47 % of the picture copies), about 2.2× smaller at equal PSNR-Y, against libaom speed 2's 2.9×.
- Cost: the search takes about 10 ms per 5K key frame (2.6 ms at 720p) on top of the closed loop. An
  unchanged picture reuses the last search's answer.

Measured and dropped: splitting an analysis block that doesn't copy into quadrants that copy (and
intra ones with its modes): no gain at any threshold (5K typing key frame 422.6 KB not splitting,
423.0 at half its non-flat area copying, 425.9 splitting nearly always).

Next for text (lossy copies since, entry above): copies with a residual (glyphs at another sub-sample phase), 4×4 copies, and copies
inside inter frames (which AV1 doesn't have: the custom codec's glyph cache).

### AV2's gain on text attributed: intra block copy, which AV1 has too (2026-11-01)

The AV2 entry (2026-10-25) found AVM 3.7× smaller than libaom on typing-cc at 60 dB. To find which
tools carry that, AVM research-v15.0.0 (same build and settings: `--good --cpu-used=9
--tune-content=screen --lag-in-frames=0`) encoded the first 10 frames of typing-cc, scroll-win and
photos, cropped to the top-left 1920×1080, with each of 22 tools switched off in turn
(`--enable-<tool>=0`), at qp 100–160 (60–66 dB on text) and 210–255 (44–54 dB on text, nearer
our operating point). BD-rate on AVM's own PSNR-Y against everything on (+: bytes the tool saves):

| tool off | typing, qp 100–160 | scroll | photos | typing, qp 210–255 | scroll | photos |
|---|---|---|---|---|---|---|
| intrabc | +236 % | +56 % | +2.3 % | +245 % | +56 % | +3.3 % |
| intrabc-ext (local search area) | +14.5 % | +11.7 % | +0.7 % | +11.0 % | +9.9 % | +2.9 % |
| palette | +8.3 % | +8.6 % | +0.3 % | +10.2 % | +16.1 % | +1.0 % |
| flip-idtx (identity and 1-D transforms) | +7.6 % | +7.3 % | +1.2 % | +5.2 % | +3.2 % | +2.1 % |
| fsc (forward skip coding) | +5.9 % | +5.6 % | +1.1 % | +4.3 % | +1.6 % | +3.1 % |
| sdp, mhccp, tcq, ext-partitions, cfl, ccso | 0–5 % each | | | | | |
| cdef, mrls, cctx, gdf, pc-wiener, idtx-intra, tx-partition, intra-dip, ist, ibp, parity-hiding | within ±1 % on text | | | up to 3.4 % on photos | | |

**Intra block copy is the gain.** With it off, typing is 3.4× bigger, which is nearly all of the
3.7×. AV1 has intra block copy too, in key and intra-only frames (with the loop filters off in
those frames). The 2026-10-25 comparison ran libaom at `--cpu-used=6`, and libaom only searches it at
speed 2 and below (at speed 3 and up, `--enable-intrabc` 0 and 1 differ by under 0.2 %).
libaom at speed 2, same 10 frames, intra block copy on against off:

| | typing 60 dB | scroll 60 dB | photos 45 dB |
|---|---|---|---|
| AVM (all tools) | 37 KB | 65 KB | 468 KB |
| libaom speed 2, intra block copy on | 43 KB | 74 KB | 376 KB |
| libaom speed 2, intra block copy off | 131 KB | 104 KB | 382 KB |

- **On text, AV1 with intra block copy is within ~15 % of AV2,** not 3.7×. The rest is AV2's
  extended search area, palette, the 1-D transforms and skip coding, a few percent each.
- **It's the key frame.** In these clips libaom's inter frames are 35 bytes each (nothing moves),
  so the 10 frames measure key-frame coding. A typing key frame on its own at ~41–45 dB: 55 → 19 KB
  (cq 40) and 67 → 23 KB (cq 30, speed 0), 2.9× smaller. The gain holds at our quality.
- **Palette is worth 8–16 % on text here,** against at most 0.7 % in our own encoder at q20 (entry
  below). The gap isn't explained yet: AVM's palette may be catching what intra block copy misses.
- **Not measured here:** new text inside inter frames, where AV1 can't use intra block copy and
  AV2 can. These clips have no such frames.
- **Nothing for photos:** at most 3 % from any tool, the filters included. AVM is 25 % bigger than
  libaom speed 2 on photos at 45 dB; not looked into.

For `metal-av1`, intra block copy in key frames comes first: 2.9× smaller key frames on text, inside
AV1's syntax. Our encoder doesn't have it yet. Apple's AV1 decoder should accept it (it's in Main
profile), but that is unverified.

### Metal AV1: the filters' preset search on the GPU, one command buffer a picture (2026-11-01)

The CDEF preset search (libaom's joint greedy search, `av1enc_cdef_select_cpu`) ran on the CPU
between two GPU passes, so a picture's filters took two command buffers, and three when new presets
changed strengths outside the changed region (2.6 on average at 720p). Now `l_select` runs the
search on the GPU, a threadgroup per cdef_bits (the four levels' searches are independent), and
`l_choose`, `l_assign_c` and `l_finish` do what followed it: cdef_bits, the presets into the frame
(now a buffer, not `setBytes`), the assignment, and the list of 64×64s CDEF redoes, dispatched
indirectly. The ring the region's deblocking gets wrong is put back on the GPU (`p_copy_r`). One
command buffer a picture, two when far direct copies run meanwhile. Streams unchanged (`--digest`
on the 720p and 5K traces); `PresetSearchTests` holds the GPU's search to the CPU's on random
tables.

The search alone, GPU time against the CPU's (Apple silicon, medians of 60):

| | 720p (240 64×64s) | 1080p (510) | 5K (3600) |
|---|---|---|---|
| CPU (`select_rows`, NEON) | 23 µs | 56 µs | 490 µs |
| GPU, one threadgroup, a thread per 64×64 (≤ 1024) | 445 µs | 519 µs | 1107 µs |
| + reduction unrolled (no spills) | 207 µs | 189 µs | 707 µs |
| + a threadgroup per cdef_bits | 120 µs | 109 µs | 399 µs |
| + 128 or 256 threads | 67–96 µs | 58–89 µs | 340–350 µs |

The GPU's search is slower than the CPU's at 720p, but the round trips it saves cost more. The
first full encoder A/B, with the search at ~445 µs, was 0–13 % slower, which puts the round trips
saved at roughly 0.3 ms a picture at 720p.

**Inter frames a second,** interleaved against HEAD (three runs each, `--inter --no-planes`, 100
frames, the session disconnected, the AV2 job paused):

| | 720p | 5K |
|---|---|---|
| typing-cc | 1137 → 1184 (+4 %) | 293 → 346 (+18 %) |
| scroll-win | 450 → 490 (+9 %) | 203 → 220 (+8 %) |
| photos | 170 → 183 (+8 %) | 81.6 → 84.1 (+3 %) |
| cursor-drag | 799 → 879 (+10 %) | 288 → 336 (+17 %) |

Keeping up to four 64×64s a thread in registers, with 32-bit sums for the first halving, measured
within noise (−1 to +5 % across 720p and 1080p traces); kept.

### Metal AV1: the closed loop searches luma tx types; edge filter and QMs rejected (2026-11-01)

Intra coding (where the bytes are, entry below), BD-rate against the current encoder, same sweep as
the rounding entry (RGB luma PSNR, q 8–32, 100 frames):

| | 5K typing | 5K scroll | 5K photos | 720p typing | 720p scroll | 720p photos |
|---|---|---|---|---|---|---|
| **luma tx types searched** (the analysis's ignored) | **−1.1 %** | **−1.2 %** | **−1.5 %** | **−1.5 %** | **−1.2 %** | **−1.2 %** |
| the analysis's type against DCT_DCT | −0.6 % | −0.6 % | −0.9 % | −0.7 % | −1.0 % | −0.5 % |
| intra edge filter on | +0.5 % | +1.0 % | +0.7 % | +0.1 % | +0.2 % | +0.3 % |
| quantizer matrices, level 8 | +2.7 % | +2.7 % | +4.8 % | +3.6 % | +0.9 % | +1.7 % |

Speed of the search (interleaved, two runs, the AV2 job paused): 5K photos 82.4 → 80.0 inter frames
a second (−3 %), the other traces and 720p within noise.

- **Taken: the search** (`Hybrid::search_luma_tx`, on; the C++ hybrid kept the analysis's types,
  as its differential tests now do with `Hybrid::as_cpp`).
- The edge filter loses because the analysis decides without it. Quantizer matrices are
  perceptual: PSNR undersells them, but they're no PSNR win.

### Metal AV1: where the bytes go, by kind of block (2026-11-01)

`ENC_BLOCK_BITS` per block in the final write, totalled by kind (an experiment, `GA_BITMAP`, not
kept): inter copies, coded inter blocks, and intra blocks by their source luma: flat (≤ 2 values),
few levels (≤ 8), edges (> 5 % of samples on a step > 48), texture (the rest). q20, first 100
frames. Bits and pixels as shares of the frame type's totals:

| | key frame | flat | few levels | edges | texture | inter frames | copies | coded inter | intra edges | intra texture | intra flat / few |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 5K typing-cc | 264 KB | 4 % / 42 % px | 20 / 15 | 29 / 3 | 47 / 40 | 0.1 KB | 5 / 100 | 16 / 0 | 40 / 0 | 3 / 0 | 35 / 0 |
| 5K scroll-win | 224 KB | 6 / 61 | 29 / 16 | 35 / 3 | 30 / 19 | 3.3 KB | 2 / 99 | 21 / 1 | 32 / 0 | 2 / 0 | 44 / 0 |
| 5K photos | 541 KB | 1 / 45 | 4 / 8 | 31 / 7 | 65 / 41 | 26.1 KB | 1 / 87 | 7 / 11 | 17 / 0 | **73 / 1** | 2 / 0 |
| 5K cursor-drag | 244 KB | 4 / 41 | 21 / 18 | 28 / 3 | 47 / 39 | 0.2 KB | 3 / 100 | 11 / 0 | 50 / 0 | 7 / 0 | 29 / 0 |
| 720p typing-cc | 53 KB | 1 / 12 | 4 / 23 | 45 / 13 | 50 / 52 | 0.1 KB | 2 / 99 | 39 / 1 | 44 / 0 | 10 / 0 | 5 / 0 |
| 720p scroll-win | 43 KB | 1 / 29 | 8 / 31 | 57 / 14 | 34 / 26 | 1.9 KB | 0 / 91 | 52 / 8 | 37 / 0 | 3 / 0 | 8 / 0 |
| 720p photos | 59 KB | 1 / 29 | 3 / 15 | 49 / 18 | 48 / 39 | 11.9 KB | 0 / 34 | 60 / 63 | 14 / 1 | 24 / 2 | 1 / 0 |

(cells: % of bits / % of pixels)

- **The bytes are in intra edges and texture,** in key frames and in the new content of inter
  frames. On 5K photos, 73 % of an inter frame's bytes are intra texture blocks covering 1 % of
  the picture: newly shown photo with nothing to copy.
- On static traces the key frame is most of the BD sweeps' bytes (typing: 264 KB against 99 ×
  0.1 KB), so those sweeps mostly measure intra coding.
- Copies cost almost nothing; coded inter blocks matter at 720p (fractional motion of the
  downscaled traces).
- Next for bitrate: intra coding of edges and texture. AV2's tools are measured against exactly
  that (the attribution under way on `gpu-codec`).

### Metal AV1: the closed loop's rounding offset 0.375 → 0.45; a light RDOQ rejected (2026-11-01)

The closed loop quantized with the Metal analysis's dead zone, q = |v| < zbin ? 0 : ⌊|v| + rnd⌋
(rnd 0.375, zbin 0.656, from av1gpu). Swept on our encoder alone: typing-cc, scroll-win and photos,
5K and 720p, q 8–32, first 100 frames, BD-rate by `vquality`'s RGB luma PSNR against the old
constants (negative: smaller):

| rnd / zbin | 5K typing | 5K scroll | 5K photos | 720p typing | 720p scroll | 720p photos |
|---|---|---|---|---|---|---|
| 0.25 / 0.75 | +4.7 % | +4.2 % | +4.1 % | +3.9 % | +6.8 % | +4.0 % |
| 0.30 / 0.656 | +2.4 % | +2.5 % | +1.9 % | +1.8 % | +3.5 % | +1.7 % |
| 0.42 / 0.656 | −0.9 % | −1.0 % | −0.4 % | −0.5 % | −1.2 % | −0.4 % |
| **0.45 / 0.656** | **−1.3 %** | **−1.4 %** | **−0.6 %** | **−0.7 %** | **−1.8 %** | **−0.8 %** |
| 0.45 / 0.60 | −1.1 % | −1.0 % | +0.1 % | −0.3 % | −0.6 % | +0.2 % |
| 0.45 / 0.68 | −1.1 % | −1.1 % | −0.2 % | −0.6 % | −0.7 % | −0.6 % |
| 0.50 / 0.656 | −1.6 % | −1.8 % | −0.3 % | −0.6 % | −0.5 % | −0.7 % |
| 0.50 / 0.55 | −0.3 % | −0.4 % | +1.9 % | +1.4 % | +1.4 % | +1.9 % |

- **Taken: rnd 0.45**, zbin unchanged. The C++ reference hybrid keeps 0.375, so the differential
  tests set it (`Hybrid::set_quant_rnd`).
- The GPU analysis at 0.45 too: no change (its decisions don't move), so it keeps 0.375.
- **Rejected, a light RDOQ:** levels lowered by one, last first, where the added distortion (a
  per-size pixel gain through the inverse transform) costs less than λ times the rate proxy's
  saving. Alone ±0.1 %; on top of 0.45 / 0.60 it gave back most of the gain. The proxy's rates
  aren't good enough to steer it.

### Metal AV1 re-baselined against hardware HEVC and libaom (2026-11-01)

The sweep of "against hardware HEVC and libaom" (2026-10-31) again, after a day of speed work:
first 100 frames, `vquality`'s RGB luma, hardware HEVC at five targets, the hybrid and libaom
realtime s9 inter frames at q 8–32, libaom's tiling for both (3 × 0 at 5K, 2 × 0 at 720p).
The session was disconnected throughout.

**BD-rate, hybrid vs libaom / vs hardware HEVC, by PSNR (SSIM):**

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K vs libaom | −46 % (−44 %) | −24 % (−19 %) | −34 % (−31 %) | −46 % (−45 %) |
| 5K vs HEVC | −60 % (−58 %) | no overlap (−74 %) | −83 % (−81 %) | −60 % (−57 %) |
| 720p vs libaom | −30 % (−19 %) | −1 % (+16 %) | −13 % (−7 %) | −30 % (−20 %) |
| 720p vs HEVC | −45 % (−45 %) | −40 % (−38 %) | −2 % (+16 %) | −42 % (−42 %) |

Within a point of the 2026-10-31 sweep everywhere: the speed work since cost no bytes.

**Inter frames a second at q20,** both encoders in the same runs (`--no-planes`, no scoring:
`--score-rgb`'s scoring runs inside the hybrid's pipeline and slows it), two runs each:

| | hybrid | libaom s9 | ratio |
|---|---|---|---|
| 5K typing-cc | 252 | 219 | 1.15 |
| 5K scroll-win | 167 | 168 | 1.00 |
| 5K photos | 79 | 90 | 0.88 |
| 5K cursor-drag | 249 | 220 | 1.13 |
| 720p typing-cc | 1150 | 1975 | 0.58 |
| 720p scroll-win | 473 | 964 | 0.49 |
| 720p photos | 182 | 492 | 0.37 |
| 720p cursor-drag | 854 | 2020 | 0.42 |

(The interleaved A/B runs earlier today, without libaom in the process, gave the hybrid ~300 on 5K
typing; compare within one table only.)

**Where we stand:** smaller than both everywhere at 5K. At 720p ahead on typing and drag, about
even with libaom on scroll and with HEVC on photos. Speed: ahead at 5K except photos; at 720p at
0.37–0.58× libaom, whose small-frame costs we don't have.

### Metal AV1: palette decisions measured, not taken (2026-11-01)

**By colour count** (a block's visible source of 2 to N exact luma values, or (U, V) pairs, coded
as a lossless palette; screen content tools on key frames too), 720p, 30 frames, q20:

| Trace | N | key frame | inter frames | PSNR-Y |
|---|---|---|---|---|
| typing-cc | off / 2 / 4 / 8 | 107.0 / 110.1 / 117.0 / 131.6 KB | 92 / 93 / 95 / 97 B | 41.44 / 41.45 / 41.47 / 41.55 |
| photos | off / 2 / 4 / 8 | 119.8 / 121.3 / 124.8 / 138.7 KB | 11.6 / 11.7 / 11.8 / 12.4 KB | 40.57 / 40.58 / 40.59 / 40.61 |

Every stream decoded exactly (libaom). Bytes go up much faster than quality.

**By cost, an upper bound.** One closed loop without palettes, then per intra block its measured
bits (`ENC_BLOCK_BITS`) and SSE against a palette's (bits from the default CDFs and the real
colour contexts; cost = SSE + λ · bits, the hook's λ = 0.12 step²; all the block's bits counted
as luma where its chroma can't be a palette). Key frames:

| Trace | size, q | exact palettes (2–8 values): candidates' share of bits → gain | lossy (k-means 2/4/8, no residual): share → gain |
|---|---|---|---|
| typing-cc | 720p q20 | 1.1 % → 0.00 % | 54.6 % → 0.17 % |
| typing-cc | 720p q40 | 1.5 % → 0 | 52.5 % → 5.08 % |
| typing-cc | 5K q20 | 2.1 % → 0.02 % | 46.3 % → 0.39 % |
| typing-cc | 5K q40 | 3.0 % → 0.02 % | 38.9 % → 1.53 % |
| scroll-win | 720p q20 | 2.3 % → 0.00 % | 42.9 % → 0.20 % |
| scroll-win | 5K q20 | 3.5 % → 0.05 % | 32.9 % → 0.69 % |
| scroll-win | 5K q40 | 4.7 % → 0.03 % | 31.0 % → 2.62 % |
| photos | 5K q20 | 0.6 % → 0.00 % | 73.1 % → 0.16 % |
| photos | 5K q40 | 0.8 % → 0.00 % | 73.8 % → 1.07 % |

Blocks with a few exact colours are near-flat, and DCT codes them in about 11 bits. The expensive
blocks are antialiased text and edges, with many levels. A lossy palette helps them only at low
quality.

**Decision:** no palette decisions at our operating point. Their best case is under 1 % at q20
(a few % at q40), against a decision pass on every intra block. The writer's palette support stays
(tested, free when unused), and `ENC_BLOCK_BITS` stays for cost experiments. Worth revisiting for
a low-bandwidth mode. For a custom codec the lesson is that the bytes are in antialiased glyph
edges, not few-colour blocks.

### Metal AV1: palette blocks in the writer and parser; libaom's palette measured (2026-11-01)

**Before deciding to build it:** libaom realtime (speed 9, 720p, 6 quantizers 10–44, 20–30
frames) with palette on and off (`AV1E_SET_ENABLE_PALETTE`, a temporary switch in the shim),
BD-rate of palette on:

| Trace | equal PSNR-Y, key / inter | equal RGB SSIM, key |
|---|---|---|
| typing-cc | +34.2 % / +32.5 % | +15.9 % |
| scroll-win | +14.5 % / +14.4 % | +5.8 % |
| photos | +32.6 % / +7.1 % | +15.9 % |

libaom's realtime mode picks palette by counting colours, not by cost, and spends bytes on it.
Intra block copy changed nothing (realtime never uses it). The vendored libaom is realtime-only,
so its RD-searched palette couldn't be measured.

Distinct luma values per block, a 5K typing-cc frame:

| Block size | 1 (flat) | 2–4 | 5–8 | 9–16 | more |
|---|---|---|---|---|---|
| 8x8 | 37.1 % | 16.5 % | 7.1 % | 17.3 % | 22.0 % |
| 16x16 | 29.4 % | 15.1 % | 4.1 % | 8.2 % | 43.1 % |
| 32x32 | 21.5 % | 14.1 % | 2.4 % | 3.6 % | 58.5 % |

A quarter of 8x8s could be exact palette blocks; antialiased text has many more levels.

**What changed** (the writer and parser only; nothing decides palettes yet):
- Record: `BlockPalette` per block (sizes, Y/U/V colours, where its colour index maps start) and
  the maps, both optional, as the inter entries.
- The walk: palette_mode_info (the palette cache, colours as literals and deltas, V by deltas or
  literals, whichever is shorter), palette_tokens (anti-diagonal order, colour contexts), the
  palette prediction, in the one-pass walk and the block-parallel reconstruction.
- The CDFs for palette sizes and colours are in `InterCdfs`: `av1g_cdfs`, which the GPU entropy
  coder shares, is unchanged, and symbol streams refuse palette blocks.
- 4x16 and 16x4 blocks may have palettes (the spec compares the enum), and their chroma map is the
  chroma of their 8x8 (2 more wide or tall). The first dav1d run caught that.

**Result:** random records with half their eligible blocks turned into palette blocks (121,181 in
the still pictures, both superblock sizes, plus inter sequences) round-trip through the parser,
reconstruct the same split as in one pass, and decode exactly with dav1d and aomdec. Streams
without palettes are unchanged (`--digest`). Inter frames a second, interleaved, 3 rounds: no change
beyond noise (−1.8 % to +6.7 %, mixed signs).

### Metal AV1: blocks reconstructed on every thread apart from their coding (2026-11-01)

**Before:** each tile's walk reconstructed and coded its blocks in one pass. Intra prediction reads
decoded neighbours, so a tile is a chain. At 5K photos tile 0 holds a 1–2 superblock wide strip of
intra blocks: 6–8 ms, while the other seven tiles take 2–3 ms. The closed loop waited for it.

**What changed** (`writer/recon.rs`): the closed-loop hook reads no symbol state, so a tile with a
reconstruction is coded in three passes, each picture one task graph on the worker pool:
- **plan**: the walk with nothing coded or reconstructed. It records each intra tx block's edges
  (BlockDecoded, the edge filter type), each block's quantizer, and the earlier blocks an intra
  block may read (the row above to twice its width, the column left to twice its height, and the
  same for its 8x8's chroma).
- **reconstruct**: every block as soon as the blocks it reads are done (prediction, hook, inverse
  transform, final levels and tx types into the record). A finishing block takes one newly ready
  reader itself and queues the rest; the strip becomes a block-level wavefront.
- **code**: the walk again with the final levels and no reconstruction, after the tile's last block.

Tiles overlap: one tile plans while another reconstructs. Only reconstructions that can't fail are
split: ENC_FIX_RANGE, a hook whose luma types stay in their sets (QuantHook), and a record the plan
accepts. Anything else is coded in one pass, so errors and the record left behind are the walk's.
The planes are shared by the block tasks through raw pointers; the dependency order keeps the
samples they touch apart (`unsafe`, documented in the crate's rules).

Also fixed: a skip inter block's chroma tx blocks got a tx type derived from whatever luma types the
thread's previous block left. The record field depended on thread history. It is now DCT_DCT, as
the spec never derives one there.

**Result:** the same streams (`--digest`, 720p and 5K), and a test that split pictures equal
ENC_ONE_PASS ones (outputs, payloads, record). Interleaved, 3 rounds, inter frames a second (median):

| Trace | before | after |
|---|---|---|
| 5K photos | 82.6 | 84.4 (+2 %) |
| 5K scroll-win | 211.6 | 213.5 (+1 %) |
| 5K typing-cc | 312.5 | 304.4 (−3 %) |
| 720p photos | 168.1 | 175.8 (+5 %) |
| 720p scroll-win | 471.0 | 482.3 (+2 %) |

**Why so little:** at 5K photos the closed loop went from 5.3 to 3.7 ms (−30 %). But it now uses
every core, and the next picture's copy finder (4.4 → 5.5 ms) and the filters (5.5 → 6.6 ms) slowed
by about as much. Summed over tiles, the closed loop is 24–36 ms of CPU per picture: half the
hook's quantization trials, a quarter the copies' motion compensation. The chain no longer limits
it; total CPU does. Typing loses 3 % to the plan pass, an extra walk over tiles that were already
balanced. Next: less CPU per block, not more parallelism.

### Metal AV1: one persistent worker pool for the crate's parallel loops (2026-11-01)

**Before:** each parallel loop started its own scoped threads, every picture:
- the closed loop's tiles;
- the reconstruction's bands of rows (up to 24 threads);
- the layout's two passes and the chroma decisions (up to 14 each);
- source padding;
- the copy finder's two loops.

**Cost of starting threads (a loop of trivial tasks, M-series Mac):**

| Tasks | scoped threads | GCD `dispatch_apply_f` | parked pool |
|---|---|---|---|
| 8 × 0 µs | 56 µs | 0.6 µs | 11 µs |
| 14 × 50 µs | 159 µs | 241 µs | 118 µs |
| 24 × 20 µs | 222 µs | 165 µs | 81 µs |
| 14 × 500 µs | 691 µs | 657 µs | 562 µs |

GCD is nearly free for tiny loops but takes on workers gradually, so it loses at the encoder's task sizes.

**What changed:**
- `pool.rs`: one pool of `available_parallelism - 1` threads, started on first use and parked on a condition variable between loops.
- `pool::run(n, f)` calls `f(0..n)` on the caller and the workers and returns when all have, so `f` may borrow (one `unsafe`: the closure's lifetime erased, sound because nothing calls it after `run` returns).
- Loops from several threads (the closed loop, the copy finder, the writer) share the pool: idle workers help whichever loop has tasks left. Nested loops work, and a panic is resumed in the caller once every task is done.
- Every per-picture scope in the crate uses it.

**Result:** the same streams (`--digest`, 720p and 5K). Interleaved, 3 rounds, inter frames a second (median):

| Trace | before | after |
|---|---|---|
| 5K photos | 79.7 | 80.0 |
| 5K scroll-win | 209.9 | 212.0 (+1 %) |
| 5K typing-cc | 309.1 | 322.0 (+4 %) |
| 720p photos | 166.8 | 171.0 (+2.5 %) |
| 720p scroll-win | 469.4 | 493.9 (+5 %) |

The light frames gain most: their loops are short, so starting threads was a larger part of them.

### Metal AV1: inter frames reconstruct into the filters' buffers, deblocked in place; copies on the GPU rejected (2026-11-01)

**Before:** the copied 64×64s of an inter frame moved four times each picture:
- the reference into the tile's buffer (inter prediction);
- the tiles into the closed loop's frame-sized reconstruction, which `resize` also zero-filled first;
- the reconstruction into the filters' deblocking buffer (the changed area's surroundings) and output buffer (the direct copies);
- around the changed area, a ring of the deblocking buffer set aside and put back, because deblocking there filters the previous picture's already-deblocked samples a second time.

**What changed:**
- `av1enc_hybrid_closed_loop_ex` takes planes to reconstruct into (`recon`). An inter frame's tiles write there instead of into the closed loop's own buffer; any other frame keeps its own (the next picture's tiles come from it) and copies it there.
- The encoder passes the filters' deblocking buffers (`AV1MetalPostfilter.reconstructionBuffers`).
- When `search` gets those buffers' contents and the inter frame's `direct` map, it deblocks them in place.
  - With `lf_inter_off`, the only edges deblocked are those at coded (intra) 64×64s, and the closed loop rewrites every sample of an inter frame.
  - So the buffer starts each picture as the pure reconstruction. Nothing is filtered twice, and nothing needs loading or keeping.
- The direct copies go to the output buffer only, all of them while the GPU deblocks.
- Without `direct`, as for a key frame's tile-reuse regions, the region search needs the previous picture's deblocking, so `search` filters the whole picture.

**Result:** the same streams (`--digest` on every trace, 720p and 5K). Interleaved, 3 rounds, inter frames a second (median):

| Trace | before | after |
|---|---|---|
| 5K photos | 76.0 | 78.9 (+4 %) |
| 5K scroll-win | 196.4 | 207.9 (+6 %) |
| 5K typing-cc | 287.4 | 310.6 (+8 %) |
| 720p photos | 164.2 | 172.0 (+5 %) |
| 720p scroll-win | 441.3 | 473.5 (+7 %) |

At 5K photos the filters' main-thread time went from 5.8 to 5.3 ms, and typing-cc's closed loop from 1.7 to 1.5 ms (the zero fill and the frame copy gone).

**Rejected first: the same copies done by the GPU.** The reconstruction went in a buffer of its own, and a `p_copy_r` kernel moved the listed 64×64s in the filters' command buffer.

| Variant | 5K photos | 5K scroll-win | 5K typing-cc |
|---|---|---|---|
| every copy on the GPU | 75.8 → 72.6 | 200.5 → 201.0 | 285.1 → 294.2 |
| ring and load on the GPU, far direct copies on the CPU | 76.9 → 75.3 | 198.4 → 202.0 | 288.6 → 299.0 |

- The direct copies are most of a moving picture: 87 % of photos' 64×64s are copies. On the CPU they overlapped the GPU's deblocking; on the GPU they queued in front of it.
- The GPU is the busier side at 5K photos, shared with the next picture's analysis (the filters' first pass takes 2.4 ms there against 1.15 ms alone). Moving work there doesn't pay; removing it does.

### Metal AV1: a superblock-row wavefront for the closed loop, measured, not taken yet (2026-11-01)

**The closed loop's limit (5K photos, `--tiles 3x0`, 100 frames):**
- Each of the 8 tiles is one task. Tile 0 takes 5.0 ms every frame; the others take 1.6–2.3 ms. The sum is 18.7 ms, so a perfect 8-way balance would be 2.3 ms.

**Its range coding is discarded:**
- The closed loop runs the writer's full walk, symbols included. The hybrid then writes the frame again once the filters have chosen CDEF.
- A sink that codes nothing gives the same streams (`--digest`) in the same 5.5 ms. Coding is a negligible part of the work.
- The quantization hook reads no entropy context, so the reconstruction depends on nothing the coder produces (delta-q aside, which the encoder doesn't use).

**Experiment: a wavefront.**
- A reconstruction-only walk of one superblock row (`Walk::sb_row`, that null sink), one task per (tile, superblock row), taken in row-major order.
- Each row starts superblock c once the row above has done c + 1. The tile's buffers are shared through raw pointers, which isn't sound enough to keep.
- The streams are the same in every case.

Inter frames a second at 5K:

| Trace | tiles, 8 columns | rows, 8 columns | rows, 4 columns |
|---|---|---|---|
| photos | 76.0 (closed loop 5.5 ms) | 80.1 (4.4 ms) | 76.7 (4.6 ms) |
| scroll-win | 197 (2.2 ms) | 172 (3.1 ms) | 177 (2.6 ms) |
| typing-cc | 293 (1.7 ms) | 230 (2.4 ms) | 281 (1.5 ms) |

- 4 columns' streams are smaller: photos 26.3 against 26.4 KB, typing-cc 144 against 153 B.

**Why it's no more than this:**
- Streams use 128×128 superblocks, so a 640-wide tile is 5 superblocks wide. A lag of 2 lets about 2.5 of its rows run at once.
- Photos' work lies in a vertical strip of tile 0. Each superblock there waits for the heavy one above it, so the strip stays serial however many threads there are.
- 14 workers were slower than 8: rows on the efficiency cores stall the chain.
- On light frames (scroll-win, typing-cc), the experiment's fixed costs outweigh its gain: threads spawned every frame, per-row setup, and spinning.

**Where the closed loop's CPU goes (Time Profiler):**
- `QuantHook::trial` (forward transform and quantizer, NEON already) is 26 % of its self time.
- Next are the writer's coefficient coding, memmove and inter prediction.

Not taken: a sound version needs the tile buffers restructured for shared access, and a persistent worker pool. It would be worth about 5 % on photos, plus fewer tiles' bytes at equal speed. The patch is kept with the session's notes.

### Metal AV1: the filters' CDEF search reads the analysis's source in place; source buffers untracked (2026-11-01)

**What changed:**
- The CDEF search copied the source into target buffers, all of it for a full search and the changed 64×64s for a region. Now it binds the analysis's padded source buffers directly whenever their rows are the filters' plane width apart (widths that are a multiple of 64, such as 5K, 1080p and 720p). Other widths copy as before.

**Finding: hazard tracking.**
- Bound as is, the change was slower:

  | Trace | before | after |
  |---|---|---|
  | photos 720p | 159.4 154.3 163.0 | 131.9 140.0 137.9 |
  | scroll-win 720p | 416.7 427.4 438.8 | 360.6 363.1 349.4 |
  | photos 5K | 76.6 76.3 76.8 | 73.2 72.9 73.2 |

- The buffer is also the next picture's motion-search reference, so Metal's automatic hazard tracking orders the filters' command buffer and the next analysis behind one another (a bound buffer counts as written).
- The source buffers are now made `.hazardTrackingModeUntracked`. The CPU writes one before its analysis is committed, and every GPU use only reads it.

**Results:**
- The streams are the same (`--digest`; a 1000-wide run, which copies, too).

Inter frames a second, against the shared source alone:

| Trace | before | after |
|---|---|---|
| photos 5K | 74.9 74.1 76.1 | 77.1 76.3 75.5 |
| scroll-win 5K | 188.4 193.9 183.9 | 196.2 195.9 196.1 |
| photos 720p | 159.2 156.1 160.0 | 158.3 162.1 164.2 |
| typing-cc 5K | 276.1 282.8 284.3 | 286.1 264.8 286.6 |
| scroll-win 720p | 426.4 425.7 419.8 | 416.1 408.4 426.2 |

That's a little faster at 5K, and within noise elsewhere.

### Metal AV1: inter frames' closed loop reads the analysis's padded source (2026-11-01)

The first step of the frame store (the owner's 2026-11-01 direction: every stage borrows one copy of each picture).

**What changed:**
- The Metal analysis pads each picture to whole 64×64s in shared memory. The Rust closed loop padded its own copy (`pad_source`, 22 MB at 5K, on the main thread), byte for byte the same.
- An inter frame's closed loop now reads the analysis's buffers through a borrowed `SrcView` (`Video::padded`, `av1enc_hybrid_closed_loop_ex`'s `padded`). The filters take those buffers as their source too.
- A key frame still pads its own: the next key frame compares tiles with it to keep unchanged ones.
- The buffers stay the encoder's until the next picture's partition is read. The filters are done with them by then.

**A false alarm along the way:**
- At first, inter frames borrowed after a key frame that had borrowed too, and the next picture was made to keep no tiles.
- The bench's warm-up encode of picture 0 then stopped the measured key frame keeping its tiles. Its bytes were the same, but the filters' history differed, so later frames' streams changed.
- Borrowing only in inter frames keeps the streams the same (`--digest`, four 720p and two 5K runs; the Rust tests, oracle included, and the Swift AV1 tests pass).

Inter frames a second (three interleaved runs):

| Trace | before | after |
|---|---|---|
| photos 5K | 70.9 75.1 75.5 | 76.7 76.9 76.9 (+4 %) |
| scroll-win 5K | 175.8 186.6 174.3 | 198.5 194.4 198.4 (+10 %) |
| typing-cc 5K | 264.2 260.1 262.5 | 291.2 281.8 281.2 (+9 %) |
| photos 720p | 153.7 159.9 160.2 | 163.2 158.4 161.4 |
| scroll-win 720p | 424.2 415.8 434.1 | 423.9 430.2 431.5 |

### Metal AV1: the filters' far direct copies while the GPU deblocks; source padding in parallel, not taken (2026-11-01)

**Where an inter frame's filters go (5K photos, ms a frame, `searchChanged`):**

| Step | ms |
|---|---|
| direct copies and lists | 0.97 |
| saving the ring | 0.24 |
| loading the reconstruction around the changed 64×64s, and the source | 0.67 |
| first GPU pass (deblocking, directions, SSE) | 2.44 |
| restoring the ring | 0.21 |
| CDEF preset search (CPU) | 0.50 |
| assignment | 0.20 |
| CDEF | 0.79 |

- With the analysis finished first (a test hack), the first GPU pass is 1.15 ms. About 1.3 ms of it is waiting behind the next picture's analysis on the GPU.

**What changed:**
- About two thirds of the direct copies (1,387 of 2,098 64×64s a frame) lie outside the ring that the deblocking reads. Those are now copied while the first GPU pass runs.
- The copy is 0.74 ms, but the GPU pass took about 0.6 ms longer meanwhile, presumably because they share memory bandwidth.
- The filters are 6.05 → 5.9 ms. The streams are the same (`--digest`).

Inter frames a second (three interleaved runs):

| Trace | before | after |
|---|---|---|
| photos 5K | 74.1 74.4 74.2 | 75.3 76.0 74.3 |
| scroll-win 5K | 183.3 182.0 184.1 | 186.4 184.1 183.6 |
| typing-cc 5K | 256.9 218.0 260.6 | 265.7 259.8 259.9 |

The 720p traces were within noise.

**Not taken: the analysis's source padded on 8 threads.**
- `Run.init` pads the 22 MB source into Metal buffers in 1.22 ms, which delays the analysis's start.
- On 8 threads, photos 5K was 75.6 75.6 75.3 against 75.3 76.0 74.3, and the rest within noise. The start isn't what the filters wait for.

### Metal AV1: the next analysis started on a thread of its own (2026-10-31)

**What changed:**
- `begin` copies the next-but-one picture's source to the GPU and commits its analysis. It now runs on another thread, alongside the writer and the closed loop, instead of on the main thread. That was 0.96 ms at 5K.
- It touches only the Metal encoder, which the closed loop and the filters don't use. The main thread waits for it before that picture's partition.

**Results:**
- The streams are the same (`--digest`).

Inter frames a second, three interleaved runs each, against the threaded writer alone:

| Trace | before | after |
|---|---|---|
| photos 5K | 74.2 74.7 74.3 | 74.8 75.5 74.9 (+0.8 %) |
| photos 720p | 168.9 172.3 171.0 | 163.6 168.2 167.9 (−2 %) |
| scroll-win 5K | 178.0 179.3 179.7 | 184.0 187.1 186.9 (+4 %) |
| scroll-win 720p | 429.0 439.0 440.8 | 445.1 450.6 453.2 (+2.5 %) |
| typing-cc 5K | 248.0 224.7 247.4 | 269.2 270.3 264.2 (+12 %) |

photos 720p is within this machine's run-to-run noise.

### Metal AV1: the bitstream written on a thread of its own (2026-10-31)

**Where the main thread's time went:**
- Timed step by step at 5K photos over 100 frames: `begin` 0.96 ms (the next-but-one picture's upload and commit), chroma and padding 0.7, the closed loop 5.3, the filters 6.0, the writer 0.9.
- In steady state the main thread barely waits for the GPU. The 1.85 ms average wait was mostly the key frame's.
- A Metal System Trace shows the GPU idle between pictures while the main thread writes and starts the next analysis.

**What changed:**
- `AV1HybridEncoder` writes picture i's bitstream (`av1enc_hybrid_write_ex`) on another thread, while the main thread waits for picture i + 1's partition and starts picture i + 2's analysis.
- It waits for the write before the next closed loop, which uses the same CPU state.
- `output` gets picture i once picture i + 2's analysis has started: about a millisecond later at 5K. The bytes are ready no later than before.

**Results:**
- The streams are the same (`--digest`, four 720p and two 5K runs).

Inter frames a second, three interleaved runs each:

| Trace | before | after |
|---|---|---|
| photos 5K | 68.3 68.2 68.9 | 71.8 73.2 74.0 (+6.6 %) |
| photos 720p | 150.0 155.0 147.8 | 169.6 169.1 170.6 (+12.5 %) |
| scroll-win 5K | 163.8 168.4 164.0 | 173.9 173.5 178.0 (+5.9 %) |
| scroll-win 720p | 401.7 408.6 409.1 | 433.9 448.1 451.6 (+9.4 %) |
| typing-cc 5K | 228.0 227.8 229.8 | 231.9 246.3 240.7 (+4.9 %) |

### Metal AV1: k_me's sub-sample refinement on every lane; staged windows rejected (2026-10-31)

**What changed:**
- `k_me` refines its best vector to half and then quarter samples, measuring the 8 neighbours at each step.
- Before, lanes 0–8 each measured one neighbour's full 16×16, so 23 of the 32 lanes idled.
- Now every lane measures 8 samples (half a row) of each neighbour, and `simd_sum` adds them. The sums are integers, so they're the same.

**Results:**
- The streams are the same (`--digest`, four 720p and two 5K runs).
- A 5K photos inter frame's motion search (`k_proj` and `k_me`) is 2.53 → 1.75 ms of GPU.
- Inter frames a second, mean of three interleaved runs: photos 5K 67.8 → 69.5. photos 720p, scroll-win 5K and typing-cc 5K were within noise (149 → 150, 162 → 162, 229 → 226).

**Rejected: each search window's reference samples staged in threadgroup memory.**
- The idea was to read each sample from the picture once per window instead of once per vector. It worked window by window (no motion's ±8, then each candidate's ±4).
- The output was the same, but the motion search was slower: 2.53 → 3.02 ms.
- The barriers and the windows' partly filled SIMD-group passes cost more than the cached device reads they replaced.

### Metal AV1: an exact inter match costed without a transform (2026-10-31)

**What changed:**
- When `k_inter`'s best candidate has a SAD of zero, the residual is all zeros.
- The transform and quantizer then give no distortion and the skip flag's bits. `k_inter` now writes those directly, without filling the residual or transforming it.
- Screen content has many exact matches, both unchanged blocks and scrolled ones.

**Results:**
- The streams are the same (`--digest`, four 720p and two 5K runs).
- A 5K photos inter frame's inter candidates are 2.36 → 1.86 ms of GPU.

Inter frames a second, mean of three interleaved runs:

| Trace | before | after |
|---|---|---|
| photos 5K | 65.2 | 66.8 |
| photos 720p | 138.6 | 143.6 |
| scroll-win 5K | 157.7 | 161.9 |
| typing-cc 5K | 221.3 | 222.0 |

### Metal AV1: the closed loop's limits at 5K photos; two rejected tries (2026-10-31)

At 5K photos the closed loop is ~5.6 ms of wall time for ~20 ms of CPU over 8 tile columns. Photos' changes cluster in a few columns, and the slowest tile sets the pace.

**Rejected: the hook's residual reused by the writer.**
- For a coded inter or chroma txb, `QuantHook::trial` already dequantizes and inverse-transforms the levels (for the RD skip), and the writer did it again.
- A `TxbHook::take_residual` let the writer copy the hook's residual instead. The streams were the same (`--digest`), but there was no gain: the closed loop stayed 5.60 ms at 5K photos, and the other traces were within noise.
- NEON inverse transforms are a small part of the loop.

**Not a default: more tiles.**
- With 8 columns × 2 rows (`3x1`) or 16 columns (`4x0`) against libaom's 8 columns, the speed is ×1.05–1.06.
- BD-rate (q 12/20/28):
  - photos: +0.56 / +0.61 %;
  - typing-cc: +0.00 / +1.44 %;
  - scroll-win: +0.64 / +0.61 %.
- That's over the 0.4 % a default may cost. Tiling is the caller's choice already.

### Metal AV1: no intra below 8×8 where the 8×8's inter residual is nothing (2026-10-31)

**What changed:**
- Inter frames don't search 4×4, 4×8 or 8×4 intra blocks inside an 8×8 whose inter prediction quantizes to nothing.
- Those shapes have no inter search of their own, so `interSkipsIntra` never applied to them.
- With a zero-residual 8×8 inter block available, the partition keeps it. This is libaom realtime's rule one level up.

**Results:**
- A 5K photos inter frame's intra analysis is 5.4 → 3.2 ms of GPU (4×4 0.84 → 0.12, 4×8 0.97 → 0.21, 8×4 0.95 → 0.22).

BD-rate (q 12/20/28, PSNR-Y) and inter frames a second (mean of the three):

| Trace | BD-rate | before | after |
|---|---|---|---|
| photos 5K | +0.00 % | 60 | 64 |
| photos 720p | +0.11 % | 141 | 145 |
| scroll-win 720p | +0.00 % | 375 | 377 |
| scroll-win 5K | +0.03 % | 164 | 164 |
| typing-cc 720p | +0.00 % | 811 | 833 |
| typing-cc 5K | +0.00 % | 208 | 224 |
| cursor-drag 720p | +0.00 % | 754 | 726 (noise at this rate) |

Within the 0.4 % a default may cost.

### Metal AV1: k_me measures each vector once (2026-10-31)

**What changed:**
- k_me searches no motion's ±8 window and ±4 around each of the frame's shift candidates and the SB's k_proj vector, and these overlap.
- A position an earlier window has is now skipped.
- The best vector can't change: a repeat has the same SAD and a larger index, so it loses the tie.
- The second best is now always a different vector: before, it could repeat the best.

**Results:**
- The motion search stage of a 5K photos inter frame is 2.73 → 2.48 ms.
- BD-rate (q 12/20/28, PSNR-Y): 0.00 % on photos 5K and 720p and on scroll-win 5K, +0.05 % on scroll-win 720p.

Inter frames a second, mean of the three quantizers:

| Trace | before | after |
|---|---|---|
| photos 5K | 60 | 61 |
| photos 720p | 137 | 141 |
| scroll-win 720p | 384 | 392 |
| scroll-win 5K | 156 | 156 |

### Metal AV1: inter candidates' SADs from 8×8s measured once (2026-10-31)

**What changed:**
- k_inter measured every candidate vector's SAD over the whole block, for every shape. A 64×64 has up to 33 candidates over 4,096 samples, and the 64×32s, 32×32s and smaller shapes measured the same samples at the same vectors again.
- A new kernel, k_inter_sad (one threadgroup per analyzed SB, after k_me), lists the SB's distinct candidates: no motion, then its 16×16s' k_me vectors. It measures every 8×8's SAD at each into a table kept across pictures (`GpImage.meU`, `meSad`).
- k_inter sums a block's 8×8s. The SADs are of whole samples, as the float sums before were, so every choice and stream is the same.

**Results:**
- Same streams (`--digest`: the four 720p checks, 5K photos and scroll-win).
- GPU stages of a 5K photos inter frame (`--profile --inter`): inter candidates 3.79 → 2.35 ms, and the motion search 2.52 → 2.73 ms (it now holds k_inter_sad).

Steady-state inter frames a second, three interleaved runs each, a quiet machine:

| Trace | before | after |
|---|---|---|
| photos 5K | 58.6 | 62.2 |
| photos 720p | 137.0 | 141.9 |
| scroll-win 720p | 356.9 | 376.4 |
| scroll-win 5K | 160.1 | 156.9 (noise) |
| typing-cc 5K | 228.3 | 225.2 (noise) |

### Metal AV1: where an inter frame's CPU time goes; copies on the GPU rejected (2026-10-31)

**Time Profiler** (`xctrace record --template 'Time Profiler'`, 5K photos, 100 inter frames, the encode's window only; about 65 ms of CPU a frame across all threads):

| Work | Share | Where |
|---|---|---|
| The closed loop's tiles (`writer::encode::code_tile`, `QuantHook::trial` its largest part) | 31 % | 8 tile threads, one of them the main thread |
| Deciding the copies (`ShiftFinder::candidates`: `vote`, sort, `col_hashes`, `sb_matches`) | 22 % | the CopyFinder's thread and its bands |
| `memmove` | 21 % | mostly `AV1MetalPostfilter.copy` (direct 64×64s, ~10 %), then the writer's reconstruction assembly, `predict_inter` of copies and source padding |

The main thread is busy about 11 ms of a ~24 ms profiled frame:
- 56 % is the closed loop;
- 24 % is `memmove`, mostly the post-filters' 64×64 copies;
- the rest of the frame, it waits on the GPU or the tile threads.

**Rejected: the GPU making the post-filters' copied 64×64s** from the previous output at their shift, instead of the CPU copying them from the reconstruction.
- The streams are the same (`--digest`, six checks). That needed the CPU-copied ones near the region to write their output only after the GPU pass, which reads the previous output.
- But 5K photos went 58.5 → 54.2 inter frames a second (filters 8.2 → 9.8 ms; interleaved runs, a quiet machine), and 720p was even.
- The copies go into the filters' first command buffer, which already waits behind the next picture's analysis on the GPU, so they lengthen the wait.
- The CPU copy runs on 8 threads (~1 ms of wall time), so it costs less.
- Lesson: at 5K photos, GPU work added to the filters is on the critical path. CPU work done in parallel isn't.

### Metal AV1: the partition search a SIMD-group per superblock; a key frame's GPU profile (2026-10-31)

**Profile:**
- A 720p photos key frame (`av1seq --gpu-capture`, now with analysis reuse off for a key frame, as `--profile` has it), replayed in Xcode.
- A 5K key frame's capture crashed Xcode 27.2's replay (EXC_BAD_ACCESS in Xcode), so it was 720p.

Kernels by share of the capture (analysis 84 %, filters 16 %):

| Kernel | Share | Registers | Spilled | SIMD-groups |
|---|---|---|---|---|
| k_leaf | 33.9 % | 192 | 288 B | 12,880 |
| k_analysis_small_8x8 | 12.1 % | 192 | 1.77 KiB | 470 |
| k_dp | 8.6 % | 156 | 1.42 KiB | 12 |
| k_analysis_small_8x4 / 4x8 / 4x4 | 7.0 / 6.6 / 6.5 % | 192 | 1.06 KiB / 992 B / 864 B | 920 / 920 / 1290 |
| k_analysis_32x16_w4 | 4.6 % | 192 | 416 B | 376 |
| k_analysis_small_8x16 | 3.0 % | 192 | 2.69 KiB | 245 |

The leaf decisions (k_leaf: chroma mode, CfL and luma tx type for every leaf) are a third of a key frame's GPU time.

**What changed:**
- k_dp ran a thread per superblock, holding its 85-node partition tree in registers, and spilled. A 720p picture was 12 SIMD-groups.
- It now runs a SIMD-group per superblock, with the tree in threadgroup memory. The lanes take a level's nodes, which read only the level below, with each node's arithmetic as before.
- Lane 0 writes the leaves in decode order, as before.

**Results:** same streams (`--digest`, the four 720p checks). The partition stage (`--profile`, best of 10) is 0.3 → 0.1 ms on 720p key frames and 5K photos inter frames, and 0.3 ms either way on 5K key frames. That was measured with a Screen Sharing session open, and the stage sits on the GPU's critical path between the analysis and the leaves.

**The leaf stage of a 5K key frame** (`--profile`, photos 17.8 ms, typing-cc 13.4 ms):

| | photos | typing-cc |
|---|---|---|
| no luma tx search (`--leaf-tx 0`, chroma alone) | 7.7 | 7.5 |
| up to 4×4 (`--leaf-tx 16`) | 9.2 | 10.6 |
| up to 8×8 (`--leaf-tx 64`) | 14.4 | 12.9 |
| up to 8×16 / 16×8 (128, the default) | 17.8 | 13.4 |

**Rejected:**
- **A larger `maxTotalThreadsPerThreadgroup` for the analysis kernels** (256, 512 or 1024, against the threadgroup's 128). Stage times didn't move on inter or key frames. On Apple GPUs the hint doesn't change how many registers the compiler allocates; k_dp has no hint (1024) and still allocates 156.
- **k_leaf's chroma costs summed mode by mode,** instead of into a per-lane array indexed by mode. The output was identical, but the leaves went 17.5 → 26.2 ms at 5K. The array version packs every mode's items across the 32 lanes. Mode by mode, a small chroma block's 2–32 items leave most lanes idle.
- **`LEAF_WARP_TX` 0** (a lane per tx type, scalar). The leaves are 38.2 against 17.5 ms at 5K and 4.0 against 2.0 at 720p, and the streams differ. The SIMD-group evaluation stays.

### Metal AV1: inter frames' 8×8 to 16×8 blocks on the SIMD-group kernel; fewer registers in the small kernel (2026-10-31)

**What changed:**
- **Inter frames analyze blocks of 64 samples and up (8×8, 8×16, 16×8) with the SIMD-group kernel** (`k_analysis_WxH_wN`), not the thread-per-block one.
  - In an inter frame, a block whose inter residual is nothing skips the intra search. A thread-per-block SIMD-group then waits on its slowest block.
  - The SIMD-group kernel spends one SIMD-group per block, so a skipped block costs almost nothing.
  - Key frames keep the thread-per-block kernel: there it's 2× faster (8×8 at 5K: 13.1 vs 26.7 ms).
  - 4×4, 4×8 and 8×4 keep it in inter frames too: the SIMD-group kernel is 4–7× slower for them (4×4: 6.3 vs 0.83 ms).
- **The small kernel quantizes each coefficient as the forward transform makes it,** so no thread holds the whole transformed block. The distortion is summed in the same order, so the output is the same.
  - Its spills, from Xcode's profile of the same frame:
    - 4×8: 1.64 KiB → 992 B;
    - 8×4: 1.73 → 1.06 KiB;
    - 8×8: 3.41 → 1.77 KiB;
    - 8×16: 3.66 → 2.69 KiB;
    - 16×8: 3.64 → 2.62 KiB;
    - 4×4: 864 B, unchanged.
  - Every one still allocates 192 registers.
- **`av1seq --digest`** prints a hash of the whole stream, to check that a change keeps it.

**Results:**
- Same streams on 720p photos, scroll-win and typing-cc inter, and on photos key frames (`--digest`).
- BD-rate 0.00 % at 5K and 720p (q 12/20/28).

GPU stages of a 5K photos inter frame (`--profile --inter`, best of 10, ms):

| | 4×8 | 8×4 | 8×8 | 8×16 | 16×8 | intra analysis |
|---|---|---|---|---|---|---|
| before | 1.06 | 1.09 | 0.80 | 1.45 | 1.42 | 8.5 |
| after | 0.96 | 0.95 | 0.29 | 0.25 | 0.25 | 5.3 |

Steady-state inter frames a second (mean of q 12/20/28):

| Trace | before | after |
|---|---|---|
| photos 5K | 57 | 59 |
| photos 720p | 132 | 137 |
| scroll-win 720p | 361 | 372 |
| scroll-win 5K | 160 | 160 |

The GPU saving is 3.2 ms a 5K photos frame, but the frame rate moves only 3 %: the hybrid's thread (closed loop and filters) is the limit there now.

### Metal AV1: what Xcode's GPU profiler says about an inter frame (2026-10-31)

**How:**
- `av1seq --gpu-capture` captured one 5K photos inter frame, the 12th; it needs `MTL_CAPTURE_ENABLED=1`.
- It was replayed in Xcode 27.2 with "Profile after replay" on an M4 Pro.
- The capture also holds the key frame's full-frame filters, which explains `p_cdef` and `p_deblock`'s share.

**The inter frame's analysis encoder:**
- Kernel occupancy is **16 %**, against the occupancy manager's target of 88 %.
- ALU utilization is 18 %.
- The compute shader launch limiter is at 61 %, and the instruction throughput limiter at 39 %.
- 68 % of instructions are integer or conditional, and 12 % floating point.
- L1 register residency is 23 % and threadgroup residency 3 %.

So the analysis isn't compute-bound: few SIMD-groups fit on a core.

**Why: registers.** Every analysis kernel allocates the full 192 registers, and most spill:

| Kernel | Share of the capture | Registers | Spilled |
|---|---|---|---|
| k_me | 13.5 % | 92 | 0 |
| k_inter_64x64_w1 | 5.6 % | 188 | 272 B |
| k_analysis_small_8x4 / 4x8 / 4x4 | 5.1 / 4.4 / 4.0 % | 192 | 1.73 KiB / 1.64 KiB / 864 B |
| k_inter_32x32_w3 | 3.6 % | 192 | 0 |
| k_analysis_small_8x16 / 16x8 / 8x8 | 2.6 / 1.4 / 1.2 % | 192 | 3.66 / 3.64 / 3.41 KiB |
| k_inter_16x32 / 8x8 / 8x16 / 16x8 / 16x16 / 32x16 | 0.97–1.9 % | 120–164 | 0 |
| k_leaf | 1.1 % | 192 | 288 B |
| k_dp | 1.1 % | 156 | 1.42 KiB (26 SIMD-groups in all) |
| k_analysis_{16x16 … 64x64} | ≤ 1.05 % | 192 | 384–688 B |
| k_proj | 0.9 % | 157 | 0 |

**Next:** cut the analysis kernels' register use. Threadgroup memory is almost unused (3 % residency), so it could take the per-thread arrays that spill now.

**Rejected:** sizing p_cdef_r's chroma dispatch to the chroma planes. Half of its threadgroups exit at once, but removing them changed nothing: the filters stayed at 8.5–8.8 ms a 5K photos frame.

### Metal AV1: the next picture's copies decided on their own thread (2026-10-31)

**What changed:** the hybrid's thread used to decide picture i + 1's copies itself (`av1enc_motion_classify`, 3.8–4.6 ms at 5K photos), between waiting for picture i's analysis and finishing picture i.
- Now a `CopyFinder` with its own motion handle decides them on another thread, one picture ahead, while picture i - 1 is finished.
- Applying copies (`av1enc_motion_apply_ex`) takes the decisions as input and doesn't read what classifying left in its handle, so the two handles are independent.
- Same bytes and PSNR.

**Results** (5K, libaom's tiling, `--no-planes`, two or three runs each; steady-state inter frames a second):

| Trace | before | after | libaom s9 |
|---|---|---|---|
| typing-cc | 204 | 222 | 225 |
| scroll-win | 130 | 154 | 170 |
| photos | 45 | 55 | 92 |
| cursor-drag | 187 | 206 | |
| photos 720p | 118 | 126 | ~500 |

**Where 5K photos stands now:**
- The hybrid's thread waits ~0.2 ms for each analysis, and the copies are always ready.
- The cycle is `finish`, ~15–19 ms: the closed loop 5.5–6 ms, and the filters 6–10 ms.
- Most of the filters' time is their first command buffer, which waits behind the next picture's analysis (~12.7 ms of GPU work, committed just before).

**Rejected: holding back part of the next picture's analysis until the filters finish.**
- The next picture's blocks 16×16 and up, its partition and its leaves went in a second command buffer, released after this picture's filters.
- The filters got faster (8.7 → 7.1 ms), but 5K photos went 57.5 → 54.5 inter frames a second: the thread then waited for that half instead.
- The GPU is the limit now. An inter frame's serialized stages (`av1seq --profile --inter`, 5K photos), in ms:
  - motion search 2.6;
  - inter candidates 3.7;
  - intra analysis 8.1, of which 6.2 is the shapes up to 16×8;
  - partition 0.3;
  - leaves 0.3.

### Metal AV1: each inter candidate once; parallel post-filter copies; interPreset's shapes (2026-10-31)

**What changed:**
- **k_inter tries each candidate vector once.** A block's candidates are no motion plus k_me's best two in every 16×16 it covers: 33 for a 64×64. On moving content they mostly repeat, and each repeat cost a full bilinear SAD. Same output.
- **The post-filters copy 64×64s on several threads.** A moving 5K inter frame copies its directly-filtered 64×64s (~2,500 of 3,600 on photos) into two buffers. With the rest that's 30+ MB, which took 2.9 ms on one thread; it's now 1.1 ms, and loading the region is 1.3 → 0.7 ms.
- **`interPreset`'s block shapes now apply.**
  - The analysis grids were built from the key frame's shape mask, so `turbo2` (no 4×4, 4×8 or 8×4) changed nothing for inter frames.
  - The analysis cache's key now includes the mask.
  - `HybridEncoderTests` codes a stream with it.

**Results** (first 100 frames, libaom's tiling, `--no-planes`, three runs each):

| Trace | GPU analysis a frame | Inter frames a second |
|---|---|---|
| photos 5K | 15.7 → 14.8 ms | 44 → 45 |
| photos 720p | 7.2 → 6.9 ms | 113 → 118 |
| scroll-win 720p | 2.8 → 2.4 ms | ~298 → ~334 (noisy) |

These are the candidate dedupe alone; the parallel copies add ~1 more frame a second at 5K photos.

**`interPreset` now that it applies** (same runs, PSNR-Y / inter frame bytes / inter frames a second):

| Trace | default | `turbo2` | `turbo3` |
|---|---|---|---|
| photos 5K | 42.72 / 26.4 KB / 43 | 42.66 / 26.5 KB / 46 | 42.66 / 26.8 KB / 48 |
| photos 720p | 40.75 / 12.1 KB / 111 | 40.70 / 12.2 KB / 118 | 40.71 / 12.2 KB / 139 |
| scroll-win 720p | 43.02 / 2.0 KB / 286 | 42.98 / 2.1 KB / 310 | 42.98 / 2.1 KB / 338 |

Both stay opt-in: each costs ~0.05 dB at equal or larger size.

**Rejected:** inter frames without the small shapes as a default (4×4, 4×8 and 8×4, and also 8×8). libaom's realtime mode uses no 8×8 or smaller blocks above 480p. Here it's 4–9 % faster for 0.04–0.06 dB less at 0.4–2 % more bytes, so ~+1–1.5 % BD. That's what `turbo2` does, for whoever wants the trade.

**Where a 5K photos inter frame's time goes:** the hybrid's CPU thread is the limit, at ~21 ms a frame:
- the closed loop, 5.3 ms;
- deciding the copies, 3.8 ms;
- the filters, 8–12 ms.

The post-filters' own GPU work is ~1.3 ms of that, but their command buffers wait 1–6 ms behind the next frame's analysis on the GPU.

### Metal AV1: the closed loop's reconstruction assembled on several threads (2026-10-31)

**What changed:** the writer's pre-filter reconstruction (tiles → one frame-sized picture, which the post-filters read) is now copied in bands of rows on several threads.
- It was one thread copying 22 MB a 5K picture: 1.35 ms, more than coding the tiles (0.93 ms), on 5K typing-cc inter frames (timed in the writer).

**Results** (5K, libaom's tiling, `--no-planes`; same bytes):

| Trace | Closed loop | Inter frames a second | libaom s9 |
|---|---|---|---|
| typing-cc | 2.2 → 1.4 ms | 168 → 208 | 225 |
| scroll-win | | 109 → 130 | 170 |
| photos | | 42 → 43 | 92 |

### Metal AV1: no intra search where the inter residual is nothing (2026-10-31)

**What changed:** in inter frames, `k_inter` now runs *before* the intra analysis.
- It records its J, and whether the residual quantizes to nothing (`GpInterRes.J`, `.zero`).
- The intra kernels (both kinds) skip a block whose inter residual is nothing, and otherwise keep the cheaper J (`ga_merge_inter`).
- This is libaom realtime's `skip_intra_pred` rule. It's on by default (`AV1HybridEncoder.interSkipsIntra`; `av1seq --intra-everywhere` turns it off).

**Results** (first 100 frames, libaom's tiling, `--no-planes`; BD-rate by PSNR-Y over q 12 / 20 / 28):

| Trace | BD-rate, stream / inter frames | Inter frames a second |
|---|---|---|
| photos 5K | −0.10 % / −0.24 % | ×1.44 (29 → 42) |
| photos 720p | +0.30 % / +0.29 % | ×1.24 (87 → 108) |
| scroll-win 720p | +0.20 % / +0.21 % | ×1.18 (237 → 279) |

Within the 0.4 % that a default may cost.

### Metal AV1: no decoded picture copied out; a lighter inter preset as an opt-in (2026-10-31)

**What changed:**
- **`AV1HybridEncoder.returnsPlanes`** (on; `av1seq --no-planes` turns it off).
  - Off, a frame comes back without its decoded picture, and the next inter frame references the post-filter's output buffers (`AV1MetalPostfilter.outputPlanes`).
  - That saves copying 22 MB out every 5K picture. Same bytes and PSNR, so the GPU-side reference is the decoded picture.
- **`interPreset`** (`av1seq --inter-preset`): inter frames' analysis effort, separate from key frames'. `turbo3` (no angle deltas) is opt-in only.

**Results** (5K, 8 tile columns, steady-state inter frames a second):

| Trace | planes → no planes |
|---|---|
| typing-cc | 126 → 161 (175 in another run) |
| scroll-win | 88 → 112 |
| photos | 30 → 31 |

**`turbo3` for inter frames:**

| photos | inter frames | inter frames a second |
|---|---|---|
| 5K | 26.5 → 26.8 KB (+1.1 %) | 31.4 → 37.7 |
| 720p | 12.2 → 12.2 KB | 90 → 108 |

Above the 0.4 % default rule, so it's an opt-in. `turbo2` changed nothing for inter frames.

**Where a near-static 5K inter frame's ~5.7 ms goes:**
- the closed loop over every tile, 2.2 ms (motion-compensating and assembling 22 MB of copies);
- the filters, 1.4 ms;
- deciding the copies, ~1 ms;
- the writer, 0.3 ms.

libaom does such a frame in ~4.4 ms. On moving content, the GPU's intra analysis of the coded superblocks is the limit (photos 31 against libaom's 92).

### Metal AV1: 128×128 superblocks, no sequence header on inter frames, fewer tiles; equal quality again (2026-10-31)

**What changed:**
- **Writer** (subagent):
  - `fp.sb128`: 128×128 superblocks, every partition at the 128 level, the deblocking rule for skipped inter blocks wider than 64.
  - `ENC_NO_SEQ_HEADER`: a frame without the sequence header; `parse_with` keeps the stream's.
  - Tested exact: 20,000 random frames (6,944 sb128, 8,608 header-less) in dav1d and aomdec, plus the Swift libaom gates.
- **Hybrid** (`largeSuperblocks`, `omitsSequenceHeaders`, both on with `interFrames`):
  - The stream is sb128.
  - `av1enc_motion_apply_ex` puts the GPU's 64×64 partition into the 128×128 decode order; a 128×128 whose four 64×64s are copies at one shift becomes one skip block.
  - Inter frames go out without the sequence header.
  - The GPU analysis stays 64×64, on the 128-unit tile layout.
- **Tiling:** the comparison now uses libaom's own (log2 3 columns × 0 rows at 5K, 2 × 0 at 720p).
  - Each tile costs a size field and a range-coder flush. At log2 4 × 4 an sb128 5K frame has ~170 tiles: most of a near-static inter frame's bytes.

**Inter frame mean at q20** (first 100 frames, every frame exact):

| | before (64×64 SBs, 4×4 / 2×2 tiles) | sb128, 4×4 / 2×2 tiles | sb128, libaom's tiling | libaom s9 |
|---|---|---|---|---|
| 5K typing-cc | 663 B | 486 B | **152 B** | 324 B |
| 5K cursor-drag | 838 B | 644 B | **276 B** | 486 B |
| 5K scroll-win | 4.2 KB | 4.0 KB | **3.4 KB** | 4.0 KB |
| 5K photos | 27.9 KB | 27.5 KB | **26.5 KB** | 37.2 KB |
| 720p typing-cc | 136 B | 108 B | **90 B** | 123 B |
| 720p cursor-drag | 161 B | 134 B | **114 B** | 125 B |
| 720p scroll-win | 2.1 KB | 2.0 KB | 2.0 KB | 2.0 KB |
| 720p photos | 12.3 KB | 12.3 KB | 12.2 KB | 14.4 KB |

- **Key frames** get 2–3 % smaller with these tilings as well.
- **Inter frames a second** (5K, libaom's tiling): typing 134, drag 129, scroll 85, photos 28. Unchanged within noise.

**Equal quality** (BD-rate by `vquality`'s RGB-luma PSNR, as in "against hardware HEVC and libaom" below; q 8–32; the hardware HEVC points from that entry):

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K: hybrid vs libaom | −46 % (was −27) | −24 % (was −1) | −34 % (was −27) | −46 % (was −26) |
| 5K: hybrid vs HEVC | −60 % | −74 % by SSIM (no PSNR overlap) | −83 % | −60 % |
| 720p: hybrid vs libaom | −30 % (was −23) | −1 % (was +91) | −12 % (was +255) | −30 % (was −21) |
| 720p: hybrid vs HEVC | −45 % | −39 % | −3 % | −42 % |

By SSIM instead, two cells turn: 720p scroll-win vs libaom is +15 %, and 720p photos vs HEVC is +14 %.

**Speed is still libaom's:** 2–5× our inter frame rate, and 5K photos is 28 against 92 inter frames a second. That's next.

### Metal AV1: inter tx blocks code nothing where that's cheaper (2026-10-31)

**What changed:** the closed loop's quantization hook drops an inter tx block's coefficients when coding nothing costs less: SSE + λ against the coded residual's D + λR (`HookOpts.inter_rd_skip`, on in the hybrid). This is libaom realtime's "skip when coding costs more than the distortion" (nonrd_pickmode.c), here per tx block. Before, every inter residual that survived the dead zone was coded.

**BD-rate**, on against off, by PSNR-Y over q 12 / 20 / 28 (first 100 frames, every frame exact):

| Trace | Whole stream | Inter frames |
|---|---|---|
| photos 720p | −6.9 % | −7.9 % |
| scroll-win 720p | −3.3 % | −4.8 % |
| photos 5K | −2.7 % | −4.2 % |

- **At q20 it trades PSNR for bytes:** 720p photos goes 14.3 → 12.3 KB at 41.29 → 40.81 dB. Equal-quality comparisons need the sweep.
- **Static content gains a little:** 5K typing 665 → 663 B, drag 856 → 838 B, 720p typing 149 → 136 B, drag 187 → 161 B.

### Metal AV1: long-range motion per superblock, from projections (2026-10-31)

**Why:** libaom realtime's screen path (read in the vendored source) finds each superblock's motion from 1-D row and column projections over a long range (`av1_int_pro_motion_estimation`, mcomp.c; called from var_based_part.c). Our search looked ±8 around no motion and ±4 around the frame's hashed shifts, and those need exact line matches. So a photo sliding tens of samples a frame, or fading, was never found.

**What changed:** `k_proj`, one threadgroup per coded 64×64, runs before `k_me`.
- **Matching:** it matches the superblock's 64 row sums against the previous source's over ±192 rows, and its 64 column sums over ±96 columns (doubled from 3840 wide).
- **Cost:** the variance of the difference, so a brightness change still matches, with a slight bias toward short vectors.
- **Checking:** the horizontal, vertical and combined vectors are checked by SAD, and the best goes to `GpImage.meSb`.
- **Search:** `k_me` searches ±4 around it as one more candidate centre.

**Results** (first 100 frames, q20, every frame exact; inter frame mean):

| Trace | 720p: before → now | libaom s9 | 5K: before → now | libaom s9 |
|---|---|---|---|---|
| photos | 44.2 → **14.3 KB**, PSNR-Y 41.12 → 41.29 | 14.4 KB, 41.29 | 29.5 → 29.5 KB | 37.2 KB |
| scroll-win | 4.5 → **2.2 KB** | 2.0 KB | 4.5 → 4.3 KB | 4.0 KB |
| typing-cc | 149 → 149 B | 123 B | 692 → 665 B | 324 B |
| cursor-drag | 187 → 187 B | 125 B | 865 → 856 B | 486 B |

- **Speed is unchanged:** 720p photos 86 and scroll 221 inter frames a second; 5K photos 29 and scroll 87.
- **720p moving content is now level with libaom.** The rest of the gap is static content (the next entries: no sequence header on inter frames, 128×128 superblocks).

### Metal AV1: quarter-sample motion vectors (2026-10-31)

**What changed:**
- **Writer** (subagent): `fp.mv_precision` (0 whole, 1 quarter, 2 eighth samples). The sequence header now selects force_integer_mv per frame. The MV stack lowers candidates to the frame's precision, and the fr/hp bits and their CDFs (carried with `cdf_from_ref`) are coded.
  - **Exact:** 3200 random frames decode exactly in dav1d and aomdec, and the Swift libaom gate passes. Every filter phase is covered.
  - **Whole-sample tile data is byte-identical** to before.
  - **Writer cost:** a sub-sample frame costs the writer +13–16 % (both filter passes on every block).
- **GPU search:**
  - `k_me` refines each 16×16's best vector to half and then quarter samples.
  - `k_inter` screens and costs fractional candidates.
  - The GPU predicts fractional positions bilinearly; the closed loop is exact.
  - On by default (`AV1HybridEncoder.searchesSubpelMotion`, `av1seq --no-subpel`); those frames code `mv_precision` 1.

**Results** (first 100 frames, q20, every frame exact in libaom; inter frame mean, steady-state inter frames a second):

| Trace | 720p whole → quarter | 5K whole → quarter |
|---|---|---|
| scroll-win | 4.9 → 4.5 KB (−8 %) · 209 → 218 fps | 4.5 → 4.5 KB · 92 → 94 fps |
| photos | 55.7 → 44.2 KB (−21 %), PSNR-Y 40.97 → 41.12 · 91 → 88 fps | 29.5 → 29.5 KB · 30 → 30 fps |
| typing-cc | 148 → 149 B | 691 → 692 B |
| cursor-drag | 187 → 187 B | 864 → 865 B |

- **Downscaled content gains** (the 720p traces are resampled from 5K, so their motion is fractional); the native 5K captures move by whole samples.
- **libaom is still ahead at 720p:** 2.0 KB (scroll) and 14.4 KB (photos).
- **Few vectors go fractional:** only ~2–3 % of the searched blocks choose one.
- **Rejected: the exact 8-tap filter in the GPU's estimates** in place of bilinear. Photos 720p came out 43.6 KB against bilinear's 44.2 (−1 %), but at 49 against 88 inter frames a second (5K photos 21 against 30). At 64 multiply-adds per fractional sample it isn't worth it.

### Metal AV1: inter frames' fixed costs; steady-state frame rates (2026-10-31)

**What changed** (same bytes everywhere):
- **Placeholders for copies:** a superblock the caller replaces (an inter frame's copy) comes back from the partition as one placeholder block, not its cached block list (~3,600 lists rebuilt a 5K frame).
- **No comparison under a skip mask:** with the mask, the analysis cache doesn't compare the whole source; the mask decides.
- **`k_leaf` visits only analyzed superblocks' leaves:** its prefix scan counts no leaves for kept ones.
- **SIMD-group analysis for small inter workloads:** an inter frame analyzing fewer than 4,096 blocks of a shape uses the SIMD-group-per-block analysis for the small shapes, not thread-per-block.
  - The thread-per-block kernel's single-thread chain takes ~1.5 ms for an 8×16, so a few blocks cost the GPU 5.4 ms; now 1.6 ms (5K typing, stages timed one by one).
  - Its float sums may order differently, so key frames keep the thread kernel, and kept analysis there still codes as fresh analysis.

**Measured** (5K typing-cc, inter frames, the overlapped pipeline):

| | Before | After |
|---|---|---|
| Starting a picture (copy decisions, source padding and comparison) | 4.0 ms | 1.4 ms |
| fps, the whole run with its key frame | 68.5 | 107–110 |

**`av1seq` now prints steady-state inter frames a second,** from the first frame's output to the last, for both encoders.
- The whole-run fps above includes the key frame's ~300 ms full analysis at 5K. An earlier "3.3 ms wait for the partition" on every inter frame was just that, averaged over 100 frames.

| inter frames a second (ours / libaom s9, 8 threads) | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K | 134 / 225 | 89 / 169 | 30 / 87 | 132 / 227 |
| 720p | 474 / 2006 | 227 / 974 | 87 / 481 | 493 / 2012 |

### Metal AV1: inter frames start from their reference's CDFs (2026-10-31)

**What changed:** an inter frame (`fp.cdf_from_ref`, on in `AV1HybridEncoder.carriesCDFs`; `av1seq --no-cdf-carry` turns it off) codes primary_ref_frame = LAST, and starts from the CDFs its reference saved instead of the defaults.
- **Saving:** every video frame saves the CDFs of one tile (disable_frame_end_update_cdf = 0, counters cleared).
- **Wire-up:** the writer returns them (`Output.saved_cdfs`, `av1g_output.cdfs`) and takes them per reference slot (`RefPicture.cdfs`, `av1g_ref_planes.cdfs`). The hybrid keeps a slot's from the write that refreshed it. `writer::parse_with` follows them over a stream.
- **Loss:** this stays loss-safe while the reference is a frame the decoder has, which the acknowledged-reference scheme guarantees.
- **Exact:** random sequences with it decode exactly in libaom (the Swift gate), dav1d and aomdec. Clearing the counters wrongly fails both.

**Which tile's CDFs to save** (context_update_tile_id). Inter frame mean, 5K, 4×4 tiles:

| Tile | typing-cc | cursor-drag | scroll-win | photos |
|---|---|---|---|---|
| the most blocks (libaom: the largest) | 884 B | 1.0 KB | 4.6 KB | 29.8 KB |
| the fewest blocks | 691 B | 864 B | 4.6 KB | 30.3 KB |
| **the median by blocks (kept)** | **691 B** | **864 B** | **4.5 KB** | **29.5 KB** |

At 720p (2×2 tiles), median and most are within 2 % of each other.

**Results:** first 100 frames, q20, every frame decoded by libaom in order, exactly. Inter frame mean:

| Trace | 5K: default CDFs → carried | libaom s9 inter | 720p: default → carried | libaom s9 inter |
|---|---|---|---|---|
| typing-cc | 2.0 KB → 691 B | 324 B | 238 → 147 B | 123 B |
| cursor-drag | 2.2 KB → 864 B | 486 B | 279 → 186 B | 125 B |
| scroll-win | 5.8 → 4.5 KB | 4.0 KB | 5.0 → 4.9 KB | 2.0 KB |
| photos | 30.5 → 29.5 KB | 37.2 KB | 56.1 → 55.7 KB | 14.4 KB |

- **Static content's floor falls by 58–66 % at 5K.**
- **Still about 2× libaom's on static content.** The rest is per-superblock symbols on 64×64 superblocks (libaom uses 128×128 at this size), tile overhead, and a sequence header on every frame.
- **Moving content barely changes.** Its gap is the coding itself; the entry below has the measurements.
- **Speed:** unchanged within noise (5K: typing 72, scroll 65, photos 27, drag 74 fps).

### Metal AV1 against hardware HEVC and libaom, at equal quality (2026-10-31)

**Setup:** first 100 frames of each trace, at the trace's timing. One quality metric for all three: `vquality`'s, BT.601 luma of the decoded picture in RGB against the trace frame (PSNR, and SSIM on 8×8 blocks).
- **AV1:** `av1seq --score-rgb` (new) scores both AV1 encoders that way:
  - the hybrid: inter frames, motion search, q 8–32;
  - libaom realtime speed 9, 8 threads, inter frames (`--aom-inter`, new) at the same q.
- **HEVC:** `vquality` runs the VideoToolbox HEVC encoder as the Host configures it (max frame QP 34, realtime, average-bitrate targets), at five targets per trace.
- **Comparison:** BD-rate, i.e. bytes at equal quality, piecewise-linear in PSNR (or SSIM). Negative: smaller.
- **Conditions:** M4 Pro, the owner's session disconnected; Spotlight and Time Machine were active, so speeds are approximate.

**BD-rate by PSNR (by SSIM where PSNR ranges don't overlap):**

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K: hybrid vs HEVC | −40 % | −65 % (SSIM; by PSNR HEVC tops out below the hybrid's lowest point) | −81 % | −40 % |
| 5K: hybrid vs libaom | −27 % | −1 % | −27 % | −26 % |
| 720p: hybrid vs HEVC | −36 % | +28 % | +278 % | −33 % |
| 720p: hybrid vs libaom | −23 % | +91 % | +255 % | −21 % |
| 720p: libaom vs HEVC | (no overlap) | −38 % | +12 % | −15 % |

**Split by frame type**, hybrid vs libaom by PSNR-Y, from the same sweep (before the CDF carry-over in the entry above):

| | typing-cc | scroll-win | photos | cursor-drag |
|---|---|---|---|---|
| 5K, key frames only | −44 % | −29 % | −44 % | −44 % |
| 5K, inter frames only | +512 % | +43 % | −17 % | +340 % |
| 720p, key frames only | −31 % | −25 % | −33 % | −32 % |
| 720p, inter frames only | +103 % | +161 % | +291 % | +119 % |

**What it shows:**
- **The hybrid's lead is its key frames.** Its inter frames lose to libaom everywhere but 5K photos.
- **On static content,** the inter-frame floor is the cause; the entry above halves it.
- **On moving content at 720p (+90–290 %),** whole-sample motion is the cause. The 720p traces are downscaled from 5K, so their motion is fractional. Sub-sample motion vectors are next.
- **At 5K the HEVC curve saturates.** Photos achieved 24.2 Mbit/s at both the 24 and 48 Mbit/s targets, and scroll 4.5 at a 12.8 target, at 37–42 dB. So the 5K HEVC numbers are the Host's HEVC settings, not HEVC's best.
- **Speed:** libaom s9 on 8 CPU threads runs 2–5× the hybrid's frame rate on these traces:

  | | libaom s9 | hybrid |
  |---|---|---|
  | 5K | 70–185 fps | 27–80 fps |
  | 720p | 330–1590 fps | 80–340 fps |

**Correction:** the "pinned HEVC loop" bitrates the entries below compare with (2.4 / 5.0 / 10.9 / 4.4 Mbit/s) are the whole Glass Act loop: lossless tiles, handoff, and repair under 5 % loss, over full traces. They're not an encoder's bitrate. This entry's HEVC numbers are the encoder alone.

### Metal AV1: motion search in inter frames (2026-10-31)

**What changed:** the 64×64s that aren't exact copies now search for motion on the GPU, inside the analysis (`AV1HybridEncoder.searchesMotion`, on with `interFrames`; `av1seq --no-motion-search` turns it off).
- **`k_me`**, per 16×16, searches by SAD on every other row:
  - whole-sample vectors within ±8 of no motion;
  - ±4 around each of the frame's shift candidates (from the copy decisions);
  - it keeps the best two.
- **`k_inter`**, per block shape of 8×8 and up, runs after the intra analysis:
  - it screens no motion and the vectors of the 16×16s the block covers;
  - the best is costed with the analysis's own exact-rate RD (DCT_DCT, with rough motion-vector bits);
  - where that's below the intra J, it takes its place. The partition DP then mixes inter and intra blocks as it would two intra modes.
- **Prediction source:** the search predicts from the previous picture's *source*, which the GPU already holds. Picture i + 1's analysis doesn't wait for picture i's reconstruction, so the CPU/GPU overlap stays. The closed loop predicts exactly from the decoded picture and codes the residual (DCT_DCT for inter blocks, for now).

**Results:** same setup as below (5K, 4×4 tiles, q20, turbo, first 100 frames; every frame decoded by libaom in order, exactly):

| Trace | Inter frames: copies only → with search | Mbit/s at the trace's timing | Searched blocks, share of the picture | PSNR-Y |
|---|---|---|---|---|
| typing-cc | 2.4 → 2.0 KB | 0.6 → 0.5 | 0.0 % | 47.34 → 47.34 |
| scroll-win | 10.1 → 5.8 KB | 2.4 → 1.7 | 0.7 % | 48.83 → 48.83 |
| photos | 108 → 30.5 KB | 21.0 → 7.3 | 7.9 % | 42.74 → 42.86 |
| cursor-drag | 2.8 → 2.2 KB | 1.2 → 1.1 | 0.1 % | 47.56 → 47.56 |

- **Photos now comes in under the pinned HEVC loop** (10.9 Mbit/s over the whole trace), as typing, scroll and drag already did (2.4 / 5.0 / 4.4). Caveats as below: different spans, quality not matched.
- **Speed:** photos 30.9 → 29.5 fps, with the GPU analysis at 21.3 → 24.9 ms a frame.
  - The machine was loaded during these runs (other processes at ~130 % CPU), so speeds moved by up to 25 % run to run. For example, copies-only typing ran at 80–85 fps here, against 94 in the entry below.
  - Typing and drag measured 63–80 fps with the search on; that needs re-measuring on a quiet machine before calling it a regression.

**Limitations:**
- Inter blocks are at loop filter level 0 (`lf_inter_off`), searched ones included, so their residual's block edges aren't deblocked. A per-superblock `delta_lf` would deblock the coded 64×64s and leave copies alone.
- Whole-sample vectors only (`force_integer_mv`). DCT_DCT only. No chroma in the inter cost.
- The motion-vector bits are a rough estimate, not the reference MV stack's.

### Metal AV1: inter frames from exact copies (2026-10-31)

**What changed:** `AV1HybridEncoder.interFrames` (`av1seq --inter`) codes a sequence as one stream: a key frame, then inter frames that each reference the frame before.
- **Writer** (Rust): inter frames in video mode, with one reference (LAST_FRAME), whole-sample motion vectors, EIGHTTAP, and `primary_ref_frame` NONE. Each frame needs only its reference picture. Random inter sequences decode exactly in libaom, dav1d and aomdec.
- **Copies:** per 64×64, before the GPU analysis (`rust/av1/src/motion.rs`):
  - A 64×64 whose source equals the previous picture's, unchanged or at a whole-sample shift (candidates from row and column hashes, and the left and upper neighbours' shifts), becomes skip inter blocks at that shift.
  - The GPU doesn't analyze copied 64×64s.
  - The rest is coded intra, as before.
- **Filters:** `lf_inter_off` codes loop filter ref deltas (INTRA_FRAME 0, LAST_FRAME −63), so inter blocks are at level 0. A copy of already-filtered content stays as it was, and only edges next to intra blocks are deblocked. Both post-filters (Rust and Metal) apply it; the region filtering treats a copy as unchanged when it was a copy, with no coded 64×64 around it, in the previous picture too.

**Results:** 5120×2880, 4×4 tiles, q20, turbo, M4 Pro, the first 100 frames of each trace. Every frame decoded by libaom in order, equal to the encoder's picture.

| Trace | fps | Key frame | Inter frames, mean | Copied (at a shift) | Mbit/s at the trace's timing: all / inter frames only | Key frames only (before) | PSNR-Y |
|---|---|---|---|---|---|---|---|
| typing-cc | 94 | 551 KB | 2.4 KB | 99.9 % (0 %) | 0.6 / 0.17 | 38.7 | 47.3 |
| scroll-win | 69 | 473 KB | 10.1 KB | 98.7 % (4.9 %) | 2.4 / 1.6 | 79 | 48.8 |
| photos | 32 | 1.08 MB | 108 KB | 87.1 % (52.3 %) | 21.0 / 18.6 | 190 | 42.7 |
| cursor-drag | 92 | 510 KB | 2.8 KB | 99.9 % (0 %) | 1.2 / 0.42 | 84 | 47.6 |

- **Against the pinned HEVC loop** (2.4 / 5.0 / 10.9 / 4.4 Mbit/s, measured over the whole traces earlier, with rate control): typing, scrolling and dragging come in under it, and photos at about twice it.
  - The spans differ, so the comparison is rough: here the first 100 frames (4.6–11.6 s), where the key frame is most of the bytes for typing and drag.
  - Quality isn't matched either: these are q20 throughout, and a copy keeps the quality its content was coded at.
  - Not re-measured against HEVC: no hardware-encoder benches while the owner is connected.
- **Photos' 13 % of 64×64s that aren't exact copies cost almost a key frame's share each.** That's the photos app's animated transitions (scaling, fading). This needs real motion search: inexact matches with a residual.
- **Where the speed came from** (same bytes at every step):

  | Step | scroll-win | photos |
  |---|---|---|
  | GPU analyzes every 64×64 | 36.6 fps | 6.9 fps |
  | GPU skips copies | 59.1 | 22.2 |
  | Shift candidates on 8 threads (deciding the copies: 3.3 → 1.3 ms, 14.8 → 3.9 ms) | 63.4 | 29.7 |
  | Copies with no coded 64×64 around them copied into the filters' output, not filtered (photos: 82 → 24 % filtered) | 69.4 | 32.1 |

  The table above is the last row's. Deciding the copies takes 0.9–1.3 ms a frame outside photos.

**Not done yet:**
- The analysis, rate estimates and CDFs still assume key-frame syntax for intra blocks in inter frames.
- Tiles aren't kept across inter frames: every inter frame runs the closed loop and the writer over every tile.
- References the Viewer has acknowledged (loss recovery): every frame references the one before.

### Tiles as AV1: lossless and lossy AVIF, and the Metal encoder, against VP8L (2026-10-31)

**What was compared:** changed 64×64 tiles, measured per tile.
- **Corpora:** `glassact-bench dumptiles`, every 7th changed tile of the 5K traces. 400 tiles each, but only 67 for typing-cc.
- **In process (`glassact-bench av1tiles`, new):**
  - VP8L lossless, as the tile path codes a tile: efforts 1 and 4 (production: 4, or 1 in bursts over 32 tiles) and 9.
  - The Metal/CPU hybrid AV1 encoder, coding each tile as its own 4:2:0 key frame.
- **External tools (`scripts/tile-codec-probe`, new):**
  - avifenc 1.4.2 (libaom 3.15.2 all-intra, single-threaded) and cwebp.
  - Lossy tiles are scored with ssimulacra2 against the source tile.
- **AVIF sizes:** given as the whole file and as the AV1 data in its mdat box. At this size, AVIF's container is ~275 B of the file.

**Lossless (bytes a tile):**

| Tiles | VP8L z1 | VP8L z4 | VP8L z9 | AVIF lossless s6: file / AV1 data | AVIF lossless s10: AV1 data |
|---|---|---|---|---|---|
| typing-cc | 440 | 417 | 413 | 1351 / 1076 | 2365 |
| scroll-win | 394 | 381 | 370 | 1140 / 865 | 1561 |
| photos | 3413 | 3332 | 3343 | 4553 / 4278 | 5636 |
| cursor-drag | 2512 | 2381 | 2350 | 3277 / 3002 | 3948 |

Even AV1 data alone, without its container, is 1.26–2.6× VP8L z4's bytes. VP8L z4 takes 165–1130 µs a tile on one core. This confirms the whole-frame result of 2026-08-07, by a wider margin at tile size. **AV1 lossless stays rejected for tiles.** The Metal encoder has no lossless mode: it would need qindex 0, the Walsh–Hadamard transform and 4:4:4.

**Lossy (bytes a tile, then SSIMULACRA2 mean / p10):**

| Tiles | AVIF 4:4:4 q90 s6 | AVIF 4:4:4 q75 s6 | AVIF 4:2:0 q75 s6 | WebP q90 | Metal AV1 4:2:0 q8: stream, payload | Metal q20 | VP8L z4 (lossless) |
|---|---|---|---|---|---|---|---|
| typing-cc | 379 · 94.1 / 91.6 | 282 · 91.0 / 89.0 | 274 · 88.6 / 87.4 | 502 · 89.2 / 88.1 | 364, 340 · 87.9 / 86.6 | 287 · 87.8 / 85.9 | 417 |
| scroll-win | 270 · 95.6 / 91.7 | 210 · 94.3 / 89.1 | 200 · 91.3 / 82.0 | 357 · 90.4 / 82.7 | 246, 222 · 90.5 / 82.5 | 190 · 88.7 / 78.1 | 381 |
| photos | 1026 · 91.0 / 84.9 | 631 · 87.6 / 77.6 | 615 · 86.0 / 74.7 | 897 · 86.2 / 75.8 | 808, 784 · 84.7 / 71.2 | 471 · 81.2 / 66.1 | 3332 |
| cursor-drag | 526 · 91.5 / 87.9 | 358 · 89.1 / 82.8 | 344 · 86.4 / 74.9 | 538 · 85.2 / 73.6 | 390, 366 · 83.8 / 68.6 | 263 · 81.2 / 66.2 | 2381 |

What the lossy rows show:
- **Near-lossless gains depend on content.** AVIF 4:4:4 q90's AV1 data is near-lossless (SSIMULACRA2 91–96) and smaller than VP8L lossless by:

  | Tiles | Smaller by |
  |---|---|
  | typing-cc (text) | 9 % |
  | scroll-win | 29 % |
  | photos | 69 % |
  | cursor-drag | 78 % |

  So lossy tiles pay on photos and graphics and barely on text, and they'd give up the canvas's byte-exactness.
- **The Metal encoder trails AVIF at tile size.** It never reaches the AVIF 4:4:4 q90 tier: its mean SSIMULACRA2 tops out at 84–90, below AVIF 4:2:0 q75 at similar bytes. The reasons:
  - 4:2:0 in video range;
  - coding each tile as a cold, standalone frame, with ~24 B of TD, sequence and frame headers;
  - its fast preset.
- **Standalone tiles are slow on the GPU.** One at a time, a tile takes 2.7–4.6 ms, because each is a GPU round trip. Tiles belong in a frame.
- **The colour format sets the ceiling.** The BGRA → 4:2:0 (video range) → BGRA conversion alone, with no coding at all, scores:

  | Tiles | Mean | p10 |
  |---|---|---|
  | typing-cc | 91.2 | 90.6 |
  | scroll-win | 92.3 | 86.0 |
  | photos | 87.6 | 73.0 |
  | cursor-drag | 86.5 | 70.2 |

  That's below AVIF 4:4:4 q90. Most of the Metal encoder's gap is its 4:2:0 input, not its coding. Near-lossless tiles need 4:4:4 (AV1's high profile) and full range.

**One-superblock tiles inside a frame,** i.e. coding the whole frame and cutting it into independently parseable 64×64 tiles. `av1seq` at 4096×2304, where AV1's 64-tile-column limit fits one 64-px superblock per tile column. 64×36 tiles against 4×4, 30 frames:

| Sequence | 4×4 tiles | 64×36 tiles |
|---|---|---|
| typing-cc | 471.7 KB · 117 fps | 514.3 KB (+9.0 %) · 104 fps |
| scroll-win | 391.6 KB · 133 fps | 433.7 KB (+10.8 %) · 110 fps |
| photos | 888.9 KB · 11.2 fps | 927.6 KB (+4.4 %) · 10.8 fps |

Encoding the whole frame and cutting it isn't wasteful in work: unchanged superblocks cost next to nothing, and that's what makes these frame rates. Cutting it has these costs:
- **Bytes:** independent tiles (fresh CDFs, no prediction across tiles) cost 4–11 %.
- **The deblocking and CDEF filters cross tile edges,** so a tile on its own decodes exactly only with them off. Measured with `av1seq --no-filters` (`AV1HybridEncoder.postfilters = false`), 64×36 tiles:

  | Sequence | Filters on | Filters off |
  |---|---|---|
  | typing-cc | 514.3 KB · 45.43 dB · 108 fps | 513.5 KB · 45.26 dB · **122 fps** |
  | scroll-win | 433.7 KB · 46.94 dB | 432.5 KB · 46.68 dB |
  | photos | 927.6 KB · 41.84 dB · 10.6 fps | 926.6 KB · 41.75 dB · **12.4 fps** |

  Without the filters, the bytes stay the same and PSNR-Y drops 0.1–0.27 dB, with no filter search. Tiles that decode alone cost little.
- **Wider than 4096 doesn't fit.** At 5K's 80 superblock columns, AV1's 64-tile-column limit forces 128-px tiles or two frames.
- **Decoders decode frames, not tiles.** Independent tiles need libaom's large-scale-tile mode or a stitched frame.

### Metal AV1: an exact deblocked frame, and no analysis work when nothing changed (2026-10-31)

**A bug in the previous entry, fixed.** The preset-change path was *not* exact: 720p typing-cc decoded differently from the encoder's picture at frame 3.

- *Cause:* region deblocking reloads the changed area, plus two 64×64s around it, and deblocks it in place. Near that region's edge it reads neighbours that are deblocked already. It also filters their samples a second time, because an edge's filter reaches 7 samples into both sides.
- *Why it hadn't shown:* until now, nothing read those samples. CDEF only reran one 64×64 inside the region.
- *Why it showed now:* when new presets rerun CDEF where a strength changed, those 64×64s are read, in that picture or a later one.

Now the unchanged 64×64s within three of a change, outside the exactly recomputed inner area, are saved before the reload and restored after the deblock. Their deblocked samples are the previous picture's, so the deblocked frame stays exact everywhere.

A new test, `HybridEncoderTests.regionFilteringStaysExactAcrossPresetChanges`, encodes 40 pictures of random grainy edits that change the presets. Each picture is compared with a fresh full encode. It fails on the half fix.

200 frames of typing-cc, scroll-win, photos and cursor-drag at 720p, typing and scroll at 1080p, and typing at 5K now all decode exactly.

**Analysis overhead with little or nothing to analyze (kept, exact):**
- *The padded source planes are pooled.* Partitions already waited on return them, so 22 MB of shared memory isn't made and cleared per 5K picture. `begin` went 4.3 → 3.0 ms.
- *Only the changed 64×64s* are copied into the previous-source copy.
- *No GPU dispatch at all* when every SB keeps its analysis. The kept results are in the cache already.
- *Kept SBs' blocks are reused,* in `leafBlocks`, from the previous partition.

Interleaved against the Rust port's commit (f755b42); middle of three runs, identical bytes:

| Sequence | Before | After |
|---|---|---|
| typing-cc 720p, 3×3 | 233 fps | **391 fps** |
| scroll-win 720p | 239 | **299** |
| photos 720p | 79 | **86** |
| typing-cc 1080p | 135 | **233** |
| typing-cc 5K, 4×4 | 47 | **80** (filters 9.8 → 3.6 ms) |

### Metal AV1: filters when the CDEF presets change; preset selection on the CPU (2026-10-31)

`av1seq`, turbo, q20, 60 frames, M4 Pro. Interleaved A/B runs on a loaded machine; bytes unchanged. *Not exact as first committed:* see the entry above for the deblocking fix.

**Presets that change no longer re-filter the frame (kept, exact).** With only changed tiles filtered, the whole frame was still filtered again whenever the joint search picked different CDEF presets. That happened often enough that 5K typing filtered 29 % of the frame on average.

Now, when the presets differ:
- every 64×64's preset is re-chosen from the SSE tables (the rows outside the changed area are still exact);
- CDEF reruns only in the changed area and where a 64×64's applied strengths changed.

5K typing-cc, 4×4 tiles: filtered 29 → 2 %, filters 10 → 5 ms, 44 → 60 fps.

**Preset selection on the CPU (kept, exact).** libaom's joint greedy search (`l_select_small`: every cdef_bits level, 45 greedy and refinement steps) ran in a single 1024-thread GPU threadgroup in 64-bit math. That took ~2.5–3 ms of GPU time at 5K.

It now runs as `av1enc_cdef_select_cpu`, the Rust reference the kernel was held to:
- costs precomputed per (luma, chroma) preset pair as contiguous u32 rows (a 64×64's SSE fits);
- each step a NEON min and widening sum;
- the u64 reference loop as the fallback for tables that wouldn't fit 32 bits.

The kernel is removed. Swapping in the CPU search unoptimized was slower at 5K (filters 5 → 6.7 ms); the rows made it faster.

| Sequence | Before both | After |
|---|---|---|
| typing-cc 5K, 4×4 | 47 fps (filters 10.0 ms) | **65.8 fps** (3.6 ms) |
| typing-cc 1080p, 3×3 | 208 | **232** |
| photos 720p, 3×3 | 80 | **96** |

### Metal AV1: the CPU code in Rust (2026-10-31)

The AV1 encoder's CPU code moved from C++ to Rust (`rust/av1`, std only):
- the writer and parser;
- DSP and post-filters;
- the range coder and AVIF;
- the Metal encoder's host half;
- the hybrid closed loop;
- test support.

The new code uses NEON for the transforms (forward and inverse), whole-block prediction, deblocking, CDEF, dequantization and the CDF update. The C++ is kept in `rust/av1/oracle/cpp` as the reference for the crate's differential tests, which require identical bytes, reconstructions and decisions.

**`av1seq`** (turbo, q20, 60 frames, M4 Pro), C++ build (b589159) and Rust build interleaved, two runs each. All bytes are identical and every decode is exact.

| Sequence | C++ | Rust | CPU closed loop, ms per frame | Writer |
|---|---|---|---|---|
| typing-cc 720p, 3×3 | 192 fps | **232 fps** | 1.7 → 0.7 | 0.5 → 0.4 |
| photos 720p, 3×3 | 78 | 81 (GPU-bound) | 4.2 → 1.6 | 1.1 → 1.0 |
| typing-cc 1080p, 3×3 | 126 | **207** | 3.3 → 1.2 | 0.8 → 0.6 |
| typing-cc 5K, 4×4 | 34 | **47** | 7.0 → 3.1 | 1.4 → 1.5 |
| photos 5K, 4×4, every SB analyzed | 5.5 | 5.5 (GPU-bound) | 72 → 21 | 11 → 11 |

**Crate micro-benchmarks** (the C++ oracle is built at -O2 without LTO):

| Piece | C++ | Rust |
|---|---|---|
| Hybrid closed loop, synthetic 5K first picture | 83 ms | 39 ms |
| Hybrid closed loop, ~5 % changed | 18 ms | 9 ms |
| Writer, 5K full encode with filters, 16 tiles | 499 ms | 75 ms |
| Writer, bitstream only, 16 tiles | 6.4 ms | 6.6 ms |
| Range coder, symbol streams | 83 Msym/s | 150 Msym/s |

The writer's bitstream-only time is at parity: what's left there is the range coder and context derivation.

### Metal AV1: why moving content is GPU-bound, and two exact speedups (2026-10-31)

`av1seq`, turbo, q20, 60 frames, M4 Pro. Every superblock is analyzed (`--no-reuse`), which is the moving-content case. Every decode is exact.

**Where photos 720p goes.** On an otherwise idle GPU (`--serial`), the analysis takes 16.6 ms a frame and the filters 2.4 ms. Overlapped, those 19 ms are the frame time (51 fps). Two encoders running at once reach 58.6 fps between them, so the GPU is ~87 % busy. The cost is the volume of search, not latency or serial work.

Stage shares, from ablations (each stage replaced by a stub):

| Stage | Share |
|---|---|
| Prediction in mode screening | ~5 ms |
| The shapes' exact-rate RD (K = 1) | ~1.5 ms |
| Leaf decisions | ~4.5 ms |
| The rest: edges, SATD, setup, the partition DP | |

turbo screens 13–25 candidates per block over 11 block shapes, about 175 predicted pixels per source pixel. libaom's realtime path tries a few modes at a few sizes. The difference is what buys the 30–48 % smaller files.

`av1seq --profile` now reports each stage's best of 10 runs. Single isolated dispatches varied 2× from run to run.

**Kept (exact, same decisions):**
- *Hoisted prediction (`pred_cand` / `pred_fast`).* `av1g_pred_pixel` derived each candidate's angle zone and derivatives at every pixel. These are now derived once per candidate, in the shapes' screening and RD, and in the leaf pass.
- *Leaf tx search across the SIMD-group.* Before, each of the ≤7 intra tx types ran its scalar evaluation on one lane, so 25 of 32 lanes idled. Now the types run one after another, each evaluated by the whole SIMD-group (`warp_eval`). Leaves 4.5 → 2.7 ms.

Interleaved A/B against the previous commit, every SB analyzed:

| Sequence | Before | After | Bytes |
|---|---|---|---|
| photos 720p | 51.6 fps | **67.4 fps** | 134.4 KB (±0) |
| typing-cc 720p | 49.4 | **65.9** | 108.5 KB (±0) |
| scroll-win 720p | 50.2 | **67.7** | 88.4 KB (±0) |
| typing-cc 1080p | 25.0 | **33.5** | 199.6 KB (±0) |
| typing-cc 5K, 4×4 | 4.0 | **5.6** | 550.4 → 550.5 KB (+0.02 %: float near-ties in the tx search) |
| photos 5K, 4×4 | 3.9 | **5.4** | 1.16 MB (±0) |

With reuse, photos 720p went 60.1 → 75.2 fps. The other reuse runs were too noisy to compare: another process was taking ~2 CPU cores, which shows up in the CPU closed loop.

**Measured, not kept:**
- *Edges in threadgroup memory* for the thread-per-block kernel (in case the thread arrays spilled): the 8×8 shape went from 6.9 to 8.9 ms.
- *Checkerboard SATD screening for the 64–128-pixel shapes:* +2 fps for +0.1–0.2 % bytes.
- *turbo2* (no 4×4 / 4×8 / 8×4): photos +11 % fps, but +3.6 % bytes and −0.18 dB.

**What this means at 5K.** With every superblock changing, intra-only analysis is ~16× the work of 720p: 5.4 fps on photos. Reaching 60 fps there would take ~11× less work per pixel. That has to come from inter prediction (unchanged and moved blocks cost nothing to analyze) or from a codec designed for the GPU, not from trimming this search.

### Metal AV1: filtering only around changes; a large-block prune (2026-10-31)

`av1seq`, turbo, q20, overlapped, M4 Pro. Every stream decodes in libaom to
the encoder's picture exactly.

**Filters and strength search only around changes (kept).** Away from
re-coded tiles, the reconstruction, block maps and source are the previous
picture's. With the same filter parameters, each pixel's deblock and CDEF
output and each SB's CDEF SSE row are too.
- `search(changed:)` reloads and deblocks the re-coded SBs dilated by two
  (so one SB in, it's exact).
- It recomputes directions, SSE rows, cdef_idx and CDEF output on them
  dilated by one.
- It keeps the rest, and runs the preset selection over the whole table.
- If the presets come out other than the previous picture's, it falls back
  to filtering everything.

The bytes are identical with and without (5K: 557.7 KB both). Pictures and
libaom decodes are checked against fresh encodes (HybridEncoderTests).

| typing-cc | before | around changes | filtered |
|---|---|---|---|
| 1080p, 3×3 | 128.7 fps | **150.6 fps** (filters 2.9 → 1.4 ms) | 5 % |
| 5K, 4×4 | 29.7 fps | **50.2 fps** (filters 15.7 → 4.3 ms) | 1 % |

**Busy large blocks pruned (kept, at 4).** av1gpu's `pruneVar` skips the
analysis of 32×32-and-up shapes where the source variance exceeds v
quantizer steps squared. These runs analyze every SB (`--no-reuse`, the
moving-content case):

| | v = 0 (off) | v = 4 (default) | v = 1 |
|---|---|---|---|
| photos 720p | 41.9 fps · 128.8 KB | 46.0 · 128.8 KB | 50.3 · 128.8 KB |
| typing-cc 720p | 45.9 · 109.3 KB | 46.3 · 109.3 KB | 51.6 · 109.3 KB |
| typing-cc 1080p | 21.4 · 201.4 KB | | 25.4 · 201.5 KB |
| typing-cc 5K | 3.7 · 551.4 KB | 4.0 · 553.4 KB (+0.36 %) | 4.2 · 557.7 KB (+1.1 %) |

From 1 down to 0.1 the bytes don't move at 720p, and the speed plateaus.
`busyBlockPrune` defaults to 4 for bitrate efficiency, with 1 as the faster
choice. Angle deltas off (`searchesAngleDeltas = false`) is ~20–30 % of the
analysis for +0.1–0.9 % bytes: photos 720p 53.5 fps, typing 60.4.

Now, with reuse: typing-cc 720p ~208 fps (3×3), scroll-win 88, photos 44,
typing-cc 1080p 151, 5K 50. Photos is GPU-bound, with every SB changing:
analysis 18 ms, and the filters waiting behind it.

**The leaf decisions on moving content (`av1seq --profile`, kept).**
Stage by stage on photos at 720p, the leaf pass is the largest GPU stage (8.3
ms; the shapes take 0.9–3 ms each).
- *Tx search size:* each 16×16 tx type runs serially on one lane.
  Searching only up to 128 pixels (`leafTxSearchPixels`) saves ~13 % for
  +0.08–0.2 % bytes; up to 64 pixels, +0.5–1.3 %; none, +3.3–6.8 %.
- *Chroma modes:* screening the seven plain modes, without the six angled
  ones (`leafChromaAngledModes`), costs 0–0.3 % bytes for ~5–8 %.
- *Small kernel:* the thread-per-block analysis of 8×16 / 16×8 stays. With
  the SIMD-group kernel, photos is 46.2 fps against 48.6.

The hybrid's defaults (prune 4, tx search ≤128 px, plain chroma modes),
analyzing every SB at 720p, 3×3 tiles:

| | before these | now | bytes |
|---|---|---|---|
| photos | 41.9 fps | **53.0 fps** | 128.8 KB (±0) |
| typing-cc | 45.9 | **53.2** | 109.5 KB (+0.2 %) |
| scroll-win | 46.8 | **54.2** | 92.3 KB (+0.3 %) |

With reuse at 720p: typing-cc **254.6 fps**, scroll-win 95.5, photos 51.3.
libaom realtime key frames run 47–56 fps there, with 30–40 % more bytes.

### Metal AV1: decisions up front on the GPU, and analysis kept across pictures (2026-10-30)

`av1seq`, turbo, q20, overlapped, M4 Pro. Every stream decodes in libaom to
the encoder's picture exactly.

**Leaf decisions on the GPU (`k_leaf`, kept).** After the partition DP, each
leaf's chroma mode and CfL and its luma tx type are decided from the source
on the GPU, so the CPU closed loop only quantizes and reconstructs.
typing-cc 100–139 at 720p, 2×2 tiles:

| | CPU decides | GPU decides |
|---|---|---|
| size | 108.9 KB | 108.1 KB |
| CPU closed loop / chroma | 14.6 / 3.7 ms | 6.9 / 0.8 ms |
| GPU analysis incl. leaves | 18.2 ms | 24.9 ms |
| fps | 36.0 | 32.6 (GPU-bound until the next change) |

- A first version took 12 ms of GPU at 720p: one threadgroup per SB served
  text SBs' ~200 leaves four at a time, and 4×4 chroma left 31 lanes idle.
  `k_leaf_scan` now lays all leaves out as one list behind an indirect
  dispatch, and lanes take (mode, plane, 4×4) items. That brought it to
  ~4.5 ms.
- Measured without the full GPU pass: transform types alone save 6 % (117.8
  → 110.9 KB); chroma alone 2.4 %; both together match the CPU's choices.

**Analysis kept across pictures (`reusesAnalysis`, kept, on in the
hybrid).** The analysis reads only source pixels. An SB whose pixels, and
those of the left, above, above-left, above-right and below-left SBs its
edges read, haven't changed keeps the previous picture's block results,
DP leaves and leaf decisions. HybridEncoderTests check that those code the
same bytes as fresh analysis.

| trace, frames | size, tiles | no reuse | reuse | kept |
|---|---|---|---|---|
| typing-cc 100–139 | 1280×720, 2×2 | 40.4 fps | **83.6 fps** | 97 % |
| scroll-win 100–139 | 1280×720, 2×2 | 41.4 fps | **61.0 fps** | 59 % |
| photos 100–139 | 1280×720, 2×2 | 38.2 fps | 39.7 fps | 5 % |
| typing-cc 100–129 | 1920×1080, 2×2 | 21.1 fps | **39.9 fps** | 99 % |
| typing-cc 100–109 | 5120×2880, 3×3 | 3.7 fps | **9.6 fps** | 100 % |

The bytes are identical with and without reuse. With most of the analysis
kept, the frame is the CPU's again. At 5K the closed loop takes 60 ms,
filters 19, chroma bookkeeping 8 and the writer 6. Next: unchanged tiles
could keep their closed loop and bitstream too.

**Tiles kept across pictures (kept).** Prediction never crosses a tile and its
CDFs start afresh. So a tile whose blocks' decisions and source are unchanged
keeps its coefficients and reconstruction (av1core's `TileSkip`, the hybrid's
`TileMem`). It keeps its bytes too while its cdef_idx values and cdef_bits
are as last written (`av1enc_hybrid_write`). The bytes are still identical to
fresh encoding (HybridEncoderTests).

| trace, size | analysis kept only | + tiles kept | tiles kept |
|---|---|---|---|
| typing-cc 720p | 83.6 fps | **90.9 fps** (closed loop 6.2 → 3.2 ms, writer 1.3 → 0.7) | 94 % |
| scroll-win 720p | 61.0 fps | 60.4 fps | 49 % |
| typing-cc 1080p | 39.9 fps | **52.8 fps** | 94 % |
| typing-cc 5K, 3×3 | 9.6 fps | **19.7 fps** (closed loop 60 → 9.7 ms, writer 5.8 → 0.6) | 99 % |

**Only stale SBs dispatched; shapes concurrent (kept).** The analysis kernels
and the DP take a list of the SBs to recompute instead of launching every
block. That alone changed nothing, because the cost was latency: 19 shape
dispatches in a row, each over a few SBs. A fully kept picture costs the GPU
0.01 ms. With the encoder's dispatches concurrent (shapes are independent;
barriers separate the stages), at 2×2 tiles:

| trace, size | before | concurrent | GPU per frame |
|---|---|---|---|
| typing-cc 720p | 87.4 fps | **102.8 fps** | 9.2 → 3.3 ms |
| scroll-win 720p | 61.8 | **72.6** | 14.2 → 9.8 |
| photos 720p | 39.7 | **41.9** | |
| typing-cc 1080p | 45.4 | **46.9** | 9.7 → 4.7 |

**More tiles, now that unchanged ones cost nothing.** A changed tile is coded
on one thread, so smaller tiles spread a change over more cores:

| typing-cc | 2×2 (16) | 3×2 (32) | 3×3 (64) | 4×3 (128) |
|---|---|---|---|---|
| 720p | 102.8 fps · 108.1 KB | | **174.0 fps · 109.3 KB** | **184.2 fps · 110.2 KB** |
| 1080p | 50.4 fps · 199.3 KB | 73.4 fps · 200.9 KB | **96.6 fps · 201.4 KB** | |
| 5K | (3×3: 18.3 fps · 539.5 KB) | | 4×4: 20.5 · 551.4 KB | 5×4: 20.3 · 560.3 KB |

The size cost is 1–2 % at 720p and 1080p. At 5K the frame doesn't
follow, because whole-frame work leads there: the filters (~19 ms wall,
~12 of it GPU) and the CPU's per-frame bookkeeping (~8 ms: padding the
source, layout, block fields).

**Fixed per-picture costs out (kept).** Each cut keeps the bytes:
- Partition-only jobs leave the GPU closed loop's buffers out. They were
  ~100 MB allocated and zeroed per 5K picture, on the CPU's path.
- The hybrid stops zero-filling its coefficient array (the hook writes every
  coefficient), pads the source on several threads, and skips its per-block
  pass when the GPU decided chroma.
- The filters keep their job's buffers across pictures of one geometry.

| typing-cc | before | after (tiles) |
|---|---|---|
| 720p | 174.0 fps | **231.7 fps** (3×3) |
| 1080p | 96.6 fps | **128.7 fps** (3×3) |
| 5K | 20.5 fps | **29.7 fps** (4×4) |

At 720p a frame is now 4.3 ms: GPU analysis 3.2 (overlapped), filters 1.8,
closed loop 1.3, chroma 0.5, writer 0.3. At 5K the filters take 15.7 ms;
their GPU work covers the whole frame (~12 ms) however little changed.

What's left:
- At 720p, the GPU's 9 ms with 97 % kept: every block's thread still
  launches to find its SB kept (since fixed above).
- At 5K, the filters (19 ms, whole frame) and the CPU's fixed costs: source
  padding and recon copies of the whole frame, and per-block bookkeeping.

### AV1HybridEncoder: sustained speed on frame sequences (2026-10-30)

The hybrid is now a product class, `GlassActAV1.AV1HybridEncoder`. Its CPU
closed loop moved from the test-support reference engine into
`AV1Encoder/src/hybrid.cpp`, and the reference engine is upstream's again. A
sequence starts picture i + 1's GPU analysis before finishing picture i on
the CPU (`AV1MetalEncoder.beginPartition`).

`glassact-bench av1seq` (new) encodes consecutive trace frames, each as an
intra frame. Turbo, q20, after one warm-up picture; every stream decodes in
libaom to the encoder's picture exactly. libaom is realtime key frames at
the same quantizer, speed 9, 8 threads. M4 Pro.

| trace, frames | size, tiles | hybrid | libaom s9 | hybrid bytes |
|---|---|---|---|---|
| typing-cc 100–139 | 1280×720, 2×2 | serial 23.8 fps → **overlapped 39.9 fps** · 108.9 KB · 41.60 dB | 48.0 fps · 182.9 KB · 43.05 dB | −40 % |
| scroll-win 100–139 | 1280×720, 2×2 | **45.9 fps** · 90.9 KB · 43.37 dB | 56.0 fps · 130.0 KB · 44.34 dB | −30 % |
| photos 100–139 | 1280×720, 2×2 | **38.7 fps** · 129.9 KB · 41.40 dB | 47.0 fps · 200.6 KB · 42.22 dB | −35 % |
| typing-cc 100–129 | 1920×1080, 2×2 | **22.3 fps** · 200.9 KB · 42.64 dB | 26.5 fps · 354.1 KB · 43.70 dB | −43 % |
| typing-cc 100–119 | 2560×1440, 3×2 | **14.1 fps** · 287.2 KB · 43.61 dB | 18.8 fps · 540.8 KB · 44.47 dB | −47 % |
| typing-cc 100–109 | 5120×2880, 3×3 | **3.9 fps** · 542.5 KB · 47.46 dB | 6.6 fps · 1.03 MB · 47.61 dB | −47 % |

- **Overlap works.** At 720p the frame time (21–26 ms) is the CPU's work
  (chroma 3–4, closed loop 12–16, filters 3–4, writer 1–2), with the GPU
  analysis (~18 ms) hidden behind it.
- The hybrid runs at 75–85 % of libaom realtime's speed. At one quantizer
  its files are 30–47 % smaller and its PSNR 0.2–1.4 dB lower. The
  SSIMULACRA2-matched spot checks above put the size gap at 35–50 %.
- Copying the filtered planes out by rows instead of pixels (kept) takes
  720p typing-cc from 39.9 to **44.4 fps** (filters 4.2 → 2.7 ms).
- **At 5K the filters take 85 ms** of wall time against 12 ms of GPU work.
  Their dispatches queue with the next picture's 200 ms analysis. The next
  levers are the filters' setup and copies, and their place in the overlap.

### Metal AV1 hybrid at region sizes; where the CPU goes (2026-10-30)

M4 Pro, turbo, q20, frame 200 / 150 / 150 of typing-cc / scroll-win /
photos, resampled to 1280×720. The hybrid is GPU analysis and partition,
then CPU chroma decisions and closed loop on tile threads, the GPU strength
search and filters, and av1core's writer. Wall ms, and size @ SSIMULACRA2:

| trace | GPU-only, 2×2 tiles (log2) | hybrid, 2×2 | libaom s9 (8 threads) |
|---|---|---|---|
| typing-cc | 104 · 106.6 KB @ 74.4 | **50** · 109.8 KB @ 73.9 | 37 · 184.2 KB @ 77.2 |
| scroll-win | 110 · 85.1 KB @ 77.9 | **49** · 88.1 KB @ 77.5 | 29 · 127.7 KB @ 79.3 |
| photos | 105 · 129.5 KB @ 78.9 | **56** · 134.4 KB @ 78.8 | 35 · 202.1 KB @ 80.2 |

- The hybrid's ~50 ms: GPU analysis 18, CPU chroma 5, CPU closed loop
  17–22, filters 3–5, writer 2–3, the rest overhead. With frame N+1's GPU
  analysis overlapped with frame N's CPU work it would be ~30 ms
  (projected).
- **Thread-per-block analysis for 8×16 / 16×8** (kept): at 5K the
  analysis goes from ~225 to ~205 ms, with the same bytes.
- **CPU profile** (`sample`, 5K hybrid):
  - The closed loop's tx-type trials (`trial`) are the largest part, and
    their exact inverse transforms (`av1g_inv_1d`) add ~40 % more.
  - The chroma decisions (prediction + Hadamard cost) are next, then entropy
    coding.
  - A float, vectorizable forward transform made the same bytes but no
    measurable change (kept): the time isn't in the multiply.
- At 5K the CPU side (~170 ms: chroma 42, closed loop 90, filters 30,
  writer 6) is already below the GPU analysis (~210 ms). Overlapped, the
  analysis bounds the frame, so GPU analysis time is the lever there.

### av1core codes tiles in parallel (2026-10-30)

av1core's encoder now codes each tile on a worker thread. A copy of the
encoder holds the tile's state (contexts, CDFs, cursor); the frame's
buffers, which tiles write in disjoint parts, are shared. The output is
unchanged, and every gate holds: the decoder gate's random multi-tile
records, GPU entropy against the writer, the post-filters, and the Metal
encoder's tiled pictures through libaom. typing-cc frame 200, 5K, turbo,
3×3 tiles (64), M4 Pro (14 cores):

| | one thread | tile threads |
|---|---|---|
| writer (symbols only) | 65 ms | 6.5 ms |
| writer with reconstruction | 184 ms | 18 ms |
| hybrid CPU closed loop | ~1000 ms | 97 ms |

The previous entry's projection holds. The hybrid now takes ~440 ms a frame,
wall: GPU analysis 245, CPU chroma decisions 41, CPU closed loop 97,
filters and search 29, writer 7. All-GPU takes ~515–540 ms (closed loop
250–270), and the hybrid is 3–4 % larger. Overlapping frame N+1's GPU analysis
with frame N's CPU work would make it ~245 ms a frame, analysis-bound
(not built).

### Metal AV1: small-shape kernel, and a first CPU closed loop (2026-10-30)

The previous entries' frames and machine. `av1still --hybrid` (new).

**Small-shape analysis kernel (kept).** av1gpu's thread-per-block analysis of
the shapes up to 64 pixels, on by default upstream, is now ported and on.
It makes the same decisions, so the same bytes. On turbo with 3×3 tiles at
5K, the analysis drops from ~356 to ~225 ms on typing-cc, scroll-win and
photos (−36 %); base drops from ~1160 to ~960 ms.

**The hybrid (prototype).** The GPU's analysis and partition DP give the
partition and luma modes. The closed loop runs on the CPU through
av1core's `TxbHook`, built from the reference engine: chroma modes and CfL
from the source, the GPU's dead zone (rnd 0.375, zbin 0.656), luma tx types
searched by exact reconstruction error, then skip flags. The GPU strength
search and filters follow, then av1core's writer. Every stream decodes in
libaom to the filtered picture. Single-threaded: av1core codes tiles one
after another.

| typing-cc frame 200 | GPU closed loop | hybrid (1 CPU thread) | size, hybrid vs GPU |
|---|---|---|---|
| 1280×720 2×2, q12 | 143.1 KB @ 80.17, closed loop 77 ms | 147.5 KB @ 80.06, closed loop 116 ms | +3.1 % |
| 1280×720 2×2, q28 | 78.0 KB @ 64.91, 72 ms | 80.8 KB @ 63.85, 100 ms | +3.6 % |
| 5120×2880 3×3, q12 | 674.5 KB @ 81.62, 272 ms | 697.6 KB @ 81.73, 997 ms | +3.4 % |
| 5120×2880 3×3, q28 | 413.2 KB @ 69.60, 260 ms | 431.4 KB @ 69.35, 999 ms | +4.4 % |

- Keeping the analysis's luma tx types instead of searching halves the CPU
  closed loop (56 ms at 720p q12) but costs +8.7 % size. Not worth it.
- The CPU closed loop is ~4× the GPU's single-threaded. Most of that is
  the tx-type trials: double-precision matrix transforms, an inverse and an
  SSE for each type. The writer alone reconstructs the 5K frame in ~115 ms.
- **Projection, not measured:** with tiles coded on parallel threads (64
  tiles at 5K on 14 cores), the CPU closed loop would be ~90–100 ms against
  the GPU's 260–270, the writer ~6 ms, and the frame ~350 ms. A pipeline
  with frame N+1's analysis on the GPU during frame N's CPU closed loop
  would be analysis-bound at ~230 ms a frame. Both need av1core to code
  tiles concurrently: its encoder keeps tile state (contexts, CDFs, cursor)
  in one object.

### Where the Metal AV1 encoder's time goes (2026-10-30)

The previous entry's encoder, turbo preset, typing-cc frame 200, q20,
M4 Pro. I measured with per-dispatch command buffers (temporary
instrumentation, not committed) and isolated 64×64 crops of the frame. Unless
noted, numbers are at 5120×2880 with 3×3 tiles.

**The analysis.** 376 ms. The four smallest shapes take half of it: 4×4 75 ms,
4×8 38, 8×4 36, 8×8 44. Each block there gets a whole SIMD-group (32 lanes
for 16–64 pixels). av1gpu's thread-per-block kernel for these shapes
(`smallKernel`, on by default upstream) isn't ported yet. 64×64 takes 45 ms,
at one SIMD-group per threadgroup (the 32 KB threadgroup-memory limit).

**The closed loop.** 266 ms in 20 steps.
- A step costs about its slowest superblock plus a throughput term: 64
  superblocks ~8 ms, 304 ~19 ms.
- Superblocks cropped from the frame and encoded alone take 0.7–24 ms
  (median 1–2 ms). The slow ones are text with ~100–180 blocks, at
  **100–220 µs per block**. Blocks within a superblock are coded in decode
  order, so that's the critical path. Absolute values for single superblocks
  are inflated by the GPU's low clock under light load.
- Switching off CfL, the second chroma candidate and the closed-loop
  tx-type search together saves 20 % (266 → 212 ms, +8.6 % size). The cost
  is the per-block machinery itself, not the optional searches.
- Padding the closed loop's threadgroup memory from 23.5 to 31.5 KB slows
  turbo 41 % on 1024 superblocks in one step, and doesn't change base.
  Threadgroup memory isn't base's limit, and is only part of turbo's.
- Compiling the pipelines for their real thread counts
  (`maxTotalThreadsPerThreadgroup` 128 / NW·32) changes nothing at frame
  level. It's kept, since it's the right description of the kernels.

**Smaller pictures don't escape the floor** (the same frame resampled; GPU ms
at the best tiling, against libaom s9's CPU wall time on 8 threads):

| size | Metal turbo | closed loop | libaom s9 |
|---|---|---|---|
| 1280×720, 2×2 tiles | 99 | 74 in 9 steps | 21 |
| 2560×1440, 2×2 tiles | 269 | 177 in 20 steps | 51 |

**The CPU's side, single-threaded.** av1core's writer codes the 5K frame in 53
ms, and in 170 ms when it reconstructs too (prediction, inverse transforms,
reconstruction of every block). At 720p it's 9.6 and 19.8 ms. That puts a CPU
block at a few µs, against ~100 µs for one 128-thread threadgroup on the GPU.

**Conclusion.** The GPU suits the parallel analysis. The serial closed loop
belongs on the CPU, one thread per tile. av1core's writer already
reconstructs, and offers the closed-loop hook (`TxbHook`, which its CPU
reference engine uses) for choosing coefficients from the exact prediction.
The next entry measures that hybrid.

### Metal AV1 key frames vs libaom realtime: first measurements (2026-10-30)

Research branch `metal-av1` (the Metal port of av1gpu, `GlassActAV1`).
`glassact-bench av1still` (new) encodes one trace frame as an AV1 key frame
two ways, at fixed quantizers q, and scores luma PSNR and SSIMULACRA2
against the source:
- **Metal:** GPU analysis, partition DP and closed loop at qindex 4q; the
  GPU strength search and filters (libaom tune=iq's levels); av1core's CPU
  writer.
- **libaom realtime:** the retired AV1 video path's screen-content encoder
  (palette, IntraBC), speed 9 or 6, 8 threads.

Every Metal stream decodes in libaom to exactly the GPU's filtered picture.
Machine: M4 Pro. Native 5120×2880, one frame per trace, so these are spot
checks, not BD-rate.

**Size at equal quality.** Metal base preset, minimum tiling; size @ SSIMULACRA2:

| trace (frame) | Metal q12 | libaom s9 q12 | Metal q20 | libaom s9 q20 |
|---|---|---|---|---|
| typing-cc (200) | 653 KB @ 81.8 | 1.19 MB @ 81.5 | 510 KB @ 77.6 | 1.04 MB @ 78.4 |
| scroll-win (150) | 540 KB @ 80.2 | 833 KB @ 79.8 | 432 KB @ 78.0 | 698 KB @ 78.4 |
| photos (150) | 1.46 MB @ 81.2 | 2.44 MB @ 81.8 | 1.06 MB @ 76.5 | 2.06 MB @ 78.4 |

That's 35–50 % smaller at matched SSIMULACRA2. libaom speed 6 lands within
0.5 % of speed 9 here. At one q, Metal's quality falls faster with q than
libaom's, so compare at equal scores, not equal q.

**Time at 5K** (typing-cc, ms; GPU is from GPU timestamps, stage by stage):

| configuration | analysis | closed loop | GPU total | writer (CPU) | size vs base |
|---|---|---|---|---|---|
| base, minimum tiles (128 steps) | 1093 | 1038 | 2131 | 65 | — |
| base, 2×2 tiles (42 steps) | 1198 | 470 | 1668 | 93 | +0.3 % |
| base, 3×3 tiles (20 steps) | 1181 | 296 | 1478 | 139 | +1.4 % |
| base, 4×3 tiles (15 steps) | 1220 | 277 | 1498 | 85 | +2.6 % |
| fast, 3×3 | 627 | 313 | 940 | 63 | +1.5 % |
| faster, 3×3 | 660 | 276 | 936 | 64 | +1.5 % |
| **turbo, 3×3** | 356 | 272 | **629** | 65 | +1.9 % |
| turbo2, 3×3 | 224 | 171 | 395 | 76 | +39 % |
| turbo3, 3×3 | 128 | 141 | 270 | 78 | +40 % |
| libaom s9 (8 CPU threads) | | | 250–330 wall | | +80 % |

These are q12 rows. The writer column is noisy (30–200 ms run to run). The
filters and strength search take 12 ms of GPU time (~28 ms wall).

- **The closed loop is latency-bound.** A wavefront step costs ~7 ms
  whether it holds 10 superblocks (720p) or 40 (5K), so its time is the step
  count; tiles cut it. Past 3×3 the steps get slower as they widen.
- **The analysis is throughput-bound** (~13 MP/s on base). The presets cut
  it most.
- **turbo is the sweet spot on text:** 2.3× base's speed for +2 % size,
  still ~43 % smaller than libaom s9 at equal SSIMULACRA2.
  turbo2 / turbo3 drop 4×4 / 4×8 / 8×4 blocks, which costs text ~40 %.
  Turning off angle deltas alone (turbo + turbo3's change) saves ~65 ms of
  analysis for +0.7 %.
- **Still 20× short of a 30 fps 5K frame.** Leads, unmeasured:
  - occupancy: the closed loop's threadgroup takes 23.5 KB of threadgroup
    memory and the large analysis shapes 20–32 KB;
  - av1gpu's small-shape analysis kernel (`smallKernel`, on by default
    upstream, not ported);
  - writing tiles on parallel CPU threads;
  - for video, encoding only the regions that change.

### Prefer smooth motion runs AV1 on a thin link (2026-10-28)

The next entry's candidate, in the product. With the Viewer's AV1 opt-in
and Prefer Smooth Motion, the Host now allows AV1 without room
(`allowedVideoCodecs`), and while the link has none the AV1 encoder runs at
quantizer ceiling 60 aiming at 60 % (`setSmoothMotion`). HEVC still gets
ceiling 38 alone.

`replay --mode loop` with the product's pair (`--video av1-hevc`: AV1 and
HEVC negotiated, hardware decode), on the same three links. `--prefer-smoothness`
(new) has the Viewer send QUALITY preference 2 before the first region
forms. Video frames · link queue p95 (ms):

| link · trace | AV1 opt-in today | smooth today (HEVC 38) | smooth on AV1 |
|---|---|---|---|
| 2M cursor-drag | 281 · 652 | 329 · 569 | **396** · 446 |
| 2M scroll-win | 170 · 651 | 227 · 620 | **358** · 449 |
| 2M photos | 20 · 1732 | 45 · 1676 | **180** · 993 |
| 2M typing-cc | 14 · 470 | 13 · 417 | 15 · 485 |
| 3M cursor-drag | 346 · 435 | 373 · 477 | **385** · 435 |
| 3M scroll-win | 218 · 414 | 239 · 358 | **443** · 377 |
| 3M photos | 56 · 998 | 60 · 997 | **271** · 761 |
| 3M typing-cc | 11 · 386 | 12 · 416 | 17 · 394 |
| 6M cursor-drag | 408 · 276 | **411** · 284 | 382 · 324 |
| 6M scroll-win | 413 · 332 | 300 · 210 | **417** · 253 |
| 6M photos | 62 · 499 | 124 · 499 | **402** · 359 |
| 6M typing-cc | 17 · 263 | 17 · 259 | 17 · 275 |

Every run settled byte-identical. "AV1 opt-in today" fell back to HEVC on
every run (1–2 regions without AV1 each).

- Against today's smooth motion: 1.2× the frames on 2M dragging, 1.4–1.9×
  on scrolling, 3–4.5× on photos, with a shorter queue p95 on 7 of 12 runs.
- Three queue p95s rise by more than 10 %. Two come with more frames:
  6M scroll-win 210 → 253 ms with 1.4× the frames, and 2M typing-cc
  417 → 485 ms with 15 frames against 13. Accepted: response comes first,
  and the frames are the response.
- One run loses outright: 6M cursor-drag, 411 → 382 frames (−7 %) and
  284 → 324 ms (+14 %). Accepted for the gains everywhere else; 6 Mbit/s
  is the edge of "thin", where both codecs deliver about the same.
- What the frames look like is the next entry's `vquality`: against HEVC
  38, sharper dragging (75 · 43 vs 72 · 26), a little softer scrolling
  (64 · 37 vs 70 · 39), and poor photos (10 vs 32) until they settle to
  lossless tiles.

### AV1 at ceiling 60: a higher rate aim (2026-10-28)

Follow-up to the next entry, which left open whether AV1's softness at
quantizer ceiling 60 came from the ceiling or from aiming at only 40 % of
the cap. Same `glassact-bench` build, traces and links as that entry;
`--av1-target-pct` 60 / 80 / 100 at ceiling 60, and 80 at ceiling 54.
HEVC 38 is what Prefer Smooth Motion runs on a thin link today.

Motion quality: `vquality` at 2 Mbit/s, 15 fps submitted, SSIMULACRA2
mean · worst sampled frame (Mbit/s achieved):

| trace | HEVC 34 | HEVC 38 | AV1 60 aim 40 | aim 60 | aim 80 | aim 100 | AV1 54 aim 80 |
|---|---|---|---|---|---|---|---|
| scroll-win | 72 · 56 (1.55) | 70 · 39 (1.55) | 56 · 28 (0.69) | 64 · 37 (0.99) | 69 · 49 (1.25) | 74 · 65 (1.54) | 70 · 50 (1.25) |
| cursor-drag | 73 · 46 (0.34) | 72 · 26 (0.35) | 70 · 30 (0.84) | 75 · 43 (1.08) | 77 · 47 (1.06) | 78 · 51 (1.07) | 78 · 51 (1.07) |
| photos | 42 · 39 (3.39) | 32 · 21 (2.55) | −1 · −26 (1.14) | 10 · −22 (1.50) | 20 · −21 (1.88) | 25 · −22 (2.24) | 27 · 6 (2.13) |

Thin-link loop, video frames · link queue p95 (ms):

| link · trace | HEVC 38 | AV1 60 aim 40 | aim 60 | aim 80 | aim 100 | AV1 54 aim 80 |
|---|---|---|---|---|---|---|
| 2M cursor-drag | 323 · 574 | 406 · 423 | 305 · 480 | 361 · 514 | 301 · 538 | 184 · 733 |
| 2M scroll-win | 192 · 650 | 408 · 369 | 346 · 570 | 244 · 496 | 176 · 673 | 263 · 662 |
| 2M photos | 65 · 1894 | 208 · 711 | 162 · 1030 | 54 · 918 | 59 · 1288 | 28 · 1517 |
| 2M typing-cc | 13 · 456 | 16 · 399 | 15 · 430 | 15 · 491 | 16 · 510 | 15 · 613 |
| 3M cursor-drag | 355 · 541 | 447 · 443 | 432 · 488 | 398 · 472 | 287 · 506 | 350 · 554 |
| 3M scroll-win | 255 · 364 | 454 · 348 | 415 · 344 | 329 · 399 | 208 · 460 | 324 · 404 |
| 3M photos | 49 · 997 | 304 · 564 | 284 · 753 | 239 · 962 | 97 · 986 | 124 · 997 |
| 3M typing-cc | 12 · 344 | 16 · 362 | 16 · 394 | 15 · 420 | 16 · 465 | 15 · 444 |
| 6M cursor-drag | 406 · 283 | 454 · 278 | 423 · 265 | 366 · 275 | 331 · 286 | 333 · 299 |
| 6M scroll-win | 349 · 323 | 483 · 209 | 431 · 221 | 319 · 224 | 189 · 260 | 381 · 283 |
| 6M photos | 69 · 499 | 422 · 297 | 420 · 389 | 382 · 498 | 322 · 498 | 221 · 499 |
| 6M typing-cc | 17 · 259 | 17 · 263 | 17 · 276 | 17 · 281 | 17 · 283 | 17 · 283 |

Every run settled byte-identical.

- **The softness was the aim.** At aim 100 ceiling 60 matches or beats
  HEVC 34 on scrolling (74 · 65 vs 72 · 56, at the same 1.54 Mbit/s) and
  dragging (78 · 51 vs 73 · 46, though HEVC needs only 0.34 Mbit/s there).
  Once the aim is that high, ceiling 54 looks the same as 60 on scrolling
  and dragging. Photos stay well below HEVC at every aim.
- **Every step up in aim costs frames:** bigger frames queue, and the send
  gate skips them. Aim 100 delivers fewer frames than HEVC 38 on scrolling
  and dragging on every link. Aim 80 falls below it on 6M scrolling and
  dragging and on 2M photos. Ceiling 54 at aim 80 delivers fewer frames
  than ceiling 60 at aim 80 on most runs.
- **Aim 60 is the middle that keeps the frames.** It delivers at least
  HEVC 38's frames on every run but 2M cursor-drag (305 vs 323): 1.2–1.8×
  on scrolling, 2.5–6× on photos. Its queue p95 is shorter or within 15 %.
  Against HEVC 38 its motion is sharper on dragging (75 · 43 vs 72 · 26),
  a little softer on scrolling (64 · 37 vs 70 · 39), and poor on photos
  (10 vs 32).
- **Against aim 40** (the previous entry), aim 60 gives up 0–25 % of the
  frames for +8 SSIMULACRA2 on scrolling, +5 on dragging and +11 on photos.

Ceiling 60 at aim 60 became Prefer Smooth Motion's AV1 trade, on Viewers
that opt in to AV1 ("Prefer smooth motion runs AV1 on a thin link", above).

### Live AV1 encoders, and a looser AV1 ceiling on thin links (2026-10-27)

Could another AV1 encoder, or AV1 allowed to look worse, buy frames on a
thin link? Response time comes first; motion only needs to look about as
good as HEVC, since lossless tiles settle the picture anyway.

**Encoders at equal quality.** The four reference traces, 300 frames each
(typing-cc 266) at 2900×1632 on a 60 fps timeline, exported with `y4m` and
scaled with lanczos. Every encoder low-delay (no lookahead, no
reordering), CBR, no quality ceiling, 5 targets from 0.25 to 4 Mbit/s,
decoded by ffmpeg, SSIMULACRA2 on every 20th frame. Encoders:

- hardware HEVC through ffmpeg: `hevc_videotoolbox -realtime 1 -bf 0`;
- libaom 3.15.2 `aomenc --rt` with the Host's settings: screen tuning,
  8 threads, row-MT, 3 tile columns, a 1 s buffer, ±50 % shoot;
- SVT-AV1 4.2.0 `--rtc 1 --scm 1 --rc 2 --lookahead 0`;
- rav1e 0.8.1 `--speed 10 --low-latency --rdo-lookahead-frames 1
  --threads 8 --tiles 8`.

Below, the bitrate each needs to match HEVC's quality at HEVC's 1 and
2 Mbit/s settings, as a fraction of HEVC's (under 1 = fewer bytes), and
its speed:

| encoder | bytes for HEVC's quality | speed |
|---|---|---|
| libaom speed 9 (shipped) | 0.40–0.84 (median ~0.7) | 2.4–7 ms per frame p50, 3.4–10.4 p95 (`vquality`) |
| libaom speed 10 / 11 | 0.46–0.97 | the same as speed 9 |
| SVT-AV1 preset 7 | 0.41–0.84 | 24–48 fps |
| SVT-AV1 preset 8 | 0.48–0.99 | 32–72 fps |
| SVT-AV1 preset 10 | 0.57–1.03 | 41–87 fps |
| SVT-AV1 presets 12–13 | 1.17–1.45, or never reaches HEVC's quality | 41–98 fps |
| rav1e speed 10 | 0.54–0.90 | 24–32 fps |
| hardware HEVC | 1 | 12.9 ms per frame p50, 13.1–16.3 p95 (`vquality`) |

- SVT-AV1 and rav1e are too slow for a live session at this size on a
  14-core M4 Pro, whatever they save. SVT-AV1 switches its screen-content
  tools off in real-time mode at preset 9 and faster, so its fast presets
  also lose on text. SVT itself reports 58–60 fps on scroll-win today; the
  157–204 fps in "Real-time AV1" below doesn't reproduce at 300 frames.
- libaom at speed 9 is both the smallest and the fastest live encoder
  here, faster per frame than the hardware HEVC encoder. Speeds 10 and 11
  encode no faster in the product's libaom.
- Fed every frame, hardware HEVC doesn't go below ~1 Mbit/s on typing,
  3 on scrolling or 6.6 on photos whatever the target, and with no QP cap
  its quality collapses mid-scroll (luma PSNR 36.6 → 23–25 dB at
  2 Mbit/s). The Host's QP 34 cap and send gate drop frames instead.

**A looser AV1 ceiling on thin links.** `replay --mode loop` on the
link-estimate entry's 2M and 3M links plus 6M (`--link-mbit 6
--link-buffer-ms 500 --latency 30-40`). HEVC at its frame-QP ceiling (34,
38 = the smooth-motion floor, 42) against AV1 at libaom quantizer ceilings
42 (the product's), 48, 54 and 60 (`--av1-qmax`). Video frames · link queue
p95:

| link · trace | HEVC 34 | HEVC 38 | HEVC 42 | AV1 42 | AV1 48 | AV1 54 | AV1 60 |
|---|---|---|---|---|---|---|---|
| 2M cursor-drag | 281 · 664 | 323 · 574 | 330 · 611 | 283 · 1183 | 307 · 905 | 222 · 480 | 406 · 423 |
| 2M scroll-win | 170 · 651 | 192 · 650 | 208 · 670 | 315 · 1040 | 342 · 697 | 381 · 489 | 408 · 369 |
| 2M photos | 20 · 1732 | 65 · 1894 | 71 · 1997 | 10 · 1997 | 13 · 1782 | 28 · 1810 † | 208 · 711 |
| 2M typing-cc | 14 · 470 | 13 · 456 | 14 · 481 | 13 · 598 | 16 · 743 | 16 · 510 | 16 · 399 |
| 3M cursor-drag | 346 · 435 | 355 · 541 | 396 · 458 | 369 · 746 | 398 · 626 | 417 · 548 | 447 · 443 |
| 3M scroll-win | 218 · 414 | 255 · 364 | 260 · 358 | 383 · 572 | 407 · 460 | 463 · 438 | 454 · 348 |
| 3M photos | 56 · 998 | 49 · 997 | 57 · 867 | 16 · 999 | 112 · 998 | 153 · 997 | 304 · 564 |
| 3M typing-cc | 11 · 386 | 12 · 344 | 15 · 364 | 11 · 496 | 15 · 474 | 16 · 422 | 16 · 362 |
| 6M cursor-drag | 408 · 276 | 406 · 283 | 411 · 286 | 292 · 354 | 315 · 324 | 343 · 296 | 454 · 278 |
| 6M scroll-win | 354 · 319 | 349 · 323 | 319 · 225 | 458 · 301 | 483 · 269 | 483 · 254 | 483 · 209 |
| 6M photos | 81 · 498 | 69 · 499 | 200 · 498 | 141 · 499 | 224 · 499 | 297 · 498 | 422 · 297 |
| 6M typing-cc | 17 · 263 | 17 · 259 | 17 · 259 | 17 · 295 | 17 · 286 | 17 · 279 | 17 · 263 |

† didn't settle within the 60 s budget; every other run settled
byte-identical.

At ceiling 60 AV1 delivers the most frames on every run, or within 2 %
of the most, and the shortest queue p95 on most; where it isn't the
shortest it's within 5 % (3M cursor-drag 443 vs 435 ms, 3M typing-cc 362
vs 344, 6M cursor-drag 278 vs 276). 2M scroll-win gets 2.4× HEVC's frames
with 57 % of its queue p95, 2M photos 10× the frames. Its sync frames shrink to HEVC's size (3M:
0.27–0.72 MB against 0.6–2.0 MB at 42). Loosening HEVC's ceiling buys
little (2M scroll-win 170 → 208 frames at 42).

What the frames look like: `vquality` at 2 Mbit/s, 15 fps submitted,
SSIMULACRA2 mean · worst sampled frame (`--max-qp` 39 / 44 / 49 map to
libaom 48 / 54 / 61):

| trace | HEVC 34 | AV1 42 | AV1 48 | AV1 54 | AV1 61 |
|---|---|---|---|---|---|
| scroll-win | 72 · 56 | 68 · 61 | 62 · 47 | 58 · 35 | 56 · 28 |
| cursor-drag | 73 · 46 | 77 · 52 | 74 · 39 | 71 · 30 | 70 · 30 |
| photos | 42 · 39 | 46 · 41 | 31 · 25 | 15 · 5 | −1 · −26 |

The frames ceiling 60 buys are softer than HEVC's on scrolling (56 vs 72)
and poor on photos; dragging stays close (70 vs 73). The middle ceilings
cost quality without a clear win on frames or queue. AV1 here also aims at
40 % of the cap, so part of its softness may be the aim rather than the
ceiling. Not acted on yet: a candidate for the smooth-motion opt-in on
Viewers that decode AV1.

### Back up the rung without proof of room (2026-10-26)

On a phone hotspot after landing (`6f2d76f` Host; 2944×1600 capture) the
rung fired 8 s after connecting. The first seconds read thin: SRTT 150–180 ms
and capacity 0.2 → 1.6 → 2.1 Mbit/s while the radio woke and QUIC ramped
under the cold start. From 10 s on the link was plainly fine: SRTT 35–45 ms,
network queue ~10 ms, video never backed up (`vlink unmeasured`), and peaks
of 3.2 Mbit/s with room to spare. The rung, as first merged, came back up
only after the link *delivered* 2 × the full capture's thin bar (7 Mbit/s
here) for 30 s. A half-size, mostly quiet screen never sends that, so it
would have stayed halved all session.

Now it comes back up unless the link shows it's too thin: 30 seconds with
no queue and a capacity (queued spans, last ~60 s) unmeasured or at least
2 × the bar, after the hold (60 s, doubling to 16 min each time it comes
back down). The thin-link rules re-halve within seconds if that was wrong.
On plane Wi-Fi every queued span read 0.3–2.3 Mbit/s, which keeps it down
(`ScalePressureTests.theEngineKeepsAThinLinkHalved`). A quiet minute on a
thin link does make it try again; the doubling hold bounds that cost. Not
measured live yet.
### Input → update latency on plane Wi-Fi: the link, not the Host (2026-10-26)

Typing and scrolling over plane Wi-Fi felt about as quick as Apple's Screen
Sharing. The Host now times each key-down, click, scroll or text input from
arrival to the first update that leaves after it (`HostStats.inputUpdate*`,
in the status line per 2 s window). Live, `6f2d76f` Host, 1450×786 after
auto-scale, ~40 s of typing and scrolling:

| | per-window averages |
|---|---|
| input → update (the Host's share) | 11, 14, 15, 15, 41, 43, 44, 47, 61, 94 ms (1–43 inputs each); outliers 368 ms (2 inputs) and 835 ms (the auto-scale engine rebuild) |
| SRTT (the link) | 632–821 ms |

The Host adds a frame or two to a round trip of ~0.7 s, so about 95 % of the
lag is the link, and both apps sit on the same floor. Only local prediction
(the Viewer moving the picture on a scroll before the Mac answers) could
feel faster on such a link. The measure is a lower bound: an unrelated
update that leaves right after an input ends it early.

### Auto-scale from the viewer's link reports (2026-10-26)

Live, United lounge Wi-Fi, M4 Pro Host, MacBook Air Viewer over Tailscale,
2900×1572 capture. One session at 09:30:03–09:31:04, HEVC:

- The link carried ~0.3 Mbit/s (the video gate's `vlink 0.30` from its
  one backlogged window), SRTT 1.4–5.6 s.
- Video ran at 0–4 fps and 200–580 Kbit/s, more than the link: the QP 34
  floor keeps frames large (first key frame 95 KB, ~2.5 s of link). The
  network queue reached 4–5 s.
- After 47 s the region dissolved; the lossless repaint couldn't get
  through (0 Kbps for 13 s), and the Host reset the session on 10 s
  without a PONG.

In 61 s, at ~0.1 bit/s per captured pixel, **the resolution rung never
fired**:
- The ACK-delay rule had no samples (video only, no tiles).
- The video rule counts only seconds with a fresh backlogged-window
  measurement, and the send gate skipped frames (vskips ~65 per 2 s)
  instead of letting video back up, so there was one measurement in the
  whole session.

The viewer's RECEIVED reports had the answer all along, so `ScalePressure`
gains a third rule: 5 s in a row of `LinkEstimate`'s recent capacity
(queued spans, last ~10 s) under the same bars (0.75 bit/s per pixel and
4 Mbit/s), counting only seconds with a reading.

Loop, `--video mock`, `--link-mbit 1 --link-buffer-ms 2000 --latency
75-100`, the loop now reporting when the rung fires (before =
`--no-link-reports`):

| trace | before | after |
|---|---|---|
| cursor-drag | 17.2 s | 7.2 s |
| scroll-win | 8.2 s | 8.2 s |
| photos | 7.2 s | 7.2 s |

None settled in the loop's 60 s budget either way; the mock codec's
whole-region frames are slow on 1 Mbit/s.

**A stall isn't a thin link.** Live on this build (same lounge, 09:44:46),
the link carried 2–5.4 Mbit/s with AV1 at 20–31 fps until 09:45:34. Then
the Wi-Fi stalled for a few seconds, and the rung fired at 09:45:38,
halving the capture for the rest of the session. A stall queues data while
almost nothing arrives, so its queued spans read as a very thin link, and
the fast stretch before it had no queued spans to say otherwise. The rule
now judges by the larger of the queued capacity and what the link
delivered in the last ~10 s, a lower bound on it: the 0.3 Mbit/s session
never delivered more than ~0.6 Mbit/s and still fires, the stall doesn't
(`ScalePressureTests.aStallAfterAFastStretchIsntThin`, which fails without
the delivered bound).

**Live on plane Wi-Fi** (same day, `7f3232a` Host, `d35406b` Viewer; 2900×1572
virtual display, ~0.3 Mbit/s, SRTT ~0.6–1 s): the rung fired 7.4 s after
connecting (the 2026-10-22 plane session took 45 s), and a second session 9 s
after. Over the following 7 minutes at 1450×786, from the Host's 2 s status
lines:

| | p50 | p90 / p95 | max |
|---|---|---|---|
| video frames per second | 5 | 44 (p90) | |
| video Kbit/s | 226 | 531 (p90) | |
| network queue | 28 ms | 60 ms (p95) | 83 ms |
| SRTT | 675 ms | 806 ms (p95) | |

The same lounge link at full size had built 4–5 s of queue. The owner's
verdict: "pretty responsive, considering". The capture then stayed halved
for the session, which "Back up the rung" (DESIGN §4.9) addresses.

**Against Apple's Screen Sharing, same flight** (one session each, minutes
apart; per-process bytes handed to the Tailscale tunnel, `nettop`, 5 s
windows). Screen Sharing (`screensharingd`, the standard mode as far as the
process shows) sent 0.57–2.9 Mbit/s, about 1.5 on average, for its ~2 minutes,
2–10× what the link carried, and almost nothing came back (0–19 kbit/s).
Glass Act sent 0.23–0.41 Mbit/s. The owner: Screen Sharing was "pretty
stuttery", about as responsive or slightly less. Not like for like: Screen
Sharing sent the full 2900×1572 throughout (it doesn't scale on the host),
while Glass Act had halved to 1450×786. At full size Glass Act also overran
a 0.3 Mbit/s link (the lounge's 4–5 s queues), so the halving is much of
the difference, and Screen Sharing has nothing like it. An impression from
two short sessions on a link that changes by the minute, not a benchmark.

**A rig artifact found on the way.** On scroll-win and cursor-drag the
estimate read a capacity of 20.4 and 16.8 Mbit/s on the 1 Mbit/s link
(photos 0.97). The rig delivers each video message whole when its last
byte clears the bottleneck, so a message longer than a second of link
lands at once and a one-second span reads it as several times the link
(the timeline, now with `ldeliv` and `lcap`: 3.31 Mbit/s at t=10 s on
cursor-drag). QUIC hands stream bytes over as they arrive, so this exact
case doesn't happen live. A lossy link's head-of-line blocking can release
a burst the same way, though, and that could only push the estimate up:
never a false downscale, but possibly an early "room" for AV1 and Smooth
Motion. To measure next.

### How low can video go: rate–quality knees, looser floors, prefer smooth motion (2026-10-25)

How far can bitrates drop, and does that buy smoothness on a thin link?
Three measurements; M4 Pro, the 5K traces resampled to 2900 px.

**1. Where each codec reaches high quality.** `vquality --width 2900
--frames 300 --codec hevc|av1 --kbit n --max-qp q`, caps 0.25–4 Mbit/s,
floors 34 (the default), 38 and 42 (HEVC scale; AV1 maps them to
quantizers 42, 47, 52). The lowest rate actually used where SSIMULACRA2's
mean reaches 70, floor 34:

| trace | HEVC | AV1 |
|---|---|---|
| typing-cc | 0.18 Mbit/s, but only under a cap ≥ 2 Mbit/s (63 at a 1 Mbit/s cap, same bytes) | 0.25 (75, at a 0.25 cap) |
| cursor-drag | 0.43, cap ≥ 2 | 0.41 (72) |
| scroll-win | 1.71, cap ≥ 2 | ~1.06 (70) |
| photos | not reached by 4.5 Mbit/s (55.5) | not reached by 4 Mbit/s (49) |

Text is already nearly free: HEVC spends 0.16–0.53 Mbit/s on typing and
dragging whatever the cap or floor, so a looser floor saves nothing there
and only loses the worst frames (typing at a 0.25 cap, p5 37 → 20 → −1 at
floors 34, 38, 42). The bytes are in scrolling and photos, where the floor
binds: at a 0.25 cap HEVC scroll-win uses 0.88 / 0.56 / 0.34 Mbit/s at
SSIMULACRA2 47 / 28 / 10, photos 2.85 / 1.68 / 0.99 Mbit/s at 40 / 20 / −2.
AV1 holds up better: scroll-win 1.06 / 0.75 / 0.57 Mbit/s at 70 / 62 / 53,
so on scrolling AV1 at floor 42 beats HEVC at 34 on both bytes and
quality.

**2. Looser floors on thin links.** `replay --mode loop --max-qp q` (a new
loop flag; the rest as in "Link estimate from the viewer"). Video frames ·
queue p95:

| link | trace | HEVC 34 → 38 → 42 | AV1 34 → 38 → 42 |
|---|---|---|---|
| 2M | cursor-drag | 336·641 → 412·585 → 385·587 | 283·1183 → 305·987 → 303·786 |
| 2M | scroll-win | 210·728 → 205·526 → 206·428 | 315·1040 → 346·999 → 368·522 |
| 2M | photos | 20 → 48 → 149 | 10 → 16 → 33 |
| 3M | cursor-drag | 413·469 → 390·388 → 399·458 | 369·746 → 387·642 → 408·576 |
| 3M | scroll-win | 247·423 → 285·344 → 304·349 | 383·572 → 400·452 → 406·414 |
| 3M | photos | 58 → 110 → 210 | 16 → 41 → 124 |

typing-cc moves by at most 5 frames from floor 34. Identical runs differ by about ±3 %.
Every run settled byte-identical, but AV1 at 38 on 2M photos needed 60.45
s, past the loop's 60 s budget (a new `--settle-s` raises it). Floor 42's
photo frames are unreadable (SSIMULACRA2 near zero, above); floor 38 is
the usable trade.

**3. A minimum encoder cap, rejected.** HEVC's text quality follows its
cap even at the same bytes, so would a cap that never drops below
2–3 Mbit/s keep text sharper on a thin link? `--min-encoder-cap` (bench
only; the send gate still decides what goes):

| link | trace | base | min 2M | min 3M |
|---|---|---|---|---|
| 1M | scroll-win | 98 · 1238 ms | 51 · 1533 ms | 61 · 1513 ms |
| 1M | typing-cc | 9 · 463 ms | 9 · 625 ms | 8 · 557 ms |
| 2M | cursor-drag | 326 · 641 ms | 286 · 756 ms | 231 · 566 ms |
| 2M | scroll-win | 208 · 736 ms | 155 · 692 ms | 179 · 726 ms |
| 3M | cursor-drag | 413 · 469 ms | 375 · 469 ms | 352 · 471 ms |

The higher target lets frames grow (typing at a 0.85 → 3 Mbit/s cap: mean
frame 2.5 → 3.1 KB, largest 143 → 167 KB), and the gate skips more of
them.

**Kept: prefer smooth motion, an opt-in.** The Viewer's motion setting
gains a third choice (QUALITY preference 2, behind caps bit 3): while the
link has no room (`LinkRoomPolicy`, the AV1 fallback's judgement, renamed
from `AV1LinkPolicy`), the frame-QP ceiling loosens from 34 to 38. The
defaults don't change: balanced stays at 34 and prefer sharpness at 34/28.

### AV1 only while the link has room (2026-10-25)

With the Viewer's AV1 opt-in on, the Host now picks AV1 for a region only
while the link has room (`AV1LinkPolicy`, DESIGN §4.6), judged on the
Viewer's delivery reports ("Link estimate from the viewer" below):

- A session starts on HEVC.
- AV1 turns on once the link delivered ≥ 6 Mbit/s over a span in the
  last 10 s. A delivered rate is a lower bound, so a thin link can't fake
  it.
- It turns off after 3 s of queued spans carrying < 4 Mbit/s.
- A change applies when the next region forms.

A first version judged the link on the tile governor's rate. It was
unreliable near the crossover, and the delivered rate replaced it.

`replay --mode loop`, the same links as the link-estimate entry plus 6M =
`--link-mbit 6 --link-buffer-ms 500 --latency 30-40`. Video frames ·
link queue p95. Every run settled byte-identical.

| link | trace | HEVC (`--video vt`) | AV1 (`av1`) | fallback (`av1-hevc`) |
|---|---|---|---|---|
| 2M | cursor-drag | 326 · 641 ms | 283 · 1183 ms | 326 · 641 ms |
| 2M | scroll-win | 208 · 736 ms | 315 · 1040 ms | 208 · 736 ms |
| 2M | photos | 20 · 1732 ms | 10 · 1997 ms | 20 · 1732 ms |
| 3M | cursor-drag | 413 · 469 ms | 369 · 746 ms | 413 · 469 ms |
| 3M | scroll-win | 247 · 423 ms | 383 · 572 ms | 247 · 423 ms |
| 3M | photos | 58 · 998 ms | 16 · 999 ms | 58 · 998 ms |
| 6M | cursor-drag | 408 · 268 ms | 292 · 354 ms | 408 · 268 ms |
| 6M | scroll-win | 238 · 224 ms | 458 · 301 ms | 238 · 224 ms |
| 6M | photos | 165 · 498 ms | 141 · 499 ms | 141 · 499 ms |
| 10M | cursor-drag | 442 · 238 ms | 447 · 308 ms | 447 · 282 ms |
| 10M | scroll-win | 483 · 219 ms | 483 · 209 ms | 483 · 179 ms |
| 10M | photos | 276 · 244 ms | 320 · 499 ms | 243 · 286 ms |

typing-cc moves no more than 2 frames on any link; its queue p95 with AV1
alone is 11–33 % above HEVC's (2M 598 vs 520 ms, 3M 496 vs 372 ms), and the
fallback matches HEVC.

- On 2 and 3 Mbit/s the fallback is HEVC exactly. AV1 alone costs latency
  on every trace but 3M photos there (queue p95 +15 % to +85 %; 3M photos
  even) and frames on dragging
  and photos. It delivers more frames only on scrolling (2M scroll-win 315
  vs 208), each later.
- On 10 Mbit/s it runs AV1 and has the best queue p95 on scrolling.
  Photos sits between the two codecs.
- 6 Mbit/s is the threshold itself: scroll-win never proves 6 Mbit/s and
  keeps HEVC (AV1 would deliver 458 frames to 238), and photos goes to AV1
  and loses 24 frames to HEVC.
- **Switching a live region in place, rejected.** A first version moved a
  live region to the new codec at once: a new encoder, its first frame a
  whole-screen sync frame, mid-motion. On 6M photos that delivered 68
  frames (HEVC 165, AV1 141); 6M cursor-drag 337 (HEVC 408); 10M photos
  238 at a 499 ms queue p95. Waiting for the next region costs nothing
  measurable on these traces.
- **A codec per area of the screen** (AV1 for scrolling everywhere) would
  need cells; "Video cells" below rules that out.

### Video cells instead of one full-screen region: rejected (2026-10-25)

Would a fixed grid of video cells, each its own encoder started only when
the cell changes, cost less than the pinned full-screen region? It avoids
what sank the August partial regions (geometry churn, slivers, seams), and
each key frame covers only a cell. `glassact-bench vcells` measures it: the
same trace frames through one full-screen encoder and through a grid of
encoders on 64-px tile boundaries, at one pinned quantizer (QP 30; AV1
libaom quantizer 37), so bytes measure content and not a rate target.

- Each area runs the region's lifecycle. A change after quiet starts a
  session with a key frame; 2.1 s without one ends it with a re-sharpen key
  frame. `--keep-sessions` keeps a quiet area's encoder, so its next change
  is an inter frame.
- Every change is encoded in both setups (the Host sends small changes as
  lossless tiles; neither setup models that), and the cold start is left
  out, since both pay it equally.
- Canvas 2900×1630, M4 Pro. Quality is equal by construction (one
  quantizer); pooled PSNR differs only because the full-screen setup also
  counts static pixels.

Cells' bytes as a share of the full-screen region's, 4×4 grid:

| trace | HEVC | HEVC, sessions kept | AV1 | AV1, sessions kept |
|---|---|---|---|---|
| typing-cc | 69 % | 48 % | 71 % | 50 % |
| cursor-drag | 123 % | 110 % | 152 % | 134 % |
| scroll-win | 128 % | 123 % | 166 % | 157 % |
| photos | 145 % | 143 % | 168 % | 164 % |

Grid size (HEVC, sessions kept): typing-cc 129 % at 2×2, 48 % at 4×4,
24 % at 8×8; scroll-win 106 %, 123 %, 274 %.

- **Motion crosses cell edges.** A cell's encoder predicts only from its
  own past pixels, so scrolled or dragged content entering a cell is coded
  afresh. On scroll-win the cells' inter frames alone are 19 % larger
  (HEVC 6.36 vs 5.34 MB); the finer the grid, the worse.
- **Where cells win, tiles already do.** Sparse changes are cheaper in
  cells: on typing-cc the full-screen HEVC inter frames cost 298 KB
  (~1.1 KB each over 261 frames) against 50 KB of the cells' inter frames. But the Host sends
  small changes like typing as lossless tiles, not video.
- **Key frames aren't the cost on motion.** Start keys and re-sharpens are
  3–7 % of the full-screen HEVC bytes on scroll-win and photos (AV1 7–12 %).
- Sessions aren't a limit: 48 hardware HEVC sessions ran at once (8×8)
  with none refused.
- Aside: on typing-cc's near-static frames, full-screen AV1 inter frames
  cost 36 KB against HEVC's 298 KB.

### Real-time AV1: slower libaom speeds and SVT-AV1 at session size (2026-10-25)

Could AV1 get the efficiency it shows in offline encoders (HandBrake,
SVT-AV1) at a live session's size?

**libaom speeds.** `vquality --codec av1 --av1-speed n --width 2900
--frames 300`, the Host's settings otherwise (CBR aimed at 40 % of the cap,
screen tools). SSIMULACRA2 mean · encode p95:

| trace @ cap | speed 9 (shipped) | speed 8 | speed 7 |
|---|---|---|---|
| typing-cc @ 2M | 80.9 · 3.5 ms | 80.7 · 5.5 ms | 80.7 · 5.6 ms |
| scroll-win @ 2M | 71.7 · 6.4 ms | 72.4 · 8.8 ms | 72.4 · 9.2 ms |
| cursor-drag @ 2M | 79.0 · 3.3 ms | 78.1 · 4.7 ms | 78.2 · 5.2 ms |
| photos @ 2M | 47.6 · 10.6 ms | 48.3 · 14.9 ms | 48.7 · 17.7 ms |
| scroll-win @ 6M | 76.1 · 7.2 ms | 76.7 · 10.4 ms | 76.5 · 11.3 ms |

Speeds 6 and 5 produce byte-identical output to 7 here (realtime libaom
with screen tuning). Speed 8 gains at most 0.7 SSIMULACRA2 (and loses 0.9 on
cursor-drag) for 38–57 % more p95 encode time, and photos at speed 7 passes a 60 fps frame's 16 ms. Speed 9
stays. Where both codecs spent the same bytes (scroll-win at the 6M cap,
2.03 Mbit/s each), AV1 scored 76.1 against HEVC's 71.7 at this size.

**SVT-AV1 at 2900×1630.** The 2026-10-10 re-check found it capped near
14 fps at 5K. At session size speed is no longer the problem; quality is.
On the scroll-win clip at 2 Mbit/s:

| encoder | speed | size | PSNR |
|---|---|---|---|
| SVT preset 10, `--rtc 1`, screen content on | 157 fps | 347 KB | 30.4 dB |
| SVT preset 12 | 186 fps | 377 KB | 28.3 dB |
| SVT preset 13 | 204 fps | 379 KB | 28.3 dB |
| libaom realtime speed 9, CBR | 122 fps | 433 KB | 40.9 dB |

About 10 dB worse at similar size. Its strengths (lookahead, frame
reordering, slow search) are the offline tools a live share can't use. The
cursor-drag half of this run didn't happen (its source clip was missing).

**VP9 (libvpx 1.x through ffmpeg).** 266–300 frames of each trace at
2900×1632, CBR at 0.8 Mbit/s (AV1's aim on a 2 Mbit/s link), every encoder
real-time with no lag, a 1 s buffer, the key-frame cap at 1500 % and
quantizer ceiling 42: libaom speed 9 with screen tuning (the Host's
settings, via `aomenc`) against libvpx speed 7 with `-tune-content screen
-aq-mode 3` (its real-time speeds stop at 8). The ceiling binds at these
rates, so both overshoot on scrolling and photos: this compares them at
the product's quality floor.

| trace | AV1: total · PSNR | VP9: total · PSNR | inter p95 / max, AV1 vs VP9 |
|---|---|---|---|
| typing-cc | 594 KB · 41.5 dB | 617 KB · 39.2 dB | 4.1 / 12.3 vs 5.0 / 15.4 KB |
| cursor-drag | 657 KB · 42.2 dB | 624 KB · 40.0 dB | 3.9 / 9.6 vs 4.9 / 14.5 KB |
| scroll-win | 1.9 MB · 39.6 dB | 4.7 MB · 38.1 dB | 15.4 / 32.5 vs 44.5 / 51.7 KB |
| photos | 5.8 MB · 34.1 dB | 6.2 MB · 34.0 dB | 47 / 172 vs 51 / 167 KB |

VP9 is ~2 dB worse on text at about the same bytes, and on scrolling
spends 2.5× the bytes for less. Its frame sizes aren't steadier either
(larger p95 and largest inter frames on all three text traces), so it
wouldn't help a thin link. It encodes 2–3× faster (228–455 fps against
libaom's 137–190), which isn't the constraint, and its key frames are
smaller: typing-cc 164 KB against AV1's 374 KB (hardware HEVC through
ffmpeg: 140 KB). AV1's large key frames are what hurt it on thin links,
but a tighter cap leaves the first frame unreadable ("AV1 back, as a
Viewer opt-in": 3× gave worst-frame SSIMULACRA2 30). VP9 has no hardware
decode on Apple silicon (`VTIsHardwareDecodeSupported('vp09')` is false
on an M4 Pro), so it would be software on both ends.

### Link estimate from the viewer: a fresh queue and a capacity ceiling (2026-10-25)

On a thin link the video gate starved video after every lossless burst
(2 Mbit/s photos: 8 frames in 30 s, table below). `replay --timeline` shows two causes:

- **A stale queue reading.** The gate's queue signal is the transport's
  smoothed RTT − min RTT. Once video is cut to its floor few ACKs come
  back, so a second of queue reads as present for ~20 s after it drained,
  and the gate keeps cutting. Now a cut also needs the latest PING's RTT −
  the minimum PING RTT (once a second, unsmoothed) over 60 ms. Growth keeps
  the smoothed reading alone: on 10 Mbit/s scroll-win one PING per second
  read 0 ms while the smoothed queue stood at 39–43 ms, and with growth on
  the PING the startup ramp ran to a 17.9 Mbit/s cap (frames 444 → 389,
  queue p95 195 → 265 ms). With fresh-for-cuts only it holds.
- **The host can't see the link.** Its drain readings count bytes leaving
  it, which on a deep buffer leave 2–3× faster than the link carries them.
  The viewer now reports what it received (RECEIVED, 0x1C, every ≥ 250 ms
  while pixels arrive, behind caps bit 2 `deliveryReports`), and
  `LinkEstimate` makes a rate from it over ≥ 1 s of the viewer's clock (the
  rig delivers whole video messages, and a 250 ms span read up to twice the
  link). The capacity is the most delivered in the last 60 s over spans
  where the smoothed queue stood ≥ 30 ms at both ends. The video rate and
  the startup ramp's cap stay ≤ 0.9 × capacity.

  The first version counted every span. That throttles video below the link
  for good: video sent ≤ 0.9 × capacity arrives as ≤ 0.9 × capacity, so the
  next minute's ceiling is lower, and the ratchet runs down to the floor on
  any long video-only stretch. These traces are 30 s, too short to show it,
  and it had the best latency for that reason (2M cursor-drag 374 frames,
  q95 521 ms; 10M scroll-win 447, 181 ms). Spans with room read the
  sender's rate back, so only queued spans count now. Which queue reading
  marks them matters: with the fresh one, 10M scroll-win never marks a span
  during the startup tile burst (it reads 0 throughout) and the ramp runs
  away as above.

HEVC (`--video vt`), `replay --mode loop`, three links: 2M = `--link-mbit 2
--link-buffer-ms 2000 --latency 75-100 --drop 1`; 3M = `--link-mbit 3
--link-buffer-ms 1000 --latency 30-50`; 10M = `--link-mbit 10
--link-buffer-ms 500 --latency 30-40`. Before = `--no-fresh-queue
--no-link-reports`. Video frames delivered · link queue p95 · last frame →
exact. Every run settled byte-identical. M4 Pro, 5K traces.

| link | trace | before | after |
|---|---|---|---|
| 2M | typing-cc | 11 · 520 ms · 22.6 s | 11 · 520 ms · 22.6 s |
| 2M | cursor-drag | 321 · 532 ms · 44.3 s | 326 · 641 ms · 47.8 s |
| 2M | scroll-win | 143 · 833 ms · 31.1 s | 208 · 736 ms · 30.3 s |
| 2M | photos | 8 · 1345 ms · 55.2 s | 20 · 1732 ms · 58.5 s |
| 3M | typing-cc | 12 · 365 ms · 0.05 s | 12 · 372 ms · 0.05 s |
| 3M | cursor-drag | 278 · 403 ms · 24.4 s | 413 · 469 ms · 23.8 s |
| 3M | scroll-win | 221 · 404 ms · 17.1 s | 247 · 423 ms · 17.1 s |
| 3M | photos | 9 · 665 ms · 28.5 s | 58 · 998 ms · 28.5 s |
| 10M | typing-cc | 17 · 184 ms · 0.05 s | 17 · 184 ms · 0.05 s |
| 10M | cursor-drag | 434 · 234 ms · 8.0 s | 442 · 238 ms · 8.0 s |
| 10M | scroll-win | 444 · 195 ms · 8.1 s | 483 · 219 ms · 8.1 s |
| 10M | photos | 193 · 258 ms · 11.1 s | 276 · 244 ms · 11.1 s |

Video delivers more frames on every trace with motion: 2–7× on photos at 2
and 3 Mbit/s, where the old gate left the picture nearly frozen. Typing is
unchanged on every link. **Regressions over 10 %, and why:** the link queue's
p95 rises on 2M cursor-drag (+20 %), 2M photos (+29 %), 3M cursor-drag
(+16 %), 3M photos (+50 %) and 10M scroll-win (+12 %). The queue carries the
video the old gate refused, and the p95 is over the session's busiest
traffic; on the trace where latency is what a person feels (typing-cc) it
doesn't move. The 2M cells also settle 1–3 s later (more video bytes ahead
of the final tiles).

Also measured, not kept:
- **Headroom 0.8** instead of 0.9: 2M cursor-drag 280 frames (fewer than
  before), 3M photos 26; the q95s drop only 0–13 %.
- **Fresh reading for probes too** (measured-mode growth): equal or worse,
  10M photos 299 → 215 frames.
- **Repaints yield to fresh tiles** (`owed-yield`): while a region is live,
  identical on all 12 cells; always, 3M cursor-drag 278 → 352 frames but
  typing-cc's q95 rises at 3M (365 → 422 ms) and 10M (184 → 201 ms).
- **Cut video only for its own queue** (attribute the queue to video by its
  share of bytes): byte-identical on every cell but 10M cursor-drag (434 →
  452 frames, q95 234 → 258 ms).
- **Bound the rate by the host's own delivered readings** (instead of the
  viewer's): identical to before alone; with the fresh queue, 2M cursor-drag
  391 → 436 frames but q95 1730 → 1232 ms, every other cell unchanged.
  The viewer's reports do more (2M cursor-drag q95 641 ms).

### AV1 back, as a Viewer opt-in (2026-10-25)

Software AV1 returns as a choice the Viewer makes. The Host gets a
statically linked, vendored libaom (main at 9ace39e, arm64 only;
`AOMRegionEncoder`); hardware HEVC stays the default. The encoder is
libaom realtime speed 9 with screen tools, CBR with a one-second rate
buffer, no frame drops, and key frames on demand. Rate control follows the
HEVC encoder's: the same base bitrate, quality ladder and link cap, with the
frame-QP ceiling mapped to libaom's quantizer scale (34 → 42, 28 → 35).

**Verdict: a sharpness and latency option, not a bandwidth saving.** At low
bitrates, on text and photos, the hardware HEVC encoder gives the better
picture for the bytes. AV1 wins on scrolling, reaches a sharpness on text
that HEVC doesn't, and encodes in 2–10 ms against HEVC's ~13 ms.

**Full loop, standard faults, golden** (`replay --mode loop --drop 5
--dup 1 --reorder 10 --latency 20-80 --golden --video vt|av1`, 5K, M4
Pro): every trace settled byte-identical with both, AV1 decoded in hardware
(VideoToolbox, as the Viewer does) or with libaom.

| trace | HEVC video (+ sync frames) | AV1 video (+ sync frames) | total HEVC → AV1 |
|---|---|---|---|
| typing-cc | 428 KB (+269 KB) | 372 KB (+609 KB) | 8.85 → 9.12 MB |
| cursor-drag | 4.19 MB (+1.01 MB) | 10.93 MB (+1.69 MB) | 15.76 → 23.20 MB |
| scroll-win | 12.18 MB (+786 KB) | 12.58 MB (+1.07 MB) | 17.61 → 18.32 MB |
| photos | 27.37 MB (+1018 KB) | 32.10 MB (+3.29 MB) | 37.34 → 44.37 MB |

The loop has no link cap, so both run at the 5K base (20 Mbit/s): CBR AV1
spends more of it than VideoToolbox's average-bitrate HEVC, which
undershoots on easy content. Quality needs `vquality`:

**Same caps** (`vquality --codec hevc|av1 --mbit n --width 2880`, 300
frames, Client Resolution canvas, speed 10 at the time; achieved rate ·
PSNR · SSIMULACRA2 mean):

| trace | cap | HEVC | AV1 |
|---|---|---|---|
| typing-cc | 1M | 0.17 · 38.2 · 63.8 | 0.62 · 47.5 · 80.2 |
| typing-cc | 3M | 0.21 · 41.3 · 76.0 | 0.40 · 48.1 · 81.0 |
| typing-cc | 8M | 0.24 · 43.8 · 79.9 | 0.42 · 48.6 · 81.5 |
| cursor-drag | 3M | 0.47 · 41.7 · 75.9 | 1.42 · 48.8 · 81.0 |
| cursor-drag | 8M | 0.51 · 43.2 · 78.5 | 1.37 · 49.3 · 81.7 |
| scroll-win | 1M | 0.95 · 35.7 · 58.6 | 1.24 · 40.8 · 70.9 |
| scroll-win | 3M | 2.41 · 40.6 · 74.1 | 2.45 · 44.4 · 76.2 |
| photos | 3M | 3.84 · 33.3 · 51.6 | 4.40 · 33.6 · 49.9 |
| photos | 8M | 8.27 · 36.8 · 66.3 | 7.90 · 36.4 · 62.9 |

On text HEVC sits far under any cap, so at equal caps AV1 buys sharpness
with 2–3× the bytes. That isn't a bandwidth comparison, so:

**Equal bytes: AV1 lowered to HEVC's rate.** A cap alone didn't do it: below
~0.4 Mbit/s on typing, AV1's quality floor (quantizer 42) holds the rate up,
so the floor was loosened (`--max-qp 42`, HEVC scale → quantizer 52), and
libaom's speed and rate-control mode swept (`--av1-speed`, `--av1-vbr`),
each trace capped near HEVC's achieved rate:

| trace (cap) | HEVC | AV1 s10 CBR | AV1 s9 CBR | AV1 s9 VBR | AV1 s8 VBR | AV1 s7 VBR |
|---|---|---|---|---|---|---|
| typing-cc (250k) | 0.21 · 41.3 · **76.0** | 0.33 · 42.7 · 71.0 | 0.37 · 43.1 · 73.6 | 0.25 · 41.4 · 71.0 | 0.24 · 42.4 · 71.1 | 0.24 · 42.5 · 71.3 |
| cursor-drag (450k) | 0.47 · 41.7 · **75.9** | 0.60 · 42.6 · 70.2 | 0.64 · 42.9 · 72.2 | 0.55 · 42.5 · 72.8 | 0.50 · 42.7 · 70.4 | 0.49 · 42.6 · 70.3 |
| scroll-win (900k) | 0.95 · 35.7 · 58.6 | 0.85 · 37.8 · 60.6 | 0.86 · 38.3 · **62.6** | **0.70** · 37.7 · 60.1 | 0.70 · 38.4 · 61.1 | 0.72 · 38.4 · 61.3 |
| photos (2.8M) | 2.86 · 31.7 · **40.7** | 3.14 · 31.9 · 37.6 | 3.28 · 32.2 · 39.2 | 4.13 · 32.7 · 43.3 | 4.09 · 32.7 · 41.0 | 4.26 · 32.8 · 39.6 |

- **Text and dragging:** HEVC is 3–6 SSIMULACRA2 points better at equal or
  fewer bytes. AV1 often has the higher PSNR, but the perceptual score
  favours HEVC.
- **Scrolling:** AV1 is better: 26 % fewer bytes at slightly better quality
  (s9 VBR), or +4 SSIMULACRA2 at 10 % fewer bytes (s9 CBR).
- **Photos:** HEVC by bytes; AV1 VBR only matches it with 45 % more.
- **Speed 9** beats 10 by 2–3 points at the same encode time (2.3 ms at
  2880; 5K scroll-win 9.5 ms p50, photos 15.2 ms p50 / 24.8 ms p95, the same
  as speed 10). Speeds 8 and 7 gain nothing. The product uses speed 9.
- **VBR** saves bytes on text for some quality; the product keeps CBR, since
  the reason to choose AV1 is sharpness.

The first quick look (`aomenc` cq 30 against VideoToolbox at a fixed q75,
"AV2 on screen text" above) overstated AV1: fixed-q75 HEVC is far less
frugal than the product's average-bitrate HEVC.

**Headroom: aim at 40 % of the link** (after the first live test,
2026-10-25). Live on a ~10 Mbit/s, 70 ms link, AV1 felt less smooth than
HEVC. The Host's log showed why: CBR spent the link cap exactly (video
8.5 Mbit/s against an 8.6 Mbit/s measured link), so every burst queued and
the send gate skipped frames (`vskips` 17–73 per 2 s, 6–21 fps); HEVC
undershoots on its own and keeps headroom. Encode CPU wasn't the limit
(engine encode 7–18 %, libaom 2–8 ms a frame).

`replay --mode loop --link-mbit 10 --link-buffer-ms 500 --latency 30-40
--video vt|av1 [--av1-target-pct n] [--av1-vbr]`, 5K:

| trace | HEVC | AV1 at 100 % | AV1 at 60 % | AV1 at 40 % | AV1 VBR | AV1 VBR at 60 % |
|---|---|---|---|---|---|---|
| cursor-drag frames · video · queue p95 | 434 · 4.14 MB · 234 ms | 360 · 11.18 MB · 431 ms | 448 · 11.74 MB · 305 ms | **452** · 9.96 MB · 305 ms | 258 · 4.84 MB · 298 ms | 256 · 3.19 MB · 298 ms |
| scroll-win frames · video · queue p95 | 444 · 9.75 MB · 195 ms | 374 · 12.37 MB · 289 ms | 455 · 10.71 MB · 225 ms | **479** · 9.64 MB · 209 ms | 482 · 7.14 MB · 209 ms | 482 · 5.25 MB · 199 ms |

Quality at 40 % of a 10 Mbit/s cap (`vquality --mbit 4` at the time's
100 %, against HEVC at `--mbit 10`; achieved · PSNR · SSIMULACRA2):
cursor-drag AV1 1.32 · 49.0 · 82.2 vs HEVC 0.55 · 43.9 · 79.3; scroll-win
AV1 3.07 · 46.1 · 78.7 vs HEVC 3.67 · 43.5 · 78.2.

- With headroom AV1 delivers more frames than HEVC on both traces. On
  scrolling it also uses 16 % less bandwidth at slightly better quality; on
  dragging it is sharper for ~2.4× HEVC's bytes.
- VBR overshoots on single frames when a window is dragged, the burst
  queues, and the gate drops frames (258 of 434). It stays CBR.
- **VBR, second try** (asked in review). The loop now prints the gate's
  skips: on cursor-drag, VBR at 40 % sends 247 frames with **219 backlog
  skips** (CBR: 452 frames, 13 skips), none encoder-full, though VBR sends
  only 3.1 MB to CBR's 10 MB. The token bucket refills at the measured
  video rate, which settles at VBR's low average, so a drag's bursts find it
  empty. libaom's frame-size clamps can't help: `AV1E_SET_MAX_INTER_BITRATE_PCT`
  (150–300 %), `AOME_SET_MAX_INTRA_BITRATE_PCT` (300 %) and
  `rc_overshoot_pct` (10 %) left the VBR output byte-identical, since
  realtime libaom applies them only in CBR. On scroll-win VBR sent every
  frame (482) with 3.9–4.2 MB to CBR's 9.6 MB, so it would pay off if the
  gate tolerated its bursts.
- **Gate changes, tried and rejected.** `replay --timeline` now prints the
  gate's estimate, cap, cuts and skips each second. On cursor-drag the
  estimate never measures the link (0 link measurements in every run): it
  moves by cuts when a queue builds and by probes on "used" windows. Twice
  the trace's lossless tiles flood the shared bottleneck (network queue
  400–500 ms), and each time the video estimate is cut: HEVC and CBR take 2
  cuts and recover, VBR 6, ending at 0.6 Mbit/s. Two changes, over HEVC,
  AV1 CBR and VBR, on 10 Mbit/s (500 ms buffer, 30–40 ms) and 2 Mbit/s
  (2 s buffer, 75–100 ms, 1 % loss):
  - *Refused frames count as demand* (a window where the gate refused a
    frame on a clean path probes up, as one that used half the estimate
    does): HEVC and CBR unchanged on both links (2 Mbit/s cursor-drag HEVC
    321 frames either way, scroll-win 141 vs 143); VBR cursor-drag at
    10 Mbit/s worse, 247 → 175.
  - *The token budget binds only while the network shows a queue*: 10 Mbit/s
    unchanged (HEVC cursor-drag 434 → 441); 2 Mbit/s HEVC cursor-drag
    **321 → 224 frames**. The bucket is doing its job on thin links.

  Neither went in.
- **AV1 on a thin link loses to HEVC.** At 2 Mbit/s cursor-drag: HEVC 321
  frames, queue p95 532 ms; AV1 CBR 75 frames, 764 ms (scroll-win 141 vs
  141, 784 vs 1226 ms). AV1 is an option for a link with room; the Viewer's
  setting says so ("on a slow network, HEVC looks better").
- 40 % holds the frame rate as well as 60 % with more room, so the Host
  aims at 40 % of both the base bitrate and the link cap
  (`AOMRegionEncoder.targetPercent`). `vquality` and the loop default to it
  too; the tables above it ran at 100 %.

**Key frames:** capped at WebRTC's 3× an average frame, a region's first
frame came out unreadably soft (worst-frame SSIMULACRA2 30 on typing-cc and
cursor-drag at 3M). At 15× (1500 %, a quarter second at 60 fps) the worst
frame is 56, at about the same bytes. Kept at 15×.

### AV2 on screen text: AVM research-v15.0.0 (2026-10-25)

How much would a future hardware AV2 encoder save over today's video
path? An offline measurement, not a product option: AV2 has no
hardware encoder or decoder on any Apple chip and no VideoToolbox
support, and the only encoder, AOM's reference AVM, has no realtime
mode.

**Setup.** The first 30 frames of typing-cc and scroll-win, exported
with `glassact-bench y4m` (4:2:0, BT.709 video range) and cropped to the
top-left 1920×1080, on an M4 Pro. All low-delay (no B-frames or
lookahead). Y-plane PSNR against the source, via ffmpeg.

- **hevc-vt:** VideoToolbox hardware HEVC through ffmpeg
  (`hevc_videotoolbox -realtime 1 -bf 0`, `-q:v` 60–90), the encoder
  the Host ships.
- **hevc-x265:** x265 `medium`, `bframes=0`, no lookahead, crf 8–32.
- **av1-aom:** aomenc 3.x, good quality, `--cpu-used=6`,
  `--tune-content=screen`, `--lag-in-frames=0`, cq 40–60.
- **av2-avm:** AVM research-v15.0.0 (917ddae), built from source
  outside the repo, `--good --cpu-used=9 --tune-content=screen
  --lag-in-frames=0`, qp 120–230 (its 0–255 scale).

Bytes for 30 frames at matched PSNR (log-interpolated between
measured points; – means that encoder's range didn't reach it):

| clip | PSNR | hevc-vt | hevc-x265 | av1-aom | av2-avm |
|---|---|---|---|---|---|
| typing-cc | 56 dB | 557 KB | 171 KB | – | 30 KB |
| typing-cc | 60 dB | – (q90: 59.0 dB, 647 KB) | 233 KB | 141 KB | 38 KB |
| scroll-win | 56 dB | 461 KB | 141 KB | – | 53 KB |
| scroll-win | 60 dB | – (q90: 59.2 dB, 549 KB) | 189 KB | 113 KB | 66 KB |

libaom's screen tools put a floor near 58 dB even at cq 60, so it has
no 56 dB point.

Speed: hevc-vt ~100 fps, x265 ~120 fps, libaom ~25 fps, **AVM 0.09
fps** (four encodes of 4 threads in parallel; about 11 s per frame
with 14 threads).

**Reading it:**
- **On text, screen-content coding tools dominate.** AV2 at 60 dB is
  0.16× x265 on typing and 0.35× on scroll; AV1 is 0.6× on both. Against
  the hardware HEVC the Host ships, AV2 is about 9× (scroll) to 18×
  (typing) smaller at 56 dB.
- **The hardware HEVC encoder is itself ~3.2× bigger than x265** at the
  same PSNR. Some of every gap above is encoder effort, not the codec.
- **These are ceilings.** AVM's good mode searches far harder than any
  realtime hardware encoder will, and 30 frames of a 1080p crop is small.
  A hardware AV2 encoder would give back part of the gain.
- Nothing changes in the product. The video codec ids reserve AV1 for
  hardware encode (§3.8); AV2 would be another reserved id once hardware
  exists. Worth re-measuring when Apple ships AV1 or AV2 encode.

**Realtime speed at the sizes the Host sends.** The same day: 60 frames
of each trace at 5120×2880 and at 2900×1572 (a Scale/virtual-display
session's size), realtime low-delay settings, on the M4 Pro with nothing
else running. These timings come from command-line runs, file reading
included, so treat them as approximate. x265 used `-tune zerolatency`,
crf 20. libaom was the old engine's configuration: `--rt --cpu-used=10`,
screen tune, 8 threads, row-mt, 8 tile columns, cq 30. The hardware and
Apple software HEVC used `hevc_videotoolbox` at q75, the latter with
`-require_sw 1`.

| encoder | 2900×1572 fps | typing-cc | scroll-win | 5K fps | typing-cc | scroll-win |
|---|---|---|---|---|---|---|
| hardware HEVC (shipping) | ~79 | 2.17 MB · 46.2 dB | 2.16 MB · 47.5 dB | ~50 | 4.33 MB · 45.3 dB | 4.20 MB · 45.8 dB |
| Apple software HEVC | 14–15 | 2.51 MB · 38.0 dB | 2.36 MB · 39.5 dB | 6 | 5.91 MB · 38.6 dB | 3.88 MB · 40.7 dB |
| x265 ultrafast | 75–80 | 0.90 MB · 49.0 dB | 2.15 MB · 47.6 dB | 26–27 | 1.72 MB · 50.5 dB | 4.10 MB · 49.5 dB |
| x265 superfast | 66–71 | 0.60 MB · 50.3 dB | 1.36 MB · 49.0 dB | 23–24 | 1.02 MB · 52.2 dB | 3.28 MB · 51.0 dB |
| x265 medium | 32–35 | 0.63 MB · 50.8 dB | 1.00 MB · 50.9 dB | 11 | 1.10 MB · 53.1 dB | 1.87 MB · 54.2 dB |
| libaom AV1 rt, speed 10 | 129–136 | 0.80 MB · 50.5 dB | 0.90 MB · 49.6 dB | 61–62 | 1.19 MB · 53.0 dB | 1.00 MB · 54.6 dB |

- **x265 can't hold 60 fps at 5K.** Zero latency turns off frame
  threading, so even superfast runs at about 24 fps on every core. It's
  also GPL, which would change the licence of the Host binary.
- **Apple's software HEVC is unusable:** slower than the hardware encoder
  and worse.
- **libaom realtime is the only software encoder fast enough at 5K.** It's
  3.6–4× smaller than the hardware HEVC there, at 7–9 dB higher PSNR.
  That was the case for AV1 before it was retired on 2026-10-10 (the
  library-validation exemption, and software decode on M1/M2 Viewers).

**Software AV1 decode keeps up.** dav1d 1.5.4, one frame at a time
(`--framedelay 1`, as a live session decodes), on the libaom realtime
streams above plus Photos.app browsing (photos, the heaviest content).
Bitrates are the encoder's at cq 30, uncapped.

| stream | Mbit/s at 60 fps | 1 thread | 2 | 4 | 8 |
|---|---|---|---|---|---|
| typing-cc 2900×1572 | 6.4 | 415 fps | 741 | 1185 | 1175 |
| typing-cc 5K | 9.5 | 167 | 281 | 427 | 483 |
| scroll-win 2900×1572 | 7.2 | 328 | 619 | 986 | 904 |
| scroll-win 5K | 8.0 | 176 | 296 | 465 | 474 |
| photos 2900×1572 | 26.4 | 101 | 196 | 372 | 567 |
| photos 5K | 38.3 | 82 | 155 | 273 | 374 |

The worst case, 5K photos at 4 threads, uses about a fifth of four M4 Pro
cores at 60 fps. An AV1 Viewer wouldn't need AV1 hardware decode (M3 and
later). dav1d's output is YUV, which the Viewer would convert to BGRA
itself. Not measured on M1/M2 or Intel.

**libaom 3.15.2 corrupts screen content at these sizes.** With
`--tune-content=screen` in realtime mode (IntraBC on) and 2 or more
threads:
- **5K photos:** frames the decoders reject ("Invalid intrabc dv", in
  both aomdec and dav1d). Since 2026-10-12 libaom's main explains it:
  on frames wider or taller than 2048 pixels the nonrd IntraBC search
  could read past the DV cost table and pick a DV the decoder rejects
  (b57fd44).
- **2900×1572 photos:** silent drift. `aomenc --test-decode` reports an
  encode/decode mismatch from frame 2: with IntraBC and 2+ threads, the
  reconstruction stops matching the decoder until the next keyframe
  (3ca3bea).
- fb357ae (2026-10-21) also removes a thread-timing dependence in the
  same path.

One thread, or `--enable-intrabc=0`, avoids it, at a cost in speed or
in compression on text. 3.15.3-rc1 still corrupts 5K photos. libaom main
at 9ace39e (2026-10-24) is clean on every clip here: no decode errors,
and no `--test-decode` mismatch. A Host that ships AV1 needs a libaom
with those commits (or a pinned main) and a regression test that
round-trips 5K screen content.

### HEVC Main 4:4:4 for video regions: rejected (2026-10-25)

VMPal Remote (VMPal 0.97, static analysis) sends its screen as HEVC Main
4:4:4 when both ends can. Apple silicon's hardware encoder lists
`HEVC_Main444_AutoLevel` among its supported profiles (M4 Pro,
`VTCopySupportedPropertyDictionaryForEncoder`), though the SDK declares no
constant for it, and the M4 Pro decodes it in hardware (2940×1912 in about
10 ms). Two catches:
- With low-latency rate control the encoder quietly emits 4:2:0 from BGRA
  input; only 4:4:4 YUV input ('444v'/'444f', which VMPal converts to with
  `VTPixelTransferSession`) stays 4:4:4. The product doesn't use low-latency
  rate control, so BGRA works.
- Other Macs' decoders (Intel especially) are untested, so shipping it
  would need a caps bit and the 4:2:0 fallback.

`vquality --chroma444` (new bench knob), 200 frames, `--settle 6`, the
product's QP 34 cap, no low-latency, M4 Pro. Achieved bitrate (Mbit/s) and
SSIMULACRA2 mean / min; the target bitrate rarely binds, since the QP cap
does:

| trace | target | 4:2:0 | 4:4:4 |
|---|---|---|---|
| typing-cc | 1 | 0.45 · 65.7 / 37.5 | 0.57 · 67.8 / 40.7 |
| typing-cc | 8 | 0.57 · 77.2 / 54.7 | 0.77 · 79.8 / 54.5 |
| scroll-win | 1 | 1.95 · 50.8 / 48.8 | 2.17 · 54.2 / 52.1 |
| scroll-win | 3 | 2.71 · 66.9 / 48.8 | 2.93 · 67.5 / 52.1 |
| scroll-win | 8 | 4.23 · 75.4 / 61.0 | 4.97 · 78.0 / 61.8 |
| cursor-drag | 1 | 1.03 · 66.0 / 37.5 | 1.31 · 68.1 / 41.0 |
| cursor-drag | 8 | 1.29 · 76.8 / 54.5 | 1.74 · 80.0 / 55.1 |
| scroll v3 | 3 | 23.3 · 68.4 / 63.7 | 24.6 · 70.1 / 66.2 |
| photos | 3 | 8.13 · 36.4 / 28.7 | 8.97 · 39.8 / 32.2 |

4:4:4 scores 2–3.5 points higher at every setting, but spends 5–35 % more
to do it. At equal bytes 4:2:0 wins: typing-cc 0.57 Mbit/s is 77.2 for
4:2:0 against 67.8 for 4:4:4, and cursor-drag at about 1.3 Mbit/s is 76.8
against 68.1. Encode time is the same (p50 24–37 ms at 5K). What 4:4:4 does
better, crisp coloured text, Glass Act gets from the lossless tile handoff
and dissolve once motion stops; video carries motion, where the bits are
better spent on luma. Revisit if a trace of coloured text in motion (syntax
highlighting while scrolling) shows chroma fringing that SSIMULACRA2 misses.

### Small changes inside a live region: parked (2026-10-22)

Plane Wi-Fi, live: with only a terminal's spinner changing (3 rects, about 9
tiles), the region kept sending video at 577–890 Kbit/s, 9–11 fps, until it
dissolved. The idea (an `agy` analysis): send such sub-32-tile updates as
lossless tiles and let the encoder idle.

Measured first, with `synth --kind spinner` (new: a text page scrolls for
1.5 s, then only a 192×64 spinner changes at 10 Hz, frames only on change)
at 2900×1572, `replay --mode loop --video vt --link-mbit 8 --link-buffer-ms
2000 --latency 75-100 --drop 1 --golden --timeline`: the spinner phase sent
~9 video frames a second, and video bytes barely moved (the timeline's
running total stayed at 2 MB from the end of the scroll to the dissolve at
~3.6 s; 2.14 MB in all, 1.13 MB of it the cold-start sync frame). The
region dissolved on schedule and the screen was exact 100 ms after the last
frame. At `--link-mbit 2` the synthetic page's 1.13 MB keyframe fills the
link for the whole trace, so it says nothing about the spinner. (Real
terminal text compresses far better: the live keyframe at 1450×786 was
58 KB.)

So most of the live 0.6–0.9 Mbit/s was likely the re-sharpen keyframes the
next entry removes, plus the encoder refining a picture first coded under a
thin budget. Routing the small changes to tiles would also need the region
diff moved ahead of the tile pass: decided where it is now (after
`collectCandidates`), the records would wait for the next tick, and with
captures quiet the Host's drain ticks start only after 100 ms, which would
make a keystroke in a live region later. Parked until a live session after
the re-sharpen fix shows it still matters.
### Tile governor: high-RTT start and feedback cadence (2026-10-22)

Follow-up to **Tile governor on thin links: late ACKs, loss, slow start**
(2026-09-28). Apple M4 Pro, macOS 27.0.1, Xcode 27.1, release build;
builds and replays under `nice -n 15`. Baseline `2adf55e`. No hardware video
replays. All cases below use seed 1 unless the rig specifies its own seed.

The final HELLO/HELLO_OK exchange already seeds SRTT before any tile batch;
geometry negotiation restarts that exchange's send stamp. Use the same
sample to start Auto at 32,000 bytes / RTT when RTT is at least 150 ms,
with the existing 32 KB/s floor. That is about 183 KB/s at 175 ms and
46 KB/s at 700 ms. Shrink the initial tokens too, and seed the delay
baseline before the first congested tile ACK can define it. The minimum
bucket is now one RAW tile (16,384 bytes): the old 64 KB minimum alone
takes 1.75 s at 0.3 Mbit/s. The LAN's 2 MB/s start is unchanged.

Growth waits for max(200 ms, the path-delay EWMA) and honors the 400 ms
decrease hold. A gap longer than both recent-delay windows now expires the
old clean minimum; previously the first queued ACK after a quiet period
could still read zero standing queue and grow Auto. No change to the 0.9
drain factor, late-ACK measurement, wire format, or timeout commit rules.

**Why the new loop's queue p95 stays full.** Tiles-only replay still sends
a striped reliable keyframe plus a lossy first paint outside this governor.
Those bytes fill the shared bottleneck for roughly 19–31 s on these 5K
traces. The typing baseline's first measured tile path delay was 2.192 s,
accepted as the baseline; after the reliable startup drained, the minimum
returned to 166–178 ms. Its queued delivery samples then measured about
238–254 KB/s, so the drain factor was operating on the expected 250 KB/s
link. Late ACKs were reaching the sensor. An ending governor rate above
the line is not by itself a standing queue: it is a token refill budget,
and two open batches, admission estimates and capture gaps also limit the
actual traffic. The reliable startup, not that last rate sample, dominates
this replay's full-buffer p95. Fixing that startup stream is separate work.

Commands (the bench prints byte sizes as “MB”, actually MiB; rates below
are decimal MB/s). The governor summary now prints three decimal places
so thin-link rates are distinguishable. Rebuilding the original governor
with just that formatting change reproduced all baseline bytes and times.

```sh
nice -n 15 swift build -c release --product glassact-bench
nice -n 15 .build/release/glassact-bench replay \
  --trace "$HOME/Library/Application Support/Glass Act/traces/glassact-1786116323.scap" \
  --mode loop --link-mbit 2 --link-buffer-ms 2000 --latency 75-100 --drop 1 --golden
# Repeat for 1786116861 (cursor-drag) and 1786116475 (scroll-win).
# LAN: 1785962837, --mode loop --drop 5 --dup 1 --reorder 10 --latency 20-80 --golden
```

Every cell is **before → after**. “Settle” is the summary's total virtual
time; “last → exact” is the first exact canvas after the last captured frame,
which can precede final ACK/repair quiescence.

| trace | total bytes (MiB) | queue p95 / worst (ms) | bottleneck drops | last → exact (s) | governor at end (MB/s) | settle (s virtual) | settled byte-exact |
|---|---:|---|---:|---:|---:|---:|---|
| typing-cc, 1786116323 | 14.74 → 14.65 | 1,999 / 1,999 → 1,999 / 2,000 | 211 → 107 | 46.400 → 53.400 | 0.221 → 0.255 | 84.6 → 85.5 | yes → yes |
| cursor-drag, 1786116861 | 14.37 → 14.09 | 1,999 / 2,000 → 1,999 / 2,000 | 307 → 110 | 48.250 → 52.300 | 0.224 → 0.222 | 80.5 → 85.0 | yes → yes |
| scroll-win, 1786116475 | 8.80 → 8.79 | 1,999 / 2,000 → 1,999 / 2,000 | 189 → 25 | 22.550 → 24.400 | 0.958 → 0.221 | 54.2 → 55.7 | yes → yes |
| LAN, 1785962837 | 45.98 → 45.98 | no bottleneck | 0 → 0 | 0.200 → 0.200 | 32.000 → 32.000 | 21.1 → 21.1 | yes → yes |

Tile bytes: typing 7.29 → 7.20 MiB, cursor-drag 7.13 → 6.85 MiB,
scroll-win 4.22 → 4.20 MiB. Striped keyframes stay 6.40 / 6.23 / 3.75 MiB;
video and video sync frames stay zero. Still periods exact remain 0/2,
0/3 and 0/10, respectively (p50/max unavailable); LAN has 0/0. LAN datagrams
remain 52,698 sent, 2,590 randomly dropped, 488 duplicated: no bytes or
settle regression. Its isolated slow-start test still reaches ≥ 100 MB/s
in six 200 ms steps (1.2 s).

**Cost:** typing's first exact canvas is 15.1% later. Kept because the
smaller bursts and feedback holds prevent startup loss on the long, thin
paths below, and cut replay bottleneck drops by 49–87%; this is not a
claim that every exact settle is faster. Typing's fully quiescent settle
is only 1.1% later; cursor-drag's is 5.6% later and scroll-win's 2.8%.

**Governor rigs.** New `autoFollowsAHighLatencyLink`, seed 1408, 640×384
incompressible frames changing every 2.4 s for 12 rounds, 1% loss, two-second
buffer, reliable cold-start keyframes disabled to isolate tile admission:

| link / RTT | first-round worst queue (ms) | worst over all rounds (ms) | bottleneck drops | rate at end (B/s) | final canvas |
|---|---:|---:|---:|---:|---|
| 0.3 Mbit/s / 700 ms | 1,975 → 859 | 1,975 → 1,319 | 565 → 0 | 32,000 → 50,000 | exact → exact |
| 2 Mbit/s / 175 ms | 1,986 → 529 | 1,986 → 663 | 27 → 0 | 302,815 → 167,467 | exact → exact |
| 5 Mbit/s / 700 ms | 824 → 144 | 824 → 599 | 0 → 0 | 558,416 → 665,678 | exact → exact |

Existing `autoFollowsAThinLinkDown` (250 KB/s, no propagation latency):
350,750 → 224,480 B/s; worst backlog in the last three rounds 184 → 268 ms;
847 → 847 bottleneck drops; exact in both. The higher late peak is a cost
of the changed growth/ACK schedule, still below 0.3 s, while the ending
budget is now below the line. That rig's initial reliable cold start still
fills the buffer; it does not exercise a high-RTT handshake.

**Measured alternatives:**
- Lower start alone: typing 14.75 MiB / 49.900 s last → exact, queue p95
  still 1,999 ms. The 0.3 Mbit/s rig dropped only 7 datagrams instead of
  565, but still reached 1,959 ms of queue. Keeping the 64 KB burst floor
  after adding feedback pacing also left those 7 drops and 1,959 ms.
  Rejected as incomplete: the minimum bucket needed to shrink too.
- Freeze the baseline while queue > 20 ms, and pace growth by the baseline
  RTT instead of the delay EWMA: typing 14.65 MiB / 53.800 s last → exact,
  cursor-drag 14.10 MiB / 51.150 s, scroll-win 8.81 MiB / 25.100 s; all
  exact, all queue p95 1,999 ms. The 0.3 Mbit/s rig's worst queue improved
  to 859 ms, but a constant 175 → 700 ms route change still read 525 ms of
  queue after 30 s, versus zero with aging. Rejected: it cannot distinguish
  sustained queueing from a new route, and it did not solve the replay's
  reliable startup. Baseline aging remains; the 0.3 Mbit/s rig still has
  a late 1,319 ms excursion, so this is not a complete congestion controller.

Validation: `swift test --filter GovernorTests` passes all 34 tests,
including the slow rigs. The added unit cases pin LAN ramp time, the initial
flight, the handshake delay seed, long-RTT growth spacing, expiry after a
quiet gap, the growth hold after a cut, and learning a higher-RTT route.
`GLASSACT_FAST=1 swift test`, the five `QUICLoopbackTests` /
`QUICSustainedSessionTests`, and release `ScrollAllocationTests` (three
directions) pass. The package and tests also cross-compile with
`swift build --arch x86_64 --build-tests`; Intel performance and a live
plane session have not been measured.

### No re-sharpen for a dying region (2026-10-22)

Plane Wi-Fi, live: 6 re-sharpening keyframes in ~95 s, each followed 2–4 s
later by the region's dissolve, whose lossless repaint makes the screen
exact anyway. `refreshDue` fired on "quiet for 1 s after large changes"
without asking whether anything still kept the region alive; on a thin
link that's a full-screen keyframe for a second or two of sharper video,
sharing the bottleneck with the repaint behind it. It now also needs an
update of ≥ 32 tiles within the last 1 s (the record handoff's own test,
`handoffRecordActiveUS`). A busy panel on an otherwise still screen, the
case the re-sharpen exists for, still gets its keyframe
(`VideoRefreshTests.quietRegionGetsOneResharpeningKeyframe`); a large
change followed only by a spinner doesn't
(`aDyingRegionIsNotResharpened`, which fails without the guard).

`replay --mode loop --video vt --link-mbit n --link-buffer-ms 2000
--latency 75-100 --drop 1 --golden`, main (ae76a12) → guard. 6 Mbit/s for
5K is about the bits per pixel of the plane session's 2 Mbit/s at
2900×1572. All runs settled byte-exact.

| trace, link | total bytes | video sync bytes | re-sharpens | queue p95 | last frame → exact |
|---|---|---|---|---|---|
| scroll-win, 6 Mbit/s | 12.55 → 12.05 MB (−4.0 %) | 1.00 MB → 519 KB | 1 → 0 | 275 → 264 ms | 16.4 → 15.7 s |
| cursor-drag, 6 Mbit/s | 13.22 → 12.25 MB (−7.3 %) | 1.92 MB → 972 KB | 3 → 1 | 329 → 294 ms | 20.25 → 20.4 s |
| scroll v3, 6 Mbit/s | 5.40 → 5.13 MB (−5.0 %) | 535 → 269 KB | 1 → 0 | 325 → 323 ms | 5.6 → 5.6 s |
| typing-cc, 6 Mbit/s | 7.85 → 7.85 MB | 269 → 269 KB | 0 → 0 | 350 → 350 ms | 0.1 → 0.1 s |
| scroll-win, 20 Mbit/s | 17.80 → 17.21 MB (−3.3 %) | 1.34 MB → 772 KB | 1 → 0 | — | 9.35 → 9.25 s |
| cursor-drag, 20 Mbit/s | 14.59 → 13.35 MB (−8.5 %) | 2.04 MB → 937 KB | 3 → 1 | — | 7.4 → 7.35 s |
| scroll v3, 20 Mbit/s | 23.07 → 22.77 MB (−1.3 %) | 581 → 269 KB | 1 → 0 | — | 3.75 → 3.75 s |
| typing-cc, 20 Mbit/s | 7.91 → 7.91 MB | 269 → 269 KB | 0 → 0 | — | 0.15 → 0.15 s |

Not measured: how soft the screen looks between the motion stopping and
the dissolve's repaint landing (the loop has no quality metric); that
stretch is what the skipped keyframe would have sharpened.

### Thin-link loop: one bottleneck for tiles, video and control (2026-10-22)

Plane Wi-Fi (2026-10-22, live: 0.3–5 Mbit/s, SRTT p50 170 ms / p90 690 ms,
up to 4 s of queue) needed a bench that reproduces a thin link. The loop's
`InProcLink` had a bottleneck for tile datagrams only; video, most of the
bytes on such a link, bypassed it. Now `replay --mode loop --link-mbit n
--link-buffer-ms m` sends everything the host sends through one FIFO:
datagrams drop when it's full, control queues, and video waits in a send
buffer (`videoBacklogBytes`, which the video rate controller gates on). The
queueing feeds a modeled `transportRTT`, the controller's network-queue
signal. The summary adds bytes by kind, the queue's p95 and worst, and
"time to exact": in each still period (≥ 500 ms without a new frame) and
after the last frame, how long until the viewer's canvas is byte-identical
with no video over it. Without `--link-mbit` the output is unchanged
(typing-cc and cursor-drag, standard faults, `--video mock`: identical).

Baseline, `--video mock --link-mbit 2 --link-buffer-ms 2000 --latency
75-100 --drop 1`, all settled byte-exact:

| trace | tiles | striped keyframes | video | queue p95 / worst | datagrams dropped at the bottleneck | still periods exact | last frame → exact |
|---|---:|---:|---:|---|---:|---|---:|
| typing-cc | 7.58 MB | 6.40 MB | 0 | 2.0 s / 2.0 s | 483 | 0 of 2 | 51.1 s |
| scroll-win | 4.40 MB | 0 | 11.15 MB (2 sync frames) | 2.0 s / 2.0 s | 424 | 0 of 10 | 50.6 s |
| cursor-drag | 7.17 MB | 6.23 MB | 0 | 2.0 s / 2.0 s | 298 | 0 of 3 | 48.4 s |

At 5K, the cold start alone (a 6.4 MB striped keyframe, or two mock sync
frames) is ~25 s of a 2 Mbit/s link, so every trace spends its 30 s
catching up and the queue stands at the full buffer throughout. The mock
codec's frames are absolute LZ4 of the whole region (~5.5 MB each at 5K),
so mock video bytes say nothing about HEVC: video experiments on this rig
need `--video vt`.
### Auto-scale from the video drain too (2026-10-22)

Plane Wi-Fi, live (Host 26.10.2, laptop Viewer at 2900×1572): the video
rate controller measured the link at 0.3–5 Mbit/s (p50 2.2), with SRTT p50
170 ms, p90 690 ms, and spikes to 1.3 s. The resolution rung halved the
capture to 1450×786 only **45 s** after connect. The rung fired only on 6
consecutive seconds of severe (> 700 ms) tile ACK delay, while pinned video
carried most of the motion and the tile path was often quiet. The ACK
delay sat under 700 ms most seconds anyway (p50 170 ms).

Change (`ScalePressure`): also count seconds with a fresh video link
measurement whose drain is under 0.75 bit/s per captured pixel **and**
under 4 Mbit/s. Five in a row halve the capture. A measurement is a window
in which video stayed backlogged, so the link set the pace
(`VideoRateController.linkMeasurements`). The controller's estimate alone
isn't evidence: a backoff from its startup cap sets it with nothing
backlogged (Codex's review of #53). The per-pixel bar puts 2900×1572 at
3.4 Mbit/s (FaceTime's top screen-share tier is 0.87 bit/s per pixel). The
4 Mbit/s cap keeps a 5K capture on ordinary home Wi-Fi at native
resolution: that trade costs text sharpness and stays opt-in. Seconds
without a new measurement hold the streak, whether that's no video or a
quiet or paused region.

`ScalePressureTests` drives the real controller over a simulated link,
evaluated once a second:

| case | fires? |
|---|---|
| video backed up behind a 2 Mbit/s link, 2900×1572 | yes, within 10 s; once |
| busy video on a 100 Mbit/s link, 30 s | no |
| 5K capture on a 10 Mbit/s link, 30 s | no |
| quiet connect behind a 200 ms queue (estimate set by a backoff, nothing backlogged), then 30 s light | no |
| 3 thin seconds, 30 s paused, then thin again | holds, then fires |

No trace replay: the bench can't re-capture a trace at a lower resolution,
and its loop doesn't yet constrain video (a thin-link model is in progress).

### Prefer sharpness: a QP 28 ceiling on a link with headroom (2026-10-19)

Issue #4. The QP 34 frame ceiling keeps text legible on a thin link, but
with room to spare it still leaves the frame after a big change soft: on
typing-cc at 1 Mbit/s the worst frames score SSIMULACRA2 28–41 (the
SSIMULACRA2 entry below). With the Viewer's "Prefer sharpness" on, the host
now drops the ceiling to 28 once the link has shown headroom, and back to
34 at the first sign of pressure (DESIGN §4.6).

`glassact-bench vquality --mbit 6 --width 2880 --max-qp N`, 300 frames,
M4 Pro. Achieved Mbit/s, largest frame, then SSIMULACRA2 mean / p5 / min:

| trace | QP | achieved | max frame | SSIMULACRA2 |
|---|---|---|---|---|
| typing-cc | 34 | 0.27 | 179 KB | 78.4 / 78.8 / 50.2 |
| typing-cc | 30 | 0.25 | 258 KB | 77.5 / 77.7 / 63.6 |
| typing-cc | **28** | 0.24 | 304 KB | 76.8 / 76.8 / 68.5 |
| typing-cc | 25 | 0.25 | 385 KB | 76.8 / 76.6 / 73.7 |
| scroll-win | 34 | 3.27 | 155 KB | 77.3 / 76.8 / 60.0 |
| scroll-win | 30 | 3.25 | 215 KB | 77.3 / 76.2 / 71.0 |
| scroll-win | **28** | 3.24 | 247 KB | 77.4 / 76.5 / 74.5 |
| scroll-win | 25 | 3.26 | 304 KB | 78.0 / 77.5 / 77.4 |
| cursor-drag | 34 | 0.53 | 157 KB | 78.4 / 78.2 / 53.7 |
| cursor-drag | 30 | 0.54 | 230 KB | 77.7 / 77.6 / 64.1 |
| cursor-drag | **28** | 0.44 | 264 KB | 75.8 / 75.5 / 71.8 |
| cursor-drag | 25 | 0.48 | 333 KB | 77.1 / 77.0 / 76.4 |
| photos | 34 | 6.32 | 342 KB | 61.6 / 40.5 / 37.2 |
| photos | 30 | 7.14 | 342 KB | 67.0 / 58.0 / 55.5 |
| photos | **28** | 7.99 | 405 KB | 69.4 / 63.8 / 61.9 |
| photos | 25 | 10.69 | 469 KB | 73.6 / 71.6 / 70.3 |

- **Text:** the mean barely moves and neither do the bytes. The gain is
  the worst frame (the one after a big change), up 14–25 points at 28.
- **Photos:** the ceiling binds and costs bytes: +13 % at 30, +26 % at 28,
  +69 % at 25.
- **Largest frames grow** 1.6–1.9× at 28. They reach the link as one
  burst, so on a link that can't absorb them the send gate drops frames.
  That's why the ceiling waits for headroom and leaves at the first
  pressured window.
- **28, not 25:** most of 25's gain on text, at under half its cost on
  photos and with smaller bursts.

Gating, in `HostEngine.updateSharpCeiling`: on after 4 pressure-free
quality windows in a row (30 submitted frames each), off at the first
pressured one, and each fall-back doubles the next wait (up to 64
windows). Covered by `SharpCeilingTests`; VideoToolbox accepting the change
mid-session by `VTVideoTests.maxFrameQPChangesAtRuntime`.

### Allocation-free scroll ticks (2026-10-18)

Issue #3: the scroll path broke INV-7 on every heavy tick, and INV-7 listed
it as a known exception. Each item and what replaced it:

- **Row and column signature index** (`[UInt64: [Int]]`, one array per
  distinct signature, about one per row of the bbox) and the **vote
  dictionaries**: signatures go into a flat array sized to the canvas, and
  each probe compares only the shadow rows within ±600 of itself, the
  only ones it can vote for. Votes live in a flat array indexed by shift,
  and `takeBestShift` picks the winner with the old tie order and zeroes
  the votes as it reads them.
- **`probe2DShift`:** the per-probe sample arrays, the `Set<UInt32>` of
  distinct samples, a `Set<UInt8>` per 16-byte anchor window, and the
  `found`, `collected` and result arrays. These became preallocated
  sample, probe and candidate buffers, an open-addressed 512-slot table
  for the distinct count, a 256-bit seen-set on the stack, and stable
  insertion sorts that keep the old order.
- **Array literals** in `colSignature` and the corner checks.
- **SCROLL emission:** `ControlMessage.scroll` built two byte arrays per
  op. It now goes through a new `ControlFrames.scroll` into a reused
  buffer. One `Data` is left for the transport API, as for every datagram
  and every viewer control frame; INV-7 now says so.
- **The per-scroll marks array** (a new `ContiguousArray` per op) now
  comes from a pool. Each buffer has capacity for the whole grid and goes
  back to the pool on SCROLL_ACK or eviction.
- **SCROLL_ACK repair:** the `Set<Int>` of skipped tiles became per-tile
  marks.
- **Re-hashing after a scroll:** `emitScroll` re-hashed the whole worklist
  after appending the rect's static tiles. It now hashes only the
  appended ones.
- `cachePrefix`, also named in the issue, was already a preallocated
  16-byte buffer, so nothing changed there.

Allocations are counted with the new `replay --mode encode --count-allocs`.
It hooks libmalloc's `malloc_logger`, the hook MallocStackLogging uses,
while `encodeTick` runs. Counts are given for all threads. The
encode-thread share moves between runs, because `concurrentPerform` runs
some encode jobs on the calling thread. The all-threads totals repeat to
within one allocation.

| trace (5K), encode replay | ticks | before | after |
|---|---|---|---|
| scroll v3 at 22 Mbit, scroll ticks | 71 | 710,080 (p50 7,914/tick) | **613,509** (p50 6,462) |
| scroll v3 at 22 Mbit, other ticks | 1,009 | 7,459,609 | **6,372,006** |
| scroll-win at 22 Mbit, scroll ticks | 188 | 5,105,645 (p50 23,837/tick) | **4,103,829** (p50 18,226) |
| scroll-win at 22 Mbit, other ticks | 430 | 4,262,699 | **3,467,923** |
| typing-cc at 22 Mbit (no scrolls) | 265 | 68,908 | 68,907 |
| scroll v3 Auto, scroll ticks | 456 | 49,972,611 | **49,376,189** |
| scroll-win Auto, scroll ticks | 268 | 13,487,984 | **12,140,682** |

The savings are ~1,300 allocations per scroll tick on scroll v3 and
~5,000 on scroll-win, where the column and 2-D passes run. "Other ticks"
drop too, because they include heavy ticks whose detection found no
shift. What's left per tick is outside the scroll path: libwebp's VP8L
encodes, about 150 allocations each (typing-cc's 276 per tick is almost
all of it), one `Data` per datagram, and 4 allocations per
`concurrentPerform` fan-out. The fan-out cost was found here, applies to
every tick's hash and encode, and isn't listed under INV-7.

The scroll path alone is measured by
`INV_7_steadyStateScrollTickAllocatesOnlyTheControlFrame`
(`just test-alloc`, release, 1280×768): it counts allocations in a
steady-state `maybeEmitScroll` (detection, verification, emission and
re-hash) and in `repairAfterScrollAck` with two skipped tiles.

| tick | before | after |
|---|---|---|
| vertical scroll (row votes) | 779 | **2** (the SCROLL `Data`) |
| horizontal pan (column votes) | 1,694–1,821 | **2** |
| diagonal drag (2-D probe) | 2,097 | **2** |
| SCROLL_ACK repair, 2 skipped | 2 | **0** |

The counts are asserted only in optimized builds. At -Onone, xxh64's
streaming state alone allocates ~100 times per hashed row.

**Timing.** M4 Pro, release. Other agents were building and testing on
the machine throughout (load average 36–60), so before and after runs
were interleaved A B A B A B. Medians are given with [min–max]. Output is
byte-identical in every pair: same bytes, datagrams, tiles, scrolls and
satisfied tiles.

| trace, encode replay | before p50 / p95 (µs) | after p50 / p95 (µs) | encode CPU before → after |
|---|---|---|---|
| scroll v3, 22 Mbit | 9,213 [8,763–12,113] / 26,856 [24,975–59,296] | 9,069 [8,533–11,293] / 25,417 [24,815–68,361] | 40.56 [39.30–42.63] → 40.31 [39.43–41.09] s |
| scroll-win, 22 Mbit | 13,742 [13,703–13,967] / 38,493 [37,798–38,673] | 13,678 [13,530–13,747] / 37,585 [37,431–37,819] | 42.62 [42.59–42.83] → 42.45 [42.40–42.50] s |
| typing-cc, 22 Mbit | 1,141 [1,123–1,146] / 2,390 [2,269–2,884] | 1,145 [1,136–1,164] / 2,216 [2,127–2,279] | 4.00 → 4.01 s |
| scroll v3, Auto | 20,130 [19,491–20,557] / 57,112 [55,886–59,350] | 19,412 [18,891–19,487] / 56,366 [56,189–57,536] | 207.7 → 206.4 s |
| scroll-win, Auto | 17,246 [17,159–19,895] / 51,373 [49,474–87,991] | 17,987 [16,697–30,262] / 52,541 [49,589–104,823] | 69.3 → 68.4 s |

Every difference is within run-to-run noise. As the issue said, the
dictionaries were small in profiles: the codecs dominate encode time. The
change is about the INV-7 rule, not speed.

**Intel sanity check.** x86_64 build under Rosetta 2, on the M4 Pro, scroll
v3 at 22 Mbit, 5 interleaved pairs. These numbers say nothing about real
Intel cost. The runs fall into two groups by machine load (~11 ms and
~25 ms p50). The quietest runs were before p50 10.8 ms / 52.4 s CPU and
after 10.3 ms / 51.7 s. The medians were before 21.8 ms / 63.3 s and
after 12.6 ms / 53.3 s, which mostly shows which runs drew a busy
machine. Output was byte-identical. No regression is visible. The change
removes work and adds no SIMD or arch-specific paths.

**Goldens.** The standard faulted golden (`--mode loop --drop 5 --dup 1
--reorder 10 --latency 20-80 --golden`) on scroll v3 settled with a
byte-identical canvas at 45.98 MB, both before and after. On scroll-win
it did the same at 22.79 MB. Every datagram, drop, apply and ACK count is
identical. Host encode CPU in those single runs was 4,666 → 4,234 ms and
3,388 → 4,409 ms. The second pair ran alongside the full test suite, so
treat it as noise.

### SSIMULACRA2 in vquality: the SSIM-based video decisions re-checked (2026-10-18)

Luma SSIM on 8×8 blocks is weak at telling whether text has gone soft
(issue #13). `glassact-bench vquality` now also scores SSIMULACRA2 when an
`ssimulacra2` binary is on PATH (Homebrew's, from libjxl), or one named
with `--ssimulacra2 <path>`; `--ssimulacra2 off` skips it. It scores every
5th scored frame (`--ssimulacra2-every <n>`), plus the lowest-SSIM frame
and every `--settle` step, and prints mean / p5 / min next to the SSIM
line. The pairs go to a temp directory as PNG (ImageIO) and are scored
after the run, at most 6 processes at a time, so the encode-latency line
doesn't share the CPU with them. One 2940-wide pair takes 1.5–2 s on one
core, so a 300-frame run gains ~60 pairs and 20–30 s. Without the binary,
the output is unchanged. Scale: 100 is lossless, 90 visually lossless,
70 high, 50 medium, 30 low quality, and below 0 very strong distortion.

Apple M4 Pro, macOS 27.0.1, 2940×1652 canvas from the 5K traces (2880×1620
for half-res, as on 2026-09-29), 300 frames (typing-cc has 266). Other
work loaded the machine. Repeat runs gave identical numbers except in the
`--settle` tail, which varied (one run's 3 settle frames came to 62 KB,
an identical run's to 4 KB). Each cell below is SSIM, then SSIMULACRA2.

**QP 34 frame-QP floor: holds, more clearly than under SSIM.**
`vquality --trace <t> --width 2940 --mbit 1 [--kbit 300] [--submit-fps n] --max-qp 34|51`:

| trace @ cap, submit | max QP | achieved | SSIM mean / p5 / min | SSIMULACRA2 mean / p5 / min |
|---|---|---|---|---|
| typing-cc @ 1, all | none | 0.20 | 0.967 / 0.947 / 0.762 | 59.7 / 25.4 / −51.3 |
| | 34 | 0.21 | 0.972 / 0.957 / 0.926 | **63.1 / 49.8 / 28.1** |
| typing-cc @ 0.3, all | none | 0.21 | 0.945 / 0.813 / 0.729 | 46.0 / −31.6 / −60.6 |
| | 34 | 0.19 | 0.963 / 0.929 / 0.926 | **56.7 / 30.3 / 28.1** |
| scroll-win @ 1, all | none | 0.92 | 0.949 / 0.877 / 0.823 | 37.1 / −3.6 / −35.1 |
| | 34 | 1.15 | 0.965 / 0.963 / 0.955 | **49.9 / 49.0 / 40.8** |
| scroll-win @ 1, ≤ 5 fps | none | 0.88 | 0.967 / 0.880 / 0.823 | 52.9 / −35.1 / −35.1 |
| | 34 | 0.85 | 0.982 / 0.960 / 0.955 | **64.1 / 40.8 / 40.8** |
| cursor-drag @ 0.3, ≤ 30 fps | none | 0.37 | 0.954 / 0.901 / 0.750 | 49.8 / 13.1 / −58.6 |
| | 34 | 0.36 | 0.968 / 0.937 / 0.935 | **59.3 / 34.4 / 32.9** |
| photos @ 1, all | none | 1.05 | 0.822 / 0.710 / 0.692 | −7.7 / −53.8 / −55.7 |
| | 34 | 3.07 | 0.920 / 0.906 / 0.893 | **39.6 / 35.1 / 33.3** |

Without the floor, the worst frames score far below zero. SSIM called
them 0.73–0.82, which hides how bad they are. With the floor, the means
on text rise 3–13 points, for −10 % to +25 % bytes. One caveat for #4
(opt-in sharper video): even with the floor, the worst frames score only 28–41 (low
quality), and SSIM's 0.926 hid that. On typing-cc that worst frame is the
first keyframe (145 KB at QP 34). A lower ceiling for keyframes may be
worth measuring there.

**Capture-time PTS: holds.** The index clock (frames stamped n/60) was
measured with a temporary, uncommitted `--pts-index` patch, which does
what the removed `--pts index` did. Mean / p5:

| trace @ cap, submit | max QP | index/60: achieved, SSIM, SSIMULACRA2 | capture time |
|---|---|---|---|
| typing-cc @ 1, all | none | 0.15, 0.894 / 0.795, 13.1 / −44.9 | 0.20, 0.967 / 0.947, **59.7 / 25.4** |
| typing-cc @ 0.3, all | none | 0.05, 0.726 / 0.724, −60.5 / −60.7 | 0.21, 0.945 / 0.813, **46.0 / −31.6** |
| scroll-win @ 1, ≤ 5 fps | none | 0.07, 0.822 / 0.811, −37.2 / −41.8 | 0.88, 0.967 / 0.880, **52.9 / −35.1** |
| typing-cc @ 1, all | 34 | 0.15, 0.946 / 0.935, 41.9 / 32.7 | 0.21, 0.972 / 0.957, **63.1 / 49.8** |
| typing-cc @ 0.3, all | 34 | 0.11, 0.935 / 0.935, 32.8 / 32.7 | 0.19, 0.963 / 0.929, **56.7 / 30.3** |
| scroll-win @ 1, ≤ 5 fps | 34 | 0.49, 0.961 / 0.959, 45.0 / 44.3 | 0.85, 0.982 / 0.960, **64.1 / 40.8** |

Means rise 19–24 points under the floor, and far more without it. Both
metrics agree on the one small exception: with the floor, p5 and min drop
a little under capture time (scroll ≤ 5 fps: 44.3 → 40.8; SSIM 0.958 →
0.955). That comes from the first keyframe, which is also the worst frame
in the QP table above.

**Re-sharpen keyframe: holds, but the gain is small at QP 34.** The
content arrives as an inter frame after a blank keyframe:
`--width 2940 --kbit 3750 --from-black --frames 1 --settle 8 [--settle-sync]`
(3.75 Mbit/s is the startup cap).

| | typing-cc, QP 34 | scroll-win, QP 34 | typing-cc, none | scroll-win, none |
|---|---|---|---|---|
| arrival coding (what stays without a re-sharpen) | 0.934, 32.5 | 0.961, 45.6 | 0.893, 6.4 | 0.920, 18.9 |
| re-sharpen keyframe (`--settle-sync`, step 1) | 0.942, **40.2** | 0.964, **49.1** | 0.924, **28.8** | 0.958, **45.3** |
| same frame resubmitted every 250 ms, no keyframe, step 4 / 8 | 0.966 / 0.991, 57.7 / 79.4 | 0.980 / 0.994, 63.8 / 78.2 | 0.965 / 0.991, 57.7 / 79.4 | 0.979 / 0.994, 63.1 / 78.0 |
| keyframe first, then resubmitted, step 4 / 8 | 0.944 / 0.986, 41.3 / 75.3 | 0.966 / 0.994, 50.5 / 77.9 | 0.949 / 0.990, 45.5 / 78.8 | 0.976 / 0.994, 59.6 / 77.5 |

Both metrics rank the keyframe above keeping the arrival coding, so the
decision stands. Under the QP 34 floor, though, it moves typing only from
32.5 to 40.2: still low quality, which SSIM's 0.934 → 0.942 understated.
This run also differs from 2026-10-10 in one way. That entry found
resubmitting an unchanged frame gave skip frames (SSIM flat). Here, from
`--from-black --frames 1`, VideoToolbox refines the resubmitted frame to
~78–79 within 2 s, and forcing a keyframe first delays that (typing at
step 4: 41.3 vs 57.7). The Host doesn't resubmit quiet captures, so this
doesn't apply to the product as it is. "A few timed resubmissions of a
quiet region instead of one keyframe" is an idea to measure live, not a
change made here. The settle tail is the noisiest part of the bench (see
above), so re-run it before relying on it.

**Half-resolution encode: holds, more clearly than under SSIM.**
2880×1620 canvas, product defaults (QP 34), `--scale 100|50`. Each cell is
achieved Mbit/s, then SSIM mean, then SSIMULACRA2 mean / p5:

| trace @ cap | full res | half res |
|---|---|---|
| typing-cc @ 1 | 0.20, 0.970, **62.5 / 50.1** | 0.08, 0.903, 26.6 / 27.3 |
| typing-cc @ 3 | 0.21, 0.987, **76.0 / 76.7** | 0.10, 0.917, 32.7 / 32.7 |
| scroll-win @ 1 | 0.97, 0.970, **54.5 / 49.5** | 0.82, 0.917, 25.4 / 16.8 |
| scroll-win @ 3 | 2.51, 0.989, **72.0 / 63.6** | 1.39, 0.927, 30.5 / 29.8 |

On text, half res tops out near 30, the cost of the resample round trip.
Full res reaches 54–76 at the same caps.

All four decisions stand, and the decisions table is unchanged.
SSIMULACRA2 separates the cases much more widely than SSIM does on text.
It also shows that the worst frames under the floor, and the single
re-sharpen keyframe, still look low quality. That is the gap #4 should
tune against.

### Real-codec loop: VT output on the rig's thread, awaited before time moves (2026-10-18)

Issue #6: `replay --mode loop --video vt` sometimes failed the viewer under
CPU load. The cause was in the bench, not the engines. The loop gave
`VTHEVCRegionEncoder` a private callback queue, so
`HostEngine.videoEncoderDelivered` ran on a GCD thread while the main thread
drove the same host engine and the `InProcLink` event queue. A ThreadSanitizer
build of the old bench reported 17 races on a typing-cc run (the link's
`pending` array, `claimsInFlight`, `regionFramesPending`, the video rate
controller) and then trapped. A lost or torn video message breaks the ordered
video stream: the viewer reports undecodable frames, or fails outright with
"malformed video stream". SYNC_REQUEST (#21) recovers the undecodable case,
but not a malformed stream.

The fix: the bench's VT encoder delivers on the main queue, the rig's engine
queue, as the VideoRegionEncoder contract requires. After each `encodeTick`
the loop waits in real time until every submitted frame is delivered. A
frame now lands at its submit's virtual instant, as with the mock, so encoder
latency under load no longer slides frames along virtual time. The 0.5 ms
sleep per virtual millisecond is gone, so an unloaded cursor-drag run takes
~37 s of wall time instead of ~56 s. The summary gains `undecodable` and
`sync requests` counts (both should be 0, because the bench's video channel
is lossless) and a `vt:` line with submit time, wait time and stalls. A
failed `--golden` names the viewer's failure reason.

Standard faults, `--video vt`, 6 runs in parallel plus 16 `yes` processes
(load average ~90–115), the same 16-run trace mix (6 cursor-drag, 5
scroll-win, 3 typing-cc, 2 photos):

| | viewer `.failed` | runs with undecodable frames | host encode p95 |
|---|---|---|---|
| before | 1 / 16 (cursor-drag, "malformed video stream" at 2.1 s; never settled) | 3 / 16 (11 frames, 4 sync requests) | 7–13 ms |
| after | 0 / 16 | 0 / 16 | 19–94 ms (heavier load in that batch) |

Without faults (8 runs each, under the same load), both settled 8/8. Earlier
before-runs (20 runs: 8 lightly loaded, 12 under `yes` load) settled 20/20.
The race needs load to show. A TSan build of the fixed bench is clean (0
reports) and settles typing-cc byte-exact.

Bytes are unchanged within real-codec noise: typing-cc 8.85 MB, cursor-drag
16.88–16.92 MB (reference 16.81). Goldens are byte-exact: typing-cc and
scroll-win tiles-only, typing-cc and cursor-drag `--video vt`. The host encode
CPU isn't affected. Three cursor-drag runs at the same moment (awaited
output, awaited with a busy-poll, and the old no-wait pipelining done safely)
gave encode p95 7.4 / 7.0 / 7.5 ms and totals of 3.18 / 3.15 / 3.07 s.

### macOS 27 VideoToolbox: constant quality and super-resolution — neither usable (2026-10-10)

**`kVTCompressionPropertyKey_ConstantQualityFactor` (new in 27): a no-op
for us.** Measured with `glassact-bench vquality` on an M4 Pro: 2940-wide
canvas, 300 frames of each reference trace, caps of 1 and 12 Mbit/s, new
knobs `--cqf`, `--cqf-vbv` and `--no-realtime`.

- **With our average bitrate set,** the factor is accepted but every run
  is **byte-identical** to the product at cqf 50 and 70, on all four traces
  and both caps.
- **Without an average (`--cqf-vbv`, the cap as `VBVMaxBitRate`),** cqf 5,
  50, 70 and 90 land within noise of each other (scroll @12M: 5.76 / 5.78 /
  5.86 Mbit/s, SSIM 0.997 throughout). This holds with RealTime on or off
  and with or without the QP floor.
- **The VBV peak isn't enforced in realtime either:** photos ran at
  17.4 Mbit/s under a 1 Mbit/s cap. That mode is just VideoToolbox's
  default quality with no rate control, so it's unusable behind a send
  gate.

Apple's `kVTCompressionPreset_ConsistentQuality`, read back from
`SupportedPresetDictionaries`, pairs the factor with `LookAheadFrames = 8`.
That is ~130 ms of added latency, which a live screen can't take. Our
average bitrate + QP 34 floor + re-sharpen keyframe stays. The knobs
remain in the bench for re-checking on later OS releases.

A side observation: on the light traces the product spends far under its
cap (typing @1 Mbit/s: 0.17 Mbit/s at SSIM 0.973). Headroom exists there,
but none of the new knobs is a controlled way to spend it.

**`VTLowLatencySuperResolutionScaler`: too small for a screen.** It
reports factors 1.5×, 2× and 4×, but input is capped at 1280 px and at
960 px for 2× (921,600 px). `supportedScaleFactors(frameWidth:frameHeight:)`
returns none for 1470×956, 1920×1080 or 2560×1440. Half of the 2940
canvas can't go in, so "send half-res on a bad link, upscale on the
viewer" is out. It's built for camera-sized video. The non-realtime
`VTSuperResolutionScaler` is 4× only, needs a downloaded model and is
meant for offline video.

### AV1 encoder re-check: libaom 3.15.1 vs SVT-AV1 4.2.0 (2026-10-10)

Is libaom still the fastest AV1 encoder for screen content? Yes. The
inputs were the first 240 frames of each reference trace at
5120×2880, exported with `glassact-bench y4m`, on an M4 Pro.

libaom ran with the engine's settings: `--rt`, screen tune,
`--threads=8`, row-MT, 8 tile columns, no lag, `--end-usage=q`,
cq 30. PSNR is Y-plane PSNR, decoded with dav1d.

| trace | cpu-used 10 | cpu-used 11 | cpu-used 12 |
|---|---|---|---|
| typing-cc | 94 fps · 1191 KB · 52.7 dB | 110 fps · 1223 KB · 52.7 dB | same as 11 |
| scroll-win | 87 fps · 2072 KB · 52.0 dB | 88 fps · 2117 KB · 51.9 dB | same as 11 |
| photos | 57 fps · 15.3 MB | 58 fps · 15.2 MB | same as 11 |
| cursor-drag | 111 fps · 1211 KB · 52.9 dB | 111 fps · 1256 KB · 52.9 dB | same as 11 |

Speed 12 produces byte-identical output to 11 with screen tuning.
Speed 11 buys almost nothing over 10, so the engine stays at 10.

SVT-AV1 4.2.0 used the first 120 frames of scroll-win with
`--rc 0 --crf 40`. libaom cpu-used 10 at cq 30 on the same frames
gave 42 fps, 1347 KB, 52.0 dB.

| SVT mode | speed | size | PSNR |
|---|---|---|---|
| `--rtc 1 --preset 8 --scm 1` | 12.7 fps | 1593 KB | 48.4 dB |
| `--rtc 1 --preset 13 --scm 0` | 14.3 fps | 8108 KB | 43.4 dB |
| `--pred-struct 1 --preset 13 --scm 1` | 14.4 fps | 3454 KB | 44.6 dB |
| `--pred-struct 1 --preset 11 --scm 1` | 11.7 fps | 3454 KB | 44.8 dB |

SVT-AV1 is a poor fit for this workload, for two reasons:

- **Screen-content tools are off at fast presets.** In realtime mode
  at preset 9 and above it logs "Screen-content detection and tools
  are disabled for RTC mode coding at M9 and above".
- **Low-delay throughput is capped at about 14 fps at 5K.** The preset
  barely changes it. Its strength is frame-parallel random-access
  encoding, which a screen share can't use.

Its best mode is 3× slower than libaom, bigger, and 3.6 dB worse.

**Hardware.** No Apple chip through M6 has an AV1 encoder; Apple's
specs list AV1 decode only. On this M4 Pro, `VTCopyVideoEncoderList`
lists no AV1 encoder (only avc1, hvc1, ProRes and JPEG). **AV2** 1.0
(May 2026) has only the reference encoder, which is nowhere near
realtime.

Conclusion: keep libaom for software AV1 and hardware HEVC as the
default. To ship AV1 in a signed Host without
`disable-library-validation`, bundle a libaom we sign ourselves
instead of loading Homebrew's.

*Later the same day:* AV1 was retired instead. The libaom shim, AV1
decode, the size gate and `--video av1` were removed along with the
Host's library-validation exemption. The AV1 codec id and caps bit stay reserved on the wire for
hardware AV1 encode.

### Per-tile handoff inside a live video region (2026-10-10)

The re-sharpen made a long-lived pinned region tolerable; this makes its
still majority exact. Video frames now carry **claims** (the tiles they
changed, as region-relative runs; a generation's first frame claims all),
and an overlay viewer stamps only claimed tiles — an unclaimed tile keeps
showing its exact canvas copy. The host hands a tile that has been still
for 1 s back to exact by **REVEAL** (new video message, ordered after every
frame that claimed it) when the canvas already holds its content — free —
else by an ordinary lossless record that wins at the viewer by being newer
than the claim. Wire change (breaking; both apps ship together).

Record handoffs are gated after measuring them ungated: only once the
region has had no large update (≥ ¼ of its area) for 2 s **and** a real
change in the last second keeps it alive, with per-tile backoff (a tile
reclaimed within 10 s of its record doubles its threshold, to 16 s).
Ungated, photos went 38 → 95 MB and host encode p95 5 → 20 ms (lossless
copies of photographic tiles overwritten seconds later); a region whose
motion had just stopped also paid ~2× its dissolve repaint for the same
tiles.

`replay --mode loop --video vt --pinned`, standard faults (5 % drop, 1 %
dup, 10 % reorder, 20–80 ms), `--no-handoff` for before. Video coverage =
share of screen-time presented from video during the trace.

| trace | coverage off → on | bytes off → on | host encode p95 off → on | settled |
|---|---|---|---|---|
| panel (synth, 2900×1556: page replaced, then one 24 % × 67 % panel animates for 30 s) | 99.7 % → **23.9 %** | 289.48 → 289.55 MB | 1.85 → 1.87 ms | both byte-exact |
| cursor-drag | 90.1 % → **41.5 %** | 16.72 → 16.81 MB | 4.9 → 4.5 ms | both |
| typing-cc | 11.6 % → 11.6 % | 8.85 → 8.85 MB | 6.3 → 6.4 ms | both |
| scroll-win | 99.6 % → 99.2 % | 18.34 → 18.40 MB | 4.0 → 4.0 ms | both |
| photos | 99.6 % → 99.6 % | 38.02 → 38.19 MB* | 6.5 → 5.4 ms | both* |

(* photos with the final gating: no record handoffs fire; 8 + 4 reruns
settled byte-exact. The synthetic panel's video bytes are high because it
redraws random text at 60 fps.) Scroll and photos keep their coverage: they
move nearly all the time, which is what video is for; the handoff targets
the case the live session hit — a small area keeping a full-screen region
alive. Tests: `VideoHandoffTests` (reveal, record, faults ×2 seeds,
re-claim then exact, backoff — the first two fail with the handoff pass
disabled), `VideoTests` claims/reveal round trips and malformed bodies.
`glassact-bench replay` gained `--pinned`, `--no-handoff`, `--handoff-ms`,
`--timeline`; `synth --kind panel`.

### Soft video for minutes: capture-time PTS, QP 34 floor, re-sharpen (2026-10-10)

Live (viewer logs 2026-10-09 12:36 PDT and 2026-10-10 10:04 PDT; host log
10:04–10:12): text unreadable for 8–19 minutes on a **healthy** link —
g2g p50 18–34 ms, no loss, vlink ~15 Mbit/s, vcap 11–14 Mbit/s — while the
pinned region carried 0.4–1.8 Mbit/s at ~55 fps and **zero** lossless
records were applied. Not the settle: the logs' lossless repaints drained
~1,000 tiles in 2–5 s. Three causes:

1. **The encoder's clock.** VT frames were stamped `frameIndex / 60` while
   real captures arrive irregularly (traces: 8–20 fps) and newest-wins
   skips drop more on a thin link. VT spends its average bitrate over
   presentation time, so it used 5–60 % of the cap. `vquality --pts index`
   vs capture time, 2940-wide canvas (SSIM mean / p5):

   | trace @ cap, submit | old clock: achieved, SSIM | capture time |
   |---|---|---|
   | typing-cc @ 0.3 Mbit, all | 0.05 Mbit, 0.728 / 0.725 | 0.21, **0.946** / 0.811 |
   | typing-cc @ 1 Mbit, all | 0.15, 0.892 / 0.780 | 0.22, **0.967** / 0.941 |
   | scroll-win @ 1 Mbit, ≤ 5 fps | 0.07, 0.821 / 0.800 | 0.71, **0.978** / 0.936 |
   | cursor-drag @ 0.3 Mbit, ≤ 30 fps | 0.11, 0.741 / 0.726 | 0.33, **0.930** / 0.836 |

   Fixed: frames carry their capture time (`encode(bgra:forceSync:timeUS:)`).

2. **No quality floor.** With correct stamps a frame-QP ceiling of 34 is
   byte-identical at 12 Mbit/s on all four reference traces (it never binds
   on a healthy link), and at 1 Mbit/s lifts the worst frames: typing min
   0.757 → 0.926 (same bytes), scroll p5 0.910 → 0.964 (+30 % bytes),
   cursor-drag min 0.778 → 0.928 (+23 %), photos p5 0.706 → 0.902 (2.5×).
   Bytes over the cap come out of frame rate through the send gate.
   The 2026-09-29 cost estimate (2.5–15×) was measured under the old clock.
   Default now (`VTHEVCRegionEncoder.defaultMaxFrameQP = 34`).

3. **Static content is never re-coded.** Resubmitting an unchanged frame
   yields skip frames (SSIM flat over `--settle 8`). Live, the first capture
   was a blank virtual display (`first video frame: 1 KB keyframe`); the
   content then arrived as inter frames under the 3.75 Mbit/s startup cap,
   and everything but one animating 704×1024 strip kept that coding for the
   rest of the session. `--from-black`: the content's first frame reads
   0.879 (QP 34: 0.924); a keyframe once quiet (`--settle-sync`) re-codes it
   at 0.975–0.985. Host now owes one re-sharpening keyframe when the region
   has been quiet ≥ 1 s (only updates under ¼ of its area) after large
   changes covering ≥ 10 % of it, or after the cap has doubled since the
   last keyframe — at most every 5 s. `VideoRefreshTests` (fails without).

### LZBITMAP: is the Apple-only codec worth keeping? (2026-10-06)

Question (multi-platform planning): LZBITMAP (opcode 0x09) is the one tile
payload a non-Apple peer couldn't decode. How far ahead is it?

Standalone, per changed tile (`glassact-bench codecs --frames 120`, Brotli
added): LZBITMAP is **not** the smallest — zlib, Brotli and LZFSE are all
smaller on every trace; its edge is speed.

| trace | lz4 | lzbitmap | lzfse | brotli | zlib |
|---|---|---|---|---|---|
| typing-cc B/tile | 1477 | 1125 | 1091 | 1030 | 934 |
| scroll-win B/tile | 1440 | 1024 | 993 | 933 | 873 |
| photos B/tile | 9187 | 7067 | 6753 | 6813 | 6373 |
| cursor-drag B/tile | 6550 | 4556 | 4253 | 4305 | 3920 |
| encode MB/s (range) | 1179–3612 | 390–669 | 154–278 | 225–722 | 81–272 |

In the encoder's best-of (`replay --mode encode`, cold start excluded;
`--no-lzbitmap` drops it, `--bitmap-codec` swaps another codec into its
slot — bench-only knobs). Tiles sent vary with pacing, so B/tile is the
comparison:

| trace | LZBITMAP | none | Brotli in its slot | zlib in its slot | host encode CPU (LZBITMAP → none) |
|---|---|---|---|---|---|
| typing-cc | 153 | 154 (+0.7%) | 149 | 146 | 4.0 → 3.9 s |
| scroll-win | 213 | 223 (+4.7%) | 255 (+20%) | 246 | 68.9 → 53.1 s (−23%) |
| photos (total MB) | 1641 | 1665 (+1.4%) | 1618 (−1.4%) | 1626 | 289.6 → 230.9 s (−20%) |
| cursor-drag | 1248 | 1391 (+11%) | 1203 (−4%) | 1176 (−6%) | 30.1 → 24.3 s (−19%) |

Dropping it costs ~1–11% of tile bytes and saves ~20% of host encode CPU.
A cross-platform codec in its slot recovers it on typing, photos and drags
but not on scroll-win, where Brotli does worse than nothing: the encoder's
adaptive VP8L routing (probe backoff when a cheaper codec wins) interacts
with what sits in that slot, so a replacement needs the routing re-tuned
with it, not a drop-in swap. zlib compresses best but costs ~1.5× the CPU.
Kept for now (Mac-only peers; bitrate efficiency is the default). If
non-Apple peers arrive, a platform-agnostic codec such as zlib or Brotli
replaces LZBITMAP in its slot, with the VP8L routing re-tuned alongside
it (the numbers above).

### Video startup: 3 Mbit/s cap until the link is measured (2026-09-30)

Live on a phone tether: the encoder ran at its
20 Mbit/s base until the controller measured the link, so the first
keyframe and the frames behind it queued in the path — 3–13 fps, SRTT
142 → 262 ms, and the viewer's first-interval glass-to-glass p95 1.5 s
(max 1.6 s): "a couple/few seconds" from HELLO to a picture.

`VideoRateController` now caps the encoder at 3 Mbit/s before the first
measurement and ramps it ×1.25 per 250 ms window while the path is clean
(raw queue reading < 30 ms) and video is carrying at least half the cap —
3 → 20 Mbit/s (then uncapped, exactly as before) in ~2 s of motion; a static
screen doesn't ramp. During the ramp a standing queue is read with a 100 ms
filter instead of 1 s (the 1 s filter let the ramp fill a bottleneck's
buffer); the first pushback measures the link and the normal controller
takes over. `VideoStartupTests` (fast link uncapped < 3 s; static screen
stays at 3; a 6 Mbit/s link overshot once to ~9, then rides 5.6–6.3 with
the queue < 0.2 s).

Relay rig (`VideoSendGateTests`, 3 Mbit/s, 64 KB buffer, 40 ms/way) —
the worst case for this change, since the link equals the startup cap:

| p95 one-way video delay | before | after |
|---|---|---|
| from t = 0 (startup included) | 574–755 ms | 145–673 ms |
| steady state (from 3 s) | 61–67 ms | 59–64 ms |

The rig's score now starts at 3 s (it was 1.5 s, which hid the old start's
transient and caught the new ramp's single overshoot).

Follow-up, same day (first live connect on it): a 208 → 24 ms
network queue over the first ~8 s while video sent ~27 KB/s — the queue
wasn't ours. The unmeasured cut started from that sample and hit the
0.3 Mbit/s floor; 80 s later the gentle probe had reached only 1.7 Mbit/s
(clean 2–6 ms queue, soft video). Now an unmeasured cut starts from the
startup cap when it's higher, and a standing queue cuts only while it
could be ours: something backed up here, or ≥ half the rate handed in some
window of the last second (one window misjudges: right after a cut the
gate makes it look quiet — relay p95 79–137 ms that way).
`VideoStartupTests.aQueueAtAQuietStartKeepsAUsableCap` (fails with either
half removed). Relay rig steady state, 6 runs each: 58–84 ms (median 65)
vs 59–70 ms (median 62) — within the rig's noise. The display re-apply
settle is also 0.5 → 0.15 s (the revert at that connect cost 45
full-screen frames in the first 2 s).

### Stale tiles: damage from skipped captures is carried forward (2026-09-30)

Live: "every once in a while a tile stays out of date". Dirty rects are
deltas against the previous capture, and two places threw a capture's rects
away while keeping only the newer frame: the host app's latest-frame slot
(an undrained frame superseded by the next) and the engine's early returns
before candidate collection (INV-4 skip — `capture-drops` ran at 26–62 per
2 s in that session — REFRESH_HINT throttle, pause). A tile that changed in
the dropped capture and not again was never hashed again: stale until
touched. Tests never saw it because the settle harness ticks with
`dirtyRects: nil` (a full scan).

- Engine: skipped ticks' rect tiles (`missedDirty`) join the next tick's
  fresh candidates; a skipped tick without rects forces a full scan. The
  region's change probe counts the same damage (else the overlay reveal
  could trust a stale last region frame).
  `INV_4_droppedCaptureDamageStillRequalifies` (fails without it).
- Host app: the slot keeps superseded frames' attachments (not their pixel
  buffers) and drain() unions their rects in; >16 superseded → full scan.

LAN faulted golden, scroll 1785962837 (`--mode loop --drop 5 --dup 1
--reorder 10 --latency 20-80 --golden`, before/after run concurrently):
45.98 MB both, settled byte-exact both, host encode 5,474 → 5,645 ms
(noise; concurrent runs). The replay never drops a tick carrying rects, so
it doesn't exercise the bug — the INV test does.

### Video cap: CUBIC-style recovery after a hiccup (2026-09-29)

Live: a 2 s network stall (RTT 61 → 257 ms) cut the video cap to 0.3
Mbit/s, and at the gentle 1.03 per 250 ms window it took ~60 s to climb
back to 2.6 — the viewer showed low quality at a good frame rate for a minute.

`VideoRateController` now remembers the rate the link last pushed back at
(CUBIC's W_max: set on a backoff that follows a probe, or the first; a
stall's first measurement remembers what was being sent). A cut landing
below 40 % of it (a hiccup — the saw-tooth never cuts that deep) probes at
×1.15 per window until 70 %, then gently. Repeated cuts while the stall's
queue drains don't reset the memory.

| sim (3 Mbit/s, 0.3 for 2 s, then 3) | back to 70 % of the pre-hiccup rate |
|---|---|
| gentle only (×1.03) | 9.25 s after the stall |
| recovery (×1.15 below 40 → 70 %) | 2.0 s after the stall |

Link that really slows (3 → 1 Mbit/s): late mean 146 KB/s on 125 KB/s —
not over-probed. Relay rig p95 59–63 ms (unchanged). First design ("best
clean rate" memory, fast below 80 %) recovered too but was inflated by
startup bursts: relay p95 60 → 134–430 ms; rejected.

### Fresh-before-owed admission; video cap on an unmeasured queue (2026-09-29)

Live on a ~150 ms-RTT tether (viewer log): glass-to-glass
p50 90–150 ms (mostly path), but 0.6–1.8 s spikes right after each dissolve
— the repaint's owed tiles were admitted in the same rotation as fresh
changes, so keystrokes queued behind catch-up — and video uncapped
(`vlink unmeasured`) while the network queue stood at 80–100 ms.

- Admission: this tick's dirty-rect tiles first; owed tiles (repaint,
  carry) after, at most 50 ms of the send rate per tick.
  `AdmissionPriorityTests.freshChangeShipsAheadOfOwedRepaint` (fails
  without the ordering).
- VideoRateController: a standing network queue caps even an unmeasured
  link, starting from the rate actually being sent; that signal is the
  minimum reading over 1 s (jitter spikes don't count). A measured link
  keeps reacting to the raw reading — any filter there delayed backoff:
  relay rig (3 Mbps, 64 KB buffer) p95 54 → 156–475 ms at a 300 ms window;
  raw: 61–63 ms. `VideoQueueSignalTests` (standing queue caps; jitter
  doesn't; each fails with its rule removed).

LAN faulted golden, scroll 1785962837: 45.98 MB, settled byte-exact at
21.1 s, host encode 4,260 ms — identical to the previous build.

### Video-layer quality floor: VT MaxAllowedFrameQP (2026-09-29)

`glassact-bench vquality --max-qp N` (2880×1620, 300 frames, target 2 / 6
Mbit/s). `kVTCompressionPropertyKey_Quality` is accepted but inert while an
average bitrate is set (byte-identical output). A frame-QP ceiling works —
and is a hard floor that overrides the bitrate target.

| trace @ target | max QP | achieved | SSIM mean / p5 / min | max frame |
|---|---|---|---|---|
| typing-cc @2 | — | 1.22 | 0.965 / 0.902 / 0.880 | 80 KB |
| typing-cc @2 | 25 | 1.16 | 0.986 / 0.986 / 0.986 | 350 KB |
| cursor-drag @2 | — | 1.17 | 0.969 / 0.925 / 0.887 | 71 KB |
| cursor-drag @2 | 25 | 1.14 | 0.987 / 0.987 / 0.987 | 313 KB |
| scroll-win @2 | — | 2.04 | 0.959 / 0.933 / 0.917 | 76 KB |
| scroll-win @2 | 30 | 5.05 | 0.986 / 0.985 / 0.984 | 207 KB |
| scroll-win @2 | 25 | 9.13 | 0.992 / 0.992 / 0.992 | 295 KB |
| photos @2 | — | 2.10 | 0.795 / 0.704 / 0.690 | 72 KB |
| photos @2 | 30 | 14.79 | 0.953 / 0.946 / 0.940 | 254 KB |
| photos @2 | 25 | 29.08 | 0.976 / 0.972 / 0.965 | 434 KB |

Text + small motion: QP 25 is nearly free in bytes and removes the quality
collapse after big changes (p5 SSIM 0.90 → 0.99). Heavy content: the floor
costs 2.5–15× the target, and keyframes grow 2–5×. Safe only when the link
has headroom.

### Video-layer quality: low-latency RC and half-res encode, measured (2026-09-29)

New `glassact-bench vquality`: trace frames → VideoToolbox HEVC (the host's
`VTHEVCRegionEncoder`) at a target average bitrate → the viewer's
`VTRegionDecoder` → luma SSIM (8×8 blocks) and PSNR vs the source. Canvas
2880×1620 (the live Client Resolution size), 300 frames at 60 fps, M4 Pro.
`--scale 50` encodes at half size and scales back (vImage Lanczos) for
scoring. Question from a per-title-ladder article: at thin-link rates, is a
sharp half-res picture better than a starved full-res one?

SSIM mean (achieved Mbit/s), normal rate control:

| trace | target | full res | half res |
|---|---|---|---|
| scroll-win | 1 | 0.910 (1.01) | 0.901 (1.00) |
| scroll-win | 3 | 0.981 (3.01) | 0.924 (2.86) |
| cursor-drag | 1 | 0.929 (1.00) | 0.894 (0.46) |
| typing-cc | 1 | 0.920 (1.07) | 0.878 (0.47) |
| typing-cc | 3 | 0.974 (1.36) | 0.903 (0.56) |
| photos | 1 | 0.740 (1.26) | 0.746 (1.03) |
| photos | 3 | 0.832 (3.06) | 0.836 (3.04) |
| photos | 6 | 0.887 (6.07) | 0.874 (6.06) |

Half res tops out near SSIM 0.93 / 27 dB on text (the resample round trip
itself); full res passes that at 1 Mbit/s. Only photographic content gains
(+0.003–0.006 SSIM ≤ 3 Mbit/s, PSNR still lower). **Not built** — screen
sharing is mostly text.

Low-latency rate control (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`,
accepted for HEVC on this macOS): overshoots the target 20–100 % on text and
9× on photos (1 → 9.25 Mbit/s), frame-size SD 2–3× and single frames of
117–190 KB (0.6 s of a 2.5 Mbit/s link), no latency gain (p50 12.6 vs
13.1 ms). At equal achieved bytes it roughly ties normal mode on text.
**Left off** (`VTHEVCRegionEncoder(lowLatency:)` stays for re-measurement).

Also visible: normal-mode VT undershoots on text (typing-cc: 6 Mbit/s target
→ 1.43 achieved, SSIM 0.983) — text quality there is set by VT's own rate
control, not the link.

### Tile governor on thin links: late ACKs, loss, slow start (2026-09-28)

Plane Wi-Fi, live (2 Mbps, deep buffer): a pinned dissolve repaint went out
at 7.8 Mbps; Auto halved 8.4 → 1.0 MB/s and stopped at its floor, 4× the
link. The datagram path queued 2.4 s, batches timed out into re-encodes,
PONGs missed for 10 s and the host reset — scrolling "disconnected". The
viewer read 1.3 s p50 / 12.8 s p95 glass-to-glass before the reset.

Rig (`GovernorTests.autoFollowsAThinLinkDown`: 250 KB/s bottleneck, 2 s
buffer, a 1 MB incompressible change every 2.4 s) reproduced it: rate stuck
at 8.4 MB/s, the buffer parked full (2.05 s every round), 84,910 drops.
Root cause: every ACK arrived after its batch timed out (timeouts follow PING
SRTT on the uncongested control connection) and was ignored — the delay
signal read 0 while the link sat 2 s deep.

Changes: late ACKs for timed-out batches still measure path delay and
delivery (never commit tiles); a sizable mostly-lost timed-out batch sent
after the last cut halves the rate; floor 1 MB/s → 32 KB/s; bucket = 0.25 s
of the rate (64 KB – 16 MB); growth once per 200 ms (the queue sensor's
window) and decreases held 400 ms; slow start from 2 MB/s doubling until
the first backoff (the old 8.4 MB/s + 16 MB start could queue 10+ s on a
thin link before the first ACK). Pinned formation counts governor-deferred
demand; pinned mode no longer forms hot-map partial regions.

| thin-link rig | rate at end | worst backlog, late rounds | drops |
|---|---:|---:|---:|
| before | 8.4 MB/s | 2,057 ms (buffer full) | 84,910 |
| after | 224–350 KB/s (link 250) | 183–380 ms | 1,077 |

LAN regression check, `glassact-bench replay --mode loop --drop 5 --dup 1
--reorder 10 --latency 20-80 --golden`, release, M4 Pro:

| trace | bytes | host encode CPU | governor at end | settled byte-exact |
|---|---|---|---|---|
| 1785962837 before | 49.64 MB | 4,571 ms | 8.4 MB/s (0 deferred) | yes (21.2 s) |
| 1785962837 after | 45.98 MB | 4,242 ms | 32 MB/s (7,379 deferred in slow start) | yes (21.1 s) |
| 1786116475 before | 23.64 MB | — | — | yes |
| 1786116475 after | 22.99 MB | — | — | yes |

Cost: a LAN session's first full-screen change is paced over ~1 s of slow
start instead of one 16 MB burst (deferred tiles re-qualify against the
current frame; nothing is lost). Unit tests of scroll/webp/pacing logic that
assume a one-tick full-frame send use `HostEngine.assumeFastLinkForTests()`;
the streams prototype (no path samples) keeps the old start.

### Video send gate: time at the drain rate, not bytes (2026-09-28)

First real remote session (MacBook Air on airport Wi-Fi → Tailscale, direct;
PING SRTT 200–300 ms; pinned full-screen HEVC, 2940×1652): the link carried
2–3 Mbps and glass-to-glass p50 swung from ~40 ms to **1.6–2.2 s** for 30 s at
a stretch, with zero drops. Cause: the video gate allowed 512 KB of unsent
video once SRTT > 50 ms — 1.6 s at 2.5 Mbps — and the HEVC ladder bottomed out
at 6.6 Mbps, above the link.

Probe (`VideoQueueProbeTests`, now `VideoSendGateTests`; before the fix): the
transport's `videoBacklogBytes` matches the stream's data-transfer-report
`sentApplicationByteCount` to within a frame, so the host always saw its send
queue — the limit's unit was the bug. The report's smoothed − minimum RTT tracks
the bottleneck queue per ACK (PING SRTT: 1/s, EWMA of 8 → seconds late). No
wire change needed; VIDEO_ACK not built.

Fix: `VideoRateController` (drain-rate estimate from backlogged windows; token
bucket at it; backlog ≤ 60 ms of it; encoder AverageBitRate cap 0.85× with
DataRateLimits; queue-scaled backoff when transport RTT − min > 60 ms; gentle
probe when app-limited and clean). Quality ladder pressure is standing queue
> 45 ms instead of SRTT > 45 ms. QUICTransport exposes `transportRTT` from
250 ms data-transfer reports.

Relay rig: 3 Mbps bottleneck, 64 KB drop-tail, 80 ms base RTT, ~10 Mbps
offered, frames after the first 1.5 s:

| gate                         | frames delivered (6 s) | p50 one-way | p95 one-way |
|------------------------------|-----------------------:|------------:|------------:|
| old (512 KB bytes)           | 66                     | 1,900 ms    | 2,100 ms    |
| new (time @ drain, 4 runs)   | 231                    | 53 ms       | 56–60 ms    |

Tuning on the way (same rig): backlog limit alone kept QUIC fed and the
bottleneck at 130–170 ms standing (p50 525 ms) → token bucket; the first
estimate reads ~2× the link (QUIC's opening burst into the buffer) and fixed
0.85 backoffs took 3 s → queue-scaled backoff (≥ 0.5×); probe 1.05/250 ms
overshot into drop-tail loss (p95 183–583 ms) → 1.03 and threshold 60 ms.
Not yet confirmed live when this was written.

### Live A/B: Viewer main thread (same-machine loopback, 2026-09-27)

Host + Viewer (Release) on one M4 Pro at 5K: the Host shares the display
the Viewer's own window sits on — a pinned-HEVC "hall of mirrors", a
continuous heavy load. Viewer main thread sampled 20 s per run (`sample`),
two interleaved runs per build:

| Viewer | main blocked in `queue.sync` | main idle |
|---|---|---|
| before | **89–92 %** | 5–7 % |
| blit off main | 6–8 % (the 1 Hz title poll) | 89–92 % |
| + async title / configure polls | **0.0 %** | 97–98 % |

Before, the Viewer's main thread spent ~90 % of the session waiting for
the apply queue — window, input and cursor barely serviced. The remaining
blocker after the blit move was the title-bar bandwidth poll's
`queue.sync` (and the connect-time configure poll, which ran exactly
during the cold-start keyframe decode); both are async now.

Glass-to-glass did NOT change measurably (p50 105–240 ms, p95 450–1260 ms
across all runs): this workload is latency-noisy, and the apply queue does
the same work either way. The session log shows why latency is high here:
under the mirror load the blit on the apply queue takes 16–19 ms p50 and
presents fall to 6–10/s. A real two-machine run is the latency test.

**Viewer session log** (for real-network tests): `~/Library/Logs/Glass Act/
viewer-<date>.log` (today: Viewer › Help › Show Logs in Finder). Header (build hash,
model, OS, displays, flags), status / reconnect events, and every 5 s a
`key=value` line: engine deltas (rx Mbit/s, datagrams, records applied /
stale / NACKed, reassembly expiries, DELTA / cache misses, video frames /
drops / decode failures, keyframes, ACKs), glass-to-glass p50/p95/p99/max,
presents, blit time, blit→flip, main-thread stalls (20 ms probe: max,
> 50 ms, > 250 ms), occlusion / throttle, host clock offset; session_end
totals on quit (SIGTERM / Ctrl-C quit gracefully).

### Present blit off the main thread (2026-09-27)

The display link ran `controller.queue.sync { blit }` on main: main did
the canvas → IOSurface copy AND first waited for the apply queue to be
free — behind a keyframe decode or a datagram burst, that is the whole
decode time with the window, input and cursor frozen. The blit now lives
in `GlassActCore.SurfacePresenter` (two IOSurfaces, buffer-age dirty union),
confined to the engine's queue where the canvas lives; each display tick
starts at most one blit there asynchronously and main only flips
`layer.contents` when it lands (a generation counter drops blits for a
pre-resize presenter). The next blit still starts on the next tick, so a
surface is never written while displayed — same double-buffer timing.

Full 5K blit (59 MB, warm surfaces, release): **4.1 ms** — the per-frame
main-thread cost removed on full-screen changes, plus any apply-queue
wait. The apply queue still pays the copy (it did before too, blocked by
the sync). `SurfacePresenterTests`: every presented surface equals the
canvas across 60 randomized updates. Not yet measured in a live session.

### Auto bounded by encode headroom (2026-09-27)

Follow-up to the effort-sweep note: on a fast, queue-free link Auto grew
until the governor stopped binding and heavy churn stopped being
subsampled — an encode-only replay of scroll v3 sent 392 MB at 220 s of
encode CPU for a 20 s trace. Every admitted byte is a tile encoded, so
Auto's growth is now bounded by **encode duty** (real encode time /
capture interval, EWMA): grow only below 50 %; above 75 % shrink ×0.85 per
decision even without a network signal, never below the old ladder's
2.8 MB/s base. Duty is measured only when the host injects a timer (the
app's real clock; `glassact-bench replay --encode-headroom`); tests and
golden replays have none and stay deterministic.

Encode-only replays, Auto, instant ACKs (a fast queue-free link), M4 Pro:

| trace | free: bytes / encode CPU | bounded | final rate, duty |
|---|---|---|---|
| scroll v3 | 392 MB / 220 s | **62 MB / 51 s** | 2.8 MB/s (floor), 80 % |
| cursor-drag | 81 MB / 29.7 s | **52 MB / 22.5 s** | 9.1 MB/s, 8 % |
| scroll-win | 68 MB / 67.5 s | 67 MB / 67.3 s | 2.8 MB/s, 19 % |
| typing-cc | 8.0 MB / 2.6 s | 8.0 MB / 2.7 s | 8.4 MB/s, 2 % |

Deterministic engine test (`autoStopsAtEncodeHeadroom`, a scripted cost of
1 ms per tile sent): unbounded Auto ran to the 125 MB/s ceiling; bounded,
it held 9.1 MB/s at 54 % duty — where that cost fits a 16 ms tick. The
host status line now shows `encode N%`.

### VP8L effort sweep → tick-size / rate policy (2026-09-27)

libwebp lossless presets (`WebPConfigLosslessPreset` 0–9 → method/quality)
were fixed at 4 for tiles, DELTA sub-rects and keyframe stripes. Swept with
`glassact-bench replay --vp8l-effort N --keyframe-effort N` (encode-only,
`encode cpu` = process CPU inside encodeTick incl. its workers).
**Encode-only runs now need `--limit-mbit 22` to compare with history**:
the old ladder never boosted on instant ACKs (it required a nonzero ACK
delay), so historical encode numbers are at 2.8 MB/s; Auto on an instant-
ACK "link" grows without bound (see the note at the end).

Tile effort vs 4, at 22 Mbit (bytes / encode CPU):

| effort | typing (steady) | scroll-win | cursor-drag | scroll v3 |
|---|---|---|---|---|
| 0 | +31 % / same | +6.6 % / −60 % | +3 % / −56 % | +5.2 % / −55 % |
| **1** | +5 % / same | **+1.5 % / −23 %** | **+0.6 % / −40 %** | **+0.4 % / −23 %** |
| 2 | +4 % / same | +1.1 % / −14 % | 0 % / −28 % | +0.1 % / −17 % |
| 3 | 0 / same | 0 / −1 % | 0 / −2 % | 0 / +1 % |
| 5–6 | 0 / +1 % | 0 / +19–29 % | 0 / +74–121 % | 0 / +6–9 % |

Keyframe effort (5K cold start, one 6.1–6.2 MB keyframe):

| effort | cold tick (typing / drag) | keyframe bytes |
|---|---|---|
| 4 | 728 / 916 ms | 6.24 MB |
| 1 | 424 / 429 ms | +2.6 % |
| 0 | 188 / 192 ms | +11 % |

Time to exact ≈ encode + bytes / rate: effort 0 beats 1 above ~2.2 MB/s,
1 beats 4 above ~0.5 MB/s.

**Policy (defaults; `vp8lEffort` / `keyframeEffort` override):** tiles use
effort 4 on ticks of ≤ 32 qualifying tiles (typing stays byte-optimal) and
1 above; keyframes use 0 when the governor's rate is ≥ 2.5 MB/s, else 1.

| 22 Mbit, policy vs all-4 | encode CPU | p95/batch | cold tick | steady bytes | total |
|---|---|---|---|---|---|
| typing-cc | 5.74 → 2.62 s | 2.34 → 2.33 ms | 707 → 191 ms | identical | +9 % (keyframe) |
| scroll-win | 91 → 68 s | 58 → 50 ms | 706 → 169 ms | +1.6 % | +2.3 % |
| cursor-drag | 35.6 → 19.7 s | 46 → 30 ms | 720 → 186 ms | +0.9 % | +2.4 % |
| scroll v3 | 65.5 → 48.7 s | 33 → 29 ms | 375 → 96 ms | +1.0 % | +4.1 % |

Goldens byte-exact (mock, vt). 

**Note — Auto on a fast link sends much more under heavy churn.** With
instant ACKs (an infinitely fast, queue-free link) Auto grows until the
governor stops binding: scroll v3 sent 359–392 MB vs 55 MB at 22 Mbit,
at 3–14 cores of encode CPU. The old governor's temporal subsampling of
heavy churn was saving bytes AND host CPU; on a real LAN the engine's own
tick time and INV-4 bound this, but Auto trades host CPU for freshness
there. Follow-up: "Auto bounded by encode headroom".

### PROTOTYPE: tile records over QUIC streams (2026-09-27)

Question: should pixels leave hand-managed datagrams (INV-5) for QUIC
streams? Built behind a flag (`PixelTransport.streams(frameBytes:)`,
default `.datagrams`; host app: `GLASSACT_PIXEL_STREAMS=1`): each batch rides
its own host-opened stream as `u16 len ++ datagram bytes` frames; the
viewer parses frames into `onDatagram`, so engines, records and ACKs are
unchanged. A transport reporting ≥ 16 KB frames lifts the 1200 B budget
(whole-tile frames, no fragmentation). Test tooling: `LossyRelay` (seeded
UDP loss + delay, user space) and `QUICTransport.overrideMaxUDPPayload`
(real-network 1452 B packets on loopback).

**Transport cost only** (100 MB pushed, no engines, loopback):

| | wall | CPU / MB | callbacks |
|---|---|---|---|
| datagrams (pace 120 MB/s) | 1.16–1.19 s | 13.8–13.9 ms | 91 175 |
| streams, 1200 B frames | 0.71 s | 1.9 ms | 87 375 |
| streams, 16 KB frames | 0.69–0.73 s | 1.7–1.8 ms | 6 400 |
| streams, 16 KB frames, **1452 B packets** | 0.68 s | 3.7 ms | 6 400 |

Caveat found: loopback's ~16 KB MTU lets QUIC pack stream data into huge
packets — a real 1500 MTU erases part of the win (1.8 → 3.7 ms/MB). And
datagram mode at 1452 B packets was not measurable on loopback: most runs
delivered 2–4 % with the pacing ring overflowing, one run 100 % — an
unexplained NW datagram-path behavior to check on a real link.

**Engines over loopback QUIC** (2048² noise, full-frame rounds):
datagrams ~740 ms/round; streams (1200 B) 510–575 ms; streams (32 KB)
450–500 ms, 16× fewer frames. Process CPU ~3.5 s/round in every mode
(dominated by encode + the test loop, not transport).

**Under loss** (relay, 15 ms each way, streams, 1452 B packets):
- 0 %: every round converges (1.3–2.9 s), 84 MB sent (≈ minimum).
- 1 % / 3 %: NO round converged within 30 s. QUIC's congestion control is
  loss-based: random loss reads as congestion (theory for a Reno-like
  controller at 1 % loss / 30 ms RTT: ~0.6 MB/s) and retransmits stale
  pixels; the design's datagram path instead re-encodes and doesn't slow
  for random loss. Datagram mode couldn't be compared through the relay —
  its per-packet rate saturates the relay itself (79 % delivered with no
  loss configured).

Two engine fixes the prototype needed (kept, flag-scoped): the host's
batch timeout allows a reliable carrier 4 MB/s instead of the pacer's
rate, and on timeout the batch's stream is reset (`abandonBatch`); and
Auto takes no path-delay samples from a reliable carrier — they count the
stream's own transmission as queueing, halved the rate to its floor, and
stopped a clean 30 ms-RTT session converging by the 3rd change
(`PixelStreamTests`, verified to fail without the fix).

**Verdict:** don't switch. Streams cut transport CPU 4–7× and are
faster on clean paths, but on a lossy path — the one Glass Act's loss model
exists for — they stall. Keep INV-5. Worth a real-Wi-Fi A/B (Air;
`GLASSACT_PIXEL_STREAMS=1`) before closing the door, and worth borrowing the
cheap part: fewer, larger receive units (e.g. a stream only for cold-start
/ settle bursts on a clean path).

*2026-10-13:* the prototype was removed (wire v3; viewers no longer accept
`0x54` streams); the results stay in this log. Issue #10 tracks whether
to revisit.

### Auto send rate replaces the fixed 25 Mbit ladder (2026-09-27)

The P6e governor refilled at 2.8 MB/s (×3 "boost" = 8.4 MB/s on a prompt
path), so every LAN session was capped: a sustained full-screen change
settled in 1–5 s on loopback. Now a policy: `RateLimit.auto` (default) or
a true cap (`.megabits(n)`; Host menu → Bandwidth; `glassact-bench replay
--limit-mbit n`). Auto starts at the old boost (8.4 MB/s) and:
- grows ×1.25 while admission is actually deferring tiles and the path
  shows no standing queue (< 20 ms);
- drops to 0.9 × delivery rate when a queue builds (> 60 ms) — only if it
  was limiting (an app-limited sender's delivery rate is just what it sent);
  otherwise ×0.9; halves above 200 ms; floor 1 MB/s, ceiling = the
  transport's pace (≤ 125 MB/s).
The queue is STANDING path delay: min over ~200–400 ms of (ACK time −
the datagram's estimated departure from the pacer) minus the 10–20 s
minimum. Two dead ends first: the per-batch ACK delay grows with our own
pacing of a big batch; and a mean read 20–80 ms of random latency as
30–60 ms of "queue" — auto collapsed to its floor on the faulted golden
replays until the short-window minimum replaced it (`jitterIsNotAQueue`).

Loopback QUIC, 2048² noise, 6 back-to-back full-frame rounds:

| | limit 25 Mbit | auto |
|---|---|---|
| rounds 1–5 | 2.35–3.98 s | **0.74–0.77 s** |
| governor rate | 3.1 MB/s | 8.4 → 16.4 MB/s (stops growing once not binding) |

Modeled 20 MB/s bottleneck with an 8 MB buffer (`autoSettlesNearABottleneck`):
rate settles at ~0.9 × the bottleneck, the network backlog doesn't ratchet
up change over change. Real 5K traces (glassact-1785962837, -1786116475,
standard faults): identical under auto and the 25 Mbit limit — every change
fits the 16 MB bucket, the governor never binds (0 tiles deferred).

### CACHE REF now beats DELTA (2026-09-27)

Found while building the engine fuzz corpus: the host consulted its tile
cache only for tiles not coded as DELTA (a STORE can't wrap a DELTA — but
the REF lookup was skipped too). With DELTA negotiated, as the apps do,
every tile with an ACKed base had a DELTA available, so content reverting
to a cached state (blinks, window switch-back) shipped a DELTA instead of an
11-byte REF. Test: `refBeatsDeltaForRevertedContent` (0 → 4 REFs).

`glassact-1785962837`, full loop, fault-free, mock video (deterministic; ×3 runs
identical):

| | before | after |
|---|---|---|
| CACHE REFs | 16,088 | 49,979 |
| DELTAs | 106,904 | 77,500 |
| REF misses / NACK repairs | 0 / 0 | 0 / 0 |
| bytes out | 58,276,646 | 57,275,246 (−1.7 %) |

Faulted runs (5/1/10 %, 20–80 ms) move ±2 % either way across seeds 1–3:
any byte change reshuffles which datagrams the seeded injector drops, so
fault-free is the comparison that means something here. Canvas byte-exact
in every run.

### Cold-start phantom loss: stale send stamps + pacer overflow (2026-09-27)

Instrumented round 0 of the 2048² loopback QUIC run: zero datagrams reached
the viewer before it was running, zero kernel socket-buffer drops, and
sent − received was exactly accounted for by the host:

1. **Pacer queue overflow (1,431 datagrams).** The cold-start batch (14,336
   datagrams) plus the second open batch exceeded the 16,384-slot queue,
   which dropped the oldest — the first batch's next-to-leave datagrams.
   Fix: INV-4 extended to the pacer — encode ticks are skipped while the
   transport holds > 20 ms of backlog at the current pace (a batch encoded
   then would only wait behind it); queue raised to 32,768 so one
   governor-admitted batch (≤ ~20 MB) always fits.
2. **Stale send stamps (the rest, and the pace cut).** A batch's
   `sendTimeUS` was the tick's *start*. That cold-start tick spent 2.3 s
   encoding incompressible noise, so the next tick saw a 2.3 s-old batch and
   timed it out before the viewer's first ACK: every tile re-sent, and the
   adaptive pace read the timeout as 100 % loss and halved. Same flaw for
   keyframes. Fix: `HostEngine(clock:)` stamps batches/keyframes at hand-off
   (app + QUIC tests pass `MonotonicClock`; virtual-time tests keep nowUS);
   ages clamp at 0 when a caller's `nowUS` predates the stamp.

Loopback QUIC, 2048² noise, 6 back-to-back full-frame rounds (2 runs):

| | unpaced | fixed pace | adaptive | + both fixes |
|---|---|---|---|---|
| datagrams sent (86,016 needed) | ~146k | ~93k | ~90k | **86,016** |
| lost / redundant | — | — | ~2.7k in round 0 | **0 / 0** |
| all 6 rounds | ~28 s | ~24.5 s | ~19 s | **~11 s** |
| pace | — | 50 | 25 → 36 | 53 → 71 (probing, no cuts) |

Round 0 (2.7 s) includes the 2.3 s encode. Tests: `SendStampTests` (slow
tick: 25 sends, was 50 without the clock), `encoderWaitsOutThePacerBacklog`
(fails without the gate). Golden replays unaffected (virtual time, no
clock, no bottleneck).

### Adaptive datagram pacing (2026-09-27)

`PaceController` (host engine) steers the transport's pace from each large
batch's final loss (ACK bitmaps): > 10 % lost → move toward the observed
drain `rate × (1 − lost) × 0.9`, at most halving; clean and ≥ 2 MB → +1/16;
2–10 % → hold (path noise). Only batches sent at the current rate count
(no double cuts from in-flight batches). Bounds 10–120 MB/s, start 50 MB/s.
The batch timeout's serialization allowance uses the pace in effect at send.

First cut probed up on any clean batch > 256 KB: the pace hit the 120 MB/s
ceiling within one round (those batches fit the ~768 KB receive buffer at
any pace, so "clean" proved nothing), and the next burst lost ~1.5k
datagrams. Probing now requires ≥ 2 MB batches.

Modeled slow viewer (`InProcLink.Bottleneck`: 15 MB/s drain, 768 KB buffer;
1280² noise, 6 full-screen changes after idle, `AdaptivePacingTests`):

| | fixed 50 MB/s | adaptive |
|---|---|---|
| overflow drops per change | 11,292 every round | 4,765 → 167 / 711 / 0 / 167 / 711 |
| datagrams sent, 6 changes | 129,360 | 51,380 |
| final pace | 50 MB/s | 16.0 MB/s |

Loopback QUIC, 2048² noise, 6 back-to-back full-frame rounds (2 runs):

| | unpaced | fixed 50 MB/s | adaptive |
|---|---|---|---|
| round 0 (cold) | 6.5 s | 3.4 s | 2.2 / 2.7 s |
| cold-start datagrams lost | ~6k | ~4.4k | ~2.7k |
| all 6 rounds | ~28 s | ~24.5 s | 18.5–20 s |
| bytes out | ~170 MB | 111 MB | 106.5–107.5 MB |
| pace | — | 50 | 25 after the cold burst, probing to 36 |

The round-0 cut was attributed here to a slow cold-start viewer. Wrong —
it was phantom loss from the host itself; see "Cold-start phantom loss".
Round times alternate ~1 s / ~5 s with the governor bucket, not pacing.
Golden replays unaffected: InProc links without a bottleneck don't pace
(`pacesDatagrams == false`), and their timeout arithmetic is unchanged.

### Datagram pacing: burst loss at the viewer's receive buffer (2026-09-27)

Found by the `NetworkConnection<QUIC>` spike (see that entry). Unpaced,
`sendDatagrams` handed a batch to NW in ~0.01 ms and the whole thing left at
once; the viewer's UDP receive buffer (`net.inet.udp.recvspace` 786,896 B ≈
675 datagrams) kept only that much — **~677 of 4000 (and of 12000) 1150 B
datagrams arrived on loopback**, and "dropped due to full socket buffers"
rose during the run. The governor's 16 MB bucket admits a full-screen batch
(~14k datagrams) whole, so every large change hit this; the lost tiles
returned only via timeout + re-send.

Measured drain with a trivial receiver: 256 datagrams / 5 ms (≈59 MB/s)
→ 100 % (12k in 287 ms); 256 / 2 ms → 33–100 %. Fix: token-bucket pacer on
the transport queue at `DatagramPacing.bytesPerSecond` = 50 MB/s with a
256 KB instant burst (typing never waits), queue sized to one governor
bucket (16,384 datagrams). The host's batch timeout grants serialization
time at the same rate over the batch **plus the bytes queued ahead of it**
(`queuedDatagramBytes`), so a paced batch isn't timed out while leaving.
InProc paths are unchanged (queued = 0, allowance still bytes/50 µs).

`QUICBurstTests` (new): 4000 / 12000-datagram bursts, ≥ 99 % delivered —
was 1557/4000 and 2035/12000 under test load.

2048² noise (all RAW), 6 full-frame rounds, real engines over loopback QUIC
(`QUICSustainedSessionTests` scenario, 2 runs each):

| | before | after |
|---|---|---|
| round 0 (cold) convergence | 6.47 / 6.50 s | 3.44 / 3.45 s |
| rounds 1–5 convergence | 2.65–4.95 s | 4.20–4.40 s |
| datagrams sent per full round (≈14.4k needed) | ~24k | ~14.5k |
| total bytes out, 6 rounds | 168.9 / 174.6 MB | 111.4 / 111.6 MB |

Rounds 1–5 are governor-bound either way (the bucket is empty after round
0); the win is 35 % fewer bytes for the same result and a 2× faster cold
start. Round 0 still showed ~4k datagrams sent-not-counted — *not*
datagrams beating HELLO, as first guessed here: see "Cold-start phantom
loss".

### `NetworkConnection<QUIC>` spike — not adopted (2026-09-27)

Question: should the transport move to the async `NetworkConnection<QUIC>`
API? One connection carries streams and datagrams, so the separate datagram
tunnel on `port + 1` (DESIGN §6) would go away. Spike on loopback with
1150 B datagrams.

- API shape: `QUIC(alpn:)` plus `.tls.localIdentity`, `.certificateValidator`
  and `.peerAuthentication`; `NetworkListener.run { conn in … }`;
  `try await conn.datagrams` (a throwing async property); `openStream`;
  `inboundStreams`.
- Datagram send is `async throws` only: no idempotent send and no batch.
  Awaited one at a time, 12k datagrams took 280–380 ms (23–32 µs each;
  70–97 µs each on a 4k run) and 100 % arrived. A TaskGroup fan-out lost
  57–78 %.
- `usableDatagramFrameSize` read 0 after establishment, where the legacy
  path reports 1397, so the budget query §3.3 relies on was unreliable.
- The clean delivery came only from awaiting each send, which paces
  implicitly. The legacy API paced the same way matches it (see "Datagram
  pacing: burst loss at the viewer's receive buffer", which this spike
  found), so the new API bought nothing for the pixel path.

Verdict: not adopted then. Revisit if Apple adds batch or idempotent
datagram sends, or when the two-port split becomes a deployment problem
(NAT, firewalls). Issue #10 tracks a single tunnel.

### Review pass: section-5 performance (2026-09-26)

`glassact-bench replay --mode loop` now reports per-component CPU (host encode
p50/p95, host control/ACK, viewer datagram/video/control apply). M4 Pro,
release, real 5K traces, byte-identical canvases throughout. Run-to-run noise
on this machine is ±10–25 % on totals — only differences well outside it are
claimed.

| change | measure | before → after |
|---|---|---|
| in-place scroll (no 59 MB snapshot per op, both ends) | viewer scroll CPU, 1785962837 / 1786116475, no faults | 3224 → 1922 ms / 904 → 554 ms |
| same | host encode p50 (scroll emission) | 13.2 → 11.8 ms |
| ACK walks only newly confirmed datagrams' tiles | host control/ACK, 1785962837 faulted / 1786116654 faulted | 198 → 162 ms / 115 → 78 ms |
| xxh64 register fast path (stripe-aligned rows) | 3,600 tiles of a 5K frame, one core | 5.9 → 5.1 ms (10.0 → 11.5 GB/s) |
| (combined) | encode-only p50, 1785962837 / 1786116475 | 10.05 → 9.83 ms / 20.85 → 19.44 ms |
| viewer blits from the decoder's CVPixelBuffer; borrowed CMBlockBuffer | viewer video CPU, 1786116654 `--video vt` (528 HEVC frames) | ~7.0 → ~6.5 s |
| parallel keyframe stripe decode | viewer video-stream wall (cold-start keyframe + paint) | ~63 → 19 ms / ~138 → 39 ms |
| pooled reassembly buffers | peak RSS, 1785962837 faulted full loop | 2,851 → 2,835 MB |
| one transport handoff per batch | caller (engine queue) cost, 12k datagrams, QUIC loopback | 4.6–6.3 → 0.03 ms |

Profile of a 5K replay after these (host side, `sample`): time is almost
entirely the codecs — LZBITMAP, VP8L (incl. libwebp's own hash-chain
memsets), LZ4 — plus xxh64. `cacheAllocate`'s 4096-slot scan never showed up,
so it was left alone.

### `-Ounchecked` on GlassActCodec — measured, dropped (2026-09-26)

GlassActCodec compiled with `-Ounchecked` in release (§8.4). That strips the
`precondition`s in `TileOps.apply` — the last bounds check before the viewer
writes a decoded tile into the canvas — turning a geometry bug into silent
heap corruption. Its hot code (xxh64, already all-wrapping arithmetic;
memcpy-bound tile extract/apply; C codecs) has nothing for the flag to win.
`glassact-bench replay --mode encode`, release, M4 Pro, two runs each:

| trace (5K)            | `-Ounchecked` p50 / p95 (µs) | `-O` p50 / p95 (µs) | bytes out |
|-----------------------|------------------------------|---------------------|-----------|
| glassact-1785962837 (1081 fr) | 10020 / 30699, 9962 / 30837 | 10082 / 31114, 10046 / 30402 | 56.49 MB both |
| glassact-1786116475      | 20455 / 59070, 21378 / 94640 | 20880 / 58312, 20827 / 57902 | 66.22 MB both |

Within run-to-run noise (≤ 1 % on p50); identical output. The flag is gone;
GlassActCodec builds at plain `-O` like everything else.

### High-RTT convergence: hot map read "un-ACKed" as "churn" (2026-08-10)

At ~1 s RTT (airplane/satellite wifi; InProc 450–550 ms/way, no drops) a
video session **never converged**: `settle()` failed even at 480 s of sim
time. Instrumented rig showed a permanent dissolve/re-form cycle — 15
region formations in 60 s on a static 320×320 canvas. Mechanism: dissolve
drops region tiles to cold (`ackedHash = 0`) and the hot map reinforced on
`h != ackedHash`, so the repaint's *static* tiles read as sustained churn
for the whole ACK round trip. At ≤ 80 ms RTT the ACK lands ~5 ticks after
the repaint — under the 15-tick formation cooldown, so the score decayed in
time (the tuning margin the whole ladder was sitting on). At 1 s RTT the
un-ACKed window is ~60 ticks: score pegs at hotMax, cooldown expires, the
massive-box fast-form fires at 3 stable ticks, and the region re-forms from
its own repaint — then quiesces, dissolves (wiping all acked state), and
repeats forever.

Fix: reinforcement now keys on the hash **changing between observations**
(`lastObservedHash` per position), not on differing from the ACKed hash —
"changed" and "not yet ACKed" are different things, and only the former is
churn. Photos full loop (`--mode loop --video mock`, standard faults,
20–80 ms latency, seed 1) shows the reform noise was already hurting at 5K
scale even on a healthy link:

|        | regions formed | virtual time | settled | byte-exact |
|--------|----------------|--------------|---------|------------|
| before | 14 (1 leaked)  | 89.7 s       | false   | true       |
| after  | 9              | 71.7 s       | true    | true       |

Tests: `severeLinkSkipsSettlePrepaint` restored to full
`settle()` + byte-exact assertions (its NOTE about a "pre-existing
frontier" retired), and `highRTTGoldenConvergence` (3 seeds, ~500 ms RTT +
standard fault mix) pins graceful convergence at high RTT.

**Second door, same livelock:** the saturated-tick fallback
(`videoSaturatedTick`, +6 with no hashes) reinforced cold tiles too. It
needs a repaint bigger than the governor bucket to trigger (open batches
pin both slots → INV-4 drops for ~a full RTT — 5K scale; the app's
synthetic ticks pass nil dirty rects, hitting the all-tiles branch), so
the 320×320 rig never saw it. Reproduced host-only by withholding ACKs:
the region re-formed from its own repaint in ~8 saturated ticks. Fix:
the +6 requires `ackedHash != 0` — a cold tile's sticky class flag is
stale routing memory, not churn evidence. Photos full loop unchanged (9
regions, settled, byte-exact) — legitimate formation always has prior
acked content. Test: `saturatedRepaintTicksDoNotReformRegion`.

### Settle coalescing: VP8L block-size sweep (2026-08-10)

Question: would coalescing 64×64 tiles into larger blocks (128/256/512,
whole-frame stripes) before VP8L compression shrink the settle? `glassact-bench
blockscan` (new): full-frame lossless repaint at each granularity, 3 sampled
5K frames per trace, single-threaded encode.

bytes/frame (vs tile-64):

| config    | typing-cc     | scroll-win    | photos        |
|-----------|---------------|---------------|---------------|
| tile-64   | 6.53 MB       | 3.71 MB       | 8.62 MB       |
| block-128 | 6.26 MB 1.04× | 3.50 MB 1.06× | 8.37 MB 1.03× |
| block-256 | 6.15 MB 1.06× | 3.42 MB 1.09× | 8.27 MB 1.04× |
| block-512 | 6.16 MB 1.06× | 3.39 MB 1.09× | 8.24 MB 1.05× |
| stripe-8  | 6.24 MB 1.05× | 3.56 MB 1.04× | 8.41 MB 1.03× |

Coalescing buys only **3–9%** — VP8L's palette/LZ77 already captures nearly
all exploitable redundancy within a 16 KB tile — while encode cost rises
10–40% and datagram loss granularity would worsen. NOT worth block plumbing.

Landed instead: **settle-drain VP8L widening.** The all-or-nothing probe
gate (`qualCount <= webpTileLimit`, 320) shipped ENTIRE dissolve repaints as
LZ4/LZBITMAP whenever the governor's burst bucket admitted the repaint in
one large tick. Settle-drain ticks (pendingRepaint volunteers, no active
region, not throttled) now probe at the throttled cap (4096 — a full 5K
settle fits). Before/after `replay --mode loop --video vt` on `photos`:

|        | datagrams | datagram bytes | video bytes | byte-exact |
|--------|-----------|----------------|-------------|------------|
| before | 30,706    | 57.27 MB       | 22.66 MB    | true       |
| after  | 26,053    | 51.95 MB       | 22.66 MB    | true       |

−5.32 MB (−9.3% of trace datagram bytes; −15% of datagrams) from the one
end-of-trace settle alone; identical applied-tile count, canvas still
byte-identical. Test: `settleDrainProbesVP8LBeyondLiveTickLimit`.

This also corrects the common reading of the P7 keyframe's "2–3× smaller
than the tile flood": that win comes from the flood being LZ4-heavy (the
per-tick `webpTileLimit` budget caps how many tiles get the VP8L probe, and
LZ4 runs ~3× VP8L's size on text) plus per-record wire overhead — i.e. it's
"VP8L on everything", not "bigger blocks". The actionable settle-bytes lever
is therefore the VP8L budget during settle (static screen = idle CPU), not
coalescing.

### Lossy WebP / AVIF for tiles — measured and rejected (2026-08-10)

Question: with HEVC as the motion layer, could lossy WebP (or AVIF) replace
the lossless tile codecs at high quality — "much smaller and at least as
fast"? `glassact-bench lossyscan` (new): changed full 64×64 tiles from real
traces; VP8L at production effort 4; lossy WebP method 4; AVIF = vendored
libaom intra (force-key per tile, screen-content, cpu_used 10, 1 thread,
BGRA→I420 conversion included in encode time). PSNR over BGR, aggregated
over genuinely-lossy tiles with the bit-exact share reported separately.
AVIF has no in-tree decoder, so it reports size/latency only.

typing-cc (157 tiles):

| codec     | B/tile | enc p50 | enc p95 | dec p50 | quality |
|-----------|--------|---------|---------|---------|---------|
| lz4       | 1184   | 3 µs    | 9 µs    | —       | lossless |
| lzbitmap  | 904    | 22 µs   | 36 µs   | —       | lossless |
| vp8l-z4   | 398    | 97 µs   | 379 µs  | 14 µs   | lossless |
| webp-q95  | 514    | 166 µs  | 254 µs  | 22 µs   | 48.2 dB / p5 46.1 |
| webp-q90  | 423    | 169 µs  | 237 µs  | 21 µs   | 45.8 dB / p5 43.6 |
| avif-cq20 | 543    | 183 µs  | 433 µs  | —       | n/a |

scroll-win (6000 tiles): vp8l 475 B/tile (126 µs p50) vs webp-q90
518 B/tile (153 µs, 42.9 dB avg / p5 31.6) vs avif-cq20 605 B/tile (186 µs).
photos (6000 tiles): vp8l 3412 B/tile (1116 µs p50) vs webp-q90 919 B/tile
(258 µs, 42.0 dB) vs avif-cq20 1659 B/tile (257 µs).

Conclusions:

1. **On text/UI — the tile path's entire post-P8 workload — lossless VP8L
   is SMALLER than lossy WebP at q90/q95** (typing 398 vs 423/514 B/tile;
   scroll 475 vs 518/624) and faster at p50. VP8L's palette/LZ77 modes are
   purpose-built for synthetic content; VP8's DCT spends bits ringing on
   glyph edges and still isn't exact. The "much smaller" premise inverts.
2. **AVIF-for-tiles loses everywhere**: bigger than lossy WebP at every cq
   (64×64 intra gives AV1 no spatial context to exploit + OBU overhead),
   no faster, 4:2:0 chroma on text, and no viable decoder story (VT AV1
   decode is M3+ only with per-session setup; nothing in-tree).
3. Lossy WebP DOES win 3.7×/4.3× (bytes/latency) on photographic tiles —
   but photographic churn is the video layer's job now; tiles see photos
   only in the settle, where exactness is the entire point of the pass.

Decision: tile path stays lossless. `lossyscan` was removed on 2026-09-27
(see "Removed bench commands"); the results stay in this log, for a
re-test if the workload mix ever changes.

### VP8L vs AVIF lossless — VP8L wins both content types (2026-08-07)

Head-to-head, 5K frames, size + speed (cwebp -lossless vs avifenc
--lossless):

| content | VP8L z9 | AVIF lossless | VP8L advantage |
|---|---|---|---|
| terminal/text | 6.53 MB | 7.83 MB | 20% smaller |
| photos | 8.97 MB | 13.31 MB | 33% smaller |

Speed: cwebp ~4.4 s/5K frame single-thread (our striped VP8L ~0.5 s
8-way); AVIF/AV1-intra-lossless slower. Corrects the earlier assumption
that AVIF would win on photographic — it's 33% WORSE. VP8L is a purpose-
built lossless codec (prediction + palette + color-cache + entropy);
AV1's lossless is an afterthought on a lossy transform design. VP8L
stays the settle codec (already in use); AVIF not worth adopting.

### REFINE settle — DEFINITIVE: diff is LARGER than full-lossless (2026-08-07, corrected)

Earlier entries measured the residual against the already-subsampled y4m
(hiding the color-pipeline error in both sides) and reported ~1.2-1.3×
"smaller". Re-measured against the TRUE original RGB (a real terminal
frame, the reference the settle must actually reach):

| video encode | byte-exact vs true | residual (FFV1) | full lossless |
|---|---|---|---|
| AV1 4:2:0 cq20 (current path) | 2.5% | 9.35 MB (0.74×) | 6.96 MB |
| AV1 4:4:4 cq20 | 4.0% | 9.41 MB (0.74×) | 6.96 MB |
| RGB H.264 crf20 (clean color) | 41.7% | 10.8 MB | 6.96 MB |
| RGB H.264 crf12 | 47.7% | 9.9 MB | 6.96 MB |
| RGB H.264 crf6 (near-lossless) | 58.9% | 8.75 MB | 6.96 MB |

The residual is LARGER than the full lossless frame in EVERY config, and
never crosses over as quality rises. YUV conversion (not chroma
subsampling) is the dominant error: RGB coding lifts byte-exact from
2.5%→42-59%, but even at 59% exact the residual (scattered ±1 noise,
structureless) codes WORSE than the structured original. To reach
byte-exact you must carry everything the lossy pass discarded, which is
dense low-magnitude noise with no structure to compress.

FINAL: REFINE-against-video is a net LOSS vs re-sending the lossless
tile. The only zero-residual point is lossless video (= just send it
losslessly). Reserved 0x06 stays unbuilt; the session cache (exact-tile
refs) remains the settle lever. Question fully closed.

### REFINE residual settle — measured, NOT worth building (2026-08-07)

Idea: after a video region dissolves, reach byte-exact by sending a
lossless RESIDUAL against the last (lossy AV1) frame the viewer holds,
instead of a full lossless repaint. Measured the AV1 cq20 round-trip
(encode → decode → residual) then lossless-coded full frame vs residual
(FFV1, 5K):

| content | full lossless | residual lossless | ratio |
|---|---|---|---|
| photos (frames 30/60/100) | 4.5–5.2 MB | 3.95–4.1 MB | **1.1–1.3×** |
| text/UI (github scroll) | 2.0 MB | 1.5–1.6 MB | **1.3×** |

Only ~1.2–1.3× — not the multiplicative win hoped for, in EITHER regime.
Fundamental, not tunable: the residual IS what the lossy pass discarded,
which is incompressible in isolation (photographic noise by definition;
sharp text edges + 4:2:0 chroma error for UI). Information-theoretically,
lossy-video + lossless-residual ≈ lossless-total — splitting the delivery
moves where the bits are paid, doesn't reduce them, and the residual
compresses WORSE without spatial context.

Follow-up: sub-block SPARSE per-pixel diff (send only the wrong pixels +
corrected values) was considered too. Measured the byte-exact fraction:
terminal content is 64% byte-exact from lossy AV1 (76% within ±1, 95%
within ±2, nothing off by >8) — the error IS sparse there, unlike photos.
But the terminal residual still coded to only 1.3× smaller (3.05→2.44 MB),
because the 36% wrong pixels are SCATTERED colorspace-rounding noise with
no spatial structure — and structure is exactly what makes the full
lossless frame cheap (solid bg + repeated glyphs). Explicit sparse-diff
(coding pixel positions) is WORSE than residual coding, which handles
zero-runs implicitly. General law: you can't beat lossless-of-structured-
content by sending lossless-of-its-error; AV1's error is either dense-
incompressible (photos) or sparse-but-structureless (terminal).

Decision: keep the full-lossless VP8L settle. The real "don't re-send
what they have" lever is the P3b session cache (exact-tile refs, byte-
exact) — which is why the live photos settle was ~4 MB, not ~25. REFINE
(reserved 0x06) stays reserved and unbuilt.

### Quality vs speed vs bandwidth at 5K — the cq lever is bandwidth, not framerate (2026-08-07)

Prompted by a live codec demote (AV1→HEVC→AV1 under pressure during
native-5K Photos). Measured on the photos trace, 200 frames at 5120×2880:

| AV1 cq | encode fps | bandwidth |   | HEVC q | encode fps | bandwidth |
|---|---|---|---|---|---|---|
| 20 | 64 | ~42 Mbit |   | 70 | 59 | ~78 Mbit |
| 40 | 59 | ~20 Mbit |   | 55 | 58 | ~37 Mbit |
| 60 | 57 | ~12 Mbit |   | 40 | 59 | ~16 Mbit |

**Quality barely moves encode speed** (AV1 57–64 fps across the whole cq
range; HEVC flat at 58–59, it's hardware) but is a **3–5× bandwidth
lever.** So: framerate pressure (libaom saturating at 5K — what the live
demote actually hit) is unfixable by quality; the responses are faster
silicon (HEVC) or lower resolution. Bandwidth pressure is exactly what
quality fixes — and staying on AV1 at cq40 beats demoting to HEVC on
quality-per-bit. The in-engine HEVC fallback already caps at 20 Mbit
(AverageBitRate), so a demote also sheds bandwidth vs AV1's uncapped
cq20 (~42 Mbit); the live 77 Mbit peak was AV1 pre-demote.

Design consequence: two pressure signals, not one. Encoder-
skip = CPU → demote codec (framerate). Backlog/SRTT = bandwidth → raise
AV1 cq (or lower HEVC bitrate cap) and KEEP the better codec.

### SVC exploration — K-SVC feasibility measured (2026-08-07)

`glassact-bench svc`: libaom K-SVC, two same-resolution quality layers at
5K (base q40, enhancement q16), drag trace, plus VideoToolbox decode
probes. Findings:

1. **The decode risk is retired.** VT hardware AV1 decode consumed all
   three probe streams — full (base+enh), base-only, and mixed (enh on
   1 of 3 TUs): 300/300 each. SVC needs NO new dependency viewer-side.
   (Caveat: "decodes" ≠ "decodes correctly" when enhancement refs span
   dropped TUs — that's an encoder-side reference-structure discipline.)
2. **Temporal enhancement is nearly free**: base 0.25 + enh 0.33 Mbit
   (vs 0.54 single-layer cq20 — layering overhead ~7 %). But a dropped
   enhancement silently desyncs the enh reference chain: later
   enhancements decode WRONG without erroring.
3. **Purely droppable enhancement (predict only from this TU's base,
   REFINE-style) costs 135×**: 45.05 Mbit vs 0.33. Temporal prediction
   IS the compression; total per-TU independence forfeits it. Dead end,
   measured.
4. Encode: ~20–23 fps at 5K for both layers (two passes/TU) — half the
   single-layer rate; the real cost of SVC at full 5K.

Design fork for the build: (a) **anchored chains** — enh
predicts temporally but re-anchors from base every N TUs; a drop costs
≤ N TUs of viewer-side enh-discard (needs TU numbering + gap discipline
at our wire layer); or (b) **ACK-gated long-term references** — enh
predicts from the newest ACKED enhancement slot (the videoconferencing
LTR trick, and INV-3 applied to video layers: never reference
what the viewer might not have). (b) is Glass Act-native and loss-optimal;
(a) is simpler. Both keep the ~0.6 Mbit economics.

### P8 pinned mode — first live session (2026-08-07)

The pinned full-screen AV1 mode's first two-machine run (5K host → Air
over WiFi, hardware AV1 decode confirmed). The entire session rode the
video stream: tiles 0 on every heartbeat after formation; bandwidth
followed activity — **0.3–15 Mbit moving, 5–35 KB/s calm** (CQ rate
control tracking content); SRTT 18–25 ms and datagram-path delay flat
at 42 ms throughout (no queue growth); frame-atomic rendering, zero
tearing, nothing to repair.

Direction consequence: the blend IS the architecture — AV1
screen-content motion layer while anything moves, Glass Act's lossless
tile path for typing/small churn, dissolve-on-quiesce for byte-exact
settle, INV-10 zero-idle intact. Remaining work to productionize:
video-path glass-to-glass telemetry (frame timestamps — today's g2g
only rides tile records), dissolve/settle tuning at 5K, HEVC-fallback
validation on non-AV1 viewers, and SVC layering (base layer reliable,
enhancement droppable) as the loss-resilience story.

### AV1 screen-content measurement — the pinned-region case (2026-08-07)

Phase 1 of the pinned-region study (aomenc --rt cpu-used=10 --tune-content=screen,
10 threads, full 5120×2880, real traces). Steady state excludes the
one-time keyframe (1.0–1.7 MB):

| trace | cq20 steady | cq30 steady | encode speed |
|---|---|---|---|
| cursor-drag | **0.54 Mbit** | 0.36 Mbit | ~85 fps |
| window scroll (GitHub) | **0.91 Mbit** | 0.67 Mbit | ~78 fps |

Context: our lossless tile path runs these at ~8 Mbit steady. AV1 with
screen tools (palette; motion vectors eating drags/scrolls natively) is
**9–15× cheaper, frame-atomic by construction** (no tile tearing), and
encodes full-screen 5K at ~80+ fps in software. Typing content measured
earlier at 26 kbit. The pinned full-screen-region mode (AV1 motion
layer + Glass Act dissolve-on-quiesce for byte-exact settle) is strongly
justified; SVC layering (base layer reliable, enhancement droppable
over datagrams) is the designed follow-on.

### First two-machine sessions — Air over WiFi (2026-08-07)

Round 1 (pre-fix build): SRTT 11–20 ms, bandwidth pinned at the governor
cap the whole session, screen a mixed-generation mosaic — diagnosed as
the 2 MB burst bucket vs 10–25 MB full-screen transitions at 5K (fixed:
16 MB bucket). Cross-machine glass-to-glass read 0.0 (host-clock stamps;
fixed via PING-derived min-filtered offset). Reassembly expiry found
silently discarding partials (third received≠applied instance; now
reports via DELTA_NACK).

Round 2 (fixed build): cold boot ~1 s, window drags and Photos browsing
at good latency/quality; expiry NACKs fired 4× and healed. Then the
full-screen photo transition KILLED THE SESSION: a 9.3 MB/s burst
(SRTT spiked to 71 ms, g2g p50 ~500 ms — bufferbloat) surfaced a
transient datagram RECEIVE error, and the viewer transport treated any
receive error as fatal — the canvas froze on a dead connection while
the host streamed full-screen HEVC into the void for 30+ s (no PONG
liveness). Fixes: receive errors on the unreliable flow are loss (fail
only on a 64-error streak; genuine death still arrives via the state
handler), and the host tears the session down after 10 s without a
PONG so the listener accepts a fresh dial.

Viewer now presents scale-to-fit (full-res delivery, client-side
present scaling, capped at 1:1 — INV-8 untouched).

### P6e — global send governor + full-screen region snap (2026-08-07)

Target: every workload ≤ 25 Mbit. Two mechanisms, no pixel lossiness —
byte-exact at settle is untouched; the tradeoff is temporal (paced
convergence under sustained overload).

**Governor:** a token bucket (2.8 MB/s ≈ 22.4 Mbit, 2 MB burst) at the
qualification stage of the encode tick. A deferred tile is NOT queued —
it re-qualifies next tick against the CURRENT frame, so pacing degrades
temporal resolution under overload, never freshness (INV-4's property
applied per tile; Glass Act's absolute-payload model is what makes a global
rate cap safe — there is no stale backlog to flush, ever). Admission is
estimate-based (EWMA of encoded bytes/tile, initialized RAW-sized so the
very first flood tick is bounded before any learning); settlement charges
the actual packed batch, debt allowed and bounded. Deferrals count as
pending work so settle logic can't terminate early. Interactive edits
ride inside the burst bucket and never notice.

**Full-screen snap:** a massive-class region (box ≥ ⅓ of grid) covers
the whole screen. The excluded strips (menu bar, sidebar, dock row) were
churning incompressibly on every photos transition and shipping lossless
each time — measured 94 MB of 233 on the photos loop.

Results (steady state; loop for photos, encode replay for the rest):

| workload | pre-P6e | post-P6e |
|---|---|---|
| photos loop (vt regions) | 63 Mbit | **17.1 Mbit** (62.8 MB total, byte-identical) |
| full-screen text scroll | 44 Mbit | **15.8 Mbit** (scrolls 306, satisfied 459 k tiles) |
| cursor-drag | 18.9 Mbit | **6.0 Mbit** (deltas 56 k → 13 k) |
| GitHub window scroll | 7.7 Mbit | 8.0 Mbit (≈ unchanged) |
| typing | 0.018 Mbit | 0.018 Mbit (unchanged) |

The unexpected finding: pacing IMPROVED the heavy traces beyond the cap.
Deferred ticks give ACKs time to land, so the scroll detector and tile
cache engage against settled state instead of racing the flood — the
full-screen scroll's satisfied-tile count went from 112 k to 459 k, and
the drag trace's delta volume fell 4×. Encode p95 improved on all heavy
traces (bounded ticks). Known cosmetic quirk: paced classification can
form 2–4 short-lived strip regions on the photos cold start before the
full-screen region locks (tick 238); the governor prices that thrash at
~1 MB each, so it was left alone.

Every measured workload is now ≤ ~17 Mbit against Apple Screen Sharing's
~75 Mbit lossy stream, byte-exact at settle. Test fallout of governed
qualification: three tests re-premised (single-tick flood assumptions →
paced loops); the VP8L "heavy tick skips probing" behavior is obsolete
by construction — governed ticks always fit the probe budget, a strict
routing improvement.

### P6d — region formation for paging + verified scroll promotion (2026-08-07)

Photos full loop (--video vt, 5–15 ms latency), the last workload over
Apple Screen Sharing's ~75 Mbit line, tuned from **571 → 63 Mbit**
effective (byte-identical at settle throughout). One region now forms at
tick 11, survives the entire trace through every page gap, and dissolves
once at settle. The steady-state covered phase runs ~33 Mbit. Every step
was measured on the same replay:

| change | total bytes |
|---|---|
| baseline (P6 as shipped) | 2,416 MB (~571 Mbit) |
| adaptive quiet limit (30→90→270 on quick re-form) + fast-form (3 ticks for boxes ≥ ⅓ grid) | 1,944 MB |
| dissolve softened (cooldown 60→15, halve — don't zero — hot scores) | 974 MB |
| time-based quiescence dissolve scaled by the same patience (700 ms path silently bypassed the tick limit — fired every 2 s page gap) | 874 MB |
| region RESIZE in place on geometry stray (repaint only tiles leaving coverage; codec-swap mechanism, no wire change) + sliver guard (a massive region ignores lull-noise hot mass; quiet path owns its lifecycle) | 367 MB |
| hot reinforcement net +3 → +7 for incompressible churn (76 % of bytes were pre-formation flood at net +3; text/UI never classifies incompressible, so it stays immune) | **233 MB (~63 Mbit)** |

Every intermediate number came from byte checkpoints at form/dissolve
(GLASSACT_DRAG_DEBUG): the decisive one was `form tick=24 bytesOut=279 MB`
— 76 % of the run was spent before formation. Two dead-end tunings
(saturated-tick +6, massive-region starting patience) moved nothing and
were kept only where they cost nothing.

**All four v2 workloads now beat Apple's ~75 Mbit lossy stream while
byte-exact at settle:** typing 0.018 · scroll-win 7.7 · cursor-drag 18.9
· photos 63 Mbit (steady 33). Full-screen text scroll: 44 Mbit.

Also this session: **verified scroll promotion** — SCROLL_ACK now
carries an order-independent digest of the viewer's written per-tile
hashes; the host compares against emit-time mirror marks and demotes the
whole rect on mismatch. Closes the last optimistic-belief hole (a scroll
racing a mid-heal window could promote a wrong hash with no heal path).
Honest digests never false-fire (asserted in scroll/drag goldens); photos
loop stays byte-identical.

### Photos over video regions + full-screen AV1 experiment (2026-08-07)

Photos full loop with regions (5–15 ms latency): formation barely
engages — 2 regions, 60 video frames over 30 s, because the hot-map/
stability gates are tuned for sustained playback, not paging
transitions; the tile path carried ~2.1 GB (~571 Mbit/s effective).
Region formation tuning for paging workloads is the remaining work for
the "beat ~75 Mbit everywhere" goal; the codec itself is not the
bottleneck.

Full-screen software AV1 (GLASSACT_AV1_NO_SIZE_GATE bench knob, libaom RT
at 5120×2880): the same 2 regions / 60 frames cost **3.97 MB vs
5.98 MB hardware HEVC (−34 %)** — AV1's compression edge holds at 5K.
Direct throughput measurement on the photos content (aomenc --rt
cpu-used=10, matching the engine's settings): **~62 fps average at
full-screen 5K** — typical frames 10–16 ms, transition-heavy frames
20–35 ms, first keyframe 154 ms. This refines, not contradicts, the
1440p60 ceiling: that was measured against sustained playback where
EVERY frame is transition-class (20–35 ms each → 60 Hz fails). For
mostly-static paging workloads, full-screen AV1 is realtime on the M4.
The size gate's pixels-only heuristic is too coarse — workload-aware
codec choice (paging → AV1 eligible, sustained → HEVC) is a candidate
refinement for the region-formation task, where AV1's −34 % would
compound with formation tuning.

### DELTA_NACK — the first real divergence, found and fixed (2026-08-07)

The first-ever full-loop replay of the photos trace (5–15 ms latency, no
loss) settled with **18–47 permanently divergent tiles** — host belief
`acked == shadow == frameHash` while the viewer's canvas differed, the
worst failure class this design has: the host will never resend a tile
it believes is current. Reproduced with video off (regions exonerated)
and on the pre-P3″ engine (15 tiles — latent, not introduced today;
P3″'s extra scrolls only widened exposure).

Tile-181 forensics (GLASSACT_TRACE_TILE) showed the mechanism, a two-part
protocol hole in P2′:

1. Racing scrolls and records under latency can make host and viewer
   compute different results for the same scroll op (host promotes its
   shifted-shadow hash optimistically; SCROLL_ACK repair covers LWW
   skips, not source-belief drift).
2. **Receipt ≠ application for hash-pinned deltas.** A delta whose base
   hash misses is dropped cleanly by the viewer (by design) — but the
   bitmap ACK promotes on receipt, so the host cements the never-applied
   hash as acked. Every later delta pins to a base the viewer never had:
   the trace shows 7 consecutive base-missed deltas on one tile, each
   commitAck'd. The delta goldens asserted `deltaBaseMisses == 0` —
   the one path that must heal was never exercised.

Fix: **DELTA_NACK control TLV (0x0A)**, viewer → host, listing
base-missed (frame_seq, tiles). Host repair zeroes `ackedHash` (tile
re-qualifies as an absolute record) and clears the in-flight slot under
the INV-9 seq guard, so the bitmap ACK for the same send is treated as
stale in either arrival order. Tests: wire round-trip; viewer reports
the miss; host demotes + heals absolute under both ACK/NACK orderings;
acceptance = the photos full loop now settles **byte-identical: true**.

Known residual (filed as a task): scroll-KNOWN promotion is still
optimistic — a scroll emitted while a source belief is mid-heal can
promote a wrong dest hash, and if that tile goes static immediately
after (no later delta to base-miss), it has no heal path. Candidate
fix: SCROLL_ACK carries a fold of the viewer's written per-tile hashes;
host compares against its emit-time marks and demotes the rect on
mismatch.

### P3″ — 2-D drag/shift detection (2026-08-07)

Window drags move diagonally (dragscan: byte-rigid (+106, +32) between
consecutive frames), which defeats both 1-D signature passes by
construction. Added a probe-based 2-D estimation pass to the scroll
detector: 3×3 grid of 128×128 probe blocks over the churn bbox ranked by
texture; per probe, 16 distinctive anchor bytes (rows scanned outward
from the probe center — text leaves blank rows) located in the shadow's
±224 px window via per-row memmem; anchor hits get a 256-sample check
then a full-block memcmp; up to 4 candidates feed the existing per-tile
verification, which remains the only authority (INV-3). Steady-state at
5K vs the v2 baseline:

| trace | before | after | scroll ops | p95/batch |
|---|---|---|---|---|
| cursor-drag | 3.13 MB/s | **2.36 MB/s (−25 %)** | 0 → 37 (36,469 tiles) | 53.9 → 51.6 ms |
| scroll-win | 2.24 MB/s | **967.6 KB/s (−57 %)** | 34 → 222 (112,284 tiles) | 27.3 → 26.2 ms |
| photos | 171.2 MB/s | **90.2 MB/s (−47 %)** | 5 → 163 (357,014 tiles) | 168 → 156 ms (p50 140 → 40 ms) |
| typing | 2.2 KB/s | 2.2 KB/s | 0 (correct — no motion) | unchanged |

Findings that mattered more than the drag case itself:

1. **Spurious 1-D votes were masking the detector everywhere.** The 2-D
   pass originally ran only when both 1-D passes found nothing — but
   repetitive content (terminal blank rows, browser page chrome) reliably
   produces a wrong 1-D vote that fails verification. Falling through to
   the 2-D pass after a failed 1-D candidate is what unlocked scroll-win
   (34 → 222 ops) and photos (Photos' slide transitions are rigid
   translations). The drag workload was the probe; the win is general.
2. **Probe texture tuning is content-driven:** terminal content at 5K is
   ~90 % flat background — a 64×64 probe rarely spans a glyph line
   (measured distinct-sample counts 1–12 of 64). 128×128 probes with a
   16×16 sample grid and threshold 12 of 256 engage reliably.
3. **The naive ±224² offset sweep was a real-time regression at -Onone:**
   it broke the QUIC sustained-session test's deadlines in debug builds
   (caught only because that test runs real QUIC with wall-clock
   deadlines). The anchor/memmem search produces identical candidates at
   ~1 MB of linear scanning per probe; engaged traces got *faster* than
   baseline (fewer tiles reach the encoder). §12 note: all four traces'
   p50/p95 improved or held; no regression to justify.

Residual drag cost (2.36 MB/s) is the non-rigid remainder: live session
streaming inside the window during the drag, window shadow/edges, the
revealed strip, and the pointer itself (the ~24 KB/s cursor baseline).

### Reference traces v2 — clean timed captures (2026-08-07)

Recorded with the new timed flow (menu arms a 5 s delay, 30 s duration,
auto-save) so the recorder never captures its own UI — the contamination
that poisoned the v1 typing trace (see "Typing trace autopsy"). All 5120×2880.

| trace | content | file | frames | duration |
|---|---|---|---|---|
| typing-cc | real Claude Code session in Ghostty: user typing + streamed reply + tool output | `glassact-1786116323.scap` | 266 | 31.2 s |
| scroll-win | GitHub source code scrolled in a browser **window** (not full-screen) | `glassact-1786116475.scap` | 619 | 30.9 s |
| photos | Photos.app full-screen browsing | `glassact-1786116654.scap` | 603 | 29.4 s |
| cursor-drag | pointer sweeps + dragging an opaque terminal window (with a live session streaming inside it) | `glassact-1786116861.scap` | 647 | 31.8 s |

Replay `--mode encode`, release, full path stack (deltas + cache +
scroll + keyframes negotiated). "Steady" excludes the cold start:

| trace | steady b/w | p50/batch | p95/batch | paths engaged |
|---|---|---|---|---|
| typing-cc | **2.2 KB/s (17.6 kbps)** | 1.16 ms | 2.15 ms | deltas 371, cache 51, 1 keyframe (6.24 MB cold) |
| scroll-win | 2.24 MB/s (18 Mbps) | 12.2 ms | 27.3 ms | **scrolls 34 (19,823 tiles satisfied)**, deltas 163 k |
| photos | 171.2 MB/s | 140 ms | 168 ms | deltas 492 k, cache 20 k; keyframe fell back (incompressible) |
| cursor-drag | 3.13 MB/s | 2.4 ms | 53.9 ms | deltas 93 k; scrolls 0 — see drag forensics below |

Readings:

- **Typing is the headline.** A real remote-Claude-Code workload — not
  synthetic 5 cps — costs **2.2 KB/s byte-exact**: 76.6 % of steady bytes
  in 1–3-tile ticks, zero burst ticks. Same trace through real codecs
  (y4m export, same flags as the 08-06 comparison): HEVC hw q65 = 68 kbps,
  aom RT cq20 = 26 kbps — both *lossy*. **Glass Act is 3.9× cheaper than
  lossy HEVC and 1.5× cheaper than lossy AV1 while being byte-exact.**
  The v1-trace "9× behind video codecs" is refuted: it was
  the recorder's own menu, and clean measurement lands us *ahead*.
- **P3′ engages on real content.** 34 window-scoped scroll ops satisfied
  19,823 tiles on the GitHub browser scroll — the capability built on
  2026-08-06 against a trace with no scrolls now pays on one that has
  them. Residual (revealed rows + non-rigid chrome) still dominates
  bytes; deltas carry essentially all residual tiles (163 k of 167 k).
- **Photos is the P6 workload, measured on the tile path.**
  Photos animates every transition, so ~12 full-screen photographic
  ticks/s → 171 MB/s and 140 ms p50 batches. Encode-mode replay has no
  video-region factory; live, this routes to hardware HEVC at the
  20 Mbps cap. Keep this trace as the region/lossy corpus.
- **Cursor cost baseline for cursor-as-metadata:** pure pointer
  movement is the 1–20-tile ticks ≈ 723 KB over 30 s ≈ **24 KB/s** —
  what a CURSOR TLV would reduce to ~0.
- **Drag forensics (new `dragscan`: exact rigid-shift search between two
  frames):** the dragged terminal is **opaque** — a 256×256 textured
  probe from frame 410 reappears **byte-identically** in 411 at
  (dx +106, dy +32), and 95.4 % of the full window-interior rows match
  exactly under that shift (a second pair matches at dx −16, dy −42;
  alpha-blended pixels could not survive a 106 px move over different
  wallpaper byte-for-byte). Initial "translucent re-blend" reading was
  wrong. The real reason the drag costs 97 MB: motion is **diagonal**
  (dx and dy simultaneously) and the P3′ detector only attempts pure
  vertical then pure horizontal — it sat out the whole drag, so ~1,200
  rigidly-moved tiles/frame re-shipped as deltas. Detector gap, not
  intrinsic content; 2-D shift detection would cut most of it. Residual
  under the shift (~0.1–15 % of pixels) is window shadow/edges, the
  revealed strip, the cursor, and the live session streaming inside the
  window during the drag.
- Max/batch ≈ 640 ms in every trace is the single cold-start tick
  (full-frame hash + keyframe encode), not a steady-state number.

(Superseded the same day by P3″ — the v2 numbers in this table are the
pre-P3″ baseline.)

### Typing trace autopsy: the recorder measured itself (2026-08-07)

Visual forensics (new `dumppng` + burst-frame indices) on the typing
trace's 15 burst ticks: frames 224–253 are the HOST'S OWN menu-bar menu
being operated to stop the recording — an NSMenu with vibrancy blur over
the wallpaper, re-blending ~180 tiles per hover (non-rigid by nature:
this, not terminal transparency, is why scroll/delta/scrollscan all
found nothing — the terminal is opaque). Frames 2/33–34
are the terminal window appearing (legitimate one-time paint).

Corrected steady-state decomposition: recorder-menu artifact ≈ 2.31 MB
(71 %), window-appear ≈ 0.94 MB (29 %), **actual typing ≈ 167 KB over
32.6 s ≈ 5 KB/s ≈ 41 kbps byte-exact — BELOW lossy AV1 (72 kbps) and
HEVC (91 kbps) on the same content.** The long-quoted "9× gap to video
codecs on typing" was an artifact of the trace recording its own stop
menu. Resolved same day: clean timed captures recorded and measured —
see "Reference traces v2" (typing lands at 17.6 kbps,
*ahead* of the lossy codecs; P3′ validated on a real window scroll).

P3′ benchmark-trace win: none on bandwidth (the bursts
were never scrolls) and neutral on timing — its value is the verified
window/dx capability awaiting real scroll content, plus the two latent
cache bugs its goldens flushed out, plus this diagnosis.

### P3′ — window-scoped + horizontal scroll (2026-08-06)

The detector generalizes: detection/verification/shadow-shift now scope
to the churn bounding box (a scrolling window inside the screen) and try
a horizontal (dx) pass when vertical finds nothing — the SCROLL wire
carried rect+dx since P3, so no protocol change. Verified: window
scrolls ship as one op (clean + realistic-fault goldens, byte-exact,
engagement asserted), dx pans work, full-screen path unregressed
(scroll trace 5.5 MB/s). Under brutal jitter the detector may starve
(generationally skewed shadow rows match nothing) — correctness never
depends on it (separate golden).

Bring-up caught TWO latent P3b cache bugs: (1) a fragmented STORE
superseded mid-flight is discarded by all-or-nothing reassembly while
its datagrams still ACK — receipt stopped implying storage; fixed by
committing slot state under the INV-9 seq guard (a discarding newer
send necessarily overwrote the inflight slot, so the guard is exactly
the "no discard possible" test). (2) The debugging also surfaced that
parallel test-case logs interleave — per-tile traces from concurrent
seeds are unusable; debug single-seed.

**Payoff on the typing trace: zero.** `scrollscan` confirms 0 of
260 frames have any rigid-shift consensus — the terminal bursts are NOT
pixel-rigid scrolls. [Diagnosis corrected twice since: the non-rigid
bursts were the recorder's own vibrancy menu (see "Typing trace autopsy"), and
`dragscan` later proved the terminal is fully opaque — the
"transparency re-blend" theory in this section's first draft was wrong.]
Typing stays 102.7 KB/s on this trace. Where P3′ pays:
opaque-window scrolling (browsers, editors) — demonstrated on the v2
window-scroll trace (34 ops, 19,823 tiles satisfied).

### Typing decomposed: it's scrolling (2026-08-06)

Tick-size decomposition of the typing trace's steady 3.27 MB (new
`replay --mode encode` output): keystroke ticks (1–3 tiles) are 0.8 % of
bytes; 15 terminal-scroll bursts (>100 tiles) carry **95 %**. So
"typing = 0.82 Mbps" is really "terminal scrolling = 0.78 Mbps; typing
≈ 6 kbps" — and on pure keystrokes Glass Act is already ~10× *cheaper* than
lossy HEVC (72–91 kbps for the same session) while byte-exact. The whole
remaining video-codec gap lives in the scroll bursts, i.e. exactly the
target of window-scoped scroll detection (queued): converting those 15
bursts into SCROLL ops + thin residuals is the last big typing lever.

### P7b — lossy first-paint cold start (2026-08-06)

The q90 exploration, productized as a transient: on cold start the host
sends a striped WebP-lossy (VP8, q90 ≈ 51 dB) whole-frame keyframe ahead
of the lossless one on the same ordered stream. Encode is ~60–90 ms
(8 parallel stripes) vs ~550 ms for the lossless VP8L keyframe, so the
viewer shows a full — approximately correct — picture roughly half a
second sooner; the lossless keyframe then overwrites it tile-by-tile.
Semantics are video-frame-like: LWW-gated blit, never advances tileSeq,
never ACKed, never promoted into acked/shadow — exactness is untouched
by construction, and the goldens (which now all exercise it) stay
byte-identical. Cost: one-time ~0.3–0.8 MB per connect. New codec id
`KeyframeCodec.webpLossyStriped` (3); fire-and-forget, no bookkeeping.

### P2′ — hash-pinned DELTA records (2026-08-06)

The measure-first pass (`p2scan`) retired classic P2 before it was built:
palette + left-predicted entropy wins **zero** bytes over today's best-of
on real traces — VP8L internally *is* palette+prediction+entropy, so the
spec's P2 projection (written against the LZ4 baseline) was already
banked when VP8L was adopted. The measured winner was the delta family:
XOR-vs-base 62 % / changed-bbox sub-rect 64 % of today's bytes on typing.

Shipped as `Opcode.delta` (0x0B): `{mode, baseHash u64, [rect], inner op,
payload}` — mode 0 whole-tile XOR, mode 1 absolute sub-rect — diffed
against the ACKed shadow, sent only for quiescent-acked tiles, applied by
the viewer only when the canvas tile hashes to the pinned base (clean
drop + host repair otherwise; `deltaBaseMisses` expected 0 and asserted
0 in faulted goldens). Caps-gated. INV-1 note: the base is ACK-confirmed,
hash-verified content — *specified* prior content; INV-3 governs it like
SCROLL/COPY.

Steady-state results (5K, byte-exact, 9/9 goldens):
- typing: 134.6 → **102.7 KB/s** (0.82 Mbps; was 8–15× of lossy HEVC,
  now ~6–11×)
- scroll: 9.17 → **5.49 MB/s** (77 → 44 Mbps — now *below* Apple's ~75
  lossy budget while byte-exact). The win the offline scan could not
  see: live deltas diff against the *scroll-shifted* shadow, so scroll
  residuals become sub-pixel/AA differences that crush.

Perf note (§12 justification): heavy burst-tick encode p95 rose
(typing ~17.6 → ~23 ms; scroll ~15.6 → ~30–50 ms, run-to-run variance)
— the cost of delta trials + budgeted VP8L sub-rect probes
(`deltaWebpPixelBudgetPerWorker` = 250k px). Accepted: bandwidth is the
scarce resource on exactly those ticks, INV-4 preserves correctness by
dropping captures (worst-case full-screen scroll degrades toward
~30 fps effective), and p50s are unchanged. Bug found during bring-up:
mode-1 inner encodes overran a half-offset scratch (heap corruption
crashing an unrelated suite) — worker `inner` buffers are now 2×tile.

### Typing over real video codecs (`y4m` export, 2026-08-06)

The "did we reinvent video codecs?" check: the real typing trace fed to
HEVC (hardware, constant quality) and AV1 (aom RT, cq20), steady-state
with first keyframes excluded, against Glass Act's measured 134.6 KB/s:

| encoder              | steady typing | fidelity      |
|----------------------|---------------|---------------|
| AV1 rt cq20          | 72 kbps       | lossy 4:2:0   |
| HEVC hw q65          | 91 kbps       | lossy 4:2:0   |
| HEVC hw q80          | 295 kbps      | lossy 4:2:0   |
| Glass Act                | 1077 kbps     | byte-exact    |

Video codecs win typing delta-efficiency 4–15×. Anatomy: we convergently
rebuilt their *structural* layer (skip=hash gate, global motion=SCROLL,
LTR/IntraBC=cache, IDR=keyframes) but deliberately not their *residual*
layer — predict-and-code-the-difference within a block — because INV-1's
absolute payloads are what buy the per-tile LWW loss model. A one-glyph
change costs HEVC ~hundreds of residual bits in a 16×16 block; it costs
us an absolute 64×64 VP8L repaint (1–3 KB). The gap is the bandwidth
price of exactness + loss-nativity, at a workload where 1 Mbps is
already negligible. Narrowing paths that keep the invariants: P2
palette+rANS (text tiles toward ~100–150 B ⇒ within ~2–4× of lossy
HEVC), and P4-style delta-vs-ACKed-shadow records (ACK-gated, INV-3-
legal residuals). This table is the strongest argument for P2 on file.

### Lossy q90 exploration (`keyframe --lossy`, 2026-08-06)

Where would high-quality lossy land if we ever wanted it? Whole-frame at
quality 90 vs the lossless striped-VP8L keyframe, real 5K frames:

| frame            | lossless keyframe | best lossy q90        | ratio | PSNR    |
|------------------|-------------------|-----------------------|-------|---------|
| Mixed (video)    | 1.37 MB           | 293 KB (WebP)         | 4.7×  | 52.8 dB |
| Busy desktop     | 6.07 MB           | 762 KB (WebP)         | 8.0×  | 51.0 dB |
| Full-screen text | 325 KB            | 535 KB WebP / 700 JXL | —     | —       |

Two findings. (1) On photographic/mixed content, q90 is 5–8× smaller at
50+ dB — genuinely near-transparent. (2) On text, **lossless VP8L beats
lossy WebP/JXL q90 outright** (325 vs 535–700 KB): text is the content
class where exactness is also the cheaper choice, which is the project
thesis in one row. (AVIF q90 edges the text number at 243 KB but with
4:2:0 chroma text smearing.) Role for lossy, if adopted: a *transient*
representation only — lossy first-paint cold start, hidden-viewer beats,
photographic still regions — always converging to lossless afterward via
the existing keyframe/repaint machinery (a lossy keyframe would carry a
codec id and video-frame semantics: LWW-stamped, never promoted to acked).
That is spec P4's REFINE concept, realizable on the P7 wire as-is.

### P7 — lossless region keyframes (2026-08-06)

One striped-VP8L image instead of N tile records (measured: whole-frame
beats per-tile 1.1–3×, striping ×8 makes it parallel at ≤ 6 % ratio
cost). Wire: KEYFRAME on the video stream {seq, rect, codec, stripes} +
KEYFRAME_ACK on control; caps bit; a keyframe is a batch of one giant
record — seq-stamped, per-tile LWW at the viewer (blit + tileSeq advance),
ACK promotes acked/shadow, generous timeout drops covered tiles to cold.
Used for cold start (typing trace: 21.0 → 10.4 MB total; the 16.7 MB
datagram flood becomes a ~6 MB reliable-stream blob) and dense throttled
beats (≥ 64 tiles, ≥ 25 % bbox density). Incompressible content falls
back to the tile path.

The new faulted goldens caught two latent bugs beyond the feature:

1. **Cache slot poisoning (P3b)**: a timed-out STORE's datagrams can
   arrive late/reordered after the slot was reused — stale content
   poisons the slot, a later hash-guarded REF cleanly drops, but its
   datagram is ACKed and the host commits. Fix: slots are LWW registers
   keyed by store frame_seq (already in the header — zero wire cost).
2. **VP8L `exact` (codec)**: libwebp's lossless default may discard RGB
   under alpha≈0 pixels — visually lossless, byte-inexact. Never fires
   on opaque screen content (months of goldens missed it); a random-alpha
   golden decoded a correct stream into different bytes. `config.exact=1`
   everywhere; zero cost on real content (steady rates unchanged).

### First live 5K session + detector recalibration (2026-08-05)

First end-to-end run of the P6/P6b stack on real pixels (browser video:
hover-autoplay → full-width player → resized window). The lifecycle worked
live — three FORMED→DISSOLVED cycles, all AV1, tracking every geometry
change, total bandwidth 1–4 MB/s during playback vs 45+ MB/s for the same
content on the lossless path. But the session trace
(glassact-1785995222.scap, 87.5 s of 5K) exposed three real defects:

1. **The hot-map incompressibility bar (5/8 of RAW, tuned on noise
   synths) was unreachable on real content**: across 97,861 changed tiles,
   not one exceeded 4/8. Text/UI churn codes below 1/8; real video tiles
   land in 1/8–3/8. Live formation only worked via the INV-4-saturated
   path's generous reinforcement; the strict path never fired (0 regions
   in clean replay). Recalibrated to 1/8 — churn/density/stability gates
   keep text out (verified: 0 false regions on the full-screen scroll
   trace). Replay of the live trace: 1243.6 → 349.6 MB total (3.6×),
   2 regions, byte-identical at settle.
2. **No region size gate**: the full-width player formed a region far
   beyond software AV1's measured 1440p60 ceiling. Formation/promotion/
   swap now skip AV1 for regions > 2560×1440 pixels and start on the
   hardware codec directly.
3. **Backlog-full submissions masked codec pressure**: rejected before
   the pressure window could count them, so demotion could never trigger
   while the transport was backed up (seen live alongside a runaway
   control-stream SRTT — still to be root-caused on a live run). Backlog
   skips are now counted (stat + telemetry), and backlog-full with a full
   encoder pipeline counts as demotion evidence.

`routescan` now prints a best/RAW ratio histogram — the calibration tool
this fix came from.

### P6c — REFRESH_HINT: occlusion-aware sync throttling (2026-08-05)

The battery feature App Nap fights were pointing at: a hidden viewer
doesn't need real-time sync, and a state synchronizer is *allowed* to fall
behind — catching up is one ordinary tick. New control TLV 0x08 (the slot
the spec reserved): the viewer watches window occlusion and, after 3 s
hidden, hints the host to 1 Hz and releases its App Nap exemption; the
host gates encode ticks to the hint (same correctness argument as INV-4 —
skipped captures re-qualify), dissolves any video region (no AV1 for an
invisible window), suppresses formation, and drops the SCK capture rate
itself. Visibility restored → hint(60), instant full rate, regions
re-form organically. SRTT/timeout machinery self-adapts (slow ACKs
inflate SRTT, which stretches timeouts proportionally). Tier-1 scoped
assertions cover idle apps; this covers active-but-hidden sessions —
host encode, viewer decode, and both radios go to ~zero between 1 Hz
beats. `--no-throttle` keeps the hidden-at-full-rate demo posture.
Tests: tick gating + convergence at 1 Hz, region dissolve/suppression/
re-formation, faulted goldens across throttle cycles. 135 tests; 9/9
legacy goldens.

*2026-10-13 (wire v3):* the viewer only ever sent 0 (pause) or 60, so the
1–29 Hz band went: TLV 0x08 is now PAUSE_HINT (`paused u8`), and the tick
gate, throttled-beat keyframes, VP8L budget scaling and dissolve-on-throttle
were removed. Pause keeps the region alive (DESIGN §4.10).

### P6b — AV1 regions shipped, adaptive HEVC fallback (2026-08-05)

AV1 (libaom realtime via the CAom dlopen shim; viewer decodes in hardware
on M3+) is now the preferred region codec, negotiated per session via caps
bits. Full loop on the video synth (`--video av1`), byte-identical at
settle, clean and under 5 % drop / 1 % dup / 10 % reorder / 20–80 ms
jitter:

| codec pipeline      | total bytes | video stream (225 frames) |
|---------------------|-------------|---------------------------|
| lossless baseline   | 163.26 MB   | —                         |
| hardware HEVC       | 30.52 MB    | 2.27 MB (~4.8 Mbps)       |
| **AV1 (libaom)**    | **29.47 MB**| **1.23 MB (~2.6 Mbps)**   |

aom's CBR holds the configured target; VT HEVC overshoots ~1.7× at the
same setting. Codec id travels in VIDEO_START, so a mid-stream swap is a
generation restart (new START + IDR): under sustained CPU pressure —
detected as a skip-majority window in the pacing gate, i.e. encoder
slower than capture — the region demotes to hardware HEVC, then re-tries
AV1 after a backoff that doubles while promotions fail probation (the
VP8L routing-memory pattern at region scale). Deterministic switch tests
via a stallable mock; byte-exact goldens across live swaps.

### AV1 software-encode feasibility on M4 (2026-08-05)

Question: can software AV1 replace hardware HEVC for region encoding on the
M4 host? Tools: SVT-AV1 4.2.0, libaom 3.14.1 (aomenc --rt), dav1d, ffmpeg;
content: mandelbrot motion (hard case), CBR low-delay, matched bitrates.
`VTIsHardwareDecodeSupported(AV1)` is **true on the M4** (and any M3+
viewer) — decode is hardware on the real path, and dav1d software-decodes
1440p60 at 670 fps as a universal fallback, so encode is the only question.

| encoder (720p60 @ 8 Mbps)   | fps  | PSNR     |
|-----------------------------|------|----------|
| aom --rt cpu-used=8         | 297  | 35.33 dB |
| aom --rt cpu-used=10        | 307  | 34.86 dB |
| SVT-AV1 preset 10           | 149  | 33.82 dB |
| SVT-AV1 preset 11/13        | 157  | 33.78 dB |
| VT HEVC (hardware)          | 213  | 33.80 dB |

| encoder (1440p60 @ 20 Mbps) | fps  | PSNR     |
|-----------------------------|------|----------|
| aom --rt cpu-used=10        | 129  | 35.77 dB |
| SVT-AV1 preset 11           | 48   | 34.72 dB |
| VT HEVC (hardware)          | 117  | 34.75 dB |

Verdict, contrary to x86 conventional wisdom: **on Apple Silicon libaom's
realtime mode beats SVT-AV1 on both axes at once** (WebRTC's RT path,
well-NEON'd; SVT's strength is x86 AVX-512 + high core counts) and is the
only software AV1 that holds 1440p60 with headroom on the M4. At matched
bitrate it clears hardware HEVC by ~1 dB (≈ 15–25 % bitrate at matched
quality). The trade: HEVC costs ~zero host CPU (media engine); aom RT at
1440p60 costs roughly half of ten performance cores. Integration path when
wanted: vendor libaom (intentional-dependency treatment), AOMRegionEncoder
behind the existing codec-id field (3 = AV1, reserved), viewer decodes via
VT hardware AV1 (M3+) with dav1d as the documented fallback; HEVC remains
the default and the negotiation fallback. dav1d is decode-only — there is
no dav1d encoder.

### P6 — video regions over hardware HEVC (2026-08-05)

The quarantined multi-frame path (spec §11, opcode-0x08 family): sustained
incompressible churn forms a region; region tiles leave the record path
entirely and ship VideoToolbox HEVC frames on a dedicated reliable QUIC
stream; quiescence dissolves the region and a lossless repaint restores
byte-exactness. Lossy only where pixels are photographic-in-motion, exact
everywhere and everywhen else.

Full loop on the video synth (1280×720, 640×360 noise region re-noised
every frame for 4 s, `replay --mode loop --golden --video vt`):

| pipeline                    | total bytes | video stream | settle |
|-----------------------------|-------------|--------------|--------|
| lossless (pre-P6 baseline)  | 163.26 MB   | —            | byte-identical |
| P6 + mock codec             | 200.50 MB   | 172.25 MB    | byte-identical |
| **P6 + hardware HEVC**      | **30.52 MB**| **2.27 MB**  | **byte-identical** |

The steady-state region streams ~4.5 Mbps (225 frames / 2.27 MB) against
40.8 MB/s lossless — **~60× on the churning region**; remaining bytes are
cold start + the pre-formation lossless phase (~16 ticks) + the dissolve
repaint. Byte-identical at settle holds with real HEVC in the loop, and
under 5 % drop / 1 % dup / 10 % reorder / 20–80 ms jitter — the golden bar
did not move for P6.

Detection: per-tile hot map = sustained churn × incompressibility (sticky
class per position), integrated on *changed* (not merely qualified) tiles
and on INV-4-saturated ticks from dirty-rect hints — photographic churn is
what saturates the record pipeline, so formation evidence lives on exactly
the ticks the normal path skips. Encoder: VT HEVC, realtime, no
reordering, IDR on demand, ~0.2 bpp @ 60 Hz capped at 20 Mbps. Race note:
video frames carry an LWW stamp in the frame_seq domain and viewer blits
are per-tile gated — a straggler frame crossing the dissolve repaint on
the datagram path loses tile-by-tile (test-pinned).

Wire is codec-agnostic (VIDEO_START carries a codec id + opaque config):
AV1 is the intended successor for bandwidth (M3+ has hardware AV1 decode;
encode would be a software SVT-AV1 intentional dependency later).

### VP8L routing memory (positional outcome memory, 2026-08-05)

Implementation of the routescan conclusion: per-tile-position memory of the
VP8L probe's outcome, with exponential backoff (8 → 64 skipped probes) on a
non-decisive result and full reset on a decisive win. "Decisive" = beats the
cheap best by ≥ max(1/16, 32 B) — measurement forced this refinement: on
constant-alpha photographic churn LZBITMAP lands within tenths of a percent
of VP8L, so VP8L "wins" the marketplace by hair-thin margins while costing
~240 µs/tile, and a naive won/lost signal kept resetting the backoff (18 %
avoided instead of 96 %).

Results (`replay --mode encode`, `vp8l routing` line):

| trace              | probes avoided | encode p50     | bytes            |
|--------------------|----------------|----------------|------------------|
| video synth (churn)| 96 %           | 6655 → 1070 µs | +0.13 % (margin) |
| noise synth        | 82 %           | 1924 → 765 µs  | +0.25 %          |
| typing (5K)        | 0 % (correct)  | unchanged      | identical        |
| scroll (5K)        | 0 % (correct)  | unchanged      | identical        |

Zero engagement on text traces is the design working: VP8L keeps winning
decisively there, so the memory never routes it away — zero regret. The
hostility map (sustained churn + VP8L-hostility per position) is the seed
signal for the P6 region router. New synth kind `video` (fixed centered
region fully re-noised per frame) is the P6 workload shape. 9/9 goldens
byte-identical; 109 tests.

### Codec routing measurement (`glassact-bench routescan`, 2026-08-05)

Question: can cheap per-tile signals (LZ4 output size, left-delta zero
fraction) predict the winning codec, so expensive encoders run only where
they pay? Answer on the text corpora: **no** — every gating threshold has
byte-regret with almost no encode savings, because VP8L wins on nearly
everything text-like, *including tiles LZ4 rates incompressible* (typing
corpus: gating webp at lz4≤12 KB still costs +18.6 %). Retina-AA text looks
like noise to byte-LZ77 but yields to pixel-domain tools — so "LZ4 size =
complexity" conflates exactly the two classes routing must separate
(AA text vs photographic). Conclusions: (1) on text/UI, run the full
marketplace — the only legitimate router is the *time budget* (the existing
qualifying-tile-count gate); (2) the reliable photographic detector is
**outcome memory by position** — pay the expensive probe once, remember
per-region that it failed, decay/refresh — which is also precisely the
signal a P6 region router needs (sustained churn + webp-hostility →
VIDEO_REGION). Validating the photo half needs an images-class trace
(deleted; re-record when convenient).

### P3b — session tile cache (opcode 0x07, 2026-08-05)

AV1's IntraBC/patches idea, generalized across time and made race-free:
4096 host-allocated slots per side; STORE travels inside the payload record
(content + slot atomic — no assignment race); the viewer stores **on
receipt**, decoupled from the LWW canvas gate; 11-byte REFs carry the
expected content hash so slot desync is a clean counted drop; the host
memcmp-verifies every hit against its pixel mirror (hash never
load-bearing), never reuses slots with unresolved traffic, and dedupes
identical in-flight content.

| workload (steady, 5K) | before cache | with cache | cumulative vs v1 LZ4 |
|---|---|---|---|
| typing (incl. terminal scrolls) | 159 KB/s | **134.6 KB/s** | **3.8×** — 12 % above the 120 KB/s spec target, scrolls included |
| scroll (full-screen text) | 9.83 MB/s | **9.23 MB/s** | **5.8×** |

Scroll's modest increment was expected: the scroll op already satisfies most
repeat content; the cache earns its keep on blink/revert (typing) and will
compound on scrollback-heavy sessions (cachescan measured 67 % repeat
content overall). Golden byte-identical ×3 seeds on all on-disk traces with
refs flowing; blinking-content goldens under faults added to the suite.
107 tests green.

### Codec frontier survey + cache measurement (2026-08-05)

**JPEG XL lossless** (libjxl via local probe, real tile corpora): e5 reaches
449 B/tile on text — still behind VP8L z4's 379 — at a quarter of the speed
(16.6 vs 66 MB/s); marginal 5 % win on the typing corpus. The newest
general-purpose lossless contender, measured and declined at tile
granularity (per-tile codestream overhead + VP8L's screen-content tools
decide it).

**Session tile cache (reserved opcode 0x07) sized via `glassact-bench
cachescan`**: on the full-screen scroll trace, **67.2 % of changed tiles are
byte-exact repeats of content already seen in the session** (26.3 % at the
same position — blink/revert); typing trace: 21.8 %. A cache-reference
record costs ~10 B vs ~379 B compressed payload. This is AV1's
IntraBC/patches idea adopted natively across time, and it is the largest
remaining lever on text workloads.

### VP8L tile codec (vendored libwebp, opcode 0x0A) + in-house exploration (2026-08-05)

First deliberate third-party dependency (ThirdParty/THIRD_PARTY.md): libwebp
v1.5.0, VP8L lossless only. The encode phase was restructured for it —
qualify (serial) → **parallel per-tile payload encode** across a worker pool
(best-of RAW/LZ4/LZBITMAP always; WEBPL z4 when ≤ 320 qualifying tiles) →
pack (serial). Decode is allocation-free (`WebPDecodeBGRAInto`). Encode-side
`WebPEncode` allocates internally — documented INV-7 deviation, bought for:

| workload (steady, 5K) | v1 LZ4 | +P3 | +LZBITMAP | **+VP8L** | cumulative |
|---|---|---|---|---|---|
| scroll (full-screen text) | 53.6 MB/s | 15.45 | 14.6 | **9.83 MB/s** | **5.5×** |
| typing (incl. terminal scrolls) | 514 KB/s | 514 | 313 | **159 KB/s** | **3.2×** |

Golden byte-identical ×3 seeds on all on-disk traces with WEBPL payloads
flowing; 102 tests green. Typing encode p95 sits at 17.0 ms (marginally over
the 16.7 ms budget on webp-eligible scroll-burst ticks — tunable via effort
level or the 320-tile limit; INV-4 coalescing degrades gracefully meanwhile).

**In-house predictor exploration (P2′), measured and closed:** best-of
none/left/up/avg spatial predictors + LZBITMAP residuals gains **0 %** on the
text corpus (728 → 728 B/tile) and 5 % on typing. VP8L's 2× does not come
from simple linear prediction — it comes from the full screen-content
toolbox (pixel-LZ77 with color cache, palette, per-subblock predictor
selection, canonical Huffman). Building a competitive in-house codec means
reimplementing VP8L; with the reference implementation vendored and integrated,
that effort is better spent elsewhere (P4/P6 for the photographic ceiling).

### Codec evaluation & LZBITMAP baseline (2026-08-05)

Per-tile A/B on real changed-tile corpora (`glassact-bench codecs` /
`dumptiles` + external probes), text corpus, avg B/tile @ encode MB/s,
losslessness round-trip-verified:

| codec | B/tile | speed | lossless | verdict |
|---|---|---|---|---|
| LZ4 (old baseline) | 1,051 | 4,438 | ✅ | fastest |
| **LZBITMAP (new baseline, opcode 0x09)** | **737** | **857** | ✅ | shipped: best framework ratio/speed |
| zlib / LZFSE | 666 / 792 | ~350 | ✅ | dominated by LZBITMAP |
| PNG (ImageIO) | 1,096 | 111 | ✅ | zlib + container tax |
| HEIC (ImageIO, per-tile) | 1,193 | 0.8 | ❌ | per-call session cost; lossy only |
| AVIF (ImageIO) | — | — | — | refuses lossless; q0.8 lossy @7.6 |
| libavif lossless s10 | 1,992 | 22 | ✅ | dominated by WebP on every axis |
| **libwebp lossless z4** | **379** | 66 (1-core) | ✅ | **2× better than LZBITMAP** — third-party |
| libwebp lossless z0 | 824 | 145 | ✅ | |

WebP is decode-only in macOS ImageIO (no system encoder); libwebp/libavif
probes are measurement-only (Homebrew), not linked into the product. The
VP8L result revises the P2 outlook: spatial **prediction** (not palette
alone) is what beats retina-AA text — a VP8L-style predictor+entropy tile
codec is worth ~2× over LZBITMAP if built in-house (or libwebp adopted by
explicit dep-rule exception). HEVC (the HEIF payload) has no lossless mode
in Apple's hardware encoders — VideoToolbox remains the *lossy region*
answer (P6), not a tile codec.

LZBITMAP baseline results (adaptive: best-of RAW/LZ4/LZBITMAP on ticks
≤ 320 qualifying tiles, LZ4/RAW above): typing steady 514 → **313 KB/s
(−39 %)**; scroll 15.45 → 14.6 MB/s (−6 %, capped by the adaptive limit);
scroll encode p95 16.0 ms (within budget). Golden byte-identical ×3 seeds
on all three on-disk traces.

### P3 — scroll pipeline (wire v2, 2026-08-05)

Design (measured-first: `glassact-bench analyze`/`scrollscan` showed P2 palette
projecting only 1.3–1.4× against retina-AA text while 86.9 % of scroll tiles
were byte-exact copies at a global dy — the roadmap order was inverted with
sign-off). The scroll ships as a **SCROLL control op** (reliable, ordered,
LWW-gated per tile), so datagram payloads stay 100 % absolute (INV-1 intact).
The host keeps an ACKed **pixel shadow canvas** (INV-3 at pixel granularity,
fed by per-batch retention on ACK), votes a global dy via probe-row
signatures, verifies each tile by memcmp against the shifted shadow with
reference-safe sources (ACKed ∧ no send in flight), and ships only residuals.
The record-vs-TLV arrival race is closed by **SCROLL_ACK**: the viewer
reports every tile whose seq beat the scroll (whole grid, not just the rect),
and the host invalidates dependent destinations — repair by information, not
pessimism.

Results on the full-screen scroll trace (5K):

| | v1 (absolute tiles) | P3 (scroll + residuals) |
|---|---|---|
| sustained | 53.6 MB/s | **15.45 MB/s (3.5×)** |
| tiles sent | 1,049,126 | 325,661 |
| encode p50/p95 | 6.2 / 8.1 ms | 9.7 / 11.3 ms (detection adds ~3.5 ms on scroll ticks; < 16.7 ms budget) |

Golden: byte-identical ×3 seeds on **all** on-disk traces (typing, idle,
scroll) under the standard fault mix. Getting there surfaced three protocol
bugs, each found by golden replay + per-tile forensic tracing
(`GLASSACT_TRACE_TILE`): a scroll/residual seq collision (LWW-blocked every
same-tick residual while the host committed their ACKs), a nondeterministic
dy tie-break via hash-seeded Dictionary order, and out-of-rect snapshot
contamination by early residual datagrams (invisible to an in-rect-only skip
report). Headroom vs the 7× eligibility ceiling: bbox over-scroll residuals,
detection cost, and repair conservatism.

### Live loopback session (first end-to-end demo, 2026-08-05)

Host (SCContentSharingPicker → SCK 5120×2880) → QUICTransport loopback →
Viewer (IOSurface flip-pool present). Steady-state glass-to-glass
p50 34.6 ms / p95 67.7 ms over a 5000-sample window while using the machine
normally. Getting here surfaced two scale bugs invisible to small tests, both
now regression-covered by `QUICSustainedSessionTests` at demo scale
(~14k-datagram batches): unpaced datagram bursts (deterministic tail loss →
convergence never completes; control stream starved to ETIMEDOUT) and the
§4.2 timeout expiring while large batches were still serializing (re-encode
thrash). Fixes: transport send pacing (256 in flight / 4096 queued /
counted overflow drops) and a batch-size serialization allowance on the
timeout (50 MB/s floor).

### v1 acceptance run (2026-08-05)

| criterion | status |
|---|---|
| invariant/property/fuzz tests green | ✅ 88 tests, debug + release + ASan |
| golden byte-exact at 5 %/1 %/10 %, 3 seeds | ✅ synthetic + all four real traces (typing, scroll, images, mixed) |
| typing: encode p95 ≤ 300 µs/batch | ⚠️ 2.6 ms at 5K. p95 batches are terminal-buffer **scrolls** (~160-tile full-window events on newline — 16 of 65 batches) whose serial LZ4 encode dominates; keystroke-only batches sit at the diff floor (735 µs p50 full-scan, less when SCK rects arrive). Remaining levers: parallel LZ4 encode, idle-region suppression; scroll bytes themselves are P3 COPY territory. |
| typing: sustained ≤ 120 KB/s | ⚠️ 514 KB/s steady-state — but decomposed via `glassact-trace --diff`: 206 keystroke events × 3.7 tiles avg ≈ **~100 KB/s ✅**, while 16 scroll/repaint events carry 80 % of steady bytes. Buffer scroll under absolute tiles is the designed P3 (COPY/scroll-detect) workload; keystroke bandwidth meets the target. |
| idle: 0 datagrams after settle | ✅ v2 (67 s hands-off, golden ×3): longest span of **25.2 s with zero SCK frames and zero datagrams**; the only mid-trace changes are genuine macOS UI — menu-bar clock ticks of exactly 2 tiles (each shipping ~2 tiles, nothing more) and a Dock reveal animation — plus the start/stop cursor interaction at the edges, all localized by `glassact-trace --diff`. When nothing changes, nothing ships; when 2 tiles change, 2 tiles ship. |
| scroll: no capture starvation at 60 Hz | ✅ v3 full-screen: 0 dropped captures at ~53 fps effective with ~1,220 tiles/batch; encode p95 8.11 ms < 16.7 ms budget. |
| scroll: bandwidth recorded as P2/P3 baseline | ✅ v3 full-screen text scroll: **53.6 MB/s steady** (~1.0 KB/tile after LZ4) — 3.3× the quarter-screen v2 figure of 16.4 MB/s, matching the damage-area prediction. This is the byte pile P3's COPY/scroll-detection deletes. |
| glass-to-glass p50 ≤ 35 ms loopback | ✅ **34.6 ms p50 / 67.7 ms p95** (n=5000, live 5K loopback demo, Release builds; capture_ts = SCK presentation timestamp → present flip). Cold-start full-frame transfer ~250 ms. |

**Typing caveats:** the targets assumed 4K, plain-terminal minimal damage, and
tight dirty rects. The measured trace was 5K, the Claude Code TUI animates
(spinner / status line), and SCK rects are window-coarse.

**M4 tuning results (2026-08-05):** levers 1 and 3 landed —

1. ✅ Diff pass hashes in place from the strided buffer (no per-candidate
   16 KB copy) and fans out across cores above 128 candidates; tight
   extraction only for qualifying tiles. **Full 3600-tile scan at 5K: p50
   875 µs / p95 1080 µs, was ~3.7 ms / 5.6 ms — 4.3×** (`glassact-bench synth
   --kind fullscan` micro-benchmark; goldens still byte-identical).
2. Idle-region suppression: not needed yet — revisit only if a clean
   plain-terminal typing re-record still misses the 300 µs p95 target.
3. ✅ Viewer keepalives re-ACK every active incomplete batch (§3.5 deviation,
   documented in ViewerEngine) — stragglers of the older open batch no longer
   force timeout cold-resends.

Typing encode/bandwidth acceptance still needs re-measuring against a clean
plain-terminal typing trace (the original was deleted and was TUI-animated
anyway).

### Golden divergence baselines (replay `--mode loop --golden`, standard faults, seeds 1–3, 2026-08-05)

| trace | result | dropped datagrams per run |
|---|---|---|
| typing v1 | byte-identical ×3 | ~3,000 |
| typing v2 | byte-identical ×3 | ~2,000 |
| idle v2 | byte-identical ×3 | ~2,500 |
| scroll v2 | byte-identical ×3 | ~18,000 |
| scroll v3 | byte-identical ×3 | ~65,000 |
| scroll | byte-identical ×3 | ~16,000 |
| images | byte-identical ×3 | 126k–141k |
| mixed | byte-identical ×3 | 37k–50k |

The first typing-trace golden run **failed** (1 divergent tile) and exposed a
§4.4 spec hole: timeout kept `ackedHash` for a send the viewer had actually
applied, and content that *reverted* to the acked hash never re-qualified —
permanent divergence on blinking/reverting content (menu-bar clock). Fixed by
invalidating `ackedHash` on timeout (deviation documented in
`HostEngine.swift`, regression test
`timeoutInvalidatesShadowMap_revertRegression`). All traces pass since.

### Encode baselines (replay `--mode encode`, release, 2026-08-05)

| trace | p50/batch | p95/batch | max | bytes/frame | sustained | tiles sent | batches |
|---|---|---|---|---|---|---|---|
| typing v1 (TUI) | 3.18 ms | 5.60 ms | 53.7 ms | 152.7 KB | ~1.4 MB/s | 7,255 | 235 |
| typing v2 (post-tuning) | **0.74 ms** | 2.6 ms | 60.1 ms | 154.3 KB | 514 KB/s steady | 6,869 | 65 |
| scroll v1 (half-screen) | 8.15 ms | 10.6 ms | 37.0 ms | 1.15 MB | 27.2 MB/s | 368,645 | 456 |
| scroll v2 (quarter-screen, post-tuning) | 2.81 ms | 3.62 ms | 30.9 ms | 575.7 KB | 16.4 MB/s steady | 241,945 | 489 |
| scroll v3 (full-screen, post-tuning) | **6.18 ms** | 8.11 ms | 11.4 ms | 1.01 MB | **53.6 MB/s steady** | 1,049,126 | 860 |
| images | 4.16 ms | 56.2 ms | 86.6 ms | 7.65 MB | 157.4 MB/s | 717,989 | 579 |
| mixed | 1.98 ms | 28.6 ms | 63.6 ms | 1.62 MB | 32.7 MB/s | 282,374 | 437 |

Cost-center reading:

- **typing** is candidate-hashing bound: SCK dirty rects are coarse
  (window-granularity, plus a recurring full-width top strip), so each tick
  hashes ~2,000 candidate tiles (~33 MB xxh64) to find ~31 changed ones. The
  ~3.2 ms p50 *is* the hash sweep. Frames without usable rects (~20 %) full-scan
  all 3,600 tiles.
- **scroll** is LZ4-encode bound: ~808 compressible tiles per batch.
- **images** is RAW/bandwidth bound: photographic tiles defeat LZ4 (trace
  itself only compressed to 44 %), so heavy swipes ship ~16 KB RAW tiles.
  157 MB/s is the v1 ceiling that P2 (palette/rANS) and P5 (GPU surge path)
  exist to attack.
- **mixed** is bimodal: hover video playback keeps damage localized to the
  playing thumbnail (p50 2.0 ms — small candidate sets, churning content:
  the P6 video-region workload in miniature), while scroll bursts spike to
  the scroll profile (p95 28.6 ms).

For scale, the synthetic 640×400 demo trace that preceded these real
captures ran at encode p50 61 µs/batch, 76.7 KB/frame.

### Reference traces (2026-08-05)

| trace | content (capture conditions matter — see notes) | frames | duration | fps |
|---|---|---|---|---|
| typing | plain Terminal.app, ~5 cps (v2 re-record; v1 was a TUI-animated Claude Code session) | 260 | 32.6 s | ~8 |
| scroll | v3: **full-screen** markdown in Zed, steady wheel scroll (v1/v2 were ~quarter-screen GitHub UI) | 1081 | 20.4 s | ~53 |
| images | Photos.app full-screen browsing/swiping | 782 | 38.0 s | ~20 |
| idle | static screen, hands off (v2: 67 s hands-off span) | 31 | 67.5 s | — |
| mixed | YouTube: scrolling + hover video playback | 835 | 41.3 s | ~20 |

Files: `typing` = `glassact-1785961372.scap` (6.3 GB), `idle` =
`glassact-1785961857.scap` (3.1 GB), `scroll` = `glassact-1785962837.scap`
(1.5 GB — dark-theme markdown LZ4s to 2.4 %, so the full-screen trace is
the smallest file).
