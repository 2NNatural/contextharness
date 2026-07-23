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

**Codex ON:** you MAY route the READ-ONLY, cross-vendor second opinions below automatically — always *alongside*, never *instead of*, the Claude ladder. Route only when a change/plan is genuinely risky or consequential (the same bar that warrants `architect`), not routinely. Pick the GPT-5.6 tier per task (IDs current 2026-07-09; user-maintained in `.codex/config.toml`, may drift):

| Task | Tier | Effort | Confirm with user first? |
|---|---|---|---|
| Adversarial review of a risky change (supplements `architect`) | `gpt-5.6-terra` | medium | no |
| Second opinion on a high-stakes `architect` plan before `executor` builds | `gpt-5.6-terra` | medium | no |
| Security / vulnerability audit of a module or repo area | `gpt-5.6-sol` | high | yes — priciest tier |
| High-level judgment audit — subjective design or mechanism flaws in code that may be functionally correct: math repositories, prediction-market/execution mechanisms, formal-verification parameters, algorithm & data-model design, efficiency and data audits | `gpt-5.6-sol` | xhigh | yes — priciest tier |

**Forbidden even when ON:** cross-vendor *writes* — `/codex:rescue` and `codex:codex-rescue`-as-fixer stay user-initiated by name (all writes flow through `executor`; Claude leads real-issue resolution). Never route executor-class implementation, or routine search / log-digest (haiku `scout` is cheaper and native), to Codex. Codex is never part of the scout → architect → oracle ladder — it is an optional *parallel* read-only opinion.

**Control flow (ON):** the orchestrator alone decides Codex routing at dispatch time, straight from this table — `architect` has no Codex role and never mentions it. The orchestrator checks the toggle, picks the tier, and spawns `codex:codex-rescue` via the Agent tool with a read-only prompt + tier (slash commands are user-typed and cannot be invoked by the orchestrator). Pass the table's effort level per-call as well (Codex reasoning effort); if per-call effort pass-through proves unsupported, effort falls back to the profile defaults in `.codex/config.toml` — set them there once to match this table. If the spawn fails (plugin not installed) or the subagent cannot take an arbitrary prompt/tier, finish via the Claude ladder and tell the user in one line (offer `rm ~/.claude/codex-routing.on`).
<!-- model-harness:end -->
