# Now (2026-11-26)

## In flight

- **Display choice from the Viewer** (Duo Desktop's feature, their wire format adopted byte for byte:
  DISPLAY_LIST 0x60 / DISPLAY_SELECT 0x61 / DISPLAY_SELECTED 0x62, caps bit 31).
  - #177 `display-picking`: protocol, engines, session API, tests, DESIGN §3.5/§4.10. Green, waiting to merge.
  - #178 `display-picking-host`: the Host lists displays and switches in session. Stacked on #177 (merge
    that first). Builds; not run on a Mac with two displays.
  - Viewer UI not started. Owner to decide: where the picker goes (proposed: a Displays menu in the Mac
    toolbar, the same list in the iPad controls, only with 2+ displays), and what it does in virtual-display
    mode (the Mac Viewer's default; it merges the displays, so the Host answers "not now").
  - Wanted alongside: a multi-display mode for `glassact-testhost`, to build the UI without a second display.
- **26.11.5** published 2026-11-25 (AV1 speedups, the Host on macOS 14.4+, fixes #168 resize, #169 lock,
  #172 tunnel pairing). Not yet confirmed on the tester's macOS 14.8 Mac: lock on disconnect, resize
  repaint, the 10 s first connect (#164, likely cause fixed in #172; his Viewer log would confirm).
- Merged since 26.11.5, unreleased: #175 (share only the chosen display; pointer kept on it), #176 (test host
  `--input-log`), #179 (pointer drawn at its own size; checked in the iPad Simulator, not on a Mac Viewer).

## Next

1. After #177/#178 merge: the Viewer picker UI (Mac and iPad) once the owner answers the two questions above.
2. Duo Desktop's other features, each needing the owner's call (numbers reserved in DESIGN by #177):
   lock and caret notices (0x63/0x64), display snapshots (0x65/0x66), auto-unlock typing the Mac
   password (0x67/0x68), SSH key install (0x70/0x71). The last two are security-sensitive.
3. #10 (one QUIC connection instead of two) needs `NetworkConnection` (macOS 26+) as an extra negotiated
   mode; re-run the 2026-09 spike on macOS 27 first.

## Notes for a fresh session

- The main checkout (`~/code/glassact`) sits on the merged branch `reduced-video`: make a worktree off
  `origin/main` for any change.
- No background jobs or servers running. #108 (iPad TestFlight workflow) is an old open draft.
- Duo Desktop: github.com/Stratechery/duo-desktop; their Host patches are in `patches/`. Their app works
  with a stock Host once #177/#178 ship.
- The Apple Screen Sharing comparison's scorer and frame-dump patch live only in one session's scratch
  folder, so a new session won't have them; the method and results are in BENCHMARKS.md ("Apple Screen
  Sharing's High Performance mode at 5K").
