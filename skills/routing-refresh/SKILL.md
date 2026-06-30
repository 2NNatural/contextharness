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
   If you did not fetch it this session, you do not know it.
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
returned nothing usable, go to the abort path (rule 5).

### Step 3 — Map findings onto the harness roles
The harness has five routing slots. Decide the best CURRENT model for each,
justified by the fetched data:
- **scout** → cheapest fast tier (currently the haiku line). Bare alias — DO
  NOT edit the agent file; only reflect the alias name in the routing table if
  the alias itself changed.
- **executor** → mid tier (currently the sonnet line). Bare alias — same rule.
- **architect** → strong reasoner (currently the opus line). Bare alias — same rule.
- **oracle / orchestrator top model** → strongest + largest context. THIS is
  the only role with a pinned full model ID, in `agents/oracle.md`. Choose
  fable vs opus base per the Step 1 tier detection, using the verbatim ID from
  Step 2.
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
- the detected tier and how it was detected.
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
- **Probe can't run:** assume fable, say so, continue (research is independent
  of the probe).
- **Research contradicts itself across sources:** prefer the `claude-api` skill,
  then the pricing/models docs over news; if still unresolved, abort.
- **User declines at the gate:** zero edits, stop.
