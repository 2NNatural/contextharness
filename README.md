# Model-Routing Harness for Claude Code

Work in **one long-lived Claude Code thread**, never switch models manually, and pay the cheapest rate for each kind of work. The main thread acts as an orchestrator; token-heavy work (reading code, running tests, deep analysis) is delegated to subagents pinned to cheaper models, each with its own disposable context window.

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

Note: both the **orchestrator** (your thread) and the **oracle** subagent run on your strongest available model tier. The installer asks which tier you have — fable (1M context) or opus — or you can pass `--top-model fable`/`--top-model opus`. The oracle gives that top model a fresh isolated context for huge jobs without polluting the orchestrator's lean context. Escalation ladder: scout → architect → oracle.

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

The installer will ask which model tier you have access to, or you can pass a flag:

```sh
./install.sh --top-model fable   # default — fable 1M context (oracle uses claude-fable-5[1m])
./install.sh --top-model opus    # if fable is unavailable — oracle uses opus instead
```

Then set the orchestrator model once to match your chosen tier:

- **fable:** `/model claude-fable-5[1m]` or in `~/.claude/settings.json`: `{ "model": "claude-fable-5[1m]" }`
- **opus:** `/model opus` or in `~/.claude/settings.json`: `{ "model": "opus" }`

## Update

```sh
git pull && ./install.sh --top-model fable   # or --top-model opus — pass the same tier you used at install
```

Idempotent — the marked block is replaced in place, agents are overwritten (re-applying your chosen tier to oracle).

## Tune it

- **Delegation too timid / too eager?** Edit the `description:` line in the relevant `agents/*.md` — that's what the orchestrator matches against when deciding to delegate. Stronger wording ("Use PROACTIVELY for ALL …") = more delegation.
- **Change a model:** edit the `model:` line (`haiku`, `sonnet`, `opus`, `fable`, or a full model ID like `claude-haiku-4-5`).
- **Change routing policy:** edit `routing-rules.md`.

Re-run `./install.sh` after any change.

## Files

| File | Purpose |
|---|---|
| `agents/scout.md` | haiku — read-only search/read/summarize; returns conclusions only |
| `agents/executor.md` | sonnet — scoped implementation + runs tests/builds; returns short report |
| `agents/architect.md` | opus — read-only design/debugging/review; returns plan for executor |
| `agents/oracle.md` | top model (fable 1M or opus) — read-only huge-context analysis & last-resort reasoning |
| `routing-rules.md` | the block installed into `~/.claude/CLAUDE.md` |
| `install.sh` | idempotent user-level installer |
| `tests/run-tests.sh` | sandboxed regression suite for the installer (17 cases — idempotency, content preservation, symlinks, corruption refusal, top-model flag) |

## Test

```sh
bash tests/run-tests.sh
```

Runs entirely in throwaway `mktemp` HOME directories — never touches your real `~/.claude`.
