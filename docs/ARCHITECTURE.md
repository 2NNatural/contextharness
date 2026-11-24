# ContextHarness v2 — Architecture

## Design stance

Three findings from the audit and research drive everything here.

1. **A rule nobody enforces is a wish.** v1 was almost entirely prose in an always-loaded
   CLAUDE.md block. pstack, the strongest external system studied, is the same: no hooks,
   every gate depends on the model complying. Where a behavior matters (don't claim done
   without running anything, don't deploy unasked, don't lose task state on compaction),
   v2 moves it into a hook or script that runs whether or not the model remembers.
2. **Always-loaded text is the most expensive text.** v1 put ~14 KB (~3.6k tokens) into
   every session of every project, most of it relevant only to audits or Codex. v2 keeps a
   small core always on and loads the rest on demand as skills.
3. **More agents is not more quality.** Published evidence (Anthropic's multi-agent
   writeup, the MAST failure study) says multi-agent setups cost roughly 4-15x the tokens
   and pay off for breadth-first work, not coupled implementation. v2 uses subagents for
   context isolation and for independence (the checker is not the author), and adds
   exactly one agent.

## Layers

```
operator (plain English)
   │
always-on core  (routing-rules.md → CLAUDE.md block, size-budgeted by a test)
   │   routing table · rigor modes · definition of done · autonomy & escalation · report shape
   │
skills (loaded on demand)          agents (isolated contexts)        hooks (deterministic)
   plan      sharpen + criteria       scout     haiku  read           journal      record edits/commands/failures
   verify    prove it works           executor  sonnet write          stop-gate    block "done" without verification
   review    non-author review        verifier  sonnet break it       session-state restore task state on resume/compact
   audit     seam-level standard      architect opus   design/review  ops-guard    ask before deploy/publish/secrets
   learn     mistake → prevention     oracle    top    huge context   destructive-guard (v1)
   parallel  worktree fan-out                                         context-meter     (v1)
   routing-refresh (v1)
   │
scripts/harness  (one CLI: detect · trust-verify · stats · lessons · codex-review · doctor)
bench/           (reproducible baseline-vs-candidate evaluation)
```

## Rigor modes (selected by the orchestrator, never by the operator)

| Mode | When | What it adds |
|---|---|---|
| Light | small, reversible, one area, obvious check | do it, run the check, report |
| Standard | features, integrations, multi-file changes | acceptance criteria first, project verify recipe, STATE.md checkpoint, non-author review of risky parts |
| High assurance | money, auth/security, data migration/loss, concurrency, irreversible or production-facing actions, broad architecture | Standard + written plan challenged before build, invariants/property tests, `verifier` adversarial pass, `audit` standard, cross-vendor review when Codex is on |

Escalate one mode when: the change touches something on the High list, a check fails twice,
the diff grows past what was planned, or the request turns out to be ambiguous in a way that
changes the outcome. Never de-escalate mid-task.

## Verification-first, enforced

- `journal` hook records every file edit and every command result per session.
- `stop-gate` hook runs when the agent tries to finish. If code changed since the last
  successful verification it (a) runs the project's trusted `.claude/harness/verify.sh` and
  blocks on failure with the output, or (b) when no recipe exists, blocks once if nothing
  that runs code was executed after the last change. Change detection comes from git
  (so edits made through the shell count), docs-only changes are exempt, a question to the
  operator is not a claim of completion, plan mode and subagents are never gated. Blocks
  are bounded per operator request (2), so it can never loop; when the bound is hit it
  lets go and tells the operator the work is UNVERIFIED.
- `verify` skill creates the project recipe on first use: `harness detect` finds the real
  test/build/run commands deterministically, the skill writes `verify.sh` plus a short
  `VERIFY.md` (how to launch, drive, observe, clean up), runs it once to prove it, and
  registers its hash with `harness trust-verify` (stored outside the project). A recipe
  that arrives with a cloned repo, or that is edited after being trusted, is never run
  automatically, and re-trusting an already-trusted project goes to the operator — the
  agent cannot weaken its own exam.
- Review findings count only with a reproduction (command + observed output). Verdicts
  come from an agent that did not write the code.

## State and recovery

- `.claude/harness/STATE.md` per project: goal, acceptance criteria, decisions, done/next.
  Written by the orchestrator at milestones in Standard and High modes.
- `session-state` hook (SessionStart): on resume or after compaction it injects STATE.md
  plus the journal summary (files touched, last verification result). On a fresh start it
  injects one line pointing at unfinished state, not the content.
- `journal` also detects loops: the same command failing three times in a row triggers an
  injected instruction to change strategy or escalate.

## Self-improvement, controlled

`learn` skill: root cause → is it a class (seen twice)? → strongest prevention on the
ladder (architecture → types/schemas → constraints → tests → CI/hooks → skill → prose) →
prove the prevention fails on the original mistake → record. Project lessons go in the
project (`.claude/harness/LESSONS.md`, capped). Global lessons are never applied in place:
`harness lessons propose` queues them, and they land only as a branch of this repo that
passes the test suite and benchmark and that the operator approves. Installs are versioned
and `install.sh --rollback` restores the previous one.

## Model routing

v1 routing table, effort defaults and escalation ladder are kept. Additions: mode-aware
review routing (no reviewer for Light), `verifier` for adversarial QA, and
`harness stats` which reads real per-model spend from session transcripts so routing
changes can be argued from measurements. Codex stays toggle-gated and read-only; the
invocation path becomes a tested wrapper around `codex exec` (read-only sandbox) instead
of an unverified assumption about a plugin subagent.

## Security

Least privilege by role (only executor writes; verifier runs but cannot edit),
`destructive-guard` (v1), `ops-guard` (asks before deploy/publish/infra/force-push/secret
access; in unattended sessions an "ask" is a refusal), untrusted verify recipes never
auto-run, external skills/plugins are reviewed before install (core rule), and every hook
is honest about being a tripwire against accidents rather than a sandbox.

## Independent design review

Before implementation the design was handed to a separate reviewer with instructions to
find how it would fail in practice. Material findings and what was done:

| Finding | Resolution |
|---|---|
| The agent could weaken `verify.sh` and re-trust it | Trust stored outside the project; a changed recipe is not honoured; re-trust asks the operator (`ops-guard`), also behind wrappers such as `timeout`, `env -u` or `xargs` since the third round (indirection such as `eval` or a script still evades it); tested (T37p, T38g, T38p); strengthened after the Codex review (F3, F4, N1) |
| "Something ran after the edit" is satisfied by `ls` | Only commands that run code count; listing, reading, moving and git bookkeeping do not (T36a, T37e) (quoted/`env` forms since F10) |
| Edits made via the shell were invisible | Change detection from git status, not tool events; a shell command that may write also arms the gate (F2) |
| A per-session block budget dies on the first hard task of a long-lived thread | Budget is per operator request (T37d) |
| Stop fires on every turn end, including questions | A closing question is never blocked (T37i) |
| Moving the Audit Standard would break `/audit` and the installer | Single-sourced in the skill; installer copies whole skill directories (T28a) |
| Verify timeout would read as a pass | Timeout is reported as a failure (T37q) (also without a `timeout` binary since F13) |
| Docs-only edits and worktrees | Docs exempt (T37h); trust keyed on the repository's common git dir so worktrees share it |
| Loop detector false-fires in red-green cycles | Count resets on any edit; keyed per agent (T36d) |
| Parallel subagents racing on state | Append-only single-line journal entries; counts derived at read time; torn lines tolerated (F9) |
| Stale STATE.md injected into unrelated work | One-line pointer on fresh start, content only on resume/compaction, 7-day freshness, 2 KB cap (T39) |
| ops-guard gaps (script names, push to main, Read tool) and false positives | Added; matches the leading words of each command segment (and of `bash -c` strings), ignores heredoc bodies (T38, T41j) |
| Destructive guard blocks every in-project delete | Now blocks only what git cannot restore, except that ignored build output is allowed (see LIMITATIONS) (T41) |
| `learn` could author auto-executed hooks | `learn` may not touch hooks, trust or global rules |
| No kill switch, no hook self-test | `harness off`, `harness doctor`, `tests/live-hooks.sh` |

### Codex cross-vendor review (2026-11-23)

The same challenge was put to Codex (`harness codex-review plan`, gpt-6.1-sol, high, read-only
sandbox, codex-cli 0.162.1 on Windows). Codex could not execute jq, so every finding was
re-verified by a Claude architect with real hooks and real jq before being accepted. Four
further defects (N1–N4) surfaced during that verification. "Static" means confirmed by
reading the code, not by running it on the affected platform. The Status column reflects
the code after the second review round below: "resolved" means the reported failure no
longer reproduces and a test asserts it; "mitigated" means the reported forms are fixed
but a residue remains, listed in LIMITATIONS.md.

| Finding | Verdict | Resolution | Status |
|---|---|---|---|
| F1 installer `head -n -5` aborts on macOS | Confirmed (static) | awk pruning; portability lint (T46a, T47a) | resolved (macOS not run) |
| F2 shell-only edits skip the gate | Confirmed | journal marks commands that may write (`w`), matched anywhere at a word boundary outside quotes (`for … do`, `find -exec`, `(…)`, `env X=1`, `bash -c`) (T37t/u, T36h) | resolved in git; deliberately liberal (false "yes" documented); outside git shell writes do not arm the gate (documented) |
| F3 `trust-verify <other dir>` bypasses the re-trust check | Confirmed | ops-guard resolves the target project; an argument naming another project, or a `cd` anywhere (subshell, braces, `bash -c`), asks; only real `harness trust-verify` invocations are checked, found after the same wrapper skipping as every other command (T38j, T38p) | resolved for literal and wrapped forms; `eval`/wrapper scripts documented |
| F4 changed recipe silently downgraded to weak mode | Confirmed | a modified trusted recipe, or one DELETED during the session, blocks once, then releases as UNVERIFIED; weak evidence never counts for it; `harness untrust-verify` for a deliberate removal; a session that starts on a branch without the recipe is in weak mode (T37s, T37z, T37zk, T40j) | resolved; one trusted hash per project (branches with different recipes read "changed", documented) |
| F5 `cd x && rm y` resolved against the wrong directory | Confirmed | literal `cd`/`pushd` tracked, also after `VAR=value`, `{`, `then`, `do`, `else`, `!`; an unknown target blocks, and so does any relative `cd` after a non-empty `CDPATH` set or exported earlier in the command; a leading `cd "$(git rev-parse --show-toplevel)"` is the repository root (T41k, T41m, T41o) | mitigated — `cd` in other positions documented |
| F6 ignored files treated as recoverable | Partly (deliberate for build output) | ignored credential files, and credential-named files inside a wholly ignored directory (bounded scan), are not recoverable (T41l, T41n) | mitigated — scan bound and non-credential data documented |
| F7 size+mtime fingerprint collides | Confirmed (low) | content hash via `git hash-object` up to 5 MB, non-ASCII names included (T37w, T37zj) | resolved |
| F8 edits during the recipe certified | Confirmed (low) | pre-run fingerprint recorded; changed tree re-verified next stop; outside git the journal-known files' content is fingerprinted (T37x, T37zd) | resolved in git; mitigated outside git (files unknown to the journal documented) |
| F9 torn journal line disables the gate | Confirmed | tolerant reader; corrupt records count as activity, and outside git as a change (T36g, T37v, T37ze) | resolved |
| F10 `"ls"` / `env ls` count as evidence | Partly (weak mode is coarse by design) | quotes stripped; wrappers (also `xargs`) and their option operands skipped; the closing words `fi`/`done`/`esac`/`}` are not evidence (T36f, T36i, T36j) | resolved for the listed forms |
| F11 `git -C`, `env`, `kubectl -n` bypass ops-guard | Confirmed | global options normalised; wrappers consume their option operands (`nice -n 5`, `env -u X`, `sudo -u u`, `timeout -k 5 60`) (T38k, T38r) | mitigated — not a shell parser, documented |
| F12 Windows backslash paths bypass secret reads | Confirmed | paths normalised before matching (T38l) | resolved |
| F13 no `timeout` binary = unbounded recipe; CLI ignores `gtimeout` | Confirmed | portable watchdog `h_run_bounded`; its KILL stage is no longer cancelled; the `timeout` path adds `-k 5` when supported (T37y, T40h, T37zh, T37zi) | resolved (descendant kill verified on Windows only; background processes left by a *successful* run are not stopped, documented) |
| F14 large Codex prompts exceed argv limits | Confirmed (40 KB fails on Windows) | prompt sent on stdin (`codex exec … -`) (T40g) | resolved — ran live on Windows (73 KB prompt, `review` tier, codex-cli 0.162.1, 2026-11-23); by 2026-11-24 all four tiers and the fallback retry had run live |
| F15 `harness off` via the CLI is not gated | Confirmed | ops-guard asks on `harness off` and `harness untrust-verify`, also quoted, wrapped (`xargs`, `( … )`) or inside `bash -c '…'` / `bash --norc -c $'…'`, and on Write/Edit/MultiEdit/NotebookEdit of `harness/off`, `harness/trust` (any letter case) or `harness/state/…`; every ask is logged to `ops.log` (T38m–o, T38q, T38s, T34g, T34h) | mitigated — writes by other mechanisms (and shell writes to the state directory) documented; the Write/Edit ask never fired live |
| N1 trust lookup matched key prefixes (sibling dirs, submodules) | Confirmed | exact tab-delimited match (T38i) | resolved |
| N2 `sed 's/…/\n/'` does not split on BSD sed | Probable (macOS not run) | awk splitter `h_segments`; lint (T47a) | resolved (macOS not run) |
| N3 benchmark graders "failed" on Windows only because `python3` is absent | Confirmed | Python resolved (`h_python`, T40i); T44 rejects interpreter-missing failures | resolved |
| N4 hardcoded `timeout` in live test and bench | Confirmed (static) | both now run `claude` through `h_run_bounded` (watchdog when neither `timeout` nor `gtimeout` exists) (T47b) | resolved (neither script run on Windows) |

### Second review of the fixes (2026-11-23)

The fixes above were reviewed again, independently, by a Claude architect (probes with the
real hooks and jq) and by Codex (`harness codex-review review`, gpt-6-luna, xhigh; the
73 KB diff travelled on stdin). Both found partial fixes; this round addressed them.

| Finding (reviewer) | Resolution | Status |
|---|---|---|
| S1 deleting a trusted recipe dropped the project to weak mode (Claude) | missing recipe + trust record = `changed`; `harness untrust-verify` added and gated (T37z, T40j, T38o) | resolved |
| S2 the block told the agent to `git checkout --` a recipe it may not have changed (Claude) | wording: restore only if YOU changed it, otherwise stop and tell the operator (T37z) | resolved |
| S3 may-write matched only segment-initial writers (Claude) | see F2 (T36h) | resolved |
| S4 trust-verify after `(cd …)`, `bash -c 'cd …'`, `{ cd …; }` (Claude) | see F3 (T38j) | resolved for literal forms |
| S5 any command mentioning trust-verify asked (Claude) | argument taken only when the command word is `harness` (T38p) | resolved |
| S6 `harness 'off'`, `bash -c '… harness off'`, Write tool to `harness/off` (Claude) | see F15; the installer replaces the old `Bash\|Read` matcher on upgrade: in this round only with the hook flags, since the third round also on a plain `./install.sh` (T38q, T34g, T34h) | mitigated |
| S7 edit, `git commit`, stop was allowed (Claude; pre-existing) | SessionStart records HEAD; files changed by later commits count. Since the third round this applies only when the session itself ran a commit-creating git command (T37za–zc, T37zl) | resolved for sessions started on this version; residue (commits through an alias, script or IDE) documented |
| N-a / Codex #4 watchdog cancelled its own KILL stage | see F13 (T37zh, T37zi) | resolved |
| N-b `ps -ef` columns shift with spaced user names (Claude) | `ps -A -o pid= -o ppid=`, then MSYS `ps -al`, then `ps -ef` (T40k) | resolved |
| N-c non-ASCII names never fingerprinted (Claude) | `core.quotePath=false` (T37zj) | resolved |
| N-d a may-write command alone produced "You changed code" (Claude) | wording: code changed on disk since the session started (T37zg) | resolved |
| N-e / Codex #2 `cd` after `VAR=value`, `{`, `then` … not followed | see F5 (T41m) | resolved for the listed forms |
| N-f / Codex #1 wrapper option operands hid the command | see F11 (T38r) | resolved for the listed wrappers |
| N-g outside git a torn record failed open (Claude) | see F9 (T37ze) | resolved |
| N-h overclaiming docs (Claude) | this table, LIMITATIONS, ROADMAP, REPORT, CHANGELOG corrected | resolved |
| Codex #3 outside git a passing recipe's own writes were certified | see F8 (T37zd) | mitigated |
| Codex #5 live test and bench unbounded without `timeout`/`gtimeout` | see N4 (T47b) | resolved |
| Codex #6 credential files inside a wholly ignored directory | see F6 (T41n) | mitigated |
| Codex #7 a session changing only the trusted recipe passed silently | not blocked, but one visible note per request (T37zf) | resolved |
| Codex #8 `env -i` treated as an environment dump | `env -i` alone allowed; bare `env` still asks (T38r) | resolved |

### Third review of the fixes (2026-11-24)

The second-round fixes were reviewed again by a Claude architect (probes with the real hooks
and jq; findings SF1–SF9, nits N1–N15) and by Codex (`harness codex-review review`,
gpt-6-luna, xhigh; six findings). This round aimed at convergence: the smallest sound change,
and where closing a hole fully would need a shell parser, a minimal mitigation with the
residue in LIMITATIONS.md.

| Finding (reviewer) | Resolution | Status |
|---|---|---|
| SF1 a session on a branch without the trusted recipe blocked on every request (Claude) | SessionStart records whether the recipe existed (`recipe0`); absent then and absent now = `none` (T37zk) | resolved; one hash per project documented |
| SF2 / Codex #2 `timeout`/`nice`/`env -u`/`stdbuf`/`setsid`/`xargs` hid a re-trust | the trust-verify detector uses `h_prefix_skip` like every other check (T38p) | resolved for wrapped forms |
| SF3 `…/harness/OFF` or `…/TRUST` bypassed the check on case-insensitive file systems (Claude) | Write/Edit paths and Bash commands are matched lower-cased (T38q) | resolved |
| SF4 a plain `./install.sh` kept the old `Bash\|Read` matcher; doctor said "registered" (Claude) | a plain install upgrades an existing ops-guard registration; doctor warns about one without Write/Edit (T34h) | resolved (path-form duplicates documented) |
| SF5 someone else's commit, a pull or a branch switch blocked a doc-only session (Claude) | committed files count only after a journaled commit-creating git command (`g`); the block wording counts only code edits (T37za–zc, T37zl) | resolved; alias/script commits documented |
| SF6 writer words and `>` inside quotes armed the gate on read-only sessions (Claude) | quoted text is blanked before matching (`h_unquote`); `bash -c` strings are still checked (T36h) | resolved for the listed forms |
| SF7 `fi`, `done`, `esac`, `}` counted as "ran code" (Claude; pre-existing) | closing and opening words are not evidence (T36j) | resolved |
| SF8 T37zh/T40k depended on fixed sleeps (Claude) | both poll; T37y has a wider margin (`sleep 20` recipe, `< 15 s`) | resolved |
| SF9 docs claimed behaviour the code lacked (Claude) | CHANGELOG, LIMITATIONS, this file, ROADMAP corrected | resolved |
| Codex #1 `CDPATH=/x; cd sub && rm f` checked the wrong directory | a non-empty `CDPATH` anywhere earlier in the command taints every later relative `cd` (T41m) | resolved |
| Codex #3 / N2 `bash --noprofile -c '…'`, `bash -c $'…'` were not inspected | long options and `$'…'` accepted by `h_inline_scripts` (T38s) | resolved for the listed forms |
| Codex #4 outside git, shell-only writes do not arm the gate | not changed: counting every may-write command outside git would block on `cmd > /tmp/log` and shell-written docs | documented |
| Codex #5 a deleted tracked file let pre-deletion evidence pass | a missing changed file counts as changed at the latest edit / may-write record (T37zm) | resolved |
| Codex #6 a successful recipe can leave background processes running | not changed (the tree is gone once the top process is reaped; GNU `timeout` behaves the same) | documented |
| N1 `( env )` dumped the environment | `)` stripped from command words (T38s) | resolved |
| N3 `xargs` was not a wrapper | `xargs` with operand-taking options is a wrapper; `… \| xargs harness` asks (T38s, T36j) | mitigated |
| N4 / N5 unwritable `TMPDIR`; non-numeric timeouts | `mktemp` falls back to `/tmp`, then the harness directory; `HARNESS_VERIFY_TIMEOUT` / `HARNESS_CODEX_TIMEOUT` must be digits, else the default (T37zn) | resolved |
| N7 ops-guard cost ~1 s per Write/Edit on Windows | an edit-tool payload that never mentions `harness` exits before jq | resolved |
| N8 the agent could write the gate's own state | Write/Edit to `…/harness/state/…` asks (T38q); shell writes documented | mitigated |
| N10 `cd "$(git rev-parse --show-toplevel)" && rm -rf build` was blocked | a leading cd to the toplevel resolves to the repository root (T41o) | resolved |
| N6, N9, N11–N15 | small races, path forms, substring false positives, BusyBox `ps`, untrust concurrency | documented |

## What was deliberately not built

See docs/GAP-ANALYSIS.md for the per-capability adopt/adapt/defer/reject table.
