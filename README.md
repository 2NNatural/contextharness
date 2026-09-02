# Model-Routing Harness for Claude Code

**Status:** active · `main` · last session 2026-06-30 (routing-refresh skill + auto tier-detection + effort policy shipped)

Work in **one long-lived Claude Code thread**, never switch models manually, and pay the cheapest rate for each kind of work. The main thread acts as an orchestrator; token-heavy work (reading code, running tests, deep analysis) is delegated to subagents pinned to cheaper models, each with its own disposable context window.

## Documentation

- [CONTEXT.md](CONTEXT.md) — project brain / session memory: behavioral rules, goals, stack, decisions (upload this to start a session)
- [PROGRESS.md](PROGRESS.md) — changelog, feature status, known issues
- [ROADMAP.md](ROADMAP.md) — the single prioritized what's-next

```
                       you (one thread, never recreated)
                                    │
                  orchestrator — strongest model you have (fable 1M or opus)
                  holds decisions + summaries, not file dumps
                                    │
        ┌──────────────┬────────────┴─┬──────────────────┐
        ▼              ▼              ▼                  ▼
   scout (haiku)  executor (sonnet)  architect (opus)  oracle (top model)
   search, read,  write/edit code,  design tradeoffs, >200k-token analysis,
   summarize      run tests/builds  root-cause,       last-resort hard
   read-only      returns report    review → plan     problems — read-only
```

Note: both the **orchestrator** (your thread) and the **oracle** subagent run on your strongest available model tier. The installer **auto-detects** that tier — fable (1M context) or opus — by probing the API on every run; pass `--top-model fable`/`--top-model opus` to override. The oracle gives that top model a fresh isolated context for huge jobs without polluting the orchestrator's lean context. Escalation ladder: scout → architect → oracle.

Why this saves tokens:

- **The bulk of session tokens is reading** — code, logs, test output. All of that lands in scout/executor contexts at haiku/sonnet rates and is thrown away after each task.
- **The expensive model sees only distillate.** The orchestrator accumulates short summaries, so its context stays small (and prompt-cached) and it compacts rarely.
- **No model switching, ever.** Model choice is baked into each agent's frontmatter; routing rules in `~/.claude/CLAUDE.md` make delegation the default behavior. (Claude Code can't auto-switch the *main* thread's model — that's exactly why routing happens via subagents.)

## Install

```sh
git clone <this-repo> harness
cd harness
./install.sh
```

The installer:

1. Copies `agents/*.md` → `~/.claude/agents/` (user-level: applies to every project).
2. Inserts the routing-rules block from `routing-rules.md` into `~/.claude/CLAUDE.md` between `<!-- model-harness:start/end -->` markers — anything else in your CLAUDE.md is preserved.
3. Copies `skills/*/` → `~/.claude/skills/` (on-demand skills like routing-refresh).

Without a `--top-model` flag the installer always auto-probes your strongest available model tier first; it only prompts (TTY) or defaults silently to fable (non-TTY) when the probe is inconclusive. You can also pass a flag explicitly:

```sh
./install.sh --top-model fable   # default — fable 1M context (oracle uses claude-fable-5-1[1m])
./install.sh --top-model opus    # if fable is unavailable — oracle uses opus instead
```

Then set the orchestrator model once to match your chosen tier:

- **fable:** `/model claude-fable-5-1[1m]` or in `~/.claude/settings.json`: `{ "model": "claude-fable-5-1[1m]" }`
- **opus:** `/model opus` or in `~/.claude/settings.json`: `{ "model": "opus" }`

## Update

```sh
git pull && ./install.sh --top-model fable   # or --top-model opus — pass the same tier you used at install
```

Idempotent — the marked block is replaced in place, agents are overwritten (re-applying your chosen tier to oracle).

### Optional: context meter (opt-in hook)

A local `UserPromptSubmit` hook that reads real token usage from the session transcript and injects a one-line `[context: ~N%]` marker **only** when usage crosses 70/80/90% — giving the orchestrator a true compaction signal instead of a guess. Pure local shell: no `claude`/API calls, zero cost below threshold.

```sh
./install.sh --with-context-hook     # copies hooks/context-meter.sh, registers it in ~/.claude/settings.json (jq merge, backup written)
./install.sh --remove-context-hook   # unregisters + deletes the script
```

Requires `jq`. The default context window is **1,000,000** (fable 1M / opus-5 / sonnet-5); on a 200k-capped plan set `CLAUDE_CONTEXT_WINDOW=200000`. The merge is idempotent and non-destructive — your existing `settings.json` (model, other hooks) is preserved and backed up before any write.

## Tune it

- **Delegation too timid / too eager?** Edit the `description:` line in the relevant `agents/*.md` — that's what the orchestrator matches against when deciding to delegate. Stronger wording ("Use PROACTIVELY for ALL …") = more delegation.
- **Change a model:** edit the `model:` line (`haiku`, `sonnet`, `opus`, `fable`, or a full model ID like `claude-haiku-4-5`).
- **Change an effort level:** edit the `effort:` line (`low`, `medium`, `high`, `xhigh`, `max`) in the relevant `agents/*.md` file.
- **Change routing policy:** edit `routing-rules.md`.

Re-run `./install.sh` after any change.

## Optional cross-vendor tools (Codex — toggle-gated)

Independent of the routing harness, you can bolt on OpenAI's official [Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc) for cross-model review and a different-vendor escape valve. A single **toggle** controls whether the orchestrator may reach for it automatically.

**Prerequisites:** Node.js 18.18+ and a local `codex` CLI authenticated against your ChatGPT/Codex subscription (`codex login`).

**Install — manual, inside an active Claude Code session (cannot be scripted from `install.sh`):**

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
```

Its config lives in `.codex/config.toml` (user or project level) — a separate namespace that does not touch this harness's agents, aliases, or the `~/.claude/CLAUDE.md` block. Pick a model per call with `--model <id>` — GPT-5.6 in three tiers: `gpt-5.6-sol` (flagship; complex-coding, cybersecurity, and research strength; default for bare `gpt-5.6`), `gpt-5.6-terra` (cheaper/faster), `gpt-5.6-luna` (lightest).

### The toggle

Auto-routing to Codex is **OFF by default** and gated by one file:

```sh
touch ~/.claude/codex-routing.on   # ON  — orchestrator may auto-route read-only reviews/audits to Codex
rm    ~/.claude/codex-routing.on   # OFF — Codex is manual-only (default)
ls    ~/.claude/codex-routing.on   # check state at a glance
```

The file survives `./install.sh` re-runs, so `git pull && ./install.sh` never flips it. Fresh installs and users without the plugin have no file → OFF, and nothing here assumes you have Codex.

- **OFF (default):** Codex runs only when *you* type a `/codex:*` command by name. The orchestrator never auto-invokes it; it may only remind you the option exists.
- **ON:** the orchestrator may automatically get a cross-vendor **read-only** second opinion — *alongside*, never instead of, the Claude ladder — choosing the tier per task:

  | Task | Tier | Effort | Notes |
  |---|---|---|---|
  | Adversarial review of a risky change (supplements `architect`) | `gpt-5.6-terra` | medium | cheap cross-vendor diversity |
  | Second opinion on a high-stakes `architect` plan | `gpt-5.6-terra` | medium | high-stakes plans only |
  | Security / vulnerability audit of a module or area | `gpt-5.6-sol` | high | orchestrator confirms with you first (priciest tier) |
  | High-level judgment audit — subjective design/mechanism flaws in functionally-correct code (math repos, prediction-market execution mechanisms, formal-verification parameters, algorithm & data-model design, efficiency and data audits) | `gpt-5.6-sol` | xhigh | orchestrator confirms with you first (priciest tier) |

  Even when ON, Codex never does **writes**: implementation stays with `executor` (Claude leads SWE-bench Pro real-issue resolution), and `/codex:rescue` / `codex:codex-rescue`-as-fixer remain user-initiated by name. Routine search and log-digestion stay on `scout` (haiku is cheaper and native). The binding rules live in `routing-rules.md` (installed into `~/.claude/CLAUDE.md`). Effort is passed per-call where supported; otherwise set matching defaults once in `.codex/config.toml`.

**Manual commands (any time, regardless of toggle):** `/codex:review`, `/codex:adversarial-review`, `/codex:rescue`, `/codex:transfer`, `/codex:status`, `/codex:result`, `/codex:cancel`.

This deliberately spreads some review/audit load off your Anthropic quota onto your Codex subscription. The `routing-refresh` skill keeps the Codex tier IDs in this table fresh too — but only when the toggle file exists, and always under the same diff-then-confirm gate; your `.codex/config.toml` itself is never touched.

## Files

| File | Purpose |
|---|---|
| `agents/scout.md` | haiku, low effort — read-only search/read/summarize; returns conclusions only |
| `agents/executor.md` | sonnet, medium effort — scoped implementation + runs tests/builds; returns short report |
| `agents/architect.md` | opus, high effort — read-only design/debugging/review; returns plan for executor |
| `agents/oracle.md` | top model, xhigh effort (fable 1M or opus) — read-only huge-context analysis & last-resort reasoning |
| `routing-rules.md` | the block installed into `~/.claude/CLAUDE.md` |
| `install.sh` | idempotent user-level installer |
| `hooks/context-meter.sh` | UserPromptSubmit hook — injects `[context: ~N%]` at 70/80/90% band crossings from real transcript usage |
| `tests/run-tests.sh` | sandboxed regression suite for the installer (27 cases — idempotency, content preservation, symlinks, corruption refusal, top-model flag, skill install, Codex toggle preserved, context-meter hook install/merge/remove/logic) |
| `skills/routing-refresh/SKILL.md` | on-demand "refresh the routing policy" skill — live model research + diff-then-confirm |

## Test

```sh
bash tests/run-tests.sh
```

Runs entirely in throwaway `mktemp` HOME directories — never touches your real `~/.claude`.
