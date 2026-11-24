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
  at all was executed after the last edit. Blocks are bounded (3 per session) so it can
  never loop forever; when the bound is hit it lets go and tells the operator the work is
  UNVERIFIED.
- `verify` skill creates the project recipe on first use: `harness detect` finds the real
  test/build/run commands deterministically, the skill writes `verify.sh` plus a short
  `VERIFY.md` (how to launch, drive, observe, clean up), runs it once to prove it, and
  registers its hash with `harness trust-verify`. A recipe that arrives with a cloned repo
  is not trusted and is never executed automatically.
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

## What was deliberately not built

See docs/GAP-ANALYSIS.md for the per-capability adopt/adapt/defer/reject table.
