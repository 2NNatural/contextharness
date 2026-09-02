---
name: audit
description: Run a full Audit Standard audit of a target (a diff, a path, a module, or the current branch). Use when the user says "audit", "review this", "check this", "verify this", "is this safe", runs /audit, or uses the shorthand "syntax + code + unknowns". Extracts the Audit Standard verbatim from the installed CLAUDE.md, reads the project's INTERFACES.md, gathers liveness evidence via scout, and routes the verdict to a read-only architect.
---

# /audit — Audit Standard runner

You orchestrate one audit. You do NOT audit anything yourself: you assemble the
prompt, dispatch, and gate the result. The verdict comes from `architect`
(read-only, effort high or above) and is returned to the user UNCHANGED.

## Step 0 — Resolve the target

The target is a diff, a path, a module, or "current branch" (=
`git diff $(git merge-base HEAD main)..HEAD` plus the changed-files list). If the
target is ambiguous, ask ONE question and stop. Never guess a target — auditing
the wrong thing and reporting clean is the worst outcome.

## Step 1 — Extract the Audit Standard verbatim (never from memory, never a copy)

The Audit Standard is single-sourced in `routing-rules.md` (installed inside the
`<!-- model-harness:start/end -->` block of `~/.claude/CLAUDE.md`). Never paraphrase
it, never rely on a memorized or previously-pasted copy — extract it fresh, every
run, from the installed file. Prefer the installed `~/.claude/CLAUDE.md`:

```
awk '/^## Audit Standard/ {inblk=1; print; next}
     inblk && /^<!-- model-harness:end -->/ {exit}
     inblk && /^## / {exit}
     inblk {print}' ~/.claude/CLAUDE.md
```

Fallback (installed file missing or empty): run the identical `awk` pattern against
`./routing-rules.md` in the harness repo.

Then run an integrity check: the extracted text must contain ALL of `Required
output shape`, `Pre-live gate`, `Claims verified`, `Unknowns and how to close
them`. If any are missing, or the extraction is empty, ABORT with:

> Audit Standard not found in ~/.claude/CLAUDE.md — run ./install.sh from the
> harness repo and retry.

Running a degraded audit is itself a silent fallback, which the standard forbids.

## Step 2 — Read the interface inventory (if present)

Look for `./INTERFACES.md`, then `docs/INTERFACES.md`. If neither exists, note its
absence and that `--init-inventory` creates one, continue the audit, and record the
missing inventory as an Unknown. Include the inventory verbatim in the `architect`
prompt.

## Step 3 — Fan out `scout` calls for liveness evidence (cap: 8)

Dispatch one `scout` per link, as a single parallel-dispatch message. If there are
more than 8 links, distribute them evenly across exactly 8 scouts (multiple links
per scout). If there are more than ~48 links (more than 6 per scout), STOP and
offer the user either narrowing the audit target or routing to `oracle` per the
routing note in the standard. Never silently drop a link — any link that ends up
uncovered must be named explicitly in Unknowns.

Verbatim scout prompt template (fill in the link):

> For the link `<link>` (mechanism: `<mechanism>`), determine liveness. Search
> logs, journals, and any other observable record for evidence this link has
> actually executed. Do not read source code to infer that it "should" run. Only
> observed output counts. Return exactly:
> VERDICT: LIVE | NEVER-FIRED | NO-EVIDENCE-SOURCE
> EVIDENCE: the single most recent matching line (≤200 chars) with file/journal +
> timestamp, or "none"
> SAMPLE: one real join-key value observed in that evidence, or "none"

## Step 4 — Dispatch `architect`, effort high (xhigh if multi-system)

Build the `architect` prompt in this exact order:

1. The standard, pasted verbatim, prefixed: "Apply this standard in full to the
   audit below. All five sections A–E are in scope. End with the four required
   lists, present even when empty."
2. The target (diff / path / module / current-branch diff).
3. The inventory verbatim, or "no INTERFACES.md present" if Step 2 found none.
4. The liveness table gathered in Step 3, followed by: "These are
   observed-liveness findings gathered by scouts. Treat NEVER-FIRED and
   NO-EVIDENCE-SOURCE links as broken per rule 6."
5. "Return the audit as your final message. Do not summarize it."

## Step 5 — Gate the verdict (hard gate)

Return the architect's verdict UNCHANGED. Check that all four required lists are
present (Claims verified/assumed; Links with liveness evidence/never fired;
Irreversible actions and their verified guards; Unknowns and how to close them).

- All four present → return the verdict as-is.
- Any missing → you may NOT report the change as clean/passed/no-issues. Re-dispatch
  `architect` ONCE with: "Your verdict is missing these required lists: <names>.
  Return the complete audit including them." If they are still missing after the
  retry, return the verdict prefixed with the header:

  > AUDIT INCOMPLETE — verdict is missing required list(s): <names>. Treat this as
  > unverified, not as clean.

Never write the missing lists yourself — you did not do the analysis.

## Step 6 — Codex second opinion (toggle-gated; alongside, never instead)

Check `test -e ~/.claude/codex-routing.on`.

- Absent → do nothing Codex-related (you may mention it exists, but do not invoke
  it).
- Present → you MAY additionally run a read-only second opinion, per the Codex ON
  table: security/vulnerability audit → `gpt-5.6-sol` effort high, confirm with the
  user first; high-level judgment audit (subjective design/mechanism flaws — math,
  market/execution mechanisms, formal-verification parameters, algorithm and
  data-model design, efficiency and data audits) → `gpt-5.6-sol` effort xhigh,
  confirm with the user first; otherwise, adversarial review of a risky change →
  `gpt-5.6-terra` effort medium, no confirm needed.

  Spawn `codex:codex-rescue` via the Agent tool, strictly read-only. If the spawn
  fails, say so in one line and return the Claude verdict alone. Present both
  opinions separately, clearly labelled; never merge them; never let the Codex
  opinion downgrade a Claude finding.

## Failure modes (handle explicitly)

- Standard not extractable → abort per Step 1. Never audit from memory.
- No INTERFACES.md → proceed, record as an Unknown.
- Scouts find no log or journal at all for a link → NO-EVIDENCE-SOURCE, treated as
  broken, not unknown; pass that through to `architect` unchanged.
- Inventory too large (>~48 links) → stop, offer the user narrowing or `oracle`.
- Target ambiguous → ask one question, stop.
