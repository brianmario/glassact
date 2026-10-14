# Contributing to Glass Act

This page gets you from a clone to a working build. The rules for changing
the code (invariants, hot paths, wire changes, perf claims) are in
[AGENTS.md](AGENTS.md); read it before your first change. How the system
works is in [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- A Mac with Apple Silicon running macOS 27 or later. The Host and the
  Viewer both need it. One Mac is enough to start: the Viewer can connect
  to a Host on the same machine.
- Xcode 27 (Swift 6.4).
- [`just`](https://github.com/casey/just).

The package uses system frameworks only, plus the vendored libwebp in
`ThirdParty/`. Don't add dependencies.

## Building

```sh
just build          # the Swift package (debug)
just test-fast      # the quick test lane, ~40 s
just install-cli    # the glassact CLI → ~/.local/bin
xcodebuild -project Apps/GlassActApps.xcodeproj -scheme Host build
xcodebuild -project Apps/GlassActApps.xcodeproj -scheme Viewer build
```

You can also open `Apps/GlassActApps.xcodeproj` in Xcode. The "(Release)"
schemes are for anything performance-related. `just bench <args>` runs the
release `glassact-bench`; see [BENCHMARKS.md](BENCHMARKS.md#reference-traces)
for recording and replaying traces.

## Signing

The apps build without any signing setup, but macOS ties Screen Recording
and input permissions to the app's code signature. An unsigned or ad-hoc
build gets a new identity on every build and silently loses its grants. To
keep them, sign with your own team.

Create `Apps/Signing.local.xcconfig` (it's git-ignored) and set **both**
values:

```
DEVELOPMENT_TEAM = ABCDE12345
GLASSACT_BUNDLE_PREFIX = com.example.glassact
```

The default prefix, `app.glassact`, belongs to the project owner's team:
an app ID belongs to the team that registered it first, so your team
can't sign `app.glassact.host`. Pick a prefix of your own and keep it
stable; grants follow the bundle ID and team.

`just release` builds Developer ID–signed, notarized apps. It needs a
Developer ID certificate and an Apple ID signed in to Xcode; AGENTS.md
covers its quirks.

## Permissions (TCC)

The Host needs **Screen & System Audio Recording** and **Device Control and
Data Access** (remote input). Setup asks for both on first launch.

- **A frozen canvas almost always means a missing grant**, not an engine
  bug. Check System Settings › Privacy & Security first.
- Grants belong to one code identity. Run the Host from `/Applications`
  and keep replacing that copy (`rm` it, then copy the new build in;
  overwriting a signed binary in place gets it killed). A Debug build run
  from Xcode is a different identity and needs its own grants.
- Quit the Host from its menu or with
  `osascript -e 'tell application "Glass Act Host" to quit'`, not with
  SIGKILL, so the virtual display and session state unwind.

## Tests

- `just test-fast` while iterating. It skips the real-QUIC and slow tests.
- `just test` (everything) must be green before you push. `just test-asan`
  runs the suite under AddressSanitizer.
- Every invariant in DESIGN §1 has an `INV_*` test. A failing one blocks
  the change. Don't weaken an invariant to make something work; open an
  issue and ask.
- Loss tests use fixed seeds, and goldens must be byte-exact.

## Pull requests

`main` is protected: every change lands through a pull request, and CI
must pass first.

- CI (`.github/workflows/ci.yml`) runs the test suite and builds both
  apps, unsigned, on GitHub's macOS 27 / Xcode 27 runner. It skips
  `VideoSendGateTests`, a link-emulation rig that needs real hardware to
  reproduce its baseline, so run `just test` locally before pushing.
- A pull request must be up to date with `main` before it merges. Use
  **Update branch** on the pull request to catch up.
- Keep each pull request to one change, with DESIGN.md and BENCHMARKS.md
  updated in the same pull request when it changes behaviour or
  performance.

## Performance changes

Anything that affects performance or loss behaviour needs a
`glassact-bench` number on a named trace, before and after, recorded as a
new entry in [BENCHMARKS.md](BENCHMARKS.md). A regression over 10 % needs a
written reason. Check its
[decisions table](BENCHMARKS.md#decisions-and-rejected-experiments) before
trying an idea: many have been measured already.

## Filing issues

Open work lives in GitHub issues, labelled `bug`, `enhancement`,
`performance`, `security`, `research`, `macos` or `agents`. For a bug,
include:

- the build on each end (the wire protocol changes between builds, so both
  ends must run the same one) and the macOS versions;
- the Viewer's log: Viewer › Help › Show Logs in Finder
  (`~/Library/Logs/Glass Act/`), or Help › Send Logs to Host;
- the Host's log:
  `/usr/bin/log show --predicate 'subsystem == "app.glassact.host"' --last 10m`
  (use `/usr/bin/log`; zsh has a `log` builtin).

Screen recordings and `.scap` traces contain whatever was on screen, so
check them before attaching.
