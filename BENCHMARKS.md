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
| Tile governor on a thin link | 224–350 KB/s on a 250 KB/s link; worst backlog 183–380 ms | `GovernorTests` rig | 2026-09-28 |
| 5K trace over a 2 Mbit/s link, 2 s buffer (time from the last frame to exact) | typing-cc 51.1 s · scroll-win 50.6 s · cursor-drag 48.4 s; queue p95 2.0 s | loop replay `--video mock --link-mbit 2` | 2026-10-22 |
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

Details: "Reference traces v2" (2026-08-07) and "Reference traces"
(2026-08-05) in the log.

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
| VT low-latency rate control | rejected | overshoots 20–100 % (9× on photos), no latency gain | [entry](#video-layer-quality-low-latency-rc-and-half-res-encode-measured-2026-09-29) |
| Half-resolution encode, upscaled | rejected | text tops out near SSIM 0.93; full res passes it at 1 Mbit/s | [entry](#video-layer-quality-low-latency-rc-and-half-res-encode-measured-2026-09-29) |
| VT constant quality factor (macOS 27) | rejected | byte-identical while a bitrate is set; Apple's preset adds ~130 ms of lookahead | [entry](#macos-27-videotoolbox-constant-quality-and-super-resolution--neither-usable-2026-10-10) |
| VT low-latency super-resolution | rejected | input capped at 1280 px; nothing screen-sized fits | [entry](#macos-27-videotoolbox-constant-quality-and-super-resolution--neither-usable-2026-10-10) |

**Rate control and transport**

| idea | verdict | key number | entry |
|---|---|---|---|
| Global send governor (P6e) | kept | photos loop 63 → 17.1 Mbit | [entry](#p6e--global-send-governor--full-screen-region-snap-2026-08-07) |
| Auto send rate instead of a fixed 25 Mbit cap | kept | loopback rounds 2.35–3.98 s → 0.74–0.77 s | [entry](#auto-send-rate-replaces-the-fixed-25-mbit-ladder-2026-09-27) |
| Auto bounded by encode duty | kept | scroll v3 on a fast link: 392 → 62 MB, 220 → 51 s encode CPU | [entry](#auto-bounded-by-encode-headroom-2026-09-27) |
| Slow start, late-ACK delay samples, 32 KB/s floor | kept | thin-link rig: 8.4 MB/s → 224–350 KB/s on a 250 KB/s link | [entry](#tile-governor-on-thin-links-late-acks-loss-slow-start-2026-09-28) |
| Fresh tiles before owed tiles | kept | keystrokes no longer queue behind a dissolve repaint (live spikes were 0.6–1.8 s) | [entry](#fresh-before-owed-admission-video-cap-on-an-unmeasured-queue-2026-09-29) |
| Datagram pacing, then adaptive pace | kept | 6 loopback rounds ~28 s → ~11 s with 0 lost | [pacing](#datagram-pacing-burst-loss-at-the-viewers-receive-buffer-2026-09-27), [adaptive](#adaptive-datagram-pacing-2026-09-27), [cold start](#cold-start-phantom-loss-stale-send-stamps--pacer-overflow-2026-09-27) |
| Video send gate in time at the drain rate | kept | 3 Mbit/s relay: p50 1,900 → 53 ms | [entry](#video-send-gate-time-at-the-drain-rate-not-bytes-2026-09-28) |
| CUBIC-style video cap recovery | kept | back to 70 % in 2.0 s instead of 9.25 s | [entry](#video-cap-cubic-style-recovery-after-a-hiccup-2026-09-29) |
| 3 Mbit/s video cap until the link is measured | kept | p95 from connect 574–755 → 145–673 ms | [entry](#video-startup-3-mbits-cap-until-the-link-is-measured-2026-09-30) |
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
