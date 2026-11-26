Start from [NOW.md](NOW.md) (in flight, next steps) and [RUNBOOK.md](RUNBOOK.md) (exact commands).

## Sessions and handoff

- Start each session from NOW.md (in flight, next steps) and RUNBOOK.md (exact commands); do not ask me to
  re-explain, and do not search old transcripts for commands: add them to RUNBOOK.md the first time they are worked out.
- Keep NOW.md under ~60 lines, rewritten (not appended) at each handoff: uncommitted work and whether it is verified,
  background jobs or servers still running, the next 2-3 steps, decisions not yet written elsewhere.
- When a chunk of work is committed and the next task differs, when I switch topics, when a long investigation reaches
  its answer, or once the session has been compacted: finish the current step, then stop and ask me whether to hand
  off before starting anything new. On yes: update NOW.md and RUNBOOK.md, commit them, and give me the one line to
  start the next session with ("Continue from NOW.md").
- Save tokens: read large files and logs by section, send big tool or review output to a file and read its summary,
  delegate broad searches to a subagent, and prefer text output over screenshots.

## Standing rules

- Every change lands as a PR from its own worktree off `origin/main`; never commit to `main`, never force-push.
- Don't merge, and don't turn on auto-merge: the owner merges. Say which order to merge in.
- Check CI once per message (`gh pr checks`); no polling loops or timers.
- Tags and releases only when asked; the owner publishes drafts. Candidates stay pre-releases.
- One build, test or bench at a time on this Mac; time only when it's idle, and say the load.
- Don't touch signing, TCC, the keychain, `Apps/Signing.local.xcconfig` or `/Applications`; build with
  `CODE_SIGNING_ALLOWED=NO`. Don't launch the owner's Host or Viewer; the Simulator and the test host are fine.
- Ask before using the Mac Studio.
- Traces stay in `~/Library/Application Support/Glass Act/traces`: never in the repo or sent anywhere.
- Keep testers' details, and other projects' authors, out of issues, PRs and notes; link repos only.
- Perf claims need a `glassact-bench` number in BENCHMARKS.md; keep byte-neutral speedups, even small ones.
- Stay bitrate-efficient by default; spending bandwidth for quality is an opt-in.
- UI work meets an Apple Design Award bar: native, accessible, checked visually.
- Wire changes are additive (AGENTS.md); bring any new message type or caps bit to the owner first.

@AGENTS.md
