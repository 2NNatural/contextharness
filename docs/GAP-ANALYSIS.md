# Gap analysis and capability decisions

What was studied, what ContextHarness v1 actually did, and for every capability whether it
was **implemented**, **adapted**, **deferred** or **rejected** in v2 — with the reason.

## Sources

| Source | Read how | Notes |
|---|---|---|
| ContextHarness v1 (this repo at `34eb046`) | every file, test suite run (63/63) | The harness was **not installed** in the environment this work ran in (a fresh cloud container with no `~/.claude` harness files and no Codex CLI). "Installed environment" findings below come from installing v1 into sandboxes, not from the operator's own machine. |
| pstack (`cursor/plugins`, v0.15.48, commit `005d8f6`) | cloned and read: all skills, playbooks, agents, scripts, harness adapter | No code from it was executed. |
| "How to be like @poteto" (thoughtfulbits.ai) | full page | A third-party digest of her posts, talks and the plugin. |
| xAI "Grok Bot for Engineering" and "Grok Bot 101" | full pages | Vendor guides. |
| Claude Code docs (hooks, skills, subagents, memory, headless, worktrees, permissions) | official docs, plus hook payloads captured live on Claude Code 2.1.331 | Payload fields used by the hooks were observed, not assumed. |
| Codex CLI | `openai/codex` source on GitHub (exec flags, config schema, hooks) and the `codex-plugin-cc` README | The official OpenAI docs site was not reachable from the build environment; Codex was **not installed or authenticated** there, so nothing Codex-related was exercised live. Later (2026-11-23) the `review` and `plan` tiers ran live on Windows with codex-cli 0.162.1; see ARCHITECTURE.md › Codex cross-vendor review. |
| Anthropic engineering posts (context engineering, multi-agent research system, harness design for long-running apps, agent evals) | full pages | |
| Research papers (AGENTS.md effectiveness, MAST multi-agent failure taxonomy, cross-model review) | search summaries only | arXiv was not reachable; treated as weak evidence and labelled so. |

## What v1 claimed vs. what it demonstrably did

| v1 claim | Reality |
|---|---|
| Cost-optimised routing via four pinned subagents | **True and worth keeping.** Agent files and routing table are coherent. |
| "Audit Standard applies to every project" | True as text. It was ~6 KB loaded into **every** session of every project whether or not an audit was happening. |
| Codex cross-vendor review, toggle-gated | The toggle is real. The invocation path was explicitly "shipped unverified" (spawning a plugin subagent that may not accept an arbitrary prompt or model). The audit skill named `gpt-5.6-sol/terra` while the routing rules named `gpt-6-astra/luna/sol` — two sources of truth, already drifted. |
| Destructive guard | Works as tested, but opt-in, "blocking unverified live", and at its default scope it blocked **every** in-project `rm`/`mv` — including deleting build output — which pushes operators toward switching it off. |
| Context meter | Works; opt-in. |
| Tier auto-detection | Works, but the probe ID, the post-install message and the oracle pin were three separate hardcoded strings; two were stale. |
| "Executor verifies its own work" / "never claim success that didn't happen" | Prose only. Nothing checked it. |
| Session memory (CONTEXT/PROGRESS/ROADMAP) | A manual convention for this one repo ("upload this to start a session"). Nothing for other projects, nothing automatic. |
| Self-improvement | None. |
| Planning, acceptance criteria, rigor levels, recovery, loop detection, deployment safeguards, benchmarking | Absent. |

The pattern: v1's routing was real; nearly everything about correctness was a request to the model.

## Capability decisions

### Planning and task interpretation
| Capability | Decision | Why |
|---|---|---|
| Sharpen an ambiguous request without interrogating the operator | **Adapted** from pstack `sharpen` + "restate in your own words" → `plan` skill | pstack's four questions are good; its "never block on the human" is too loose for a nontechnical operator, so `plan` allows one batched question, only when answers lead to different builds. |
| Acceptance criteria before building | **Implemented** (`plan`, core rule) | Needed by everything downstream; a criterion must be checkable by a command or observation. |
| Inspect architecture before proposing | **Implemented** (`plan` step 2 via `scout`) | |
| Workflow by complexity; no overhead for small tasks | **Implemented** — three rigor modes in the core block | Light mode is deliberately "do it, check it, report". |
| pstack's 22 playbooks and 24 principle skills | **Rejected** | ~44k tokens of prose, mostly conventional maxims and personal taste; the research on instruction files says large generated/accumulated instruction sets raise cost without raising success. |
| Architecture "arena" (N competing designs, cross-judged) | **Deferred**, one paragraph in `parallel` | Expensive; pstack's own guide warns about cost. Worth it only for contested designs, and the cross-vendor judge needs Codex. |

### Model routing
| Capability | Decision | Why |
|---|---|---|
| v1 routing table, effort defaults, escalation ladder | **Preserved** | Demonstrated strength. |
| Escalate on observed failure | **Implemented** — "fails the same task twice → escalate the model once" (core) plus loop detector | |
| Cross-vendor review Claude ↔ Codex | **Preserved and hardened** — `harness codex-review` wraps `codex exec` in a read-only sandbox with tier/effort from one config file, confirm gate for the priciest tier, one fallback | Replaces an unverified path with a tested one (stub-tested; on Windows, codex-cli 0.162.1, `review`/`plan` ran live on 2026-11-23 and `security --yes`/`judgment --yes` plus the fallback retry on 2026-11-24; review quality not measured). |
| Avoid redundant review | **Implemented** — no reviewer in Light mode; cross-vendor only for genuinely risky work | One preliminary study found Codex reviewing Claude's drafts made results *worse*; a second model is not automatically a gain, so findings must reproduce before they count. |
| Routing adjusted from measured performance | **Adapted** — `harness stats` reports real per-model token use from transcripts; `routing-refresh` may cite it | Fully automatic re-routing was **rejected**: it is uncontrolled self-modification on thin data. |

### Context engineering
| Capability | Decision | Why |
|---|---|---|
| Minimise always-on context | **Implemented** — core block 14.4 KB → 7.4 KB, guarded by a size-budget test | Audit Standard and Codex detail moved to on-demand skills. |
| Selective retrieval | **Preserved** (`scout`) | |
| Durable decisions, state across interruptions | **Implemented** — `.claude/harness/STATE.md` + `session-state` hook | Restores on resume/compaction; one-line pointer on a fresh start. Writing STATE.md is still a prose rule; the hook guarantees the deterministic part (files touched, last verification result, checkpoint). |
| No cross-project pollution | **Implemented** — state is per project and per session | |
| Detect stale/contradictory docs | **Adapted** — consistency tests (no Codex IDs outside one file, no hardcoded model ID in the installer, every skill/agent named in the core exists) | General doc-staleness detection across arbitrary projects was **deferred**: no reliable deterministic signal. |
| Auto-generate a project instruction file | **Rejected** | Evidence (weak, but directionally consistent with Anthropic's guidance) that generated instruction files cost more and help less. `harness detect` computes facts on demand instead. |

### Multi-agent orchestration
| Capability | Decision | Why |
|---|---|---|
| Worktree-isolated parallel work with ownership and integration | **Adapted** from pstack `swarm` → `parallel` skill, using Claude Code's native `isolation: worktree` | Guidance plus a strict "should this be parallel at all?" gate. No custom orchestration engine. |
| Supervise for stalls and loops | **Implemented** in part — loop detector hook; "judge by side effects" in `parallel` | A long-running supervisor daemon was **rejected** (see Grok Bot). |
| Avoid multi-agent overhead | **Implemented** as an explicit core rule | Anthropic reports ~15x token use for multi-agent work and a poor fit for coupled coding tasks. |
| Agent swarms that "fuzz" every PR | **Rejected** as a default | Cost scales with nothing in particular; `verifier` gives one independent adversarial pass where risk justifies it. |

### Verification-first engineering
| Capability | Decision | Why |
|---|---|---|
| Work must be demonstrated, not claimed | **Implemented deterministically** — `journal` + `stop-gate` hooks | The central upgrade. pstack and v1 both leave this to the model. |
| Project-specific verification skill, discovered or generated | **Adapted** from pstack `create-verification-skill` → `verify` skill + `harness detect` + trusted `verify.sh` / `VERIFY.md` | Kept: interview the repo not the user, run it once to prove it, prove it can fail. Changed: the fast part is an executable the gate runs, and it must be *trusted* (hash registered outside the project) so a cloned or weakened recipe is never honoured. |
| Verification matched to project type (web, API, money, data, scripts, backend, UI) | **Implemented** as a table in `verify` | Browser checks use Playwright when present; not bundled. |
| Property-based / invariant testing where justified | **Implemented** as a High-assurance requirement | |
| Formal verification (TLA+ etc.) | **Deferred** | pstack ships a TLA+ pipeline; valuable for a narrow class of systems, heavy for a general default. |
| Scheduled daily maintenance of the verify skill | **Deferred** | Needs a scheduler; the recipe is exercised on every gated stop anyway. |

### Adversarial review
| Capability | Decision | Why |
|---|---|---|
| Independent Claude + Codex review | **Preserved** | |
| Implementation separated from verification | **Implemented** — `verifier` agent (cannot edit), "the judge is not the author" rule | |
| Findings must be substantiated | **Adopted** from pstack `interrogate` — reproduce or it is "unconfirmed" | Removes the main cost of LLM review: plausible noise. |
| Disagreements resolved by evidence | **Implemented** (`review` step 3) | |
| Audit Standard (seams, liveness, failure paths) | **Preserved verbatim**, now on demand | |
| Verdicts bound to `git patch-id` | **Deferred** | Elegant, but only matters once agents merge their own PRs. |

### Self-improvement
| Capability | Decision | Why |
|---|---|---|
| Mistake → root cause → class? → strongest prevention → prove it → record at scope | **Adapted** from pstack `correct` and Poteto's correction ladder → `learn` skill + `harness lessons` ledger | The ledger gives "seen twice" a real counter. |
| Don't accumulate instructions | **Implemented** — project lessons capped at 30 lines, deleted once enforced by code; core block has a size budget test | |
| Controlled global changes | **Implemented** — `learn` may not touch hooks, trust or global rules; harness changes ship only as a tested branch the operator approves; installs are versioned with `--rollback` | |
| Mining weeks of transcripts for habits (`automate-me`, `reflect`) | **Deferred** | Useful, but expensive and it writes instructions — the mechanism this harness is trying to depend on less. |
| Blinded A/B eval of skill changes | **Adapted** — `bench/` compares whole harness versions on hidden checks | Per-skill blinded evals deferred. |

### Autonomy and recovery
| Capability | Decision | Why |
|---|---|---|
| Continue until criteria met; don't stop early | **Implemented** — core rule + stop-gate (which blocks an early "done") | |
| Change strategy after repeated failure | **Implemented** — loop detector | |
| Checkpoints and safe resumption | **Implemented** — git checkpoint ref at session start (`harness undo`), STATE.md restore | |
| Bounded retry / runtime / spend | **Implemented** in part — gate blocks are bounded per request, recipe has a timeout; the benchmark runner uses `--max-budget-usd` | A global spend cap for interactive sessions is Claude Code's job, not a hook's. |
| Escalate only material decisions | **Implemented** — explicit "ask only for" list | |
| Overnight autonomous loops (`autonomous-run`, `/loop`) | **Deferred** | Works today via Claude Code's own `/loop`; the harness adds no machinery until the verification gate has earned trust. |

### Security
| Capability | Decision | Why |
|---|---|---|
| Least privilege | **Preserved** (read-only agents) with an honest caveat: agents with a shell can still write | Documented in LIMITATIONS. |
| Protect credentials | **Implemented** — `ops-guard` asks before reading credential files or dumping the environment | |
| Untrusted instructions | **Implemented** — core rule; benchmark includes a planted-instruction trap | |
| Destructive actions | **Preserved and refined** — guard now blocks only what git cannot restore | |
| No unauthorised deploys / infra changes | **Implemented** — `ops-guard` | Tripwire, not a sandbox. |
| Review plugins/skills before install | **Implemented** as a core rule only | No deterministic check. |
| Auditability and rollback | **Implemented** — journal per session, versioned installs, `--rollback`, `--uninstall` | |

### External systems
| System | Decision | Why |
|---|---|---|
| Install pstack | **Rejected** | It would add a second, competing orchestration policy (its own router, model rules and worker contract) and 177 KB of skills written for Cursor. Its best ideas were ported individually. |
| Grok Bot as orchestrator | **Rejected as a dependency; nothing lost by omitting it** | It is a hosted, always-on manager layer (bots that supervise cloud agents, review a Notion board every 30 minutes, run nightly audits) tied to xAI and Cursor accounts and plans. Its transferable idea — close the feedback loop so agents can verify their own work, and run postmortems that update the playbook — is what `stop-gate`, `verify` and `learn` do locally. ContextHarness stays fully functional without it; an operator who wants chat-driven always-on bots can put one on top later. |
| Codex hooks / Codex-side enforcement | **Deferred** | Codex now has a Claude-style hook system; porting the gate there is feasible but could not be tested here. v2 ships a portable *prose* core for `AGENTS.md` (`--with-codex-agents`). |
