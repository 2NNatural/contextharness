---
name: plan
description: Turn a plain-English request into a goal, acceptance criteria and an approach before building. Use at the start of any Standard or High-assurance task - a new feature, an integration, a multi-file change, a vague or ambitious request ("make it better", "build me X") - and whenever it is unclear what "done" means. Not needed for small obvious fixes.
---

# plan — sharpen, then commit to what "done" means

Do this yourself, quickly. The operator is nontechnical: do not hand them a questionnaire.

## 1. Restate
In two or three sentences, say what you believe the operator wants and what problem it
solves for them. If the project has `.claude/harness/LESSONS.md` or `STATE.md`, read them
first (they are short).

## 2. Sharpen (answer these yourself, from the repo)
- What would a strong professional in this field do here that the request did not ask for?
  (Failure handling, the unhappy path, re-run safety, the migration, the empty state.)
- What does the existing code already do? Use `scout` — never design blind. Reuse what
  is there; match its patterns.
- What, other than your own opinion, would show the result is right?

## 3. Ask only what you cannot settle
A question earns its place only if the answers lead to materially different builds AND
you cannot find the answer in the repo or settle it with a quick experiment. Ask at most
once, all questions together, each with your recommended default. Otherwise choose,
record the assumption, and proceed.

## 4. Acceptance criteria
Write 3-7 criteria that a command or an observation can check. Include at least one
failure-path criterion and, for anything touching money, data or security, the invariants
that must always hold (e.g. "total across all accounts never changes"). "Works well" is
not a criterion.

## 5. Approach
- Light work: skip this.
- Standard: a short ordered list — files/areas touched, what can run in parallel (only
  genuinely independent pieces), how each criterion will be checked.
- High assurance: have `architect` produce or challenge the plan before any code is
  written. Settle open technical questions with a small prototype rather than debate.
  Name the irreversible steps and the rollback for each.

## 6. Record and go
Write goal, criteria, assumptions and approach to `.claude/harness/STATE.md` (create the
directory). Tell the operator the mode you chose and the criteria in a few plain lines,
then start — do not wait for approval unless step 3 produced a real question.
