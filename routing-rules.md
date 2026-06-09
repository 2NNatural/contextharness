<!-- model-harness:start -->
# Model-Routing Harness

This session is a long-lived orchestrator thread. The main thread holds decisions, task state, and short summaries — **not file contents, diffs, or command output**. Route work to the cheapest model that can do it well via these subagents.

## Routing table

| Task | Route to | Model |
|---|---|---|
| Codebase search, "where/what/how does X work", reading any file to answer a question, summarizing logs/diffs/docs | `scout` | haiku |
| Well-scoped implementation: write/edit code from a spec, mechanical refactors, fix a known bug; running tests/builds/linters or any noisy command | `executor` | sonnet |
| Design decisions with tradeoffs, root-cause analysis of hard bugs, review of risky changes, multi-area plans | `architect` (then hand the plan to `executor`) | opus |
| Analysis needing >200k tokens of material at once (whole-codebase audits, huge log/diff digests) or problems `architect` failed to crack | `oracle` — expensive, last resort | fable (1M) |
| Truly trivial: one-line edits in a file already summarized in this thread, quick factual replies | main thread directly | — |

Escalation ladder: `scout` → `architect` → `oracle`. Never start at `oracle`; never have the main thread ingest bulk material that `oracle` could hold instead.

If the *implementation itself* is genuinely subtle (not just the design — e.g. delicate concurrency code, intricate refactors where an `architect` plan can't capture every judgment call), spawn `executor` with a per-invocation model override to `opus` instead of letting `architect` write code. Architect and oracle stay read-only; all writes flow through `executor`.

## Context hygiene (main thread)

- Do NOT Read a file longer than ~100 lines in the main thread when a `scout` summary would suffice. Prefer asking `scout` a pointed question over reading at all.
- Do NOT run noisy commands (test suites, builds, package installs, verbose logs) in the main thread — wrap them in `executor` so only the verdict comes back.
- Fan out independent lookups to parallel `scout` calls in a single message.
- When delegating, give subagents self-contained prompts (paths, constraints, expected output) — they have no memory of this conversation.
- Pass each `architect` plan to `executor` verbatim plus any needed context; don't re-derive it in the main thread.

## Long-thread hygiene

- Maintain a running "state of work" summary (current goal, decisions made, what's done/pending) and refresh it when a task completes, so auto-compaction never loses the plot.
- After a subagent returns, keep only its conclusions; never paste its raw findings back into discussion at length.
<!-- model-harness:end -->
