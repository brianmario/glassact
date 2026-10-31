default: test

# The Rust AV1 library the package links (.build/rust/libglassact_av1.a)
rust:
    scripts/build-rust

# Rust tests: the crate's own, and the differential tests against the C++ it was ported from
test-rust:
    cargo test --release --manifest-path rust/av1/Cargo.toml
    cargo test --release --manifest-path rust/av1/Cargo.toml --no-default-features --features oracle

# Run all package tests
test: rust
    swift test

# Skip real-QUIC and >10 s tests (tagged .quic / .slow, trait .notInFastLane)
test-fast: rust
    GLASSACT_FAST=1 swift test

# Build everything (debug)
build: rust
    swift build

# Release-mode bench CLI (trace replay, synth traces, goldens, codec and video measurements)
bench *ARGS: rust
    swift run -c release glassact-bench {{ARGS}}

# Test run under AddressSanitizer (catches over-reads the checked parser must prevent)
test-asan: rust
    swift test --sanitize=address

# Allocation-count tests (INV-7): they assert only against optimized code
test-alloc: rust
    swift test -c release --filter ScrollAllocationTests

# Full-size hash collision sweep (10^6 × 16 KB buffers, §4.5) and 100× the
# WebP / keyframe decoder fuzz iterations (INV-6) — release mode
test-exhaustive: rust
    GLASSACT_EXHAUSTIVE=1 swift test -c release --filter 'CodecTests|KeyframeDecodeFuzzTests'

# Developer ID-signed, notarized, stapled apps (Apps/build/release/<Scheme>/)
release *SCHEMES="Viewer Host":
    Apps/release.sh {{SCHEMES}}

# The glassact CLI (agents, scripting, MCP) → ~/.local/bin/glassact
install-cli:
    swift build -c release --product glassact
    mkdir -p ~/.local/bin
    rm -f ~/.local/bin/glassact  # a fresh file: overwriting a signed binary in place gets it killed
    cp "$(swift build -c release --show-bin-path)/glassact" ~/.local/bin/glassact
    @echo "installed ~/.local/bin/glassact — MCP: claude mcp add glassact -- ~/.local/bin/glassact mcp"
