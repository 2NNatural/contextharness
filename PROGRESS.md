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
| Context-meter hook | ✅ Done | opt-in `--with-context-hook`; band-crossing 70/80/90; transcript-usage based |
| Audit Standard | ✅ Done | lives in `routing-rules.md`, installed into `~/.claude/CLAUDE.md`; `architect.md` carries a summary as degrade path |
| `/audit` skill | ✅ Done, not live-tested | runtime `awk` extraction, ≤8-scout liveness fan-out, read-only `architect` verdict, hard gate on the four required lists |
| Interface inventory template | ✅ Done | `templates/INTERFACES.md`, installed only via standalone `--init-inventory` |
| Destructive guard | ✅ Done, blocking unverified live | opt-in `--with-destructive-guard`; PreToolUse/Bash; fail-open; not yet confirmed to actually block inside a real `claude --debug` session |

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

---

## Session 2026-07-08

Doc-only session: integrated OpenAI's official Codex plugin (github.com/openai/codex-plugin-cc) as a manual-only, cross-vendor bolt-on for adversarial review and a last-resort escape valve. No code or test changes.

### Changed
- `routing-rules.md` — added "Optional cross-vendor tools" section with the NEVER-auto-invoke guardrail (inside the model-harness marker block, so it propagates to `~/.claude/CLAUDE.md`).
- `README.md` — added "Optional cross-vendor tools (Codex)" section: prerequisites, manual install commands, the two sanctioned use cases.
- `skills/routing-refresh/SKILL.md` — added rule 6 excluding Codex/cross-vendor from the skill's Claude-lineup-only scope.
- `CONTEXT.md` — logged decision 8 (see CONTEXT.md §5 for full reasoning).
- `install.sh` — deliberately NOT touched. Plugin install is an interactive Claude Code slash-command action (`/plugin marketplace add`, `/plugin install`) with no verified scriptable shell entrypoint.

### Manual step still owed by the user (not automatable)
Inside an active Claude Code session: `codex login` (if not already authenticated), then `/plugin marketplace add openai/codex-plugin-cc`, then `/plugin install codex@openai-codex`. Verify via `/agents` (should list `codex:codex-rescue`) and `/codex:status`.

---

## Session 2026-07-09

Revised the Codex integration from manual-only (decision 8) to a **toggle-gated** policy per new requirement; expanded sol to high-level judgment audits (CONTEXT.md §5 decision 9). GPT-5.6 confirmed public this session (`gpt-5.6-sol` $5/$30, `gpt-5.6-terra` $2.50/$15, `gpt-5.6-luna` $1/$6 — verified via OpenAI Codex docs).

### Changed
- `routing-rules.md` — replaced "Optional cross-vendor tools (manual only …)" with "(Codex — toggle-gated)": `~/.claude/codex-routing.on` state file (OFF default), ON-mode read-only routing table (terra: adversarial review + plan second-opinion; sol with confirm gate: security audits + high-level judgment/efficiency/data audits), forbidden-even-when-ON list, orchestrator-only control flow (architect has no Codex role).
- `README.md` — rewrote the Codex section: toggle usage (`touch`/`rm`/`ls`), ON-mode routing table incl. judgment audits, GPT-5.6 tier IDs; manual `/codex:*` commands kept; test count 20 → 21.
- `skills/routing-refresh/SKILL.md` — tightened rule 6: skill must leave the Codex section of `routing-rules.md` byte-for-byte untouched.
- `tests/run-tests.sh` — added T21 (install.sh never creates or clobbers the toggle file).
- `CONTEXT.md` — logged decision 9.
- `install.sh` — deliberately NOT changed; toggle is decoupled and default-OFF.

- **Amendment (same session):** refresh now covers Codex when the toggle is on (skill rule 6 rewritten; new Step 2b), refresh research is delegated to a cheap haiku subagent (new rule 7 — token thrift), and the Codex routing tables gained a per-task Effort column (terra=medium, sol security=high, sol judgment=xhigh) in `routing-rules.md` + `README.md`. CONTEXT.md decision 10.

### Open item owed
- **Verify on first ON-mode use:** whether the `codex:codex-rescue` subagent accepts an arbitrary read-only review/audit prompt and a per-call `--model` tier when spawned via the Agent tool. Shipped assuming yes (option A) with a degrade path: on failure the orchestrator finishes via the Claude ladder and tells the user in one line.
- User manual step still owed: `codex login`, `/plugin marketplace add openai/codex-plugin-cc`, `/plugin install codex@openai-codex`, then `touch ~/.claude/codex-routing.on` to enable auto-routing.

---

## Session 2026-07-09 (Windows/Git Bash portability)

Fixed one real portability bug and added environment skip-guards for two tests that cannot pass on Windows, so `tests/run-tests.sh` is green on Windows/Git Bash without weakening the suite elsewhere.

### Changed
- `.gitattributes` — new: `* text=auto eol=lf`, so git checks out repo text files (including `routing-rules.md`) with LF regardless of host OS; renormalized the tree (`git add --renormalize .`).
- `install.sh` — the rules-file read path now goes through a `tr -d '\r'`-normalized temp copy (both the fresh-append and block-replace code paths use it), so a CRLF-checked-out `routing-rules.md` can never make re-runs byte-non-identical. Root cause of T2's Windows failure: first install wrote a CRLF block, the block-replace path on re-run wrote LF, so bytes differed even though content matched modulo `\r`.
- `tests/run-tests.sh` — added `skip()` alongside `pass`/`fail`, plus `symlinks_supported()` and `chmod_000_enforced()` capability probes (create-and-check rather than OS sniffing). T10 (symlinked CLAUDE.md) and T14 (chmod 000 unreadable rules file) now SKIP with a clear reason when the platform can't enforce the precondition — Git Bash's `ln -s` copies instead of symlinking without elevated privileges, and NTFS doesn't enforce chmod 000. RESULTS line now reports passed/failed/skipped.

### Verified
`bash tests/run-tests.sh` on Windows/Git Bash: `=== RESULTS: 21 passed, 0 failed, 2 skipped ===`, exit 0 (T2 passes, T10/T14 SKIP, all others still PASS).

---

## Session 2026-07-23

Two threads of work: (1) a same-day nag-fix follow-up to the compaction rule, and (2) a new opt-in context-meter hook.

### Nag-fix follow-up (routing-rules.md rewrite + CONTEXT correction)
- `routing-rules.md` — rewrote the "Proactive compaction" bullet to "suggest ONCE, never nag": refresh the state-of-work summary and drop stale detail silently (no announcement needed), suggest `/compact` at most once per high-context stretch at a genuine breakpoint, never repeat an unacted-on suggestion.
- `CONTEXT.md` — added §6 correction entry logging the verbatim user feedback ("ok so now you're just asking me to compact at every prompt. I don't like this") that drove the rewrite.

### New: context-meter hook (opt-in)
- **New `hooks/context-meter.sh`** — `UserPromptSubmit` hook. Reads the session transcript's real `.message.usage` token accounting (last non-sidechain `assistant` turn), computes `%` against a configurable denominator (`CLAUDE_CONTEXT_WINDOW`, default 1,000,000), and injects a one-line `[context: ~N%]` marker only on first crossing of the 70/80/90 bands (stateful per session in `$TMPDIR/claude-context-meter/<id>.band`). Prints nothing below threshold. Always exits 0; degrades to a no-op if `jq` is missing.
- **`install.sh`** — new opt-in flags `--with-context-hook` / `--remove-context-hook`. Default install never touches `hooks/` or `settings.json`. `--with-context-hook` copies the script to `~/.claude/hooks/`, `chmod +x`s it, and (if `jq` present) merges a `UserPromptSubmit` registration into `~/.claude/settings.json` — validated (`jq empty`), idempotent, backed up before every write, preserves all pre-existing settings content (model, other hooks). `--remove-context-hook` strips only our entry and deletes the script, leaving everything else intact. Without `jq`, prints manual merge instructions instead of touching the file. Added "Optional context meter" line to the post-install next-steps message.
- **`routing-rules.md`** — appended a sentence to the Proactive compaction bullet: a `[context: ~N%]` line in the conversation is a real meter read to trust over intuition; its absence means comfortably below threshold (still never nag).
- **`tests/run-tests.sh`** — added `jq_available()` capability probe and T22–T27: T22 (default install leaves hook/settings absent), T23 (hook installed + executable), T24 (settings merge valid + idempotent), T25 (pre-existing settings/model/user-hook preserved through merge), T26 (`--remove-context-hook` strips only our entry, keeps user content), T27 (hook logic — fires above band, silent below band, using a synthetic transcript). T23–T26 pin `--top-model opus` to bypass the live tier probe (which shells out to the real `claude` CLI and can mutate the sandbox `settings.json`'s `.model` as an unrelated side effect, which would make the settings-merge assertions flaky).
- **README.md / CONTEXT.md / ROADMAP.md** — documented the feature (see "Optional: context meter" section, CONTEXT.md §5 decision 11, and two new `[MAYBE]` roadmap items on smarter denominator detection).

### Verified
`bash tests/run-tests.sh`: `=== RESULTS: 31 passed, 0 failed, 0 skipped ===`, exit 0.

---

## Session 2026-09-02

Built the Audit Standard, `/audit` skill, interface-inventory template + install mode, and an opt-in destructive-guard hook — plus a test-expectation fix for upstream oracle-pin drift.

### Built
- `routing-rules.md` — new "## Audit Standard" section (sections A–E, four required output lists, Pre-live gate, routing note) inside the marker block, so it installs into every project's `~/.claude/CLAUDE.md`. Triggered by "audit"/"review"/"check"/"verify"/"is this safe" or the shorthand "syntax + code + unknowns".
- `agents/architect.md` — new closing paragraph: apply the Audit Standard in full for audit/review requests, with a fallback summary if the orchestrator didn't paste the standard.
- `skills/audit/SKILL.md` — new `/audit` skill: resolves the target (Step 0), extracts the standard verbatim from `~/.claude/CLAUDE.md` via `awk` with an integrity check and hard abort on failure (Step 1), reads `INTERFACES.md` if present (Step 2), fans out ≤8 `scout` calls for liveness evidence (Step 3), dispatches one read-only `architect` at effort high+ (Step 4), gates the verdict on the four required lists with one retry and an `AUDIT INCOMPLETE` fallback label (Step 5), and offers a toggle-gated Codex second opinion alongside (never instead of) the Claude verdict (Step 6).
- `templates/INTERFACES.md` — new interface-inventory template: Link/Mechanism/Direction/Join key/Last verified live columns, one example row, one `NEVER FIRED` row, and a "Column meanings" section.
- `hooks/destructive-guard.sh` — new opt-in `PreToolUse`/Bash hook. Blocks `rm`/`rmdir`/`mv`/`shred`/`del`/`Remove-Item`/`git clean` when any inspectable target resolves outside a scratchpad/temp root. Fail-open (missing `jq`, empty/unparseable payload → allow). Two escape hatches: inline `HARNESS_ALLOW_DESTRUCTIVE=1 <cmd>` (main-thread only) and the env master switch (works unconditionally, including for subagents). `HARNESS_GUARD_SCOPE=subagent` narrows enforcement to payloads carrying `.agent_id`/`.agent_type`, with a verify-on-your-build caveat. Emits both documented `PreToolUse` deny mechanisms (exit 2 + stderr, and the deny JSON on stdout) since the two shipped reference hook implementations disagree on which one is authoritative.
- `agents/executor.md` — new rule 6: never delete/move/overwrite files outside the task's named paths; scratch output only to the scratchpad directory; read-only tasks make no writes anywhere else.
- `install.sh` — `--with-destructive-guard` / `--remove-destructive-guard` (mirrors the context-meter hook's install/merge/remove pattern, registered under `.hooks.PreToolUse` with a `Bash` matcher); standalone `--init-inventory` mode (refuses to combine with other flags, refuses `$HOME`/`~/.claude`, never overwrites, exits before the tier probe and before any `~/.claude` work — the one documented exception to "installer writes only `~/.claude`"); new `HARNESS_SKIP_PROBE=1` test-only escape hatch in `probe_top_model()`; post-install "Next steps" heredocs gained the guard and inventory lines.
- `tests/run-tests.sh` — new T28 (Audit Standard propagates into installed `CLAUDE.md` + `architect.md`), T29 (`/audit` skill installs), T30 (`--init-inventory` create/no-overwrite/no-`~/.claude`-touch/refuses-combining), T31 (destructive-guard install/merge/idempotent/remove, mirrors T22–T26), T32 (guard logic — blocks outside scratch, allows inside scratch, both escape hatches, subagent hatch refusal, valid deny JSON, helpful denial message, fails open on bad payload). Suite-wide `export HARNESS_SKIP_PROBE=1`; T16/T20 explicitly `-u HARNESS_SKIP_PROBE` so they keep exercising the real non-TTY/no-API fallback.
- `README.md` — new "Optional: destructive guard" and "## Audit Standard" (with `/audit` and "Interface inventory" subsections) sections; Files table gained the three new files and an updated test-count/description; status line bumped.

### Fixed (F1/F2 — discovered by the prior test run, not part of the original plan)
- `tests/run-tests.sh` T15a/T15b/T16/T20 asserted `model: claude-fable-5[1m]`; commit `f877029` (same day, `routing-refresh`) had re-pinned `agents/oracle.md` to `claude-fable-5-1[1m]` without updating these expectations. Updated all four to the current pinned string.
- `install.sh`'s `probe_top_model()` still probed the old base id (`claude -p --model claude-fable-5`); synced to `claude-fable-5-1` to match the current pin. `CONTEXT.md` §3's `claude` CLI bullet updated to match.

### Verified
`bash tests/run-tests.sh`: `=== RESULTS: 53 passed, 0 failed, 0 skipped ===`, exit 0. Wall time ~2.4s (down from 16.6s/4-failed before this session — almost entirely `HARNESS_SKIP_PROBE` removing ~21 real `claude` CLI shell-outs from the suite).

### Open item owed
- **Verify live with `claude --debug`** that the `PreToolUse` deny actually blocks the tool call on the current Claude Code build, and whether `.agent_id`/`.agent_type` populate on real subagent payloads. If both check out, `HARNESS_GUARD_SCOPE=subagent` becomes the recommended (lower-friction) default instead of `all`.
- `/audit` skill has not been exercised in a live session (SKILL.md prose only, unit-tested only via the installer plumbing in T28–T29).

### Known issues / changelog note
- **Routing-refresh re-pinned the oracle (`f877029`) without checking reverse dependencies** — it left `tests/run-tests.sh`'s expected strings and `install.sh`'s probe id asserting the old `claude-fable-5[1m]` base id. Fixed this session (see F1/F2 above). The gap in `routing-refresh` itself — it should have caught this — is tracked in `ROADMAP.md`.
