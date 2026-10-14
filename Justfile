default: test

# Run all package tests
test:
    swift test

# Skip real-QUIC and >10 s tests (tagged .quic / .slow, trait .notInFastLane)
test-fast:
    GLASSACT_FAST=1 swift test

# Build everything (debug)
build:
    swift build

# Release-mode bench CLI (trace replay, synth traces, goldens, codec and video measurements)
bench *ARGS:
    swift run -c release glassact-bench {{ARGS}}

# Test run under AddressSanitizer (catches over-reads the checked parser must prevent)
test-asan:
    swift test --sanitize=address

# Full-size hash collision sweep (10^6 × 16 KB buffers, §4.5) — release mode
test-exhaustive:
    GLASSACT_EXHAUSTIVE=1 swift test -c release --filter CodecTests

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
