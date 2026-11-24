---
name: learn
description: Turn a mistake into a prevention mechanism instead of another instruction. Use when the operator corrects you or catches a defect you reported as done, when the same failure happens twice, after a failed or reverted change, or when asked to "make sure this never happens again", run a postmortem, or reflect on a session.
---

# learn — remove the correction, do not repeat it

## 1. Root cause
State the mechanism, not the symptom: what was done, what should have been done, and why
the wrong path was the easy one (missing check, misleading name, absent test, unclear
contract, the nearest example was wrong).

## 2. One-off or a class?
Record it: `~/.claude/scripts/harness lessons add <class-slug> project "<one line>"`.
It prints how many times this class has been seen. Seen once and low-impact: fix the
instance, stop here. Seen twice, or costly once: continue.

## 3. Prevent at the strongest level that fits (top of the list first)
1. **Architecture** that makes the wrong state impossible (one owner per piece of state,
   one way to do the task).
2. **Types, schemas, interface contracts.**
3. **Database or application constraints.**
4. **An automated test or property check** that fails on the original mistake.
5. **CI or lint rule** whose error message says what to do instead.
6. **A project skill or the verify recipe** (add the check to `verify.sh`).
7. **A written note** — last resort; nothing fails when a note is ignored.

Proportion matters: do not redesign a module to prevent a typo.

## 4. Prove the prevention
Reintroduce the original mistake (or replay the bad input) and watch the new mechanism
catch it. A check you have never seen fail proves nothing. Then restore.

## 5. Record at the right scope
- **Project:** one line in `.claude/harness/LESSONS.md` — class, prevention, where it is
  enforced. Hard cap 30 lines: to add one, merge or delete one. A lesson now enforced by a
  test or type is deleted from the notes — the code remembers it.
- **Universal** (would apply to any project): re-record with scope `global`. Run
  `~/.claude/scripts/harness lessons propose`; a class seen in two or more projects is a
  candidate for a harness change.

## Limits — these are not yours to change
You may not edit the harness's installed hooks, any `verify.sh` trust, `~/.claude/CLAUDE.md`
or the harness's global skills as a "lesson". Harness-level changes are made only in the
harness repository, on a branch, with a test or benchmark case that fails before the
change and passes after, and they ship only when the operator approves. Tell the operator
a candidate exists; do not apply it.
