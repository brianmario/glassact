# glassact-av1

The AV1 encoder's CPU code, and the AV1 decoder. It's a port of [av1gpu](https://github.com/maddog107/av1gpu)'s av1core
(BSD-2, [LICENSE](LICENSE); libaom-derived parts in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)),
with Glass Act's additions. It used to be C++ in `Sources/AV1Core`, `Sources/AV1Encoder` and
`Sources/AV1CoreTestSupport`.

| Module | What |
|---|---|
| `writer` | the DecisionRecord writer: decisions and quantized coefficients in, OBUs and the decoder's exact reconstruction out; still pictures, and key and inter frames of video streams (the MV candidate stack, inter modes derived from the MVs); 64x64 or 128x128 superblocks; palette blocks; intra block copy; tiles on threads, and with a reconstruction its blocks on every thread apart from their coding (`writer::recon`); the closed-loop hook; the parser |
| `decoder` | the decoder for the writer's streams (the Viewer's AV1 where VideoToolbox has none: 4:4:4, M1 / M2, Intel): a temporal unit in, the shown frame's planes out; tiles parsed and reconstructed in one walk each on the pool (`writer::decode`), then per 64x64 a copy of a reference, the tile's samples, or deblocking and CDEF (`postfilter::deblock_rect`, `cdef_rect`); hostile input refused with errors |
| `dsp`, `blockinfo` | the decoder-mirroring DSP: intra and inter prediction (motion compensation), inverse transforms, dequantization, block geometry |
| `postfilter` | deblocking and CDEF, exactly as the decoder applies them |
| `entropy` | the range encoder, CDF contexts, symbol streams |
| `avif` | the AVIF muxer |
| `enc` | the Metal encoder's host half: derived tables as MSL, the GPU entropy plan, the post-filter frame, tune=iq and the CDEF search's host half |
| `hybrid` | the hybrid encoder's CPU closed loop, on blocks the Metal analysis decided (and inter blocks); key frames' intra block copies (`hybrid::intrabc`); palette blocks by cost, luma and in 4:4:4 chroma (`hybrid::palette`) |
| `motion` | inter frames' exact copies: 64x64s that equal the previous source, unchanged or shifted, as skip inter blocks (with 128x128 superblocks, a 128x128 of one shift as one block) |
| `pool` | the worker threads every parallel loop shares, started once and parked between loops |
| `testsupport` | random legal records and inter sequences, the reference engine, the GPU's DSP cases (tests only); the snapshot tests' hashes (`testsupport::snapshot`) |
| `capi` | the C API Swift links (`Sources/AV1Core/include/av1g/av1g.h`, `av1g/decoder.h`, `Sources/AV1Encoder/include/av1enc.h`, `Sources/AV1CoreTestSupport/include/av1core_test.h`) |

The Metal kernels keep their own copy of the DSP. MSL is a C++ dialect, so they compile the C
headers in `Sources/AV1Core/include/av1g`. The Swift tests hold the GPU and this crate to the same
results.

## Building and testing

```sh
scripts/build-rust                  # .build/rust/libglassact_av1.a, which the package links (just runs it;
                                    # --xcode in the apps' build phases, --universal for x86_64 too)
just test-rust                      # the crate's tests (cargo test --release)
cargo test --release -- --ignored --nocapture bench            # micro-benchmarks
```

The snapshot tests pin every output: on fixed seeds, they hash (FNV-1a 64,
`testsupport::snapshot`) the writer's bytes and reconstructions, the closed loops' decisions, the
DSP's, entropy coder's and post-filters' results, per family of outputs, and compare the hashes
with constants recorded in the test. A change that is still valid AV1 but different fails them,
naming the families that moved. Correctness is the real decoders' (below). A change that moves a
snapshot on purpose re-records it (the failure prints the line to paste) and says why in
BENCHMARKS. The hybrid's and tune=iq's floating-point code contracts `a * b + c` on aarch64 and
not on x86_64 (`enc::fmac`), so the tests of what it decides keep constants per architecture;
`cargo test --release --target x86_64-apple-darwin` runs the x86_64 ones (under Rosetta).

Until 2026-11-17 the tests compared the crate with the C++ it was ported from, frozen in `oracle/`
as a reference; the snapshots were recorded from that build, where the two agreed, on both
architectures. The layout tests compile `tests/layouts.cpp` against the C headers at test time
(`CXX`, else `c++`).

`examples/prune_train.rs` trains the Metal analysis's learned pruning (`Shaders/k_ml.h`: a tree
level model and a luma mode model) on pictures `glassact-bench av1seq --dump-partition` writes, and
exports `Sources/GlassActAV1/AV1PrunerWeights.swift`. `scripts/train-pruner` runs it end to end
from the traces listed in `scripts/pruner-traces.txt`: add a trace there and run
`scripts/train-pruner all`, then `install`. BENCHMARKS has the data the shipped weights came from.

`examples/own_decode.rs` decodes an IVF stream with `decoder` and times it (`--writer`: the
parser and the writer's reconstruction instead); with libaom's decode beside it, it compares every
frame. The decoder's tests hold it to the writer's reconstructions, to dav1d and aomdec
(`cargo test --release -- --ignored --nocapture decoders`), to hostile input (`hostile_input`, and
`hostile_input_long` at length), and with `OWNDEC_DIR` to a directory of streams and libaom's I420
decodes (`streams_match_libaom`).

`examples/tile_stats.rs` counts the blocks of AV1 stills (one per tile, as `glassact-bench
av1tiles --obus` writes them; libaom's AVIF data too, where it's in the writer's toolset) by size
and tool, each block's bits as the writer codes it (`ENC_BLOCK_BITS`).

`src/tables` is generated from the C table headers (`scripts/gen-av1-rust-tables`) so that the CPU
and the GPU use the same values. Never edit it by hand. The inter frames' tables
(`av1g/inter_tables.h`) come from the AV1 spec's markdown (`scripts/gen-av1-inter-tables`).

Inter frames are checked against real decoders: the Swift `InterDecoderGateTests` (the vendored
libaom), and `cargo test --release -- --ignored --nocapture decoders` (dav1d and aomdec in
/opt/homebrew/bin, when installed). So are 4:4:4 key frames and still pictures (fp.chroma_format,
the High profile: `decoders_444`, and the hybrid's `chroma444_key_frames`), which av1gpu's C++
never had. The subsampling is a parameter of the frame
(`ss`, 1 for 4:2:0 and 0 for 4:4:4; `blockinfo::chroma_ss`), not a second copy of the code.

## Rules

- **Exact.** Every output (bytes, reconstructions, decisions) stays what it was bit for bit, held by
  the snapshot tests with fixed seeds, and decodes exactly with real decoders. An optimization that
  changes an output is a format change, not an optimization.
- **No dependencies:** std only, no crates (AGENTS.md).
- **Safe Rust by default.** `unsafe` is for the C API, SIMD intrinsics, measured hot loops, the
  worker pool's one lifetime erasure (`pool::run`, which std's scoped threads can't do without
  starting threads each time) and the writer's block-parallel reconstruction (`writer::recon`:
  tasks share a tile's planes and the record, kept apart by the dependency order). Every `unsafe`
  block gets a `// SAFETY:` comment.
- **SIMD where it pays**, in hot paths: transforms, prediction, filters, quantization, SSE.
  - On aarch64, use `core::arch::aarch64` NEON (baseline on every Apple-silicon Mac).
  - On x86_64, use SSE4.1/AVX2 behind `is_x86_feature_detected!`.
  - A scalar path stays the reference, and a test compares every SIMD path against it.
  - Code that LLVM vectorizes well stays plain.
- **No per-picture heap allocation in hot paths.** Long-lived structs (`Writer`, `Hybrid`) keep
  their buffers.
- **Names follow the spec and av1gpu**, with functions in snake_case. Constants drop `AV1G_`
  (`tables::BLOCK_8X8`).
- **Types at the boundary:** internal code takes slices. The `#[repr(C)]` mirrors are in `types`,
  and their layouts are tested against the C compiler.
- **Format and lint:** run `cargo fmt` (max_width 120) and `cargo clippy --release`.
- **Float contraction:** av1gpu's floating-point code was compiled with clang's default
  `-ffp-contract=on`, which fuses `a * b + c` on arm64 but not on x86_64. `enc::fmac` mirrors this
  per architecture where it matters, so those snapshots are per architecture too.
