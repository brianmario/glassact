# Contributing to Glass Act

This page gets you from a clone to a working build. The rules for changing
the code (invariants, hot paths, wire changes, perf claims) are in
[AGENTS.md](AGENTS.md); read it before your first change. How the system
works is in [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- To build: Xcode 27 (Swift 6.4), on a Mac that runs it.
- To run: macOS 15.5 or later, on Apple silicon or Intel. The Host and the
  Viewer both need it. One Mac is enough to start: the Viewer can connect
  to a Host on the same machine. Release builds are universal; Debug builds
  are for the Mac you build on.
- The iPad Viewer: iPadOS 27 or later.
- [`just`](https://github.com/casey/just).
- Rust, from [rustup](https://rustup.rs) (stable). The AV1 encoder's CPU code
  is in `rust/av1`. For the Intel build, also run
  `rustup target add x86_64-apple-darwin`.

The package uses system frameworks only, plus the vendored libwebp and
libaom in `ThirdParty/`; the apps also use Sparkle for updates. Don't add
dependencies: the Rust crate uses std only.

## Building

```sh
just build          # the Swift package (debug)
just test-fast      # the quick test lane, ~40 s
just install-cli    # the glassact CLI → ~/.local/bin
xcodebuild -project Apps/GlassActApps.xcodeproj -scheme Host build
xcodebuild -project Apps/GlassActApps.xcodeproj -scheme Viewer build
xcodebuild -project Apps/GlassActApps.xcodeproj -scheme iPad -destination 'generic/platform=iOS Simulator' build
```

`just` builds the Rust library (`scripts/build-rust`) before every Swift build
and test. Run it yourself before a bare `swift build` or `swift test`; add
`--universal` for an x86_64 build. The apps don't link it yet.

You can also open `Apps/GlassActApps.xcodeproj` in Xcode. The "(Release)"
schemes are for anything performance-related. `just bench <args>` runs the
release `glassact-bench`; see [BENCHMARKS.md](BENCHMARKS.md#reference-traces)
for recording and replaying traces.

### The iPad Viewer and the test host

The iPad Viewer (`Apps/iPad`, the iPad scheme) shares the package with
the Mac apps and adds only its screens and input. To work on it without
sharing a real Mac, run the test host: a Host with a synthetic screen
(text to judge sharpness, a bouncing box for video) that draws whatever
the viewer sends, clicks as dots, drags as trails, keys and scrolls in a
panel.

```sh
swift run glassact-testhost --port 4533   # --tiles-only, --still, --sign-in-password P, --ask-after S
```

It admits any viewer key, since it shows nothing real and injects nothing.
To try the other ways in: `--sign-in-password P` makes new keys sign in as
`test`, and `--ask-after S` asks for them as a Host's user would, printing
the code the viewer should show, then approves each key S seconds after its
first dial (a large S never does, to try waiting and Cancel). In the Simulator, the iPad reaches it at `127.0.0.1`, and
launch arguments connect straight away:

```sh
xcrun simctl launch --terminate-running-process booted app.glassact.viewer \
  --host 127.0.0.1 --port 4533 --connect --keep-controls
```

`--keep-controls` keeps the session controls on screen, for screenshots
and UI tests. To run it on your own iPad, pick the iPad scheme and your
device in Xcode, with your team set as below.

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

With a team set, the apps also get a keychain entitlement and keep their
keys in the keychain (DESIGN §13). That entitlement needs a provisioning
profile: Xcode's automatic signing makes one the first time you build
(from Xcode, or `xcodebuild … -allowProvisioningUpdates` with your Apple ID
signed in to Xcode) and caches it. Without a team the apps get no
entitlements and keep their keys in files, which works the same apart from
where the key lives.

`just release` builds Developer ID–signed, notarized apps. It needs a
Developer ID certificate and an Apple ID signed in to Xcode; AGENTS.md
covers its quirks. Published releases come from a tag and the Release
workflow instead; see [RELEASING.md](RELEASING.md).

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
  runs the suite under AddressSanitizer. `just test-alloc` runs the
  allocation-count tests in release, the only build where they assert
  (CI runs them too).
- Every invariant in DESIGN §1 has an `INV_*` test. A failing one blocks
  the change. Don't weaken an invariant to make something work; open an
  issue and ask.
- Loss tests use fixed seeds, and goldens must be byte-exact.

## Pull requests

`main` is protected: every change lands through a pull request, and CI
must pass first.

- CI (`.github/workflows/ci.yml`) runs the test suite and builds both
  apps, unsigned, on GitHub's Apple-silicon macOS 27 / Xcode 27 runner,
  runs the allocation-count tests in a release build of their own, and
  builds everything for Intel too. It can't run the tests on Intel (hosted
  Intel runners stop at macOS 15, which can't run Xcode 27), so test
  Intel-sensitive changes on an Intel Mac. It skips
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

Security vulnerabilities don't go in public issues: report them privately,
as [SECURITY.md](SECURITY.md) describes.

Open work lives in GitHub issues, labelled `bug`, `enhancement`,
`performance`, `security`, `research`, `macos` or `agents`. For a bug,
include:

- the version on each end (Host and Viewer may differ) and the macOS
  versions;
- the Viewer's log: Viewer › Help › Show Logs in Finder (in the Viewer's
  sandbox container), or Help › Send Logs to Host;
- the Host's log:
  `/usr/bin/log show --predicate 'subsystem == "app.glassact.host"' --last 10m`
  (use `/usr/bin/log`; zsh has a `log` builtin).

Screen recordings and `.scap` traces contain whatever was on screen, so
check them before attaching.

**Crash and hang reports.** After a crash or hang, the app's **Report…**
button opens an issue prefilled from its MetricKit report and shows the
report file (`<host|viewer>-<crash|hang>-<time>-<hash>.json`) to attach.
The stacks in it are unsymbolicated: binary name, UUID and offset. To read
them, symbolicate with the dSYMs of the release that crashed (the release's
`.xcarchive` keeps them; the script searches a folder recursively and
matches binaries by UUID):

```sh
scripts/symbolicate-crash ~/Downloads/host-crash-20261019-095900-0a1b2c3d.json \
    "Apps/build/release/Host.xcarchive"            # add --all-threads for every thread
```

It needs only the Xcode command-line tools (`dwarfdump`, `atos`). Frames in
system libraries stay as binary + offset. Keep each release's archive (or
its dSYMs) for this: a rebuild has different UUIDs.
