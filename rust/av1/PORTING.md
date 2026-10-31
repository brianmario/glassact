# Porting the AV1 C++ to Rust

This file is for the port while it is in progress. When the C++ is gone, it gets folded into the
crate docs.

## What moves

The CPU code moves from C++ to this crate:
- `Sources/AV1Core`: av1gpu's av1core (writer, parser, layout, post-filters, AVIF, DSP).
- `Sources/AV1Encoder`: the host half of the Metal encoder, and the hybrid encoder's closed loop.
- `Sources/AV1CoreTestSupport`: random records, the reference engine, the DSP cases.

The Metal kernels keep their C-style headers: MSL is a C++ dialect, so they can't be Rust. After the
port, those headers are GPU-only and live with the shaders. Tests hold the GPU and the Rust CPU code
to the same results.

## Rules

- **Exact.** Every output must equal the C++ bit for bit: bytes, reconstructions, decisions and
  tables. The C++ is the oracle until the port is done.
- **Differential tests against the oracle**, with fixed seeds. Run them with:

  ```sh
  cargo test --release --no-default-features --features oracle
  ```

  The `oracle` feature builds the C++ sources and `oracle/*.cpp` and links them. When a test needs a
  C++ internal that has no C API (an inline function in a header, a class method), add a small
  `extern "C"` shim in `oracle/<module>.cpp`. Name its functions `oracle_<module>_<what>`.
  `oracle/layout.cpp` is the example.
- **No dependencies:** no crates, std only (see AGENTS.md).
- **Safe Rust by default.** `unsafe` is for FFI (the `capi` module, added at the end), SIMD
  intrinsics and measured hot loops. Each `unsafe` block gets a one-line `// SAFETY:` comment.
- **SIMD where it pays**, in hot paths such as transforms, prediction, filters, SSE and
  quantization:
  - Use `core::arch::aarch64` NEON (baseline on every Apple-silicon Mac), and on x86_64 SSE4.1/AVX2
    behind `is_x86_feature_detected!`, with a scalar path that stays the reference.
  - Test every SIMD path against the scalar one on random inputs.
  - Keep code that LLVM auto-vectorizes well plain; check with a micro-benchmark before writing
    intrinsics.
- **No per-call heap allocation in hot paths** where the C++ avoided it. Reuse buffers through
  `&mut` scratch, or keep them on the struct.
- **Same names as the spec and the C++** for functions, fields and tables, in snake_case for
  functions. Cite the spec section where the C++ does. Match the surrounding comment density; don't
  narrate.
- **Tables:** `crate::tables::*` is generated (scripts/gen-av1-rust-tables); never edit it by hand.
  Constants drop the `AV1G_` prefix (`tables::BLOCK_8X8`, an `i32`).
- **C API types:** `crate::types` has the `#[repr(C)]` mirrors (`Block`, `Txb`, `FrameParams`,
  `DecisionRecord`, …). Internal code takes slices, not raw pointers. The `capi` module turns the
  pointers into slices at the boundary (added at the end; don't add `#[no_mangle]` exports yet).
- **Format and lint:** `cargo fmt` with max_width 120 (rustfmt.toml), and `cargo clippy --release`
  clean apart from `needless_range_loop`-style lints on spec loops.
- **Concurrency:** the C++ uses `std::thread` for parallel tiles. Use `std::thread::scope`.
