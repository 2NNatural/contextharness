---
name: review
description: Independent adversarial review of a specific change or plan by an agent that did not write it. Use for the risky parts of Standard work and all High-assurance work before reporting done, when the operator asks for a second opinion or a code review of a diff, and to triage review comments from another tool or person.
---

# review — independent, evidence-bound

You dispatch and gate. You do not review your own work and you do not soften verdicts.

## When NOT to review
Light changes with an obvious passing check. A second look there costs more than it finds.

## Step 1 — Scope
The change is `git diff` against the checkpoint or base branch, plus the acceptance
criteria from `.claude/harness/STATE.md`. Reviewers get the diff, the criteria and
read access — not your reasoning or your opinion of the change.

## Step 2 — Dispatch
- **Design/logic review:** `architect` (effort high). Brief: "Find defects that would
  make this wrong, unsafe or regress existing behaviour. For each: file:line, the
  concrete inputs/state that trigger it, and how to observe it. Check reverse
  dependencies (who else uses what changed). No style, naming or hypothetical-future
  findings. 'No findings' is a valid answer."
- **Behavioural attack (High assurance, or anything with a runtime):** `verifier` in
  parallel: "Try to break this by running it. Edge cases, failure paths, repeated and
  out-of-order operations, the criteria's negatives."
- **Cross-vendor (only if `~/.claude/codex-routing.on` exists, and only for genuinely
  risky changes or plans):** write the brief plus the diff to a scratch file and run
  `~/.claude/scripts/harness codex-review <class> <file>` where class is `review` (risky
  change), `plan` (high-stakes plan), `security`, or `judgment` (subjective design or
  mechanism flaws in code that may be functionally correct). `security` and `judgment`
  print CONFIRM-NEEDED: ask the operator once, then re-run with `--yes`. Codex is
  read-only here and never fixes anything. If the command prints CODEX-OFF,
  CODEX-UNAVAILABLE or CODEX-FAILED, continue on the Claude verdict and tell the operator
  in one line.

## Step 3 — Gate the findings
For every finding, reproduce it: run the command or write the failing test. Keep what
reproduces. A finding you cannot reproduce is listed as "unconfirmed", not acted on and
not silently dropped. When reviewers disagree, the reproduction decides — not the count
of models on each side, and not the more confident tone.

## Step 4 — Resolve
Confirmed defects go to `executor` with the reproduction as the acceptance test. Re-run
the project verify recipe. A fix large enough to change the design gets re-reviewed; a
small one does not.

## Step 5 — Report
Confirmed and fixed · confirmed and open · unconfirmed · reviewers used. If a reviewer
could not run, say so; do not present one opinion as two.
