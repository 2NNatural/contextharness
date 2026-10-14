---
name: routing-refresh
description: Refresh the model-routing harness's policy to the CURRENT Claude model lineup. Use when the user says "refresh the routing policy", "update routing models", runs /routing-refresh, or asks to re-check which Claude models each agent/role should use. Researches the live Anthropic model landscape, proposes routing changes, shows a diff, and applies only after explicit confirmation.
---

# Routing Policy Refresh

You refresh this repo's model-routing policy so each role points at the best
CURRENT Claude model. You research the live model lineup, propose changes,
show a before/after diff, and apply ONLY after the user approves. Then you
re-run the installer.

## Absolute rules (read first)

1. **Live sources only — never use model knowledge from memory.** Every model
   ID, price, and context-window number you cite MUST come from a page you
   fetched in THIS session via WebSearch/WebFetch (or the `claude-api` skill).
   If you did not fetch it this session, you do not know it. **Performance
   claims must come from an independent benchmark board fetched this session
   (Step 2c).** Provider positioning language ("most capable", "most
   efficient", "for focused tasks", tier names like haiku/sonnet/opus/luna/sol/
   astra) is explicitly NOT a basis for routing; vendor model cards and blogs
   are not performance evidence (vendor pricing pages are fine for prices).
2. **Never invent or guess a model ID.** Model IDs (e.g. `claude-opus-4-5`,
   `claude-fable-5`) must be copied verbatim from fetched official content. If
   you cannot find an exact ID in a fetched source, treat it as unknown and do
   NOT write it anywhere. Plausible-looking IDs are forbidden.
3. **Diff-then-confirm, always.** Never edit any file before showing the user a
   before/after diff and receiving explicit approval ("yes"/"apply"/equivalent).
4. **Safe scope.** You may edit ONLY these files:
   - `routing-rules.md` — the routing table (the `Model` column values).
   - `agents/oracle.md` — the pinned top-model ID on the `model:` line only.
   - `README.md` — keep its model references in sync with the above.
   You must NOT touch `agents/scout.md`, `agents/executor.md`,
   `agents/architect.md` — those use bare aliases (`haiku`, `sonnet`, `opus`)
   that Claude Code resolves and auto-updates on its own. Changing them is out
   of scope and forbidden.
5. **Inconclusive research → abort with zero edits.** If after a genuine effort
   you cannot confirm the current lineup from live sources (no network, pages
   unreachable, contradictory data you can't resolve), STOP, tell the user
   exactly what was inconclusive, and make NO file changes.
6. **Codex refresh is toggle-gated.** If (and only if) `~/.claude/codex-routing.on`
   exists (`test -e`), ALSO research the current OpenAI Codex model lineup —
   official OpenAI Codex docs only (the Codex models page and changelog) — and
   propose updates to the GPT tier IDs and effort levels in the "Optional
   cross-vendor tools (Codex — toggle-gated)" section of `routing-rules.md`
   and the matching README table, under the SAME diff-then-confirm gate.
   Present Codex changes clearly separated from Claude changes in the diff.
   Never invent Codex model IDs (same verbatim-from-fetched-source rule as
   Claude IDs). If the toggle file is absent, do not research or touch
   anything Codex. Never edit `.codex/config.toml` or the toggle file itself.

7. **Keep the refresh cheap — delegate the research legwork.** Do not do the
   bulk page-fetching and extraction in the expensive main-thread context.
   Spawn a cheap subagent (e.g. `general-purpose` with a `haiku` model
   override at `low` effort; use `sonnet` only if haiku's extraction proves
   unreliable) to fetch the official pages and return ONLY a compact table of
   model IDs, tiers, context windows, prices, and source URLs. The main
   thread then cross-checks that table, builds the diff, and runs the
   confirmation gate. Full page dumps must never land in the main thread.

## Procedure

### Step 1 — Detect the user's strongest available tier (no prompting)
Probe the API for the strongest model; do not ask the user.
- Attempt a minimal probe of `claude-fable-5` (e.g. a 1-token completion) using
  whatever API access is available this session (the `claude-api` skill if
  present, otherwise a minimal `claude -p --model claude-fable-5` call).
- If it succeeds, the tier is **fable** and the installer flag is `--top-model fable`.
- If it fails (model not available to this account), fall back to **opus** and
  flag `--top-model opus`.
- Record the detected tier; you will pass it to the installer in Step 6.
- If you cannot probe at all (no API access), note it and default to **fable**,
  but tell the user the tier was assumed, not confirmed.

### Step 2 — Research the current Claude lineup (LIVE)
Use WebSearch + WebFetch (and the `claude-api` skill if available) against
OFFICIAL Anthropic sources only:
- the Anthropic models/overview docs page,
- the Anthropic pricing page,
- the Anthropic news/release page.
Cross-check the model list across at least two of these. For each currently
available model, extract verbatim: the exact **model ID**, its **tier/alias**
(haiku/sonnet/opus/fable or successor names), **context window**, and **price**.
Capture the source URL for each fact. If the `claude-api` skill is available,
use it to confirm IDs are real and current; prefer it as the source of truth
for IDs. Do NOT proceed past this step on memory alone — if WebSearch/WebFetch
returned nothing usable, go to the abort path (rule 5). Per rule 7, delegate
the fetching/extraction to a cheap subagent and work from its compact table —
do not pull full pages into the main thread.

### Step 2b — Research the Codex lineup (ONLY if the toggle is on)
If `~/.claude/codex-routing.on` exists: via the same cheap-subagent delegation
(rule 7), fetch the official OpenAI Codex models documentation and extract the
current GPT tier IDs (e.g. the current equivalents of sol/terra/luna),
pricing, and any reasoning-effort levels supported. If the toggle is absent,
skip this step entirely. Codex findings feed a SEPARATE part of the Step 5
diff: updates to the Codex section of `routing-rules.md` and the README table
only. All rule-6 restrictions apply.

**Mandatory live probe — BEFORE building the diff.** Run
`~/.claude/scripts/codex-refresh.sh --probe <id1>,<id2>,...` with EVERY Codex
model ID you intend to propose (it also restarts the plugin's resident broker,
which otherwise keeps using the CLI version it was spawned with). Adopt ONLY
IDs printed as `ACCEPTED <id>`. For each `REJECTED <id>: <error>`, record the
exact error line in the Step 5 report and leave that ID out of the diff. Do
NOT attribute a rejection to the user's account, plan, or entitlement unless a
fetched official OpenAI doc states that restriction — otherwise write
"unverified cause". If the script is missing, run `./install.sh` first; if
`codex` is not installed, no Codex ID can be verified — propose no Codex ID
changes.

**Effort ceiling:** write `xhigh` as the maximum Codex reasoning effort
anywhere in the table — the Codex CLI rejects `max` (`Unsupported reasoning
effort "max"`), even if a docs page lists it.

### Step 2c — Independent benchmarks (mandatory)
Via the same cheap-subagent delegation (rule 7), for EVERY candidate model —
all current Claude models from Step 2 and, if the Codex toggle is on, all
Codex-ACCEPTED GPT models from Step 2b — fetch scores from INDEPENDENT boards:
- Artificial Analysis: Intelligence Index, Coding Index, blended $/M price,
  output speed,
- LMArena: overall, coding, and WebDev Elo,
- SWE-bench Verified,
- Aider polyglot,
- LiveBench,
- Terminal-Bench.
The subagent returns ONLY a compact table: model, board, score, board
last-updated date, source URL. Rules:
- A model counts as **rated** only with scores from at LEAST TWO independent
  boards. A model absent from all boards is **unrated**: never route to it by
  tier name alone.
- Vendor model cards/blogs are NOT performance evidence. Prices may come from
  vendor pricing pages or Artificial Analysis.
- Record each board's last-updated date; a board older than 60 days is flagged
  **stale** in the report.
- If fewer than two boards can be fetched for the top-model decision, abort per
  rule 5 (no edits).

### Step 3 — Map findings onto the harness roles (Pareto frontier per task)
The harness has five routing slots plus the Codex task rows. Choose each by
measuring the price/performance Pareto frontier of the rated models for that
task class, never by tier name. Apply this procedure ONCE per task class
(search/summarize, implementation, hard reasoning/review, oracle, and each
Codex task row):
1. **Benchmark axis.** Name the board, or a stated average of 2+ boards,
   relevant to the task. Defaults: implementation = mean of SWE-bench Verified
   + Aider polyglot; search/summarize = Artificial Analysis Intelligence Index
   (output speed as tiebreak); reasoning/review = mean of Coding Index +
   LMArena coding. State the axis used.
2. **Price axis.** Blended $/M from Artificial Analysis, or (input + 3 x
   output)/4 from vendor pricing. State which.
3. **Frontier.** A model is dominated if another model scores >= it AND costs
   <= it, strictly better on at least one. List the non-dominated set in order
   of price.
4. **Pick from the frontier by the task's price tolerance:**
   - **scout** (search/summarize, high volume) = cheapest frontier point whose
     score >= 70% of the frontier max.
   - **executor** (implementation) = the frontier point with the best score
     within 10 points of the frontier max, cheapest among ties.
   - **architect** (hard reasoning, read-only) = frontier max, unless a
     frontier point within 3 points of it is cheaper, then that one.
   - **oracle / orchestrator top model** = frontier max on score (and largest
     context) regardless of price. THIS is the only role with a pinned full
     model ID, in `agents/oracle.md`. Keep the fable/opus tier detection from
     Step 1 and use the verbatim ID from Step 2.
   - **Codex review / second opinion (toggle on)** = cheapest frontier point
     within 5 points of the frontier max on the review axis.
   - **Codex security / judgment audits (toggle on)** = frontier max
     (operator-confirmed). Effort ceiling `xhigh`.
5. **Print the frontier table per task** in the Step 5 diff (see there).
Consider only rated models.

**Alias drift check.** scout/executor/architect stay bare aliases in the agent
files (rule 4 forbids editing them). For each, probe the alias with
`claude -p --model <alias> --output-format json` and read `modelUsage` to learn
which full model ID it currently resolves to. If the frontier-chosen model
differs, REPORT it, propose pinning the full model ID in the routing table's
`Model` column, and flag it for the user — the table may diverge from the alias
when the numbers say so. The agent files remain untouched.

Note which slots actually changed. If nothing changed, report "policy already
current" and stop (no diff, no edits).

### Step 4 — Build the proposed edits (in memory, not on disk yet)
For each in-scope file, construct the exact new content:
- `routing-rules.md`: update only the `Model` column cells in the routing
  table whose alias/name changed. Leave structure and prose intact.
- `agents/oracle.md`: replace ONLY the value on the `model:` line.
  **Preserve the `[1m]` context-window suffix when the base ID changes** — if
  the current line is `model: claude-fable-5[1m]` and the new fable base ID is
  `claude-fable-6`, the result is `model: claude-fable-6[1m]`. Re-attach the
  same `[...]` suffix that was present; only swap the base ID. If the detected
  tier is opus, the line becomes `model: opus` with NO suffix (matching how the
  installer writes the opus variant).
- `README.md`: update any literal model IDs / `--top-model` examples / the
  Files-table descriptions so they match the new policy. Do not touch unrelated
  prose.

### Step 5 — Show the diff and GET CONFIRMATION (hard gate)
Present a clear before/after for every file you intend to change:
- a unified-style diff or an explicit "OLD → NEW" per line,
- a one-line rationale per change citing the fetched source URL,
- the detected tier and how it was detected,
- **per task**: the full frontier table (ALL rated candidates, benchmark-axis
  score, price, dominated-by or "frontier") so the operator can see the curve;
  then the chosen model, the runner-up, the two+ boards, scores and price that
  decided it, and the per-$ figure; plus stale-board flags and alias-drift
  findings. A choice with no benchmark behind it is NOT allowed in the diff.
Then ask: "Apply these changes? (yes/no)".
- Do NOT edit any file until the user explicitly approves.
- If the user says no or anything ambiguous, make zero changes and stop.

### Step 6 — Apply, then re-run the installer
Only after explicit approval:
1. Write the edits to the in-scope files exactly as shown in the diff.
2. Re-run the installer to propagate into `~/.claude`, passing the detected
   tier: `./install.sh --top-model <fable|opus>` from the repo root.
3. Report what changed, the installer's result, and remind the user to set
   their orchestrator `/model` to match if the top tier changed.

## Failure modes (handle explicitly)
- **No network / fetch fails:** abort per rule 5; no edits.
- **Found a model name but no exact ID:** treat ID as unknown; do not write it;
  if it blocks the top-model decision, abort.
- **Boards unreachable or stale (Step 2c):** report, no edits.
- **Model absent from all boards:** treat as unrated; never route to it by tier
  name alone.
- **Probe can't run:** assume fable, say so, continue (research is independent
  of the probe).
- **Research contradicts itself across sources:** prefer the `claude-api` skill,
  then the pricing/models docs over news; if still unresolved, abort.
- **User declines at the gate:** zero edits, stop.
- **Codex probe rejects an ID (Step 2b):** drop that ID, quote the exact error,
  label the cause "unverified" unless a fetched official doc states it; never
  propose effort `max` (CLI ceiling is `xhigh`).
