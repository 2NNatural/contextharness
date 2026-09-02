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
- **`claude` CLI** — used by the installer's tier probe: `claude -p --model claude-fable-5-1 --max-turns 1 'hi'` (reuses Claude Code OAuth/keychain auth; no API key needed).
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

8. **(2026-07-08) Codex plugin integrated as a manual-only, cross-vendor bolt-on — never on the auto-ladder.** Goal: cross-model adversarial review on risky changes, a different-vendor last-resort escape valve when architect+executor(+oracle) are stuck, and shifting some usage off the Anthropic quota onto my ChatGPT/Codex subscription. Decided:
   - **Optional and always user-invoked.** The `/codex:*` commands and the `codex:codex-rescue` subagent are NEVER auto-invoked by the orchestrator and are NOT part of the scout → architect → oracle ladder. The binding guardrail lives in `routing-rules.md` (the block installed into `~/.claude/CLAUDE.md`), because that is the only policy file the orchestrator reads every session — a rule stated only in README wouldn't constrain it. Full how-to lives in README; this decision is logged here.
   - **`install.sh` unchanged.** Plugin install is via interactive Claude Code slash commands (`/plugin marketplace add openai/codex-plugin-cc`, `/plugin install codex@openai-codex`), not shell — there is no verified scriptable entrypoint, and poking Claude Code's internal plugin state would be fragile and would break the installer's idempotency + 20-case test suite. Documented in README as a manual in-session step. (An `executor` subagent's Bash tool also cannot run slash commands, so this can never be a delegated step.)
   - **Out of `routing-refresh` scope.** That skill tracks the current *Claude* lineup from official Anthropic sources only; Codex is a different vendor/subscription with IDs in `.codex/config.toml`. Added an explicit exclusion rule (rule 6) to the skill. GPT-5.6 tiers (Sol/Terra/Luna, public 2026-07-09) are a deliberate known-unknown — not hardcoded anywhere.
   - **Two sanctioned uses:** `/codex:adversarial-review` as a supplement to (not replacement for) `architect`'s review of a risky change; `/codex:rescue` / `codex:codex-rescue` as an optional escape valve only after architect+executor+oracle have failed.
   - **Why not auto-route to Codex despite the cost angle:** cross-vendor, separate auth, and Opus 4.x still leads GPT-5.5 by 5.7 pts on SWE-bench Pro (real issue resolution = what `executor` does), so Codex is a second opinion / escape valve, not a cheaper primary. Keeping it manual preserves the harness's single-vendor, testable core.

9. **(2026-07-09) Codex integration revised from manual-only (decision 8) to a toggle-gated policy; sol scope expanded to judgment audits.** New requirements (verbatim): *"we should have codex as an explicit on/off toggle switch (if it's on and should be called) — and then if codex is on the [orchestrator] should route to the right codex model for audits and any other tasks it may be better/more cost efficient at"* — corrected mid-design: *"sorry not the architect - the orchestrator should choose when to invoke codex models"* — and expanded: *"can we make sol available for judgment, efficiency, and data audits too, not just security? I work on a lot of design/planning models where the code may be perfect but have subjective design flaws/mechanisms I want a high level auditor to look over. AKA math repositories/prediction market execution mechanisms/formal verification parameters etc"*. Decided:
   - **Toggle = state file `~/.claude/codex-routing.on`** (present = ON, absent = OFF = default). Chosen over an in-block marker (clobbered when `install.sh` regenerates the CLAUDE.md block) and an installer flag (requires re-running install to flip). Flippable via `touch`/`rm` or by asking the orchestrator; survives `./install.sh`; fail-safe (a missed `test -e` check leaves the safe OFF posture). `install.sh` unchanged; new test T21 locks that the installer never creates or clobbers the file.
   - **OFF = exactly decision 8's behavior.** Fresh installs / users without the plugin stay here.
   - **ON = read-only cross-vendor second opinions only,** routed by the ORCHESTRATOR alone at dispatch time (architect has no Codex role — user's explicit correction): adversarial review of a risky change and second opinion on a high-stakes plan → `gpt-5.6-terra` ($2.50/$15, no gate); security/vuln audits AND high-level judgment audits (subjective design/mechanism flaws in functionally-correct code — math repos, prediction-market execution mechanisms, formal-verification parameters, algorithm & data-model design, efficiency and data audits) → `gpt-5.6-sol` ($5/$30) with a user-confirm gate each time (priciest tier). Sol's fit: stated cybersecurity/research strengths plus the GPT line's verified FrontierMath performance; cross-vendor diversity matters most where correctness is subjective.
   - **Still forbidden even when ON:** cross-vendor *writes* / rescue-as-fixer (user-initiated by name only — all writes flow through `executor`, Claude leads SWE-bench Pro), executor-class implementation, routine search/log-digest (haiku `scout` is cheaper and native). Codex is never on the ladder — parallel read-only opinion only.
   - **Mechanical caveat (shipped as option A, unverified):** the orchestrator cannot type `/codex:*` slash commands; the only programmatic path is spawning `codex:codex-rescue` via the Agent tool. Whether that subagent accepts an arbitrary review/audit prompt + per-call `--model` tier is unverified — shipped assuming yes, with a mandatory degrade path: on spawn failure, finish via the Claude ladder and tell the user in one line. Verify on first real ON-mode use.
   - **Deliberate reversal of decision 8's "GPT-5.6 tiers not hardcoded anywhere":** routing "to the right codex model" requires naming tiers where the orchestrator reads them, so `routing-rules.md` now lists `terra`/`sol` with a drift caveat. `routing-refresh` rule 6 tightened to forbid the skill from editing the Codex section even though it lives in `routing-rules.md`.

10. **(2026-07-09) Refresh covers Codex; refresh runs cheap; Codex routes carry per-task effort.** User (verbatim): *"yes routing refresh should cover codex. Make sure routing refresh is also itself run on a cheap model because we don't need to waste hella tokens every refresh. And yes add per task effort to the codex routes"*. Decided:
    - **Refresh scope reversal:** skill rule 6 rewritten — when `~/.claude/codex-routing.on` exists, the refresh ALSO researches the official OpenAI Codex lineup and proposes tier-ID/effort updates to the Codex section of `routing-rules.md` + README, same diff-then-confirm gate, Codex changes separated from Claude changes in the diff. Toggle absent → zero Codex research. `.codex/config.toml` and the toggle file are never edited by the skill.
    - **Cheap refresh mechanics:** skills execute in the main thread and can't be pinned to a model, so "run on a cheap model" = new rule 7: the skill delegates bulk fetching/extraction to a cheap subagent (`general-purpose` + `haiku` override at `low` effort; scout can't do it — no web tools) which returns only a compact ID/price table; the main thread only cross-checks, diffs, and gates. Full page dumps never enter the expensive context.
    - **Codex effort column:** terra reviews = medium; sol security audit = high; sol judgment audit = xhigh (the hardest, most subjective work mirrors oracle's xhigh). Passed per-call; if pass-through is unsupported (same unverified caveat as the model flag), falls back to profile defaults set once in `.codex/config.toml`.

11. **(2026-07-23) Real context meter via a UserPromptSubmit hook, built on transcript `usage` (not bytes/4).** Every `assistant` JSONL line carries `.message.usage` — exact API token accounting; the last non-sidechain turn's `input+cache_read+cache_creation+output` is true context occupancy and auto-resets after `/compact`. Chosen over a bytes/4 estimate (which can't survive compaction — the file keeps growing while context resets) and over reading the statusline payload (unverified for hooks; noted as a future upgrade). **Denominator default 1,000,000, not 200k:** the live session read 293,676 tokens on fable — 200k would show 146% and nag every prompt (the exact behavior of correction §6, 2026-07-09). Knob: `CLAUDE_CONTEXT_WINDOW`. **Stepped band-crossing (70/80/90), stateful per session** (`$TMPDIR/claude-context-meter/<id>.band`) over per-prompt injection — minimal noise, honors never-nag; the injected line persists in history. **settings.json = opt-in `--with-context-hook` only**, jq merge with backup + `jq empty` validation + idempotency guard, degrades to manual instructions without jq; default install untouched (mirrors decisions 8/9's refusal to poke Claude Code state). Hook always exits 0 — never blocks a prompt.

12. **(2026-09-02) Audit Standard + `/audit` skill + interface inventory + destructive guard.** Origin: a production post-mortem where four failures each lived *between* components that had audited clean in isolation, plus a live incident that same day — an `executor` subagent on a stated read-only task deleted an untracked file in the user's repo. Decided:
    - **The standard lives in `routing-rules.md`**, inside the marker block, so it installs into every project's `~/.claude/CLAUDE.md` and is the single source of truth; `agents/architect.md` carries only a short summary paragraph as a degrade path for when the orchestrator forgot to paste the standard.
    - **`/audit` extracts the standard at runtime via `awk`, never a stale embedded copy.** An embedded copy in the skill file would drift from `routing-rules.md` the moment either changed. The extraction has an integrity check (must contain the four required-list section headers) and **aborts rather than degrades** if extraction fails — running a degraded audit is itself the kind of silent fallback the standard forbids.
    - **Liveness evidence is fanned out to `scout`, capped at 8 concurrent calls**, distributed evenly above that; beyond ~48 links the skill stops and offers narrowing or `oracle` instead of silently dropping links. The verdict itself is always `architect`'s (read-only, effort high+) and is returned to the user **unchanged** — the skill is a dispatcher, not an auditor. A verdict missing any of the four required lists gets one retry, then ships labelled `AUDIT INCOMPLETE`, never silently upgraded to "clean" and never patched by the skill itself.
    - **`INTERFACES.md` lives at the project root, not under `docs/`**, and is created only by the new standalone `--init-inventory` install mode: refuses to combine with any other flag, refuses to write inside `$HOME`/`~/.claude`, never overwrites an existing file, and exits before the tier probe and before touching `~/.claude` at all. This is the one documented, auditable exception to "`install.sh` writes only under `~/.claude`" — kept narrow and explicit rather than silently expanded.
    - **The destructive guard is opt-in, `PreToolUse`, block-with-escape-hatch, fail-open** — same posture as the context-meter hook (decision 11): missing `jq`, empty stdin, or an unparseable payload always allows the call, because a broken guardrail must never wedge a session. Default scope is `all` (every Bash call), not `subagent`-only, deliberately: `.agent_id`/`.agent_type` are unverified on payloads generally and must not be load-bearing for whether the guardrail functions at all — those fields only gate the inline escape hatch and enrich the denial message. `HARNESS_GUARD_SCOPE=subagent` is documented as a lower-friction opt-in, with an explicit "verify it populates on your build" caveat. The hook emits **both** documented deny mechanisms (exit 2 + stderr, and the `PreToolUse` deny JSON on stdout) because the two shipped reference implementations for this hook type disagree about which stream carries the signal — no build behavior lets the command through. Rejected: agent-frontmatter-declared hooks (undocumented schema, a workspace-trust precondition, and always-on enforcement that violates the opt-in posture every other hook in this repo follows). Framed honestly throughout as a tripwire against accidents, not a security boundary — command-string matching cannot be made adversary-proof.
    - **Test-suite fix folded into this session:** `install.sh` gained `HARNESS_SKIP_PROBE=1`, a test-only escape hatch so `tests/run-tests.sh` never shells out to the real `claude` CLI (up to 25s × ~21 runs); T16/T20 explicitly `-u HARNESS_SKIP_PROBE` so they still exercise the real non-TTY/no-API fallback path unmodified. Wall time dropped from 16.6s to ~2.4s.

---

## 6. Corrections & behavior updates (this session)

- **Don't fabricate against a template.** The Session-Start template referenced `CONTEXT.md`/`PROGRESS.md`/`ROADMAP.md`, which did **not** exist in the repo at the time. Correct behavior was to flag that and not invent the structured report against missing files. (Those files now exist — created this session.)
- **Pure-static effort was the wrong first instinct.** I corrected it toward the hybrid (per-role default + orchestrator dynamic override). Apply the hybrid going forward.
- **"Always auto-probe"** overrode the architect's "prompt interactively, probe only non-interactively" design. Detection must require no user input.
- **Don't gut the public README.** README is a product front door for cloners; keep it functional, don't strip it to links-only. (This was my call during wrap-up, recorded so it stays.)
- **(2026-07-09) Don't nag about `/compact`.** Verbatim: *"ok so now you're just asking me to compact at every prompt. I don't like this"* — the compaction rule was rewritten to suggest-once-per-high-context-stretch, silently do the summary hygiene, and treat auto-compaction as a fine fallback. Never repeat an unacted-on suggestion.

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
