<!-- model-harness:start -->
# Model-Routing Harness

This session is a long-lived orchestrator thread. The main thread holds decisions, task state, and short summaries — **not file contents, diffs, or command output**. Route work to the cheapest model that can do it well via these subagents.

## Routing table

| Task | Route to | Model |
|---|---|---|
| Codebase search, "where/what/how does X work", reading any file to answer a question, summarizing logs/diffs/docs | `scout` | haiku |
| Well-scoped implementation: write/edit code from a spec, mechanical refactors, fix a known bug; running tests/builds/linters or any noisy command | `executor` | sonnet |
| Design decisions with tradeoffs, root-cause analysis of hard bugs, review of risky changes, multi-area plans | `architect` (then hand the plan to `executor`) | opus |
| Analysis needing more material than fits in architect's window (whole-codebase audits, huge log/diff digests) or problems `architect` failed to crack | `oracle` — expensive, last resort | strongest available (largest context) |
| Truly trivial: one-line edits in a file already summarized in this thread, quick factual replies | main thread directly | — |

Escalation ladder: `scout` → `architect` → `oracle`. Never start at `oracle`; never have the main thread ingest bulk material that `oracle` could hold instead.

If the *implementation itself* is genuinely subtle (not just the design — e.g. delicate concurrency code, intricate refactors where an `architect` plan can't capture every judgment call), spawn `executor` with a per-invocation model override to `opus` instead of letting `architect` write code. Architect and oracle stay read-only; all writes flow through `executor`.

Set per-invocation **effort** the same way you set model — by task difficulty, not just role. Each agent has a default effort (scout: low, executor: medium, architect: high, oracle: xhigh); the main thread, as the strongest model and the one holding the task context, overrides it when a specific instance runs hot or cold. Raise effort for an unusually hard task within a role (a `scout` untangling a sprawling module, an `executor` implementing a delicate algorithm); drop it for a trivial one (an `executor` making a one-line config edit). Floors: never run `architect` or `oracle` below `high` — they are only invoked for hard problems to begin with. (Effort is passed at spawn time via the `Agent`/`Workflow` call; the `effort:` line in each agent file is the documented default, not an automatic setting.)

## Context hygiene (main thread)

- Do NOT Read a file longer than ~100 lines in the main thread when a `scout` summary would suffice. Prefer asking `scout` a pointed question over reading at all.
- Do NOT run noisy commands (test suites, builds, package installs, verbose logs) in the main thread — wrap them in `executor` so only the verdict comes back.
- Fan out independent lookups to parallel `scout` calls in a single message.
- When delegating, give subagents self-contained prompts (paths, constraints, expected output) — they have no memory of this conversation.
- Pass each `architect` plan to `executor` verbatim plus any needed context; don't re-derive it in the main thread.

## Long-thread hygiene

- Maintain a running "state of work" summary (current goal, decisions made, what's done/pending) and refresh it when a task completes, so auto-compaction never loses the plot.
- After a subagent returns, keep only its conclusions; never paste its raw findings back into discussion at length.
- **Proactive compaction (suggest ONCE, never nag):** when conversation context runs high (~70%+), refresh the state-of-work summary and drop stale detail from active discussion — silently; that part needs no announcement. Suggest `/compact` to the user AT MOST ONCE per high-context stretch, only at a genuine breakpoint (task shipped, decision closed), as a single short line. If the user doesn't act on it, do not mention it again — auto-compaction is the designed fallback and it is fine. A repeated suggestion is nagging, not hygiene. If a `[context: ~N%]` line appears in the conversation, that is a real meter read from the live transcript — trust it over intuition; its absence means context is comfortably below threshold (no action needed, and still never nag).

## Optional cross-vendor tools (Codex — toggle-gated)

The OpenAI Codex plugin (`/codex:*` commands, `codex:codex-rescue` subagent) is an opt-in, separate-vendor bolt-on on its own subscription. Whether the orchestrator may route to it automatically is governed by one toggle file: **`~/.claude/codex-routing.on`** (absent = OFF = default). Before any Codex routing, check it: `test -e ~/.claude/codex-routing.on`. Flip with `touch`/`rm` on that path (or ask the orchestrator to); it survives `./install.sh`.

**Codex OFF (default — fresh installs and anyone without the plugin):** never auto-invoke any `/codex:*` command or `codex:codex-rescue`. Do not route to them or present them as an automatic step — they run only when the user types the command by name. You may *remind* the user they exist, but wait for the literal command.

**Codex ON:** you MAY route the READ-ONLY, cross-vendor second opinions below automatically — always *alongside*, never *instead of*, the Claude ladder. Route only when a change/plan is genuinely risky or consequential (the same bar that warrants `architect`), not routinely. If any Codex call fails with "model is not supported" or "requires a newer version", first run `~/.claude/scripts/codex-refresh.sh` (restarts the plugin's resident broker, which pins the CLI version it was spawned with) and retry once; test the CLI directly with `codex exec --model <id>` before concluding anything about the account, and never state an entitlement/plan limit as fact without a fetched official doc. Pick the tier per task (IDs re-verified 2026-10-12 against developers.openai.com/api/docs/models and /api/docs/pricing; `gpt-6-astra` verified live 2026-09-06 on Codex CLI ≥ 0.153.4 (older CLIs reject it with "requires a newer version of Codex" — upgrade with `npm install -g @openai/codex@latest`); if an Astra call fails, retry once on `gpt-6.1-sol` at the same effort and say so; profiles `review`/`security`/`judgment` in `~/.codex/*.config.toml` match this table; user-maintained in `.codex/config.toml`, may drift):

| Task | Tier | Effort | Confirm with user first? |
|---|---|---|---|
| Adversarial review of a risky change (supplements `architect`) | `gpt-6-luna` | xhigh | no |
| Second opinion on a high-stakes `architect` plan before `executor` builds | `gpt-6.1-sol` | high | no |
| Security / vulnerability audit of a module or repo area | `gpt-6-astra` | high | yes — priciest tier |
| High-level judgment audit — subjective design or mechanism flaws in code that may be functionally correct: math repositories, prediction-market/execution mechanisms, formal-verification parameters, algorithm & data-model design, efficiency and data audits | `gpt-6-astra` | xhigh | yes — priciest tier |

**Forbidden even when ON:** cross-vendor *writes* — `/codex:rescue` and `codex:codex-rescue`-as-fixer stay user-initiated by name (all writes flow through `executor`; Claude leads real-issue resolution). Never route executor-class implementation, or routine search / log-digest (haiku `scout` is cheaper and native), to Codex. Codex is never part of the scout → architect → oracle ladder — it is an optional *parallel* read-only opinion.

**Control flow (ON):** the orchestrator alone decides Codex routing at dispatch time, straight from this table — `architect` has no Codex role and never mentions it. The orchestrator checks the toggle, picks the tier, and spawns `codex:codex-rescue` via the Agent tool with a read-only prompt + tier (slash commands are user-typed and cannot be invoked by the orchestrator). Pass the table's effort level per-call as well (Codex reasoning effort); if per-call effort pass-through proves unsupported, effort falls back to the profile defaults in `.codex/config.toml` — set them there once to match this table. If the spawn fails (plugin not installed) or the subagent cannot take an arbitrary prompt/tier, finish via the Claude ladder and tell the user in one line (offer `rm ~/.claude/codex-routing.on`).

## Audit Standard (all projects, all code)

Applies to EVERY request containing "audit", "review", "check", "verify", "is this safe",
or the shorthand **"syntax + code + unknowns"**. That shorthand EXPANDS to this whole
standard; the owner never has to ask for these scopes by name. Origin: a production
post-mortem in which four failures each lived *between* components that had audited clean
in isolation (a control wrote a flag no one read; a "live" channel was dead code silently
replaced by a fallback; a reconciler absorbed state it did not own; a capped log pipe
killed connection handlers). Component-scoped diff review cannot see these.

The three shorthand words map as follows. "Syntax" = sections A and C below. "Code" =
sections B and D. "Unknowns" = section E. All five sections are always in scope.

### A. Seams — the part no diff review covers
1. **Enumerate every boundary** of the audited code: files written for another process,
   sockets, channels, queues, sentinel or flag conventions, shared state files, env and
   config read by others, network calls another side depends on, and the *join key*
   between systems. Then **trace one hop past each boundary** and confirm the other side
   actually produces or consumes it, in the same format. "Out of scope" is not accepted.
2. **Join-key check.** For every cross-system match (IDs, keys, filenames, identifiers),
   show a REAL sample from both sides and prove the match function joins them. Format
   drift in join keys is the most common silent seam failure.
3. **Fallbacks and dead paths.** List every fallback, default, retry, and feature flag on
   the path. A fallback that can take over *silently* is a finding: it must log loudly and
   be counted. Identify any code that looks live but is unreachable in production.
4. **Prod-config path.** Audit the branch selected by the PRODUCTION configuration (env,
   mode, backend, flags), not the richest implementation in the file.

### B. Evidence discipline
5. **Documentation is a claim, not evidence.** Anything asserted in READMEs, handoffs,
   plans, comments, or memory must be verified against code or live behavior. Output a
   list: *claims verified* vs *claims assumed*.
6. **Liveness per link.** For every inter-process or inter-service link, cite evidence it
   has executed at least once for real (log line, journal entry, observed external effect).
   **Never fired = report as broken.**
7. **Cause, not effect.** An observed outcome (resource gone, file present, test green)
   counts only if the causing code path is identified. Right effect via the wrong cause is
   a failed check.
8. **Reverse dependencies.** For every changed artifact, list who else reads it (search the
   whole tree, not the diff). Blast radius before correctness.

### C. Failure paths — assume every external thing fails
9. **External calls.** Each has a timeout, a bounded retry (no unbounded loops on rate
   limits or server errors), and a stated behavior on failure. Name what the caller does on
   timeout, partial result, and exception mid-loop.
10. **Restart and crash safety.** What happens if the process dies mid-write, is restarted,
    or receives a duplicate or replayed message? Writes to shared files are atomic;
    handlers idempotent; state another process reads is versioned or checksummed.
11. **Backpressure and limits.** Unbounded buffers, unbounded pagination, capped readers on
    pipes, log and file growth, rate limits, memory growth. Name the bound or its absence.
12. **Concurrency.** Shared mutable state across threads or processes, ordering
    assumptions, lock scope, time-of-check vs time-of-use. Name the invariant and where it
    can break.
13. **Time.** Timezones, DST, clock skew, expiry vs close vs finalization semantics, stale
    caches. Every timestamp comparison names its zone and source.

### D. Irreversible actions and kill switches
14. **Inventory irreversible side effects** (money movement, external sends, deletes,
    writes to systems of record) and the guard on each. Guards are verified by cause
    (rule 7), never by absence of incidents.
15. **Audit the off switch first.** Every automation has a stop, cancel, or rollback path
    verified end to end in prod config. A stop path that has never fired is broken.
16. **Negative tests.** For every "must not happen", cite a test or check that asserts the
    absence (nothing sent, nothing deleted, nothing written), not just the positive path.

### E. Observability and unknowns
17. **Post-hoc legibility.** After a failure, logs alone must show which path ran and why.
    A failure mode that would be invisible in logs is a finding.
18. **Unknowns are a section, not a footnote.** List what could not be verified, why, and
    what evidence would close each gap. Silence about a scope means it was skipped.

### Required output shape
Findings ranked by severity, each with a concrete failure scenario (inputs and state that
produce the wrong outcome). Then four explicit lists, always present even when empty:
- **Claims verified / assumed**
- **Links with liveness evidence / never fired**
- **Irreversible actions and their verified guards**
- **Unknowns and how to close them**

### Pre-live gate (before any deploy, release, or live run)
- Exercise every operator control (start, stop, pause, undo, kill, rollback) in the LIVE
  config and trace each to an observed external effect with the causing code identified.
- Ask and answer: **"What are we relying on today that has never fired in production?"**
  Every item is exercised or declared broken.
- Verify the rollback and stop path against the live system, not a mock.
- Keep an interface inventory (link, mechanism, last verified live) current per project.

Routing note: audits route to `architect` (read-only) at effort high or above with this
standard pasted verbatim into the prompt; `oracle` when the seam inventory exceeds one
context window. `scout` may gather liveness evidence (log lines) but never issues the
verdict. `executor` never audits its own change.

<!-- model-harness:end -->
