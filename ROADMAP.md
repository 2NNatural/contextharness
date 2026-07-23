# ROADMAP.md — What's Next

> The single prioritized task list for this project. No competing roadmaps. Labels: **[NEXT]** (do first), **[SOON]**, **[LATER]**, **[MAYBE]**. Status of what's already built is in [PROGRESS.md](PROGRESS.md); rationale in [CONTEXT.md](CONTEXT.md).

---

### [NEXT] Decide whether Sonnet 5 should absorb some `architect`-tier work
- Sonnet 5 is ~Opus 4.8 quality at ⅓ the price ($3/$15 vs $5/$25). Real cost win for design-tradeoff / risky-change-review tasks currently sent to `architect` (opus).
- This changes *which role handles which task* (the Task column), which is **outside the routing-refresh skill's safe scope** — it's a human call.
- Action: have `architect` scope exactly which task categories can safely drop to a `sonnet` `executor`, then I approve, then `executor` edits `routing-rules.md`.
- Blocked on: my go-ahead.

### [SOON] Set orchestrator effort explicitly to `medium`
- Main thread should run `opus` at **medium** effort (best model at coordination layer; reserve high effort for disposable `architect`/`oracle`).
- Catch: Opus 4.8 / Sonnet 5 **default to `high`** on Claude Code, so this needs an explicit `effort` setting — it is not automatic.
- Action: decide where to set it (per-session `/effort` vs. a settings default) and apply.

### [MAYBE] Schedule periodic `/routing-refresh`
- For true hands-off freshness: a scheduled trigger that runs the refresh on a cadence (still diff-then-confirm, so nothing applies without me).
- Why not done: I explicitly wanted on-demand, not a daemon. Only build if I change my mind.

### [MAYBE] Harden the tier probe: transient vs. entitlement failure
- Make `probe_top_model()` treat `"currently unavailable"` / 5xx / timeout as *inconclusive* (keep prior pin) instead of downgrading to `opus`.
- Trade-off: parsing CLI error strings is brittle across versions. Low priority while fable is blocked anyway.

### [MAYBE] Generalize the probe beyond binary fable/opus
- Current logic only chooses between fable and opus. If a third top-tier option ever co-exists, the probe needs real ranking logic, not a fallback chain.

### [MAYBE] Support a genuinely new model *class*
- If Anthropic ships a new tier (e.g. a nano class below haiku, or a specialized coding model) that deserves its own agent, the refresh skill won't create it (safe scope). Would need a human-designed new agent slot via `architect`.

### [MAYBE] Statusline-payload denominator (auto-detect true window instead of CLAUDE_CONTEXT_WINDOW knob)
- The context-meter hook currently uses a fixed default denominator overridden by an env var. If the statusline hook payload (or another Claude Code surface) reliably exposes the actual context window for the active model, the meter could auto-detect it instead of requiring manual configuration.

### [MAYBE] Model-map denominator (derive 200k vs 1M from .message.model + [1m] marker if a reliable signal exists)
- Transcript lines carry `.message.model`. If a dependable mapping from model ID (plus the `[1m]` context-window marker) to true window size exists, the context-meter hook could pick the right denominator per-model automatically instead of one global default.

---

## Done / archived (moved out of active roadmap — full detail in PROGRESS.md)
- ✅ `routing-refresh` skill (live research + diff-then-confirm + safe scope) — `a4f737d`
- ✅ Installer auto-detects top tier (always-probe) — `a4f737d`
- ✅ Skills install path in `install.sh` — `a4f737d`
- ✅ Tests T18–T20 + T16 hardening — `a4f737d`
- ✅ Per-role effort defaults + effort-override routing rule — `9c8bf2b`
- ✅ Orchestrator model/effort guidance decided (opus + medium) — see CONTEXT.md §5
- ✅ First live `/routing-refresh` run (confirmed current, zero edits)
