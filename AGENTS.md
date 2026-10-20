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
- `## Deviations` notes at the top of a file (e.g. `QUICTransport.swift`)
  explain where the code departs from the SDK docs or the design.

## Constraints

- Runs on macOS 15.5+, Apple silicon and Intel (universal Release builds).
  Built with Xcode 27 / Swift 6.4, Swift 6 strict concurrency, warnings as
  errors. Anything newer than macOS 15.5 goes behind `#available` with a
  sensible fallback; the CI build at the 15.5 target catches misses.
- Perf work is measured on Apple silicon; check that big changes don't
  regress on Intel, where the Host's tile encoding costs more CPU.
- System frameworks only. The one exception is the vendored libwebp
  (`ThirdParty/`). Add no dependencies.
- The apps (`Apps/Host`, `Apps/Viewer`) are thin: UI and wiring only. Logic
  lives in the package, where `swift test` covers it.

## Rules

- **Changes land through pull requests.** `main` is protected: CI (tests,
  the release allocation-count tests, both app builds and the Intel build)
  must pass, and the branch must be up to date with `main`.
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
- **Wire changes:** until 1.0 the wire protocol may change in any release.
  Bump `WireVersion.current`, and keep no old decode paths or migration
  code; both ends must run the same build.
- **Loss tests** use fixed seeds. Goldens are byte-exact.
- **Stranded-tile tests** drive explicit dirty rects. `Harness.settle()`
  full-scans every tick (nil dirty rects), which re-volunteers every tile
  and hides a tile the engine forgot to re-send
  (see `Tests/CoreTests/StrandedTileTests.swift`).

## Commands

```sh
just test-fast        # skips real-QUIC and slow tests (~40 s); run this while iterating
just test             # everything; must be green before landing
just test-asan        # AddressSanitizer
just bench <args>     # release glassact-bench (replay, synth, goldens)
just install-cli      # glassact → ~/.local/bin
just release [Host|Viewer]   # Developer ID archive → notarize → staple → zip
xcodebuild -project Apps/GlassActApps.xcodeproj -scheme Host build   # or Viewer; "(Release)" schemes for perf
```

## Gotchas

- **TCC follows the code signature.** Run the Host from `/Applications` (the
  notarized release). Debug builds sign as Apple Development, which is a
  different identity, so Screen Recording and Device Control grants don't
  carry over. A frozen canvas usually means a missing grant, not an engine
  bug.
- **Quit the Host gracefully** (`osascript -e 'tell application "Glass Act Host" to quit'`),
  never with SIGKILL. That way the virtual display and session state unwind.
- **Replacing a signed binary:** `rm` it before `cp`. Overwriting it in place
  gets the new process killed (exit 137).
- **Logs:** use `/usr/bin/log`, because zsh has a `log` builtin. The subsystem
  is `app.glassact.host`. The Viewer is sandboxed: its log files are in its
  container, which a terminal can't read without a prompt, so read it from
  the unified log instead (subsystem `app.glassact.viewer`).
- **Releases** notarize through the Apple ID signed in to Xcode. Xcode 27's
  xcodebuild sometimes drops that account ("No Accounts", or a notarization
  timeout). Check `defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists`;
  if it's empty, re-sign in to Xcode and re-run.
- **Signing setup:** `Apps/Signing.local.xcconfig` (git-ignored) sets
  `DEVELOPMENT_TEAM` and optionally `GLASSACT_BUNDLE_PREFIX`. With a team,
  the apps carry a keychain entitlement and need a provisioning profile:
  the first signed build after a profile change needs
  `-allowProvisioningUpdates` and the Xcode account. Builds signed by the
  team, Debug and Release alike, share the apps' keychain keys, so
  rebuilding never prompts or changes a key.
- **Env flags** (Host): `GLASSACT_TILE_ONLY=1` disables video (no video caps
  are offered; tiles only). The `*_DEBUG` flags add logging, and
  `GLASSACT_TRACE_TILE=<idx>` logs every change to one tile.
