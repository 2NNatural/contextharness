# Limitations and future work

## Known limitations (things v2 does not do, stated plainly)

**Verification**
- The stop-gate's weak mode (no project recipe yet) only proves that *something that runs
  code* was executed after the last change. It catches "edited and declared done without
  running anything"; it does not prove the right thing was run. Recipe mode is as good as
  the project's `verify.sh`.
- The recipe is written by an agent. It is protected against being weakened after it is
  trusted, not against being weak when first written. Read `VERIFY.md` once per project if
  the stakes are high.
- Browser/UI verification depends on Playwright being available in the project or on the
  machine. Nothing is bundled.
- Formal verification is not included.

**Safety hooks are tripwires, not a sandbox**
- `ops-guard` and `destructive-guard` match the leading words of shell commands. Indirection
  defeats them: a wrapper script with an innocent name, `eval`, a Makefile target called
  `ship`, or an MCP tool that deploys. Tools exposed through MCP servers (merging a PR,
  sending email) are covered by Claude Code's own permission prompts, not by these hooks.
- "Read-only" agents (`scout`, `architect`, `oracle`, `verifier`) have no edit tool but do
  have a shell, so read-only is an instruction plus the guards, not an enforced boundary.
- Real protection for production comes from the agent not holding production credentials.
- All hooks fail open: without `jq` they do nothing. `harness doctor` reports this.

**State and recovery**
- `STATE.md` is written by the orchestrator because a rule tells it to. If it is never
  written, recovery falls back to what the journal knows for certain (files edited, last
  verification result) and the git checkpoint.
- The session-start checkpoint covers tracked files only. Files that were never added to git
  are not in it.
- Session state lives under `~/.claude/harness/state` and is pruned after 30 days.

**Codex**
- Nothing Codex-related was exercised against a real Codex CLI: it was not installed or
  logged in where v2 was built. `harness codex-review` is tested against a stub that checks
  the model, effort and read-only sandbox arguments. Run `harness doctor` and one real
  review on your machine before relying on it.
- The Codex-side install (`--with-codex-agents`) is a prose core only. None of the
  deterministic hooks run inside Codex CLI sessions.

**Self-improvement**
- The lesson ledger counts recurrences; deciding the right prevention is still a judgement
  made by the model. Harness-level changes are deliberately manual (branch, tests,
  approval).

**Measurement**
- The benchmark is six small tasks with a handful of trials. It can show large differences
  and catch regressions; it cannot resolve small ones. See BENCHMARK.md for exactly what
  was and was not measured.
- Not measured at all: long multi-hour tasks, real UI work in a browser, multi-agent
  parallel work, recovery across genuinely interrupted sessions, and any Codex path.

**Platform**
- Developed and tested on Linux with bash, git and jq. macOS should work (BSD `stat` and
  `shasum` fallbacks are in place) but was not run. Windows via Git Bash is untested for
  the new hooks.
- This repo's own `CONTEXT.md` contains historical facts that are now stale (model IDs and
  availability notes from mid-2026). They were left as the operator's record and flagged
  rather than rewritten.

## Future opportunities, in rough priority order

1. **Grow the benchmark from real failures.** Every time the operator catches a defect,
   add it as a task with a hidden check. Twenty to fifty tasks is where pass-rate
   differences become trustworthy.
2. **Port the stop-gate and journal to Codex CLI hooks**, so both tools enforce the same
   definition of done.
3. **Machine-checkable `INTERFACES.md`** for the audit pre-live gate (stale or never-fired
   links fail automatically).
4. **Scheduled maintenance** of project verify recipes (run, report drift) once a
   scheduler is in use.
5. **Per-skill A/B evaluation** so a skill edit must beat the previous version on the
   benchmark before it ships.
6. **Scope guards by agent type** (block shell writes from read-only agents) once the
   `agent_type` payload field is confirmed reliable across Claude Code versions.
7. **A browser verification helper** (thin Playwright wrapper producing screenshots at set
   sizes) for projects that lack one.
8. **Verdicts bound to `git patch-id`** if and when agents are trusted to merge their own
   work.
