---
name: verify
description: Prove that a change actually works, and set up the project's verification recipe. Use before reporting any non-trivial work as done, when asked "does it work", "test this", "make sure it works", when a project has no reliable way to check changes yet, or when the stop-gate reports that work is unverified.
---

# verify — evidence, not assertion

## Step 1 — Find out how this project is exercised
Run `~/.claude/scripts/harness detect`. It reports project type, real test/build/run
commands, risk signals and whether a verify recipe exists (`verify_recipe`).

## Step 2 — The project recipe (create once, reuse forever)
The recipe is two files in the project:

- `.claude/harness/verify.sh` — the FAST deterministic gate: exits 0 only if the project is
  healthy. It runs automatically before work is reported done, so keep it under ~2
  minutes: the unit tests, a type-check or build if cheap, and a smoke run of the real
  thing (start the server and hit one endpoint; run the CLI on a sample input). Use
  `set -euo pipefail`. No network, no secrets, no deploys, nothing destructive, and it
  must clean up what it starts.
- `.claude/harness/VERIFY.md` — the map for deeper checks, under 60 lines: **Launch** (how
  to start it), **Drive** (how to exercise each main feature: command, request or UI
  path), **Observe** (what proves it worked: output, row counts, a screenshot),
  **Cleanup**, **Gotchas**. Interview the repo, not the operator.

If `verify_recipe` is `none`: write both, then RUN `verify.sh` and see it pass on the
unchanged project. A recipe that was never executed is a draft. Then prove it can fail:
break one thing on purpose, see it go red, undo. Then register it:
`~/.claude/scripts/harness trust-verify`.

If it is `untrusted` (it came with the repository): read it fully first. Trust it only if
it is plainly safe. If it is `changed`: someone edited it after it was trusted — that
needs the operator's decision, never yours; say so.

Never edit `verify.sh` to get a failing change through. Extending it with a new check is
good; weakening it is hiding a defect.

## Step 3 — Verify this change, matched to what it is
| Change | Proof |
|---|---|
| Script / CLI / automation | Run it on representative input AND a bad input; show the output |
| API / backend | Real requests against the running service: success, not-found, invalid input; check state after |
| Web / UI | Load it in a browser (Playwright if available), exercise the flow, screenshot at desktop and mobile widths, check the console for errors, check empty/loading/error states |
| Data pipeline | Row counts in vs out, run twice (no duplicates), a malformed record, totals reconciled against the source |
| Money / trading / accounting | Invariants as property tests over many random cases: conservation, no negative balances, exact integer rounding, idempotency, reconciliation of entries against balances; simulate before anything live |
| Concurrency / state machines | Interleavings and repeated/duplicate events; every state transition, including illegal ones being rejected |
| Migration | Replay on a copy; verify counts and a rollback |

For High-assurance work, hand the finished change to `verifier` (it did not write the
code) with the acceptance criteria and ask it to break it.

## Step 4 — Report
List what was run and what was observed, per acceptance criterion. Anything not exercised
is listed as not verified, with the reason. A passing build is never reported as
"verified".
