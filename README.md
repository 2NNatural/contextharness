# ContextHarness

**Version 2.0.0** · a general-purpose harness for Claude Code (with optional OpenAI Codex
review) that lets a nontechnical operator describe what they want in plain English and get
back work that has been shown to function — at the lowest model cost that does the job.

Three ideas, in order of importance:

1. **Done means demonstrated.** A hook blocks the agent from finishing when code changed
   and nothing proved it works. Unproven work is labelled UNVERIFIED, never "done".
2. **Cheapest capable model for each kind of work.** The main thread orchestrates; reading,
   implementing, testing and deep reasoning go to subagents pinned to the right model, each
   with a disposable context.
3. **Rigor in proportion to risk.** A one-line fix gets a quick check. Money, security,
   data deletion and production get a plan, invariant tests and an independent review.

Start here: **[Operator guide](docs/OPERATOR-GUIDE.md)** (no engineering background needed).

| Document | What it is |
|---|---|
| [docs/OPERATOR-GUIDE.md](docs/OPERATOR-GUIDE.md) | How to use it, what it asks you, what the report words mean |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it is built and why |
| [docs/GAP-ANALYSIS.md](docs/GAP-ANALYSIS.md) | What was studied (pstack, Poteto's methodology, Grok Bot, Claude Code, Codex) and the adopt/adapt/defer/reject decision for every capability |
| [docs/BENCHMARK.md](docs/BENCHMARK.md) | The evaluation suite and measured baseline-vs-upgrade results |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md) | What it does not do, and what to build next |
| [docs/REPORT.md](docs/REPORT.md) | Implementation report: what is implemented, tested, verified, and not |
| [CHANGELOG.md](CHANGELOG.md) | Every meaningful change from v1, and migration steps |
| [CONTEXT.md](CONTEXT.md) · [PROGRESS.md](PROGRESS.md) · [ROADMAP.md](ROADMAP.md) | This repo's own session memory, history and what's-next |

## Install

```sh
git clone https://github.com/2NNatural/contextharness harness
cd harness
./install.sh --recommended
```

Then restart Claude Code and check:

```sh
~/.claude/scripts/harness doctor
```

Requires `bash`, `git` and `jq`. `--recommended` installs the agents, skills, core rules
and all six hooks. A plain `./install.sh` installs everything except hooks and never
touches `settings.json`. The installer auto-detects your strongest model tier (override
with `--top-model fable|opus`), then prints the one `/model` command to run.

| Command | Effect |
|---|---|
| `./install.sh --recommended` | Everything on (best for most people) |
| `./install.sh` | Agents, skills, scripts, core rules; no hooks |
| `./install.sh --with-workflow-hooks` | journal, stop-gate, session-state, ops-guard |
| `./install.sh --with-context-hook` / `--with-destructive-guard` | the two v1 hooks individually |
| `./install.sh --remove-workflow-hooks` (etc.) | remove a hook group |
| `./install.sh --with-codex-agents` | also write the portable core into `~/.codex/AGENTS.md` |
| `./install.sh --rollback` | restore the state from before the last install |
| `./install.sh --uninstall` | remove everything the installer added; your own settings stay |
| `cd <project> && <harness>/install.sh --init-inventory` | create `INTERFACES.md` for audits |

Update with `git pull && ./install.sh --recommended`. Upgrading from v1: see
[CHANGELOG.md](CHANGELOG.md#migration-from-v1).

## How it works

```
operator (plain English)
   │
orchestrator — your strongest model; holds decisions and summaries, not file dumps
   │   always-loaded core (7 KB): routing · rigor modes · definition of done · autonomy · report shape
   │
   ├─ agents     scout (haiku, read) · executor (sonnet, write) · verifier (sonnet, break it)
   │             architect (opus, design/review) · oracle (top model, huge context)
   ├─ skills     plan · verify · review · audit · learn · parallel · routing-refresh   (loaded on demand)
   └─ hooks      journal · stop-gate · session-state · ops-guard · destructive-guard · context-meter
                 (run every time, whether or not the model remembers the rules)
```

### The hooks

| Hook | When it runs | What it does |
|---|---|---|
| `journal` | after every edit and command | Per-session record; warns once when the same command fails three times in a row |
| `stop-gate` | when the agent tries to finish | Runs the project's trusted `verify.sh`, or blocks once if code changed and nothing was run. Bounded; reports UNVERIFIED rather than looping |
| `session-state` | session start, resume, after compaction | Git checkpoint at start; restores task state so nobody has to re-explain |
| `ops-guard` | before shell commands, file reads and file edits | Asks before deploy / publish / infrastructure / force-push / push-to-main / destructive DB / credential reads / switching the harness off or changing recipe trust |
| `destructive-guard` | before shell commands | Blocks deletes and moves that git could not undo |
| `context-meter` | each prompt | Injects a real `[context: ~N%]` reading at 70/80/90% |

All hooks fail open (a broken guard must never wedge a session) and all are tripwires
against accidents, not a security sandbox. `~/.claude/scripts/harness off` disables the
workflow hooks at once; `harness on` restores them.

### Verification recipes

The first time real work happens in a project, the `verify` skill inspects it
(`harness detect`), writes `.claude/harness/verify.sh` (a fast pass/fail check) and
`VERIFY.md` (how to launch, drive and observe the app), runs it, proves it can fail, and
registers it with `harness trust-verify`. From then on the stop-gate runs it before any
work is reported done. A recipe that came with a cloned repository, or was edited after
being trusted, is not run automatically, and only the operator can re-trust it.

### The `harness` CLI

```sh
~/.claude/scripts/harness doctor          # is everything installed and live?
~/.claude/scripts/harness detect          # project type, real test/run commands, risk signals
~/.claude/scripts/harness status          # is this project's verify recipe trusted?
~/.claude/scripts/harness stats --days 30 # real token use per model
~/.claude/scripts/harness lessons list    # recurring mistake classes
~/.claude/scripts/harness undo            # checkpoints taken at session start
~/.claude/scripts/harness off             # kill switch (harness on to restore)
```

## Model routing

| Work | Agent | Model | Default effort |
|---|---|---|---|
| Search, reading, digesting logs/diffs/docs | `scout` | haiku | low |
| Scoped implementation, noisy commands | `executor` | sonnet | medium |
| Trying to break a finished change | `verifier` | sonnet | medium |
| Design tradeoffs, hard root causes, risky-change review | `architect` | opus | high |
| More than one window of material; last resort | `oracle` | strongest available | xhigh |

Bare aliases (`haiku`, `sonnet`, `opus`) follow new model releases automatically. Only
`oracle` carries a pinned ID, single-sourced in `agents/oracle.md`. To re-evaluate the
choices against independent benchmarks and current prices, say "refresh the routing
policy" (the `routing-refresh` skill: live sources only, price/performance frontier per
role, diff shown before anything is applied).

Tune it: edit `description:` (how eagerly an agent is used), `model:` or `effort:` in
`agents/*.md`, or the policy in `routing-rules.md`, then re-run `./install.sh`.

## Audits

Saying "audit", "is this safe", "check this before we go live" or the shorthand
**"syntax + code + unknowns"** runs the Audit Standard: seams one hop past every boundary,
join-key samples from both sides, silent fallbacks, the production-config path, liveness
evidence per link, failure/restart/backpressure/concurrency/time paths, irreversible
actions and their guards, the off switch, negative tests, and explicit unknowns. Every
audit ends with four lists (claims verified/assumed · links with liveness evidence/never
fired · irreversible actions and guards · unknowns); a missing list means the audit is
incomplete, not clean. The standard lives in `skills/audit/STANDARD.md`.

## Optional: Codex as an independent second vendor

Off by default. With OpenAI's Codex CLI installed and logged in:

```sh
touch ~/.claude/codex-routing.on   # on
```

```sh
rm ~/.claude/codex-routing.on      # off
```

When on, the orchestrator may get **read-only** second opinions on genuinely risky changes
and plans through `harness codex-review <class>`, alongside — never instead of — the
Claude review. Codex never writes code here. The four classes (`review`, `plan`,
`security`, `judgment`), their models, efforts and which ones need your confirmation are in
`config/codex-tiers`, the only place Codex model IDs live. Findings from either vendor
count only when reproduced.

After updating the Codex CLI run `./install.sh --refresh-codex` (it restarts the Codex
plugin's resident broker, which otherwise keeps using the old CLI).
`scripts/codex-refresh.sh [--update] [--dry-run] [--probe <id>,...]` does the same by hand
and can probe whether model IDs are accepted. The official
[Codex plugin](https://github.com/openai/codex-plugin-cc) and its `/codex:*` commands
remain available for manual use regardless of the toggle.

## Tests and benchmark

```sh
bash tests/run-tests.sh        # 188 deterministic tests, sandboxed, no model calls
```

```sh
bash tests/live-hooks.sh       # 7 checks against your real Claude Code (a few cents)
```

```sh
bash bench/run.sh --arm v2 --ref WORKTREE --flags "--recommended" && bash bench/report.sh
```

See [docs/BENCHMARK.md](docs/BENCHMARK.md) for what the benchmark measures and what it
found.

## Files

| Path | Purpose |
|---|---|
| `routing-rules.md` | The always-loaded core block installed into `~/.claude/CLAUDE.md` |
| `agents/` | scout, executor, verifier, architect, oracle |
| `skills/` | plan, verify, review, audit (+ `STANDARD.md`), learn, parallel, routing-refresh |
| `hooks/` | the six hooks and their shared library |
| `scripts/harness` | the CLI · `scripts/codex-refresh.sh` Codex CLI/broker refresh |
| `config/codex-tiers` | Codex model/effort table |
| `codex/AGENTS.block.md` | portable core for Codex CLI sessions |
| `templates/INTERFACES.md` | interface-inventory template for audits |
| `install.sh` | idempotent installer with rollback |
| `tests/` | deterministic suite and live contract test |
| `bench/` | benchmark tasks, runner and report |
