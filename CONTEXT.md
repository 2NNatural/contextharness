# CONTEXT.md — Project Brain / Session Memory

> **Purpose of this file:** the single upload-this-next-time memory for the model-routing harness project. Read it cold and you know everything: how I want you to behave, what this project is, the stack, every key decision and why, and the current state of the world. Companion files: [PROGRESS.md](PROGRESS.md) (changelog + status), [ROADMAP.md](ROADMAP.md) (the one prioritized what's-next), [README.md](README.md) (public front door).

---

## 1. My exact instructions to you (VERBATIM — do not paraphrase)

These are my standing rules. They override your defaults at all times.

### Context rules
> — My behavioral rules from CONTEXT.md override your defaults at all times
> — If I correct you during this session, apply that correction immediately and for the rest of the session
> — If something contradicts CONTEXT.md, ask me before proceeding

### Code rules
> — Never make changes outside the scope of the current task without asking first
> — If you notice an unrelated bug while working, flag it — don't fix it silently
> — Always tell me which files you're about to modify before you modify them

### Communication rules
> — Check in after each logical chunk of work — don't auto-continue
> — If you're uncertain about intent, ask one focused question rather than guessing
> — Keep responses tight — I'm here to build, not read essays

### Work cadence
> After completing each logical chunk of work, pause and ask if I want to continue to the next step or change direction. Do not barrel through the entire task without check-ins.

### Session start protocol (what I expect at the top of a session)
> Do not write any code yet. Do not make any file changes yet. Your first job is to read and internalize everything below.

Read in this order: `CONTEXT.md`, `PROGRESS.md`, `ROADMAP.md`, `README.md`. Re-read my behavioral rules. Run an environment sanity check (`git status`, `git log --oneline -5`, dependency/install state) and report it short — one line per check, flag anything off with ⚠️. Then reply with the structured confirmation block (FILES READ / BEHAVIOR RULES ACTIVE / STACK / LAST SESSION / ENVIRONMENT / FLAGS / NEXT ON ROADMAP) and **wait for my go-ahead** before starting any task.

### End of session
> When I say "wrap up" or "end session":
> → Stop any active work immediately
> → Remind me to run the Session Wrap-Up prompt
> → List anything we completed this session so I don't forget to log it

### Notes on applying these rules
- If I leave `[TASK]` blank, confirm the `[NEXT]` item from ROADMAP.md, break it into steps, and wait for approval before writing code.
- If I fill in `[TASK]`, acknowledge it, check it against ROADMAP/PROGRESS for conflicts, break it into steps, wait for approval.

---

## 2. Project goals & context (in my words)

Core requests that started and steered this project, verbatim:

> sonnet 5 is now out … our harness should be constantly updating based on information and benchmarks to use the most optimal models. Is this built in? how do I do this? Also, it should detect the top level model it's currently on without user switching/input; whether that's fable or opus

Clarification on what "constantly updating" should mean:

> it should basically do research whenever I ask it for a policy refresh, and update what gets routed to who

Distilled goals:
- **G1 — On-demand routing refresh.** When I ask, the harness researches the *current* Claude model landscape from live sources and updates which model each role/task routes to. Not a background daemon — I trigger it.
- **G2 — Auto-detect the top tier.** The harness should detect the strongest model available to my account (fable vs opus) **without user switching/input**.
- **G3 — Ride model updates automatically** where possible (new versions within a tier) so I don't hand-maintain them.

### What the project IS (orientation)
A **model-routing harness for Claude Code**: one long-lived orchestrator thread (the main thread, strongest model) that holds decisions + short summaries and routes token-heavy work to subagents pinned to cheaper models, each with a disposable context window. Goal: never switch models manually, pay the cheapest rate per kind of work. Repo: `~/harness` → https://github.com/2NNatural/contextharness. Installs user-level via `./install.sh` into `~/.claude/`.

---

## 3. Technical stack & tooling

- **Bash** — `install.sh` (idempotent user-level installer) and `tests/run-tests.sh` (sandboxed regression suite, runs in throwaway `mktemp` HOMEs).
- **Markdown** — agent definitions (`agents/*.md` with YAML frontmatter), `routing-rules.md`, and Claude Code skills (`skills/*/SKILL.md`).
- **Claude Code subagents** — `scout`, `executor`, `architect`, `oracle` (see role table below).
- **Claude Code Skills** — `skills/routing-refresh/SKILL.md`.
- **git / GitHub `gh`** — repo `2NNatural/contextharness`, default branch `main`.
- **`claude` CLI** — used by the installer's tier probe: `claude -p --model claude-fable-5 --max-turns 1 'hi'` (reuses Claude Code OAuth/keychain auth; no API key needed).
- **`curl` + `jq`** — fallback probe path only when `ANTHROPIC_API_KEY` is set.
- **WebSearch / WebFetch** — live model research inside the routing-refresh skill.

### Models in play (confirmed live 2026-06-30 from official docs)
| Tier | Model | Exact API ID | Context | Price in/out |
|---|---|---|---|---|
| top (widely released) | Claude Fable 5 | `claude-fable-5` | 1M | $10 / $50 |
| top (Glasswing-only) | Claude Mythos 5 | `claude-mythos-5` | 1M | limited access |
| opus | Claude Opus 4.8 | `claude-opus-4-8` | 1M | $5 / $25 |
| sonnet | Claude Sonnet 5 | `claude-sonnet-5` | 1M | $3 / $15 (intro $2/$10 → Aug 31 2026) |
| haiku | Claude Haiku 4.5 | `claude-haiku-4-5` | 200k | $1 / $5 |

Sources: [models overview](https://platform.claude.com/docs/en/about-claude/models/overview), [pricing](https://platform.claude.com/docs/en/about-claude/pricing), [Sonnet 5 announcement](https://www.anthropic.com/news/claude-sonnet-5).

---

## 4. Harness architecture (canonical summary — full policy lives in `routing-rules.md`)

Roles, the model each is pinned to, and its **default** effort:

| Role | Model pin | Type | Default effort | Edits files? |
|---|---|---|---|---|
| `scout` | `haiku` | bare alias (auto-updates) | low | read-only |
| `executor` | `sonnet` | bare alias (auto-updates) | medium | writes (all writes flow here) |
| `architect` | `opus` | bare alias (auto-updates) | high | read-only (produces plans) |
| `oracle` | `claude-fable-5[1m]` | pinned ID | xhigh | read-only |
| orchestrator (main thread) | strongest available | — | see §5 | holds decisions/summaries |

- **Escalation ladder:** `scout` → `architect` → `oracle`. Never start at `oracle`.
- **Bare aliases auto-update:** `haiku`/`sonnet`/`opus` resolve to the current model in that tier via Claude Code — e.g. Sonnet 5 flowed into `executor` with no edit.
- **Only `oracle` carries a pinned full model ID** (because `[1m]` context isn't expressible as a bare alias). The installer patches it per-machine based on the detected tier.

---

## 5. Key decisions & reasoning (this session, 2026-06-30)

1. **On-demand refresh, NOT a daemon.** There is no machine-readable benchmark feed to route on. "Constantly auto-update from benchmarks" isn't buildable as stated. The realistic mechanism = ride aliases (free/automatic) + an on-demand research-driven refresh I trigger.

2. **Refresh = `routing-refresh` skill, diff-then-confirm, safe scope.**
   - **Diff-then-confirm always.** Rationale: *"research can surface a wrong model ID, and silent rewrites of your routing are risky."* I chose this explicitly ("diff then confirm").
   - **Safe scope.** I said *"Use the safe scope."* A refresh may edit ONLY: `routing-rules.md` (the table), `agents/oracle.md` (the pinned ID), `README.md` (sync). It must NOT touch the `scout`/`executor`/`architect` aliases (they auto-update) or create new agent files.
   - **Abort on inconclusive research** with zero edits.
   - **Never invent model IDs** — live sources only, fetched this session.

3. **Tier auto-detection — ALWAYS auto-probe.** I chose "Always auto-probe" over the architect's interactive-prompt-first split. The installer probes on every run when no `--top-model` flag is given; it only prompts (TTY) or defaults to fable (non-TTY) if the probe is *inconclusive*. Probe drives the `claude` CLI (reuses Claude Code auth, works for subscription users with no API key) — not raw curl. `--top-model` still overrides everything.

4. **Effort = hybrid (per-role default + dynamic override), NOT pure-static and NOT pure-dynamic.** I pushed on this: *"Are we sure set effort is the best way to do it, rather than the highest model assigning an effort level depending how hard the task is?"* Resolution:
   - Per-role **default** effort pinned in frontmatter (documented baseline).
   - The **orchestrator** (strongest model, holds task context) **overrides per-invocation by task difficulty** — raise for an unusually hard instance, drop for a trivial one.
   - **Floors:** never run `architect` or `oracle` below `high`.
   - This **mirrors the existing `executor`→`opus` model-override pattern** (commit `d86a3c2`).
   - Mechanical fact: Claude Code does **not** auto-consume `effort:` from agent frontmatter; effort only takes effect when passed at spawn time. The frontmatter line is documentation/default; dynamic assignment is what actually functions. I chose to add the override rule ("yes do A").

5. **Orchestrator config: highest model, NOT highest effort.** Best model at the coordination layer is cheap (sees only distillate, prompt-cached) and high-leverage. Highest *effort* belongs in the disposable reasoning subagents (`architect` high, `oracle` xhigh), not smeared across every orchestrator turn. Recommended: main thread on **`opus`**, **medium** effort (bump to high for a heavy planning turn). Note: Opus 4.8 / Sonnet 5 **default to `high` effort on Claude Code**, so "medium" requires setting `effort` explicitly.

6. **Oracle repo pin stays `claude-fable-5[1m]` (I said "leave repo as is").** It still names the current top model; the installer auto-detects and substitutes `opus` per-machine; if fable access returns, a plain `./install.sh` re-detects it with zero manual fix. Baking `opus` into the repo would freeze a temporary condition into the source of truth.

7. **Push policy.** I authorized pushing to `main` this session ("you can push to main, then run install"). The auto-mode guard treated the first authorization as per-instance; I re-authorized explicitly. Default going forward: commit/push only when I ask.

---

## 6. Corrections & behavior updates (this session)

- **Don't fabricate against a template.** The Session-Start template referenced `CONTEXT.md`/`PROGRESS.md`/`ROADMAP.md`, which did **not** exist in the repo at the time. Correct behavior was to flag that and not invent the structured report against missing files. (Those files now exist — created this session.)
- **Pure-static effort was the wrong first instinct.** I corrected it toward the hybrid (per-role default + orchestrator dynamic override). Apply the hybrid going forward.
- **"Always auto-probe"** overrode the architect's "prompt interactively, probe only non-interactively" design. Detection must require no user input.
- **Don't gut the public README.** README is a product front door for cloners; keep it functional, don't strip it to links-only. (This was my call during wrap-up, recorded so it stays.)

---

## 7. Important facts / environment

- **Fable 5 is currently blocked for *everyone*** as of 2026-06-30 — due to government action involving Anthropic, **not** an account-specific entitlement issue. The probe returns `"Claude Fable 5 is currently unavailable"`. So **`opus` is the effective top tier for all harness users** until the block lifts. The installer correctly auto-detected `opus` and pinned `~/.claude/agents/oracle.md` to `model: opus`. The repo intentionally keeps the canonical pin as `claude-fable-5[1m]` so that if/when the block lifts, a plain `./install.sh` re-detects fable with no manual change.
- **Sonnet 5 (`claude-sonnet-5`)** is out and already flows into `executor` automatically via the bare `sonnet` alias — no edit needed.
- **Opus 4.8 and Sonnet 5 default `effort` to `high` on Claude Code** — explicit setting required for anything else.
- **Repo state:** `main`, clean working tree, in sync with origin. This session's commits: `a4f737d` (routing-refresh skill + auto-probe), `9c8bf2b` (effort defaults + override rule).
- **Open recurring theme:** Sonnet 5 ≈ Opus 4.8 quality at ⅓ the price → a real opening to route some `architect`-tier work to a `sonnet` `executor`. Deliberately left as a human decision (out of the refresh's safe scope). Tracked in ROADMAP.

---

## 8. How to pick up next time
1. Read this file, then [PROGRESS.md](PROGRESS.md) and [ROADMAP.md](ROADMAP.md).
2. Confirm the `[NEXT]` item in ROADMAP.md before doing anything.
3. Apply §1 rules from the first response.
