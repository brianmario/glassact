# Working on Glass Act

Glass Act is macOS screen sharing built as state sync. The Viewer holds a
replica canvas of 64×64 last-writer-wins tiles. Static content travels as
lossless tile records over QUIC datagrams, and motion travels as HEVC in an
overlay. Loss is repaired by re-encoding current content, never by
retransmission.

## Where things are

- **[docs/DESIGN.md](docs/DESIGN.md)** is how it works: invariants, wire format,
  engines, transport, security and agents. Code comments cite it by section
  (`§3.5`, `§8.8`), so keep its numbering stable and update it in the same
  change as the code.
- **[BENCHMARKS.md](BENCHMARKS.md)** is the project's memory: every perf or
  loss-behaviour change, with before/after numbers, plus the experiments
  that were measured and rejected. Check it before re-trying an idea.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** is setup for a new contributor:
  requirements, building, signing, permissions, tests and filing issues.
- **[RELEASING.md](RELEASING.md)** is versions, tagging a release, and the
  release workflow's one-time setup.
- **GitHub issues** hold the open work.
- **[rust/av1](rust/av1)** is the AV1 encoder's CPU code in Rust (the bitstream
  writer, post-filters, the hybrid encoder's closed loop) and the AV1 decoder;
  the apps link it. Swift reaches it through the C API in `Sources/AV1Core`,
  `AV1Encoder` and `AV1CoreTestSupport`; the Metal kernels are in
  `Sources/GlassActAV1`.
- `## Deviations` notes at the top of a file (e.g. `QUICTransport.swift`)
  explain where the code departs from the SDK docs or the design.

## Constraints

- The Host runs on macOS 14.4+ and the Viewer on 15.5+, Apple silicon and
  Intel (universal Release builds). Built with Xcode 27 / Swift 6.4, Swift 6
  strict concurrency, warnings as errors. The package targets 14.4: anything
  newer goes behind `#available` with a sensible fallback, and the CI build
  at the 14.4 target catches misses. Synchronization's `Mutex` and `Atomic`
  are macOS 15: import `GlassActSync` for its stand-ins instead.
- The `GlassActViewer` product (everything but GlassActShare) also builds
  for iPadOS 27+ (the latest only: the older macOS floor is for Intel Macs,
  which iPads don't need). Mac-only APIs in it go behind `#if os(macOS)`,
  and `#available` checks name iOS as well as macOS. CI builds it for
  iPadOS.
- Perf work is measured on Apple silicon; check that big changes don't
  regress on Intel, where the Host's tile encoding costs more CPU.
- System frameworks only. The exceptions are the vendored libwebp, the
  vendored libaom (AV1, arm64 only), and, in the apps only, Sparkle for
  updates (all in `ThirdParty/THIRD_PARTY.md`). Add no dependencies.
- New CPU code for the AV1 encoder is Rust, in `rust/av1`: std only, no crates.
  Building the package needs a Rust toolchain (rustup); `scripts/build-rust`
  makes the static library the package links, and `just` runs it first.
  Its rules (bit-exact, SIMD with a scalar reference, safe by default) are in
  `rust/av1/README.md`.
- The apps (`Apps/Host`, `Apps/Viewer`) are thin: UI and wiring only. Logic
  lives in the package, where `swift test` covers it.

## Rules

- **Changes land through pull requests.** `main` is protected: CI (the
  tests in a release build, which assert the allocation counts too; the Rust
  crate's tests; both app builds and the Intel build) must pass, and the
  branch must be up to date with `main`.
- **Invariants are frozen** (DESIGN §1). Each keeps an `INV_*` test, and a
  failing one blocks the change. Don't weaken an invariant to make something
  work; ask instead.
- **Pixel path:** the engines are serial-queue-confined `final class`es
  marked `@unchecked Sendable`. No actors or `async`/`await` between capture
  and present (§8.8).
- **Hot paths** (diff, encode, parse, apply, blit): no per-frame allocation,
  ARC, `String`, `Data` appends or dictionaries. Plain `-O`, never
  `-Ounchecked`. Wire parsing is always checked (§8, INV-6).
- **Perf claims** need a `glassact-bench` number on a named trace, recorded in
  BENCHMARKS.md. A regression over 10 % needs a written reason.
- **Wire changes are additive.** A Host and Viewer of different releases
  must work together (DESIGN §12). Add a new message type, or put new
  behaviour, fields and enum values behind a caps bit (§3.8) and keep the
  old path for peers without it. Never change how an existing message is
  encoded: `WireCompatTests` pins every type's bytes as released builds
  send them. Bumping `WireVersion.current` drops every older release, so it
  needs the owner's sign-off and should be very rare.
- **Loss tests** use fixed seeds. Goldens are byte-exact.
- **Stranded-tile tests** drive explicit dirty rects. `Harness.settle()`
  full-scans every tick (nil dirty rects), which re-volunteers every tile
  and hides a tile the engine forgot to re-send
  (see `Tests/CoreTests/StrandedTileTests.swift`).

## Commands and gotchas

[RUNBOOK.md](RUNBOOK.md) has the exact commands (build, test, run,
benchmark, release, CI), which of them have been checked on this Mac, and
the gotchas (TCC follows the signature, quitting the Host gracefully,
replacing signed binaries, `/usr/bin/log`, release sign-in, env flags).
[NOW.md](NOW.md) is what's in flight.
