# Security policy

Glass Act shares a Mac's screen and its input, so a security bug in it can
expose everything on that screen. Reports are welcome and taken seriously.

## Reporting a vulnerability

Please report vulnerabilities **privately**, not in a public issue, pull
request or discussion:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Describe the problem, the build on each end and the macOS versions, and
   the steps or a proof of concept that reproduce it.

That opens a private advisory visible only to you and the maintainer. Fixes
are developed there and published with the advisory, crediting you unless
you'd rather not be named.

Logs, screen recordings and `.scap` traces contain whatever was on screen,
so check them before attaching.

## Scope

In scope:

- **The apps:** Glass Act Host and Glass Act Viewer, including the Host's
  approval, sign-in and agent policy, and anything that lets a peer act on
  a Mac beyond what it was granted.
- **The wire protocol and QUIC transport:** the TLS and identity checks
  (trust on first use, pinning, `approved_viewers`), the record parser
  (wire parsing is always bounds-checked; any crash, over-read or
  out-of-bounds write from peer input is a bug), and the password exchange.
- **The agent CLI and MCP server:** `glassact`, the local agent sockets, and
  the MCP server it runs.

Out of scope are the limits [docs/DESIGN.md §13](docs/DESIGN.md#13-security-model)
already documents, such as traffic size and timing being visible to an
observer, other processes running as the same user reading the keys or
using the agent sockets, and the apps being unsandboxed. Reports that
change what those limits mean in practice are still welcome.

## What to expect

Glass Act has a single maintainer, so handling is best effort:

- an acknowledgement, usually within a week or two;
- an assessment and, for a confirmed issue, a fix in the next release, with
  timing that depends on severity and complexity;
- updates in the private advisory as things progress.

Only the latest release is supported; fixes don't go to older builds.

## Security model

How encryption, identities and approval work, and their documented
limitations, are in [docs/DESIGN.md §13](docs/DESIGN.md#13-security-model).
