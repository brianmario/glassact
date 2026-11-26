# Runbook

Exact commands, run from the repository root. ✓ = run and working on the M4 Pro (2026-11-23..26);
"not verified" = not run from a session yet. `just` isn't installed on this Mac: each recipe's plain
command is given, and `just <recipe>` works where `brew install just` has been done.

## Setup

```sh
scripts/build-rust                  # ✓ the Rust AV1 library the package links; before any bare swift build/test
scripts/build-rust --universal      # not verified here (CI's): adds x86_64, for an Intel build
scripts/check-version               # ✓ Apps/Version.xcconfig and the CLI's version agree
```

## Build

```sh
swift build                                         # ✓ the package, debug
swift build -c release --product glassact-bench     # ✓ the bench; binary at "$(swift build -c release --show-bin-path)/glassact-bench"
swift build --product glassact-testhost             # ✓
xcodebuild -project Apps/GlassActApps.xcodeproj -scheme Host -configuration Debug -derivedDataPath <dir> CODE_SIGNING_ALLOWED=NO build    # ✓
xcodebuild -project Apps/GlassActApps.xcodeproj -scheme Viewer -configuration Debug -derivedDataPath <dir> CODE_SIGNING_ALLOWED=NO build  # ✓
xcodebuild -project Apps/GlassActApps.xcodeproj -scheme iPad -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath <dir> CODE_SIGNING_ALLOWED=NO build  # ✓
xcodebuild -scheme GlassActViewer -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build   # not verified here (CI's iPadOS package check)
```

- `CODE_SIGNING_ALLOWED=NO` keeps builds away from the keychain and signing. Signed builds use
  `Apps/Signing.local.xcconfig` (git-ignored; never edit it from a session).
- "(Release)" schemes for anything performance-related.

## Test

```sh
scripts/build-rust && GLASSACT_FAST=1 swift test     # ✓ the fast lane (~5 min here; skips real-QUIC and slow suites)
scripts/build-rust && swift test                     # ✓ everything (~8–10 min); must be green before landing
cargo test --release --manifest-path rust/av1/Cargo.toml   # not verified here (CI's Rust job; just test-rust)
swift test --filter '<Suite>|<Suite>'                # ✓ one or more suites
swift test --sanitize=address                        # not verified here (just test-asan)
swift test -c release --filter ScrollAllocationTests # not verified here (allocation counts, release only)
```

- Real-QUIC suites are tagged `.quic` / `.notInFastLane`; CI runs them with `--no-parallel`.
- Loss tests use fixed seeds; WireCompatTests pins every control type's bytes (add a fixture with a new type).

## Run

```sh
swift run glassact-testhost --port 4533 [--size WxH] [--still] [--tiles-only] [--ask-after S] [--sign-in-password P] [--input-log]   # ✓
```

```sh
swift build -c release --product glassact && rm -f ~/.local/bin/glassact && cp "$(swift build -c release --show-bin-path)/glassact" ~/.local/bin/   # not verified here (just install-cli): the CLI, MCP: claude mcp add glassact -- ~/.local/bin/glassact mcp
```

- iPad Viewer in the Simulator against it: build the iPad scheme above, launch the `.app`, connect to
  `127.0.0.1:4533` (✓ via the Simulator tool). Or `xcrun simctl launch --terminate-running-process booted
  app.glassact.viewer --host 127.0.0.1 --port 4533 --connect --keep-controls` (not verified here).
- The real Host runs from /Applications (the notarized release): TCC grants follow the signature, so a
  Debug Host has none. Quit it with `osascript -e 'tell application "Glass Act Host" to quit'`, never SIGKILL.
- Logs: `/usr/bin/log show --last 30m --predicate 'subsystem == "app.glassact.host"'` (Viewer:
  `app.glassact.viewer`). Use the full path: zsh has a `log` builtin.

## Benchmark

```sh
B="$(swift build -c release --show-bin-path)/glassact-bench"
T="$HOME/Library/Application Support/Glass Act/traces"
$B av1seq --trace "$T/glassact-1795125212.scap" --skip 220 --width 5120 --tiles 3x0 --frames 61 --inter --q 36 --score-rgb --digest --frame-bytes   # ✓ bytes, RGB PSNR, digest, libaom decode check
$B av1seq --trace "$T/glassact-1795125212.scap" --skip 220 --width 5120 --tiles 3x0 --frames 8 --inter --no-planes --q 36 --profile --profile-pictures 5   # ✓ GPU stage timings
$B pace --trace "$T/glassact-1795125212.scap" --skip 220 --pending 3   # ✓ live-path frame rate (the Host gives the hybrid 3 pending)
$B record --out <file.scap> --seconds 30 --no-cursor                    # ✓ needs Screen Recording for the terminal's app
scripts/metal-trace <file.trace> <frames>                               # ✓ per-kernel GPU counters from an xctrace recording
```

```sh
scripts/train-pruner all && scripts/train-pruner install   # not verified here: retrain the AV1 encoder's learned pruning from scripts/pruner-traces.txt
```

- Reference traces: 1795125212 video (from 220), 1793736335 movie (from 300), 1794284096 maps (from 180),
  1786116323 typing; more in BENCHMARKS.md "Reference traces". Traces never go in the repo or anywhere else.
- Serialize every build, test and bench: one at a time (`lockf <lockfile> <cmd>`), and time only on an
  idle Mac (`uptime`; loads of 6–17 make frame rates provisional).
- Shaders are read at run time from the bench's own source tree: don't edit them while it runs.

## Release (owner's go-ahead each time)

```sh
# 1. version PR: set YY.M.N in Apps/Version.xcconfig and Sources/glassact/main.swift; scripts/check-version; merge
git tag vYY.M.N <merge commit> && git push origin vYY.M.N     # ✓ the Release workflow builds, notarizes, drafts
gh release edit vYY.M.N --notes-file <notes.md>               # ✓ the owner publishes the draft
gh api repos/brianmario/glassact/releases/latest --jq .tag_name   # ✓ what Check for Updates offers
```

- A candidate: `-rcK` in both places on a branch (`rc-YY.M.N`), tag `vYY.M.N-rcK`; the draft must stay a
  pre-release. Details and the one-time setup: RELEASING.md. `Apps/release.sh` (just release) is the local path.
- Sign-in drop: if Xcode reports "No Accounts" or notarization times out, check
  `defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists`; if empty, the owner signs in again.

## CI and PRs

```sh
gh pr checks <n>                         # ✓ Tests, Apps, Intel, Rust must pass; the branch must be up to date with main
gh run view <id> --log-failed | grep -E "✘|error:"   # ✓ what failed
```

- `main` is protected: every change is a PR. Known flaky-by-load suites have been re-barred (Scap memory #170,
  QUIC burst #171); a red run elsewhere is a real failure until shown otherwise.

## Gotchas

- Replacing a signed binary: `rm` it before `cp`; overwriting in place gets the new process killed (exit 137).
- A frozen canvas on a Debug Host usually means a missing Screen Recording grant, not an engine bug.
- `GLASSACT_TILE_ONLY=1` (Host) disables video; `GLASSACT_TRACE_TILE=<idx>` logs one tile; `GLASSACT_QUIC_DEBUG=1` logs both QUIC tunnels.
- Signed team builds share keychain keys; the first signed build after a profile change needs
  `-allowProvisioningUpdates` and the Xcode account.
