# Changelog

## Unreleased — fixes from the Codex cross-vendor design review

Codex (`harness codex-review plan`, gpt-6.1-sol, codex-cli 0.162.1, Windows) reviewed the
v2 design on 2026-11-23. Its 15 findings were re-verified with real hooks and real jq (none
refuted); four more defects surfaced during that verification. The fixes were then reviewed
again by a Claude architect and by Codex (`review` tier, gpt-6-luna; the 73 KB diff went
through the new stdin path), which found several fixes only partial; a second round
addressed them. A third review (Claude architect plus Codex `review`) found regressions and
gaps in that round; a third, convergence-only round fixed them. Not everything is fully
closed: per-finding status (resolved, or mitigated with the residue listed in
docs/LIMITATIONS.md) is in docs/ARCHITECTURE.md › Codex cross-vendor review and the two
review tables after it.

### Fixed — verification gate
- **Shell-only edits arm the gate.** The journal marks commands that may write files
  (`sed -i`, redirections, `cp`/`mv`, `git checkout` …), matched anywhere at a word
  boundary (`for … do sed -i`, `find -exec`, `(…)`, `env X=1 …`, `bash -c '…'`); the
  stop-gate then checks git for changes instead of only after Edit/Write events. Quoted
  text (search patterns, messages, jq/awk programs) does not count; the string of
  `bash -c '…'` does. When no code file was edited with an edit tool, the block says code
  changed on disk rather than "You changed code". Outside git, shell-only writes still do
  not arm the gate (documented).
- **Committing does not escape the gate.** SessionStart records HEAD. When the session ran
  a commit-creating git command (`commit`, `am`, `cherry-pick`, `revert`, `rebase`,
  `merge`; marked in the journal), files changed by commits since session start count as
  changes. The operator's own commits, a `git pull` and a branch switch do not. Sessions
  started on an older version, a missing or unreachable start commit, and commits made
  through an alias or script fall back to working-tree changes.
- **A tracked file deleted after the tests ran** counts as changed at the session's latest
  edit or may-write command, so the earlier run no longer covers it.
- **A recipe modified after it was trusted, or deleted during the session,** blocks once,
  then releases as UNVERIFIED. It no longer falls back silently to weak mode, where any
  code run counted. A session that starts on a branch that never had the recipe is in weak
  mode (SessionStart records whether the recipe existed).
  The block no longer tells the agent to `git checkout` the recipe. A session that changes
  only the recipe gets one visible note per request. New `harness untrust-verify [dir]`
  removes a project's trust record (for a recipe removed on purpose).
- **A torn journal line** no longer disables the gate or the loop detector; unreadable
  records count as activity, and outside git as a change.
- **Content fingerprints** (`git hash-object`, files up to 5 MB, non-ASCII names included)
  replace size + mtime, so a same-size edit with a preserved mtime is still a change for
  any file git lists as changed. On Windows, a clean tracked file rewritten at the same
  size with its old mtime restored is not listed by `git status` (Git for Windows has no
  ctime check) and is not seen. Files
  changed while the recipe runs are re-verified at the next stop instead of being certified
  by that run; outside git this covers the files the edit journal knows.
- **Recipes are always bounded.** Without `timeout`/`gtimeout`, a shell watchdog stops the
  recipe's process tree (TERM, then KILL, which is no longer cancelled when the top process
  exits) and reports a timeout; with them, `-k 5` escalates to KILL when supported.
  `verify.last` reads RUNNING while it runs, so a hook killed from outside never leaves a
  stale PASSED. Non-numeric `HARNESS_VERIFY_TIMEOUT` / `HARNESS_CODEX_TIMEOUT` values fall
  back to the default; the watchdog's mark file falls back to `/tmp`, then the harness
  directory, when `TMPDIR` is not writable. Background processes left by a recipe that
  *succeeds* are not stopped (documented).
- **Evidence classification**: `"ls"`, `env ls`, `'cat' x`, `env -u X ls`, `nice -n 5 ls`,
  `xargs grep …` and the closing words of `if … fi`, `for … done`, `case … esac`, `{ …; }`
  no longer count as running code.

### Fixed — safety hooks
- **ops-guard**: `git -C`/`-c`, `kubectl`/`helm -n`/`--context`, `docker -H`, quoted command
  names, and wrappers with option operands (`env -u X`, `sudo -u u`, `nice -n 5`,
  `timeout [-k 5] 60`, `xargs -n 1`, `( … )`) no longer hide the command; the strings of
  `bash -c '…'`, `sh -c "…"`, `bash --norc -c '…'` and `bash -c $'…'` are checked too;
  `env -i` alone is no longer treated as an environment dump, `( env )` is. Windows
  backslash paths to credential files ask. `harness off` and `harness untrust-verify` ask,
  also quoted, wrapped or inside `bash -c`, and so does `… | xargs harness`. ops-guard now
  also sees Write/Edit/MultiEdit/NotebookEdit and asks before they touch
  `~/.claude/harness/off`, `…/trust` (matched in any letter case, as on NTFS and APFS) or
  the gate's own `…/harness/state/`; an edit-tool payload that never mentions `harness`
  skips jq. `./install.sh` replaces the old `Bash|Read` matcher instead of adding a second
  entry: with the hook flags, and also on a plain `./install.sh` when ops-guard is already
  registered. `harness doctor` warns about a registration without Write/Edit.
  `trust-verify` aimed at another project (an argument, or a `cd` anywhere: subshell,
  braces, `bash -c`) asks, and so does re-trusting behind a wrapper (`timeout 60`,
  `env -u X`, `nice`, `stdbuf`, `xargs`); a command that only mentions trust-verify (a grep,
  an echo, a commit message) does not. Every ask is appended to the session's `ops.log`.
- **Trust lookups match the exact project key** — trusting `proj2` no longer trusts `proj`,
  and a superproject's trust no longer covers its submodules.
- **destructive-guard** follows literal `cd`/`pushd` before a delete, also after
  `VAR=value`, `{`, `then`, `do`, `else`, `!` (an unknown target blocks, and so does a
  relative `cd` after a non-empty `CDPATH` set or exported anywhere earlier in the command;
  a leading `cd "$(git rev-parse --show-toplevel)"` resolves to the repository root), and treats git-ignored files named like credentials (`.env*`, keys) as
  unrecoverable — also inside a wholly ignored directory (bounded scan: depth 3, 5,000
  files, `node_modules`/`.venv`/`venv`/`.git` skipped).
- Command splitting uses awk instead of a GNU-only `sed` newline replacement.

### Fixed — CLI, installer, tests
- `harness codex-review` sends the prompt on stdin (`codex exec … -`), so large diffs no
  longer exceed the argument limit (about 32 KB on Windows); this ran live on Windows
  (73 KB, `review` tier). It is bounded by the same watchdog when no timeout binary exists.
  All four tiers (`review`, `plan`, `security --yes`, `judgment --yes`) and the one-shot
  fallback retry have now run live (codex-cli 0.162.1, Windows, 2026-11-23/24).
  `harness detect` writes `python` into suggested commands when `python3` is absent.
- The watchdog finds descendants with `ps -A -o pid= -o ppid=` (MSYS/Cygwin: `ps -al`;
  `ps -ef` last), so a user name with a space cannot shift the columns.
- Installer backup pruning no longer uses `head -n -5`, which aborts the install on macOS.
- `tests/live-hooks.sh` runs a preflight and aborts (exit 2, not a pass) when the sandbox
  cannot reach the model; checks are no longer evaluated on errored sessions; the ops-guard
  check requires proof the guard fired (`ops.log`). Optional `LIVE_COPY_CREDENTIALS=1`
  copies your credentials file into the throwaway config (off by default; deleted on exit).
- Live test and benchmark runner run `claude` through `h_run_bounded`, so they stay bounded
  without `timeout`/`gtimeout`; they, and the graders, resolve Python (`python3` or
  `python`); T44 rejects grader failures caused by a missing interpreter.

### Tests
Regression tests for every finding (T34g–h, T36f–j, T37s–zn, T38i–s, T40g–k, T41k–o, T42f,
T46a, T47a–b), including negative tests (wrapped re-trust asks; quoted read-only commands
do not arm the gate; an operator commit or a pull does not block a doc-only session).
T37zh and T40k poll instead of sleeping a fixed time. On Windows 11 / Git Bash:
132 → 186 passed, 0 failed, 2 skipped (T10, T14 — platform capabilities).
`LIVE_COPY_CREDENTIALS=1 bash tests/live-hooks.sh` ran on Windows Git Bash (haiku) on
2026-11-24, with the second-round code and again with the final third-round code: 7 passed, 0 failed both times. `bench/run.sh` was syntax-checked
only; the Linux and macOS suites were not re-run.

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
