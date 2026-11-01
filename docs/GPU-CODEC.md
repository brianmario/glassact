# A GPU-native screen codec: plan and ideas

Status: **ideas only**. Nothing here is built, and nothing in DESIGN.md changes until a prototype
passes the gate in [Plan](#plan). This branch (`gpu-codec`) holds the design until then.

## Why consider it

Glass Act's video path today is HEVC (VideoToolbox) for motion. The `metal-av1` branch has our own
AV1 encoder (Metal analysis, a Rust closed loop). AV1 keeps hardware decode, and we control every
decision the encoder makes. But some limits are in the format itself, not in our encoder:

- **Intra prediction is a serial chain.** A block predicts from its decoded neighbours, so the
  encoder has to reconstruct in decode order. Any codec with spatial intra prediction (HEVC, VVC,
  AV2) has the same chain. Tiles and wavefronts only shorten it.
- **Entropy coding adapts after every symbol.** AV1's CDFs update symbol by symbol, so a tile is
  coded on one thread, and decoders work the same way.
- **Hardware decode is 4:2:0.** AV1 Main profile (what Apple's decoders support) has half-resolution
  chroma, which smears coloured text and thin UI lines.
- **References are whole frames.** Glass Act's model is a replica canvas of tiles, each
  last-writer-wins and repaired by re-encoding (DESIGN §0, INV-5). AV1's references are whole reference
  frames in slots, so a loss is repaired with a key frame or a new reference.

What we measured on `metal-av1` (2026-11-01, BENCHMARKS):

- With every block reconstructed in dependency order on all threads, 5K photos' closed loop went
  from 5.3 to 3.7 ms. The chain was no longer the limit; total CPU was: 24–36 ms of CPU a picture,
  half of it the quantizer's trials.
- 5K inter frames a second, ours vs libaom realtime (speed 9): typing 304 vs 225, scroll 213 vs
  170, photos 84 vs 92.
- libaom realtime's palette (colour-count heuristic) costs 7–34 % more bytes at equal PSNR-Y on our
  traces, and 6–16 % at equal RGB SSIM. Screen-content tools need decisions by cost, not
  heuristics.
- A 5K typing frame's 8x8 blocks: 37 % flat, 24 % with 2–8 luma values, 39 % with more
  (antialiased text has many grey levels).

## Goal and gate

Beat **both** VideoToolbox HEVC (the hardware encoder Glass Act uses now) and libaom realtime, on
the reference traces (typing-cc, scroll-win, photos, cursor-drag, at 720p and 5K):

- **Bitrate:** fewer bytes at equal quality, by BD-rate on SSIMULACRA2 and PSNR-Y (RGB scoring, as
  the Viewer shows it).
- **Encode speed:** more frames a second than both, with the Host's CPU mostly free.
- **Decode:** real time at 5K60 on the oldest supported Mac and on iPad, with the power cost
  measured against hardware decode.
- **Latency:** no lookahead: every frame coded on its own capture.

If a CPU prototype can't show the bitrate win, stop. The speed win only matters once the bitrate
win is real.

## Design ideas

The rule: borrow the tools that work from HEVC, VVC, AV1/AV2, JPEG XL and RDP, and drop every
serial dependency inside a frame. Every stage is a data-parallel pass on Metal, in the encoder and
in the decoder.

### Prediction without a chain

- **Coarse to fine instead of neighbour to neighbour.** Code a low-resolution layer first (for
  example 1/8 scale, or each block's DC), all blocks in parallel. Each finer level predicts from the
  decoded coarser one, which every block can read at once. The dependency depth is the number of
  levels (3–4), not the number of blocks. Prior art: JPEG XL's progressive DC and modular
  predictors, LCEVC's enhancement layers, Laplacian pyramids.
- **Directional prediction from the coarser layer.** Angles and smooth modes like AV1's, but the
  edge samples come from the upsampled coarse reconstruction, not from finished neighbours.
- **Temporal first.** Most screen frames are mostly unchanged or moved content. Exact copies,
  scrolls and shifted 64x64s (the copy finder `metal-av1` already has) come before any residual
  coding.

### Screen-content tools, all parallel

- **Palette**, with the index map's contexts taken only from inside the block (HEVC SCC and VVC
  palette, minus the cross-block predictor list). Chosen by real cost.
- **Transform skip and block DPCM** (the residual coded as row or column differences) for sharp
  text and edges (HEVC SCC, VVC).
- **A glyph and patch cache** that lasts across frames: a block that equals a cached one (by hash)
  is coded as its index. Like RDP's glyph cache, and like intra block copy without the same-frame
  restriction.
- **Lossless blocks** where they are cheaper, so Glass Act's lossless tile path becomes a mode of
  the codec instead of a second pipeline.

### Colour

- **4:4:4 throughout**, or 4:2:0 picked per region where it saves bits (photos, video).
- **A reversible colour transform per block** (YCoCg-R, as VVC's ACT), so lossless and
  near-lossless blocks stay exact.

### Transforms and quantization

- Integer DCT/DST in sizes 4–32 (AV1's and VVC's), and identity for transform skip. All of these
  map well to SIMD-group matrix operations.
- Dead-zone quantization with perceptual weighting, and rate-distortion decisions on the GPU from
  exact rates (next section).

### Entropy coding without serial adaptation

- **Interleaved rANS:** a picture's symbols split over many independent lanes (32–64 per
  threadgroup), so both ends code in parallel. Prior art: JPEG XL's ANS, GPU rANS work such as
  DietGPU and Recoil.
- **Probability tables per frame**, from a parallel histogram pass, sent in the frame header
  (compact, or as deltas from the previous frame's tables).
- **Context modelling from data available in parallel:** the coarser layer, the previous frame,
  and quantized magnitudes inside the block. This is how we win back the 5–10 % that static tables
  usually give up against AV1's adaptive CDFs.
- A bonus of static tables: every symbol's cost is known exactly before coding, so the GPU's mode
  decisions use true rates, not estimates.

### Filtering

- A parallel deblocking filter, and a CDEF-like directional filter on the decoder's GPU, each
  signalled per region. Screen content at high quality may want neither: measure.

### Fitting Glass Act's model

- **References per tile, not per frame:** a block predicts from its tile's last state the Viewer
  acknowledged (the replica canvas), so loss is repaired by re-encoding the affected tiles, with no
  key frames and no retransmission (DESIGN §0, INV-5).
- **Partial frames:** only dirty regions are coded, as the tile path does today.
- **The wire:** a new message type behind a caps bit (DESIGN §3.8, §12). The HEVC and tile paths
  stay for peers without it.

## What it costs

- **Power:** GPU decode on an iPad draws more than hardware AV1 or HEVC decode. It must be
  measured, and battery may need a fallback to HEVC.
- **Interoperability:** the stream is only ours. That's fine inside Glass Act, but recordings or
  web viewers would need another path.
- **Effort:** an encoder, a decoder, a CPU reference for the tests, and a format spec. The AV1
  work's rules carry over: a bit-exact CPU reference, differential tests with fixed seeds,
  `INV_*`-style invariants for the format.
- **Format risk:** the bitstream must be frozen with versioning before it ships, because a Host and
  a Viewer of different releases must interoperate (DESIGN §12).

## Plan

1. **Baselines.** Measure VideoToolbox HEVC (4:2:0 and 4:4:4, realtime) next to libaom realtime and
   `metal-av1` on every reference trace: BD-rate on SSIMULACRA2 and PSNR-Y, encode frames a second,
   decode cost. Record them in BENCHMARKS. (Hardware-encoder benches only while no one is
   connected.)
2. **CPU prototype in Rust** (std only, like `rust/av1`): coarse-to-fine prediction, palette,
   transform skip, interleaved rANS with per-frame tables. Measure only bytes and quality, not
   speed.
3. **Gate:** a BD-rate win over both baselines on screen traces, and no worse than libaom on
   photos. Otherwise stop, and keep what we learned for the AV1 encoder.
4. **Metal encoder**, bit-exact with the prototype.
5. **Metal decoder** for macOS and iPadOS, bit-exact with the prototype. Measure 5K60 decode time
   and power.
6. **Glass Act integration:** a new message type behind a caps bit, per-tile references,
   loss-repair tests with fixed seeds.

## Open questions

- How many coarse levels, at what scale, and does predicting from a coarser layer lose much against
  neighbour intra prediction on photos?
- Is a per-frame table enough, or do large frames need per-region tables?
- How to rank ideas: which single tool (palette, glyph cache, 4:4:4) is worth the most bytes on our
  traces? The AV1 palette work on `metal-av1` answers part of this first.
- Can we keep a hardware-decodable fallback inside the same pipeline (encode HEVC for battery-bound
  Viewers from the same analysis)?
