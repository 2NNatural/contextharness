# Changelog

## 2.0.0 — verification-first upgrade

Baseline for comparison: v1 at commit `34eb046`.

### Why
An audit of v1 found that its model routing was real, but almost everything about
*correctness* was a request to the model in an always-loaded instruction block. v2 moves
the behaviours that matter into hooks and scripts that run whether or not the model
remembers them, and shrinks what is always loaded.

### Added — enforced, not requested
- **`stop-gate` hook.** When the agent tries to finish and code changed since the last
  successful check, it runs the project's trusted `verify.sh` and blocks on failure (with
  the output), or — when no recipe exists yet — blocks once if nothing that runs code was
  executed after the last change. Bounded to two blocks per request; when it gives up it
  tells the operator the work is UNVERIFIED instead of looping or staying silent.
- **`journal` hook.** Records every edit and command per session. Detects an agent stuck
  repeating the same failing command three times and injects a change-strategy instruction.
- **`session-state` hook.** Takes a git checkpoint at session start (`harness undo`), and
  after a resume or compaction re-injects the project's task state plus the files edited
  and the last verification result. A fresh session gets one line, not the content.
- **`ops-guard` hook.** Turns deploy / publish / infrastructure / force-push / push-to-main
  / destructive database commands / credential-file reads into an explicit operator
  decision. In an unattended session the action does not run.
- **Trusted verify recipes.** `harness trust-verify` records a recipe's hash outside the
  project. A recipe that arrives with a cloned repo, or is edited after being trusted, is
  never auto-run, and re-trusting requires the operator — the agent cannot rewrite its own
  exam.

### Added — workflow
- **Three rigor modes** (Light / Standard / High assurance) chosen by the orchestrator from
  what is at stake, with explicit escalation triggers.
- **Skills:** `plan` (sharpen → acceptance criteria → approach), `verify` (find or create
  the project recipe; proof matched to project type), `review` (non-author review, findings
  must reproduce), `learn` (mistake → strongest prevention → prove it → record at the right
  scope), `parallel` (worktree fan-out with a "should this be parallel at all" gate).
- **`verifier` agent** — adversarial QA that runs the change and cannot edit it.
- **`harness` CLI** — `detect` (project type, real test/run commands, risk signals),
  `trust-verify`, `status`, `stats` (real per-model token use from transcripts), `lessons`
  (recurrence ledger), `codex-review` (read-only cross-vendor review via `codex exec`),
  `undo`, `doctor`, `off` / `on` (kill switch).
- **Reporting contract:** Done · Checked · Not checked / open · Needs you, with
  *implemented / tested / verified / deployed* used precisely.

### Changed
- **Always-loaded core block: 14,440 → 7,441 bytes (−48%).** The Audit Standard (unchanged
  text) moved into the `audit` skill as `STANDARD.md`; Codex detail moved into the `review`
  skill and `config/codex-tiers`. A test fails the build if the block exceeds 8,000 bytes.
- **Destructive guard is git-aware.** It now blocks only what git cannot restore (untracked
  files, files with uncommitted changes, anything outside the project). Clean tracked files
  and git-ignored build output can be removed. It ignores heredoc bodies, respects command
  boundaries and resolves literal scratch-path variables. In the baseline benchmark the v1
  guard blocked a legitimate cleanup and the run still reported success.
- **Codex invocation** goes through a tested wrapper (`harness codex-review`) with a
  read-only sandbox, instead of an unverified assumption about a plugin subagent. Codex
  model IDs live in exactly one file; v1 had two copies that had already drifted.
- **Installer:** `--recommended` (everything on), `--with-workflow-hooks` /
  `--remove-workflow-hooks`, `--rollback`, `--uninstall`, `--with-codex-agents`, honours
  `CLAUDE_CONFIG_DIR`, snapshots what it replaces (last five kept), refuses a malformed
  `CLAUDE.md` before changing anything, installs whole skill directories, and derives the
  top-model ID from `agents/oracle.md` instead of three hardcoded strings.
- **`executor`** must reproduce a bug before fixing it, add a failing-first test, exercise
  the behaviour (not just build), and never weaken a test or recipe to pass.
- **`routing-refresh`** must update the oracle pin's reverse dependencies in the same diff
  (the gap that left v1's tests asserting a stale ID), and edits Codex tiers in
  `config/codex-tiers`.

### Preserved
The four routing agents and their models/efforts, the escalation ladder, the Audit Standard
text, `/audit`, the interface inventory, the context meter, the Codex toggle and its
read-only policy, `routing-refresh` and its diff-then-confirm gate, `codex-refresh.sh`, and
the default install's promise never to touch `settings.json`.

### Tests
63 → 133 deterministic tests, plus `tests/live-hooks.sh` (7 checks against the real Claude
Code build) and a benchmark suite under `bench/`.

### Migration from v1
```sh
cd harness && git pull
./install.sh --recommended          # or plain ./install.sh to keep hooks exactly as they were
~/.claude/scripts/harness doctor
```
- Nothing in your own `CLAUDE.md` or `settings.json` outside the harness's block and hook
  entries is changed. A backup is taken first; `./install.sh --rollback` restores it.
- If you had `--with-context-hook` / `--with-destructive-guard`, they keep working and are
  updated in place.
- The Codex toggle file is untouched. If you customised the Codex tier table in
  `routing-rules.md`, move those IDs to `config/codex-tiers`.
- Behaviour change to expect: the destructive guard now allows deleting build output and
  clean tracked files; with the workflow hooks on, the agent may be held for an extra turn
  when it tries to finish without having run anything.
