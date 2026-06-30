# PROGRESS.md — Changelog & Status

> Changelog of what was built, current status of each feature, and known issues. Behavioral rules and decision rationale live in [CONTEXT.md](CONTEXT.md). The single prioritized what's-next is [ROADMAP.md](ROADMAP.md).

---

## Feature status (current)

| Feature | Status | Notes |
|---|---|---|
| `routing-refresh` skill | ✅ Done, live-tested | First live run = clean pass (confirmed lineup current, made zero edits) |
| Auto tier-detection (installer probe) | ✅ Done, live-tested | Probed real auth → detected `opus`; pinned `~/.claude/agents/oracle.md` to opus |
| Skills install in `install.sh` | ✅ Done | Copies `skills/*/` → `~/.claude/skills/` |
| Regression tests T18–T20 + T16 hardening | ✅ Done | 21/21 assertions pass (20 named cases) |
| Per-role effort defaults | ✅ Done | scout=low, executor=medium, architect=high, oracle=xhigh |
| Effort-override routing rule | ✅ Done | In `routing-rules.md`, installed into `~/.claude/CLAUDE.md` |
| Orchestrator model/effort guidance | ✅ Decided | opus + medium (not max); documented in CONTEXT.md §5 |

---

## Session 2026-06-30

Context: started from the prompt "sonnet 5 is now out … our harness should be constantly updating based on information and benchmarks to use the most optimal models … it should detect the top level model it's currently on without user switching/input." Repo had only `README.md`, `agents/`, `install.sh`, `routing-rules.md`, `tests/` — no CONTEXT/PROGRESS/ROADMAP.

### Built — Commit `a4f737d` "Add routing-refresh skill + auto-detect top model tier"
- **New `skills/routing-refresh/SKILL.md`** — on-demand skill. Procedure: detect tier (no prompt) → research live Anthropic lineup (WebSearch/WebFetch official pages, never memory) → map to roles → build edits in memory → **show diff + get confirmation (hard gate)** → apply → re-run installer. Absolute rules: live sources only, never invent model IDs, diff-then-confirm always, safe scope (only `routing-rules.md` + `agents/oracle.md` pin + `README.md`), abort with zero edits if research inconclusive. Preserves the `[1m]` suffix when swapping the oracle base ID.
- **`install.sh` — `probe_top_model()`** helper: drives `claude -p --model claude-fable-5` (reuses Claude Code OAuth, no API key), falls back to `curl` Messages API if `ANTHROPIC_API_KEY` set, wrapped in `timeout`/`gtimeout` when available. Never fails the install. Maps success→fable, model-rejected→opus, inconclusive→empty.
- **`install.sh` — always-probe tier logic** (modified from architect's plan per my "Always auto-probe" choice): when no `--top-model` flag, always probe first; only prompt (TTY) or default fable (non-TTY) if inconclusive. `--top-model` still overrides.
- **`install.sh` — skills install loop**: copies `skills/*/` into `~/.claude/skills/` idempotently.
- **`tests/run-tests.sh`** — added T18 (skill installs), T19 (skill copy idempotent), T20 (probe falls back to fable with no CLI/key); hardened T16 to strip `ANTHROPIC_API_KEY` and restrict PATH so it's deterministic on machines that do have model access.
- **`README.md`** — documented skills copy, the auto-probe behavior, added the skill to the Files table, bumped test-count 17→20.

### Built — Commit `9c8bf2b` "Add per-role effort defaults + dynamic effort-override routing rule"
- **`agents/*.md` frontmatter** — added `effort:` after `model:`: scout=low, executor=medium, architect=high, oracle=xhigh (documented defaults/baselines).
- **`routing-rules.md`** — new paragraph after the model-override rule instructing the orchestrator to set per-invocation effort by task difficulty (role default as baseline, override up/down, floors architect/oracle ≥ high). Mirrors the executor→opus model-override pattern.
- **`README.md`** — effort levels added to the Files table; "Change an effort level" bullet in Tune it.

### Verification performed this session
- **Test suite:** 21/21 assertions pass after each change.
- **Live tier probe (real auth, throwaway HOME):** `claude -p --model claude-fable-5` → exit 1, `"Claude Fable 5 is currently unavailable"` → detected `opus`; installer printed `auto-detected top model tier: opus`; `~/.claude/agents/oracle.md` → `model: opus`. Probe and installer agree.
- **`./install.sh` run on this machine:** auto-detected opus, installed 4 agents + the skill, patched installed oracle to opus, updated the routing-rules block in `~/.claude/CLAUDE.md`.
- **First live `/routing-refresh`:** researched the live lineup; confirmed scout/executor/architect aliases already resolve to the newest model in their tier and the oracle pin still names the current top model (Fable 5); **concluded "policy already current," made zero edits** (I confirmed "leave repo as is").

### Docs — this wrap-up (uncommitted)
- Created `CONTEXT.md`, `PROGRESS.md`, `ROADMAP.md`; updated `README.md` (status line + Documentation links). Not committed (commit only when asked).

---

## Known issues / not fixed

- **Probe can't distinguish transient vs. entitlement failure.** `probe_top_model()` maps *any* non-zero `claude` exit to `opus`. The observed `"currently unavailable"` for fable could be transient; a service blip during install would silently pin `opus` and the oracle would lose 1M context until re-run. **Decision: left as-is** — re-run `./install.sh` (or the refresh) if a downgrade is suspected; `--top-model fable` overrides. Tracked in ROADMAP as [MAYBE].
- **The `routing-refresh` skill's own behavior is not unit-tested.** It's an LLM procedure, not code — its guardrails live in prose + the diff-then-confirm human gate. Tests cover the installer plumbing only.
- **Binary tier probe.** Only fable-vs-opus; doesn't generalize to a third simultaneous top-tier option without code changes.
- **New model *class* (not version) not auto-handled.** Refresh safe-scope forbids creating new agent slots; a genuinely new tier needs a human (via `architect`) to design a new agent. By design.
