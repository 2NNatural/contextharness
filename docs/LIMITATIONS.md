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
- Change fingerprints hash file contents up to 5 MB; larger changed files are compared by
  size and modification time only. A file is fingerprinted only once git lists it as
  changed. On Windows, Git for Windows does not check ctime, so a clean tracked file that
  is rewritten with the same size and then has its old mtime restored is not listed by
  `git status` and is not seen as a change. On Linux and macOS the ctime change makes git
  list it. Files that are already in the changed set are compared by content on every
  platform.
- A verify recipe that writes untracked, non-ignored files with changing content (logs,
  timestamps) will re-run at every stop. Keep recipe outputs in ignored or temp paths.
- With `timeout`/`gtimeout`, a recipe that ignores TERM is KILLed five seconds after the
  deadline when that `timeout` supports `-k` (probed once per run); otherwise only TERM is
  sent. Without either binary the stop-gate (and `harness codex-review`, `tests/live-hooks.sh`,
  `bench/run.sh`) use a shell watchdog: at the deadline it takes one process snapshot
  (`ps -A -o pid= -o ppid=`; on MSYS/Cygwin, whose `ps` has no `-o`, `ps -al`; `ps -ef` as
  a last resort), sends TERM to the command and every descendant in it, and KILL two
  seconds later even if the top process already exited. A process that has left that tree
  (daemonised or re-parented, e.g. a server started with `nohup … &` that outlives its
  parent) is not found and may keep running. The descendant kill was verified on Windows
  only; on Linux and macOS it is unexercised. On BusyBox `ps` (Alpine) the snapshot may
  come back empty or mis-parsed, so only the top process is signalled. The watchdog also
  has small race windows: a TERM that arrives between steps can leave a temp mark file or
  one orphaned `sleep`, and the KILL goes to the pids of the snapshot taken two seconds
  earlier.
- A recipe that **succeeds** but leaves a background process behind (`server & … exit 0`)
  is not cleaned up. The watchdog only snapshots the tree at the deadline, and by the time
  the top process has exited its children have been re-parented. The `timeout`/`gtimeout`
  path behaves the same way: it signals only on timeout. Stop background processes inside
  the recipe (for example with `trap 'kill $!' EXIT`).
- Outside git, only Edit/Write tool events count as changes; edits made through the shell
  (`printf x > app.py`, `sed -i`) do not arm the gate there. This is deliberate: outside git
  there is no list of changed files to check against, so counting every may-write command
  would block on each `cmd > /tmp/log` and each doc written through the shell. A recipe run
  is checked for writes only to files the edit journal already knows (their content is part
  of the fingerprint); a recipe that writes other files outside git is not noticed.
- Concurrent journal appends are not guaranteed atomic on every platform (notably Windows);
  unreadable records are tolerated and counted as activity (outside git, as a change), so
  the failure mode is an extra gate check rather than a skipped one.
- Files changed by commits count as session changes only when the session ran a git
  command that creates commits (`commit`, `am`, `cherry-pick`, `revert`, `rebase`, `merge`;
  the journal marks it) and SessionStart recorded the starting HEAD. Consequences:
  - A commit made through an alias, a script or an IDE is not seen. The gate then sees
    working-tree changes only, so "edit, commit that way, stop" is not gated.
  - A session resumed from before the upgrade, or one whose starting commit has since
    been garbage-collected, also sees working-tree changes only.
  - The operator's own commits and a `git pull` or branch switch are not counted, which is
    intended. If the session also made a commit, everything between the starting HEAD and
    the current HEAD counts, including such commits.
  - A commit made on another branch and then left by switching back, or work put away with
    `git stash`, is not in the tree and is not gated.
- The may-write check is deliberately liberal: a writer word anywhere outside quotes
  (`xargs …`, `git stash`, `cp`) or any `>` redirect outside quotes (`cmd > /tmp/x`).
  Quoted text (search patterns, messages, jq/awk programs) is ignored, except the string of
  `bash -c '…'`. Combined with an edit the operator makes in an IDE mid-session, a may-write
  command can produce one block per request. The block then says code "changed on disk
  since this session started" rather than "you changed code".
- A tracked file deleted during the session has no modification time. It counts as changed
  at the time of the session's latest edit or may-write command, so test runs from before
  the deletion do not cover it. When an unrelated may-write command ran after the tests,
  this asks for one extra run.
- Trust holds one recipe hash per project (shared by all branches and worktrees). A branch
  whose recipe content differs from the trusted one reads as "changed". A session that
  starts on a branch without any recipe is in weak mode. Deleting the recipe during the
  session is "changed".
- A trusted recipe that is modified or removed is reported once per request even when the
  agent changed nothing else; the operator resolves it with `harness trust-verify` or
  `harness untrust-verify`.

**Safety hooks are tripwires, not a sandbox**
- `ops-guard` and `destructive-guard` match the leading words of shell commands. Indirection
  defeats them: a wrapper script with an innocent name, `eval`, a Makefile target called
  `ship`, or an MCP tool that deploys. Tools exposed through MCP servers (merging a PR,
  sending email) are covered by Claude Code's own permission prompts, not by these hooks.
- `destructive-guard` follows `cd`/`pushd` to literal directories when `cd` starts a
  command (also after `VAR=value`, `{`, `then`, `do`, `else`, `!`). A `cd` whose target it
  cannot read makes later relative targets unprovable, so the delete is blocked. That
  covers `$VAR`, `$(…)` and `cd -`, and any relative `cd` after a non-empty `CDPATH` set
  anywhere earlier in the command (prefix, assignment or `export`). The one exception is a
  leading `cd "$(git rev-parse --show-toplevel)"`, which resolves to the repository root.
  A `cd` in any other position (e.g. inside `eval "cd a"`) is not followed. A `CDPATH`
  already exported in the environment is not considered.
- `destructive-guard` treats git-ignored files as disposable build output, except files
  named like credentials (`.env*`, keys, `credentials`, `secrets.*`). Inside a wholly
  ignored directory it looks for such names only three levels deep and in the first 5,000
  files, and never inside `node_modules`, `.venv`, `venv` or `.git`. Ignored local data that
  is not named like a credential (databases, caches with value) can still be deleted.
- `ops-guard` recognises:
  - common global options (`git -C/-c`, `kubectl/helm -n/--context`);
  - wrappers with their option operands (`env -u X`, `sudo -u u`, `nice -n N`,
    `timeout [-k N] N`, `npx`, `xargs -n N`), also inside `( … )`;
  - quoted command words;
  - the string of `bash -c '…'`, `sh -c "…"`, `bash --norc -c '…'` and `bash -c $'…'`.

  It is not a shell parser: unusual option orders, `bash -c` strings that span lines or
  contain escaped quotes, and `eval` still evade it. `… | xargs harness` (subcommand from
  input) asks; other commands fed through xargs are judged by their literal words only.
- Writes to `~/.claude/harness/off`, `…/trust` (in any letter case) or `…/harness/state/…`
  through the Write/Edit/MultiEdit/NotebookEdit tools ask. This needs ops-guard registered
  with the wider matcher: `./install.sh` (plain or with hook flags) upgrades an existing
  registration, and `harness doctor` warns about an old one. Writes through any other
  mechanism (an MCP tool, a script) do not ask.
- Shell writes to the gate's own session state also do not ask. `echo 0 > …/state/<sid>/blocks.p1`
  or `cp x …/state/<sid>/verified` can reset the block budget or fake a pass. The off
  switch and the trust list are checked in Bash commands; the state directory is not,
  because reading `verify.last` there is routine.
- Matching on paths is by substring, so a project's own `docs/harness/off` (Write) or
  `cat docs/harness/off.md` asks. Any `cd` word in a command that runs `harness trust-verify`
  (even in a comment) asks.
- An existing ops-guard registration written in another path form (e.g.
  `~/.claude/hooks/ops-guard.sh` instead of the absolute path) is not recognised by the
  installer. The upgrade then adds a second entry, so ops-guard runs twice on Bash and Read.
- `harness untrust-verify` rewrites the trust file through a temp file and `mv`. A
  `trust-verify` running at the same moment can lose its line, and a symlinked trust file
  becomes a regular file.
- Outside git, a project's trust key is its physical path (`pwd -P`). Under an MSYS mount
  point (e.g. `%TEMP%` seen as `/tmp`) the same directory can yield two different keys
  depending on the path form used.
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
- `harness codex-review` has run live for all four tiers, against codex-cli 0.162.1 on
  Windows:
  - `review` and `plan` on 2026-11-23, including a 73 KB prompt on stdin
    (`codex exec … -`) to gpt-6-luna (xhigh);
  - `security --yes` and `judgment --yes` (gpt-6-astra, high / xhigh) on 2026-11-24.

  The one-shot fallback retry also ran live on 2026-11-24. With a throwaway config naming a
  nonexistent primary model, the wrapper printed "was rejected; retrying once on
  gpt-6.1-sol" and the retry returned (exit 0). The quality of Codex reviews is not
  measured.
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
  parallel work, recovery across genuinely interrupted sessions, and the quality of Codex
  reviews (every tier has run live, but no review was scored).

**Platform**
- Developed on Linux. On Windows 11 (Git Bash) the unit suite passes (186 passed, 0 failed, 2 skipped: T10 needs
  symlinks, T14 needs enforced `chmod 000` — platform capabilities, not defects). The suite
  has not been re-run on Linux after the third fix round.
- `LIVE_COPY_CREDENTIALS=1 bash tests/live-hooks.sh` ran on Windows Git Bash with the haiku
  model on 2026-11-24: "LIVE RESULTS: 7 passed, 0 failed". That run used the round-2 code;
  it was repeated on the final round-3 code with the same result. Both went through `h_run_bounded`.
- Never exercised live:
  - an ops-guard ask on the Write/Edit tools;
  - the `harness untrust-verify` ask;
  - `bench/run.sh` under `h_run_bounded`.
- macOS (bash 3.2, BSD tools) has never been run. Its known portability hazards (negative
  `head` counts, `sed` newline replacement, missing `timeout`) are covered only by a static
  lint test.
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
