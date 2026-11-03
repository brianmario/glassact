# A different AV1 encoder architecture for motion (proposal, 2026-11-03)

A proposal for discussion, not a decision. Revised the same night after its first two
experiments (below): they moved it away from cheap decisions and toward pipelining. The goal set on 2026-11-02 was 60 pictures a second
at 5K through a full-screen change, at better bitrate and quality than hardware HEVC and libaom.
The bytes are won (BENCHMARKS, "GOLDEN_FRAME…"); the speed isn't. This note says why the encoder
on `metal-av1` can't get there by tuning, what the workload needs, and an architecture that could,
with the experiments that would prove or kill it before it's built.

## What the encoder is today

The hybrid (`AV1HybridEncoder`): the GPU analyzes each picture (an RD search over every block
shape and intra mode, learned pruning, a motion search); the CPU's closed loop reconstructs and
quantizes it block by block on 14 cores (tx type search, RDOQ); the GPU deblocks and applies CDEF
(searching CDEF's strengths); a writer thread entropy-codes it. Copies of the previous picture
and of GOLDEN_FRAME's are decided on the CPU from the sources, ahead, and skip the analysis.

## Where it stands at 5K

| content | inter frames a second | against libaom / HEVC (BD-rate) |
|---|---|---|
| scrolling, dragging, typing (copies at a shift) | 160–230 | −33 to −58 % / −68 to −84 % (2026-11-01) |
| two screens in turn (app, Space or tab switching) | 48–128 | −87 to −91 % / −88 to −96 % |
| every picture new (four traces in turn) | 18–20 | −7 to −11 % / −23 to −44 % |
| every picture new, everything cheap (squares, no motion search, no tx search, tiles 4x1) | 30–35 | +8 / −1 % / −36 / −14 % |

Only the last two rows miss 60. A picture of new content costs, at q20:

| stage | where | today | everything cheap |
|---|---|---|---|
| analysis | GPU | 42 ms | 19 ms |
| closed loop | CPU, 14 cores | 18.5 ms | 10.2 ms |
| filters | GPU | ~9–11 ms alone (14–21 shared) | ~9–11 ms |
| writer | CPU thread | 8.4 ms | 6.3 ms |

## Why tuning can't reach 60

1. **A serial chain.** The next picture's closed loop predicts from this picture's filtered
   output, so it waits for the GPU's filters, and the next closed loop also waits for this
   picture's writer (they share the CPU state). Wait for the write, closed loop, filters:
   ~28 ms a new picture even with the cheapest analysis. Pipelining the analysis doesn't help;
   the chain is the period.
2. **RD analysis on every shape.** Even squares only cost 19–26 ms of GPU at 5K. Fewer shapes
   than that cost bytes fast (8x8 and 16x16 only: +30 %) and make the CPU slower (its cost follows
   the number of blocks).
3. **The GPU can't take the closed loop.** av1gpu's GPU closed loop (98 dependent wavefront steps
   at 5K) takes 749 ms a picture. Intra prediction reads the reconstruction of the block before
   it, so a tile is sequential; a GPU runs it at a few threads per tile.
4. **No hardware AV1 encoder** on the M4 Pro (VideoToolbox lists HEVC, H.264, ProRes and JPEG).

## What the workload needs

Glass Act already settles a still screen with lossless tiles, and the video layer only has to
look about as good as HEVC while things move (BENCHMARKS, "Live AV1 encoders…"). So:

- **Rigid motion** (scrolling, dragging, window animations) is copies at a shift: done, 160+.
- **A switch** (app, Space, tab) is one new picture, or a copy of GOLDEN_FRAME's: its latency
  matters (one picture, ~55 ms today), not a rate.
- **Video playing full screen** is the case that is new every picture. There is no trace of it
  yet (scripts/pruner-traces.txt asks for one). It is natural content with real motion, where a
  motion search pays and where hardware HEVC is already in the product.
- **Every picture unrelated to the last two** (the four-trace rotation) is a stress test, not a
  workload: nothing on a screen changes completely 60 times a second except video.

So 60 a second matters for video and big animations, and a fast first picture matters for
switches. Neither needs the key frame's RD search: the settle path (tiles, or this encoder's RD
mode once motion stops) restores full quality.

## First experiments, run the same night

1. **Decisions without RD lose too much.** The CPU's open-loop proxy (`Decider::node`: squares,
   NONE vs SPLIT and the mode by a Hadamard-domain RD proxy, no quantization; capped at 32x32,
   since a 64x64 transform codes only its 32x32 lowest frequencies and the proxy doesn't see that)
   in place of the GPU's partition in pictures of new content: **+64 to +76 % bytes** against
   today's (+46–66 % against libaom; level with HEVC by PSNR, +27 % by SSIMULACRA2). The same
   squares through the GPU's RD search cost +1.6 %. The RD analysis earns the bytes; keep it.
2. **The Rust post-filters on the CPU:** deblocking and CDEF of a dense 5K picture take ~70 ms on
   one thread (random content, the worst case): ~5–7 ms if spread over superblock rows on 14
   cores. Comparable to the GPU's, and with no round trip.
3. **The CPU's work a picture**, from user + system time over 40 more pictures of the rotation:
   ~480 core-ms (~380 with everything cheap), the bench's own reading, conversion and libaom
   decode check included. At 60 a second 14 cores give at most ~233 core-ms a picture (fewer: 4
   are efficiency cores). So beyond the chain, the CPU's work has to roughly halve, and so does
   the GPU's (squares alone: 19–26 ms of analysis, before the filters).

So the sketch below is replaced by the revised one after it.

## The first sketch (replaced): a motion mode beside the RD mode

Keep today's encoder as the **RD mode** for key frames, the first picture after a switch and the
settle. Add a **motion mode** for pictures that are mostly new, built to have no chain longer than
one stage:

1. **Decisions on the GPU without RD** (libaom realtime's `nonrd` idea): a variance pyramid picks
   the partition by thresholds (one shape per pixel, not five), a few intra modes per block by
   SATD with a rate model, and a hierarchical motion search on downscaled pictures (the GPU's
   strength). Estimate: 4–8 ms at 5K, against 19–42.
2. **The closed loop on the CPU without trials:** DCT (and IDTX for text), one quantizer pass,
   no tx type search, no RDOQ. Today that's ~10 ms at 5K with RD decisions; fewer, larger blocks
   from a variance partition should cost less.
3. **The filters in the closed loop, per superblock row, on the CPU** (the Rust post-filter is
   there, with NEON), or none in motion mode: the reference is ready when the closed loop ends,
   with no GPU round trip in the chain. CDEF strengths from the quantizer (libaom realtime's
   `CDEF_PICK_FROM_Q`), not a search.
4. **The writer overlapped with the next closed loop, delivering each frame from its own
   thread**, so it adds no latency (the overlap was declined for the latency of delivering on
   the encoding thread; this form doesn't have it). More tile columns halve its time for
   +0.2–0.6 % (SSIMULACRA2).
5. **Later, if needed: frames in flight** (x265's frame threads): the next picture's closed loop
   starts on a superblock row once the rows its motion vectors reach are filtered.

Budget at 60 a second (16.7 ms each, pipelined):

| | GPU | CPU, the chain | CPU, beside it |
|---|---|---|---|
| decisions | 4–8 ms | | |
| closed loop + filters | | 10–14 ms | |
| copies, GOLDEN_FRAME | | | 5–10 ms (ahead) |
| writer | | | 5–6 ms |

What it costs: bytes in motion. "Everything cheap" already costs +12–15 % against today and
stays 14–36 % under HEVC; motion mode will cost more. How much is the first experiment's job.

What it keeps: the writer and parser, copies, GOLDEN_FRAME, intra block copy key frames, the
learned models (RD mode), the Metal analysis (RD mode), the filters' Metal code (RD mode).

## The revised proposal: the same decisions, pipelined, with half the work

1. **Keep the RD analysis on the GPU**, with squares in pictures that are mostly new
   (`newPictureShapeMask`, +1.6 %): 19–26 ms. Make its square kernels about twice as fast
   (they were tuned for the full shape set: per-shape work, threadgroup shapes, the leaves).
   Target ≤ 12 ms at 5K.
2. **Take the filters off the GPU and into the closed loop**, per superblock row on the CPU
   (Rust, NEON, rows in parallel behind the reconstruction), with CDEF's strengths from the
   quantizer in motion (no search). The next picture's closed loop no longer waits on the GPU,
   and the GPU's time is the analysis alone.
3. **Halve the closed loop's CPU work in motion:** no tx type search (the closed loop 18.5 → 10.9
   ms, +7–9 %; or its learned pruning, +0.2–0.6 %), and count what RDOQ, chroma and the copy
   decisions cost before choosing more.
4. **The writer overlapped with the next closed loop, delivering each frame from its own
   thread** (no added latency), with 4x1 tiles in motion (writer 8.4 → 5.5 ms, +0.4 %
   SSIMULACRA2).
5. **Frames in flight** once 1–4 hold: the next picture's closed loop starts on a superblock row
   when the rows its references reach are filtered.

What it would cost in bytes: about "everything cheap" (+12–15 % against today, level with
libaom, 14–36 % under HEVC), or less with the learned tx pruning in place of no search. What it
needs that's new: the row-parallel CPU filters, the overlapped writer, and the kernel work. What
60 a second needs is all of it; each step is worth having alone (the chain shortens as each
lands).

## The experiments, in order (each can kill the plan)

Done: decisions without RD (killed: +64–76 %), a first timing of the CPU filters (plausible).
Next:

1. **Core-ms per stage**, measured cleanly (the closed loop, the copy decisions, the writer,
   reading the analysis), to know which CPU work to halve. Kill the CPU side of the plan if the
   closed loop alone needs more than ~150 core-ms a 5K picture without its tx search.
2. **Row-parallel CPU filters in the closed loop**, timed on real pictures and checked against
   the GPU's output (they must be byte-identical: both are the spec's). Kill the move if they
   take more than ~6 ms at 5K.
3. **The square kernels twice as fast** on the GPU (profile per shape with only squares on).
   Kill 60 a second if they stay above ~15 ms; the plan still buys ~35–45 a second.
4. **The writer overlap** delivering from the writer's thread (the owner's decision: it was
   declined in its earlier, latency-adding form).
5. **A video trace** (owner): full-screen video at 5K, where the motion search, not copies,
   decides, and where the comparison with hardware HEVC matters most.

## Alternatives considered

- **More tuning of today's design:** the measured ceiling is ~35 a second on new content
  (BENCHMARKS, "what buys speed…"), bound by the chain.
- **Decisions without RD** (libaom realtime's `nonrd`, sketched above): measured, +64–76 % bytes
  with a Hadamard proxy. libaom's own is close to our RD, so a better model could do better, but
  the GPU's RD search on squares already costs only +1.6 % for its time.
- **The closed loop on the GPU** with many tiles: per-tile wavefronts stay latency-bound; 749 ms
  a picture today, and many tiles cost bytes.
- **Hardware HEVC for video, AV1 for screen content:** the product does this already (the video
  layer); it is the fallback if the plan fails. The goal was to beat HEVC, so it isn't the
  plan.
- **A custom codec** (`gpu-codec`): fewer constraints, but no hardware decoder on the Viewer
  side; separate track.
