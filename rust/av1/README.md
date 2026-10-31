# glassact-av1

The AV1 encoder's CPU code. It's a port of [av1gpu](https://github.com/maddog107/av1gpu)'s av1core
(BSD-2, [LICENSE](LICENSE); libaom-derived parts in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)),
with Glass Act's additions. It used to be C++ in `Sources/AV1Core`, `Sources/AV1Encoder` and
`Sources/AV1CoreTestSupport`.

| Module | What |
|---|---|
| `writer` | the DecisionRecord writer: decisions and quantized coefficients in, OBUs and the decoder's exact reconstruction out; tiles on threads; the closed-loop hook; the parser |
| `dsp`, `blockinfo` | the decoder-mirroring DSP: prediction, inverse transforms, dequantization, block geometry |
| `postfilter` | deblocking and CDEF, exactly as the decoder applies them |
| `entropy` | the range encoder, CDF contexts, symbol streams |
| `avif` | the AVIF muxer |
| `enc` | the Metal encoder's host half: derived tables as MSL, the GPU entropy plan, the post-filter frame, tune=iq and the CDEF search's host half |
| `hybrid` | the hybrid encoder's CPU closed loop, on blocks the Metal analysis decided |
| `testsupport` | random legal records, the reference engine, the GPU's DSP cases (tests only) |
| `capi` | the C API Swift links (`Sources/AV1Core/include/av1g/av1g.h`, `Sources/AV1Encoder/include/av1enc.h`, `Sources/AV1CoreTestSupport/include/av1core_test.h`) |

The Metal kernels keep their own copy of the DSP. MSL is a C++ dialect, so they compile the C
headers in `Sources/AV1Core/include/av1g`. The Swift tests hold the GPU and this crate to the same
results.

## Building and testing

```sh
scripts/build-rust                  # .build/rust/libglassact_av1.a, which the package links (just runs it)
just test-rust                      # the crate's tests, and the differential tests below
cargo test --release --no-default-features --features oracle   # just the differential tests
cargo test --release -- --ignored --nocapture bench            # micro-benchmarks
```

`oracle/cpp` is the C++ this crate was ported from, frozen as a test reference. The `oracle`
feature compiles it, together with the shims in `oracle/*.cpp`, and the tests compare the two
output for output. It's never linked into the product.

`src/tables` is generated from the C table headers (`scripts/gen-av1-rust-tables`) so that the CPU
and the GPU use the same values. Never edit it by hand.

## Rules

- **Exact.** Every output (bytes, reconstructions, decisions) must match the reference bit for bit,
  checked by differential tests with fixed seeds. An optimization that changes an output is a format
  change, not an optimization.
- **No dependencies:** std only, no crates (AGENTS.md).
- **Safe Rust by default.** `unsafe` is for the C API, SIMD intrinsics and measured hot loops, and
  every `unsafe` block gets a `// SAFETY:` comment.
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
- **Float contraction:** the reference's floating-point code was compiled with clang's default
  `-ffp-contract=on`, which fuses `a * b + c` on arm64 but not on x86_64. `enc::fmac` mirrors this
  per architecture where it matters.
