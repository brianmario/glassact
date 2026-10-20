# Glass Act

Screen sharing for Macs, built from scratch: sharp text, low latency, and
nothing on the wire when nothing changes.

Glass Act isn't a video streamer. The Host divides its screen into 64×64
tiles and sends each changed tile **losslessly**. The Viewer keeps an exact
replica. When packets are lost, the Host re-sends whatever the screen shows
*now*, not the stale pixels. Motion (scrolling, video, dragging windows)
switches to hardware HEVC, and each tile hands back to exact pixels as soon
as it goes still. Text ends up pixel-perfect, and an idle screen costs zero
bytes.

It also has a CLI and an MCP server, so **AI agents** can see and use a
remote Mac. They can do that either through your Viewer session or on a
headless connection of their own.

> **Status:** pre-release. It works daily between two Macs, but the wire
> protocol still changes without notice, so run the same build on both ends.

## Requirements

- macOS 15.5 or later, on Apple silicon or Intel. That applies to both ends.
  Intel Macs are newly supported and still need performance testing; expect
  a heavier CPU load on the Host than on Apple silicon.
- A few extras need macOS 27: the Host noticing a capture stream that stopped
  silently, setup recognising screen recording blocked by device management,
  and the Viewer turning off hot corners in full screen.
- To build: Xcode 27 (Swift 6.4) and [`just`](https://github.com/casey/just).
- The Host needs two permissions: **Screen & System Audio Recording** and
  **Device Control and Data Access** (remote input).

## Build and install

```sh
just test                 # the package's test suite
cd Apps
xcodebuild -project GlassActApps.xcodeproj -scheme Host build
xcodebuild -project GlassActApps.xcodeproj -scheme Viewer build
```

**Signing:** as checked out, the apps build without any signing setup. To
sign with your own Apple developer account, create
`Apps/Signing.local.xcconfig` (it's git-ignored). See
[Apps/Signing.xcconfig](Apps/Signing.xcconfig) for the format: set
`DEVELOPMENT_TEAM` and your own `GLASSACT_BUNDLE_PREFIX` (the default
prefix belongs to the project owner's team).

Signing matters for permissions. macOS ties Screen Recording and input grants
to the app's code signature. A stable team signature keeps them across
rebuilds; an ad-hoc signature changes on every build and silently loses them.

**Distributable builds:** `just release` archives the apps and signs them with
Developer ID. It then notarizes them through the Apple ID signed in to Xcode,
staples, verifies, and zips into `Apps/build/release/<Scheme>/`. Install the
Host in `/Applications`, and keep using that copy. A Debug build has a
different code identity, so permissions granted to one don't apply to the
other.

## Using it

1. **On the Mac you want to share**, launch **Glass Act Host**.
   - It lives in the menu bar. On first launch, setup asks for its
     permissions.
   - The switch at the top of its menu turns sharing on and off.
   - The menu also has **Copy Address** and **Copy Host Key**, and under
     Options: bandwidth, Lock Screen When Viewer Leaves, Open at Login, and
     visibility to nearby viewers.
2. **On the other Mac**, launch **Glass Act Viewer**.
   - Pick the Host under **Nearby**, or type its address.
   - Choose **Entire Display** or **One Window**, and a resolution: Match This
     Mac, Fit to Window, Scale Down or Native.
   - Click Connect.
3. **Sign in, the first time.** The Viewer asks for the name and password of
   the user on the Host Mac, the way the Mac's own Screen Sharing does.
   Nothing pops up on the Host. Once you're in, that Viewer is remembered,
   and later connections need nothing.
   - Host › Options › **New Viewers** changes this. **Ask Me Each Time**
     shows a dialog on the Host with a 16-character verification code to
     compare; **Don't Allow** admits only viewers already approved.
   - Agents never get the password: they always use the dialog.
   - Host › Approved Viewers… lists approved Viewers and agents. You can
     rename them, forget them one at a time, or forget all of them.

**Ports:** the Host listens on UDP 4433 (control) and 4434 (pixels). When
connecting over the internet, open both or use a VPN such as Tailscale.

## Agents: the `glassact` CLI and MCP server

```sh
just install-cli                       # installs glassact in ~/.local/bin
glassact connect my-mac.local --wait   # headless; approve the agent on the Host
glassact screenshot -o screen.png      # waits for the screen to settle
glassact click 640 400
glassact type "hello, world"
glassact key cmd+shift+t
glassact ui-tree                       # the focused window's controls, with frames
glassact --session viewer status       # drive your open Viewer session instead
```

To use it from an MCP client such as Claude Code, run
`claude mcp add glassact -- ~/.local/bin/glassact mcp`. The tools mirror
computer use: `screenshot`, `zoom`, `click`, `drag`, `scroll`, `key`, `type`,
`wait_for_settle`, `ui_tree`, `list_windows`, `clipboard_get` and
`clipboard_set`.

Agents work two ways:
- **Headless:** the agent connects with its own key. The Host asks you once,
  and you choose **Allow Control** or **View Only**.
- **Through your Viewer:** turn on Viewer › Settings › **Allow agents to use
  this session**. It's off by default, because it lets any program running
  as you drive the remote Mac.

**Host controls** for agents (Options › Agents):
- a master switch for control;
- a time limit (1 hour by default), after which input pauses until you
  resume it;
- **you always win**: the agent pauses for 2 seconds whenever someone uses
  the Host's own mouse or keyboard;
- a menu bar indicator while an agent is active;
- an audit log of every action. Typed text is counted, not recorded.

## Security

- **Always encrypted:** everything — pixels, video, input, clipboard — rides
  QUIC, which requires TLS 1.3. There is no unencrypted mode. Someone on the
  network can still see the addresses, that it's Glass Act, and *when* the
  screen is changing (traffic volume and timing), but not what's on it.
  Bonjour discovery is unencrypted and shows the Mac's name; turn off
  "Visible to Nearby Viewers" to stop advertising.
- **Mutual TLS:** every connection is QUIC with mutual TLS.
  - The Viewer trusts the Host's key on first use and refuses if it later
    changes, the way SSH does. You can also pin the key explicitly.
  - The Host admits only keys you approved. Everyone else is turned away
    during the TLS handshake, before seeing a pixel.
  - Signing in approves a key with the Host Mac's password, which travels
    encrypted and only to the Host key the Viewer trusts. Wrong passwords
    are rate-limited well below macOS's own lockout.
- **Keys:** each Mac has its own P-256 key, never synced.
  - The Host and Viewer keep theirs in the keychain, made in the Secure
    Enclave when the Mac has one (Apple silicon, or Intel with a T2), so it
    can't be copied off the Mac.
  - The `glassact` CLI, and builds without a signing team, keep a key file in
    `~/Library/Application Support/Glass Act/`, readable only by you.
  - Keys are shown and copied as short checksummed strings (`ga1…`).
- **Known limits:**
  - Other programs running as your user can read the CLI's key file and use
    the agent sockets.
  - Agent status is declared by the client.
  - The Viewer is sandboxed. The Host can't be: remote input needs
    Accessibility, which sandboxed apps can't have. It also uses private
    API for the virtual display and screen locking.

See [docs/DESIGN.md §13](docs/DESIGN.md#13-security-model) for the full
model.

To report a vulnerability, see [SECURITY.md](SECURITY.md): please report it
privately, not in a public issue.

## Files

| what | where |
|---|---|
| Host and Viewer keys | the login keychain (data protection), "Glass Act … identity" |
| CLI key, approvals, known hosts, agent sockets, audit log, traces | `~/Library/Application Support/Glass Act/` |
| Viewer data and logs (sandboxed) | `~/Library/Containers/app.glassact.viewer/Data/`; Help › Show Logs in Finder |
| Viewer log, live | `/usr/bin/log stream --predicate 'subsystem == "app.glassact.viewer"'` |
| logs uploaded to the Host | `~/Library/Logs/Glass Act/` |
| Host's unified log | `/usr/bin/log stream --predicate 'subsystem == "app.glassact.host"'` |

## How it works and contributing

- [docs/DESIGN.md](docs/DESIGN.md) covers the invariants, wire format,
  engines and transport.
- [BENCHMARKS.md](BENCHMARKS.md) is the measurement record: current
  numbers, every experiment kept or rejected, and the full log.
- [CONTRIBUTING.md](CONTRIBUTING.md) gets a new contributor from a clone to
  a signed, tested build.
- [AGENTS.md](AGENTS.md) is the working guide, for humans and coding agents
  alike.
- Open work is in GitHub issues.

Developer tools:
- **Host › Developer › Record Trace** captures a `.scap` trace.
- `glassact-bench replay` runs a trace through the engines, including a
  faulty-network loop whose canvas must match exactly.
- `glassact-trace` inspects traces.

## License

MIT — see [LICENSE](LICENSE). The bundled libwebp keeps its BSD-3-Clause
license and patent grant; see [ThirdParty/THIRD_PARTY.md](ThirdParty/THIRD_PARTY.md).
