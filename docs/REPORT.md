# ContextHarness v2 — implementation report

2026-11-24 · branch `claude/pensive-keller-vedmcz` · baseline v1 = `34eb046`

## Status in one paragraph

v2 is implemented, tested and committed on a development branch. Nothing was merged,
published or deployed. The deterministic suite passed 133/133 on Linux at the v2 commit.
After three rounds of review fixes it passes on Windows (186 passed, 0 failed, 2 skipped); it has not been re-run
on Linux. The live contract test passed 7/7 against the real Claude Code CLI on Linux, before
it gained its auth preflight and ops.log check. It passed 7/7 again on Windows Git Bash
(Claude Code 2.1.322, haiku) on 2026-11-24, with the second-round code and again with the final third-round code. The benchmark shows **no measurable
correctness gain over v1 or over no harness at all** on its six small tasks (every arm is
at or near a perfect score) and a **modest cost increase** for v2. What v2 demonstrably
adds is enforcement and recovery mechanisms that did not exist before, a 48% smaller
always-loaded instruction block, and the removal of a v1 guard behaviour that caused a
failure. Whether those mechanisms improve outcomes on real, long work is not yet measured.

## Using the words precisely

| Item | Implemented | Tested | Verified live | Notes |
|---|---|---|---|---|
| `journal`, `stop-gate`, `session-state`, `ops-guard` hooks | yes | yes (unit) | yes (`tests/live-hooks.sh`, Linux; and Windows on 2026-11-24 with the ops.log check: journal on a real Write, stop-gate block, recipe-mode block, ops-guard ask with deploy.sh not run, STATE.md re-injected) | Loop-detector injection is unit-tested only. Never fired live: the ops-guard ask on Write/Edit tools, the `harness untrust-verify` ask. The Windows live run predates the third fix round |
| Git-aware `destructive-guard` | yes | yes | yes (benchmark: 0 denials after fix) | |
| Installer: `--recommended`, `--rollback`, `--uninstall`, `--with-codex-agents` | yes | yes | sandbox installs only | Not run on the operator's own machine |
| `harness` CLI (`detect`, `trust-verify`, `status`, `lessons`, `doctor`, `off`/`on`) | yes | yes | used in live test and benchmark | |
| `harness stats`, `harness undo` | yes | no dedicated test | run by hand once | |
| `harness codex-review` | yes | yes, against a stub | yes — all four tiers on Windows, codex-cli 0.162.1: `review` and `plan` on 2026-11-23 (stdin path with a 73 KB prompt), `security --yes` and `judgment --yes` (gpt-6-astra) on 2026-11-24; the fallback retry ran live on 2026-11-24 | The quality of the reviews is not measured |
| Skills `plan`, `verify`, `review`, `learn`, `parallel` | yes | frontmatter and consistency only | partly — the benchmark sessions ran with them available; `verifier` was dispatched on the money task | Skills are prose; their effect on outcomes is not isolated |
| `verifier` agent | yes | n/a | dispatched in benchmark runs | |
| Core block rewrite (rigor modes, definition of done, reporting) | yes | size budget + consistency | benchmark reports followed the Done/Checked/Not checked shape | |
| Portable Codex core (`AGENTS.md` block) | yes | install test | **no** | Never loaded by a real Codex session |
| Benchmark suite | yes | graders verified to fail on untouched fixtures | 84 real sessions run | At ceiling; see BENCHMARK.md |
| macOS / Windows | — | Windows: unit suite 186 passed, 0 failed, 2 skipped | Windows: `tests/live-hooks.sh` 7/7 (2026-11-24, second- and third-round code); macOS: **no** | bash 3.2 / BSD tools never run |
| Deployed / merged | **no** | | | Awaiting the operator's decision |

## Process followed

| Step asked for | What happened |
|---|---|
| 1. Research | pstack read from source; Poteto digest and both Grok Bot guides read in full; Claude Code docs plus live-captured hook payloads; Codex from its GitHub source. arXiv and OpenAI's docs site were unreachable — those claims are marked weak in GAP-ANALYSIS.md |
| 2. Audit | Every file of v1 read; suite run; claims vs reality table in GAP-ANALYSIS.md. The harness was not installed in the environment available, so "installed environment" was inspected via sandbox installs |
| 3. Baseline | v1 at `34eb046` benchmarked (24 sessions) alongside a no-harness control (24 sessions) |
| 4-5. Prioritise, design | docs/ARCHITECTURE.md |
| 6. Independent challenge | Done by a separate Claude reviewer; its material findings were resolved or explicitly declined (table in ARCHITECTURE.md). The Codex half was done on 2026-11-23: 15 findings, all confirmed; a second review of the fixes (Claude + Codex) found partial fixes, addressed in a second round; a third review found regressions in that round, fixed in a third, convergence-only round. Per-finding status (resolved / mitigated with documented residue) in ARCHITECTURE.md |
| 7-8. Resolve, implement on a branch | Two commits on the development branch |
| 9. Test capabilities | 70 new deterministic tests; they caught two real defects before any live use (a field-parsing bug that silently disabled the gate; evidence ordering within the same second) |
| 10. Integration tests and benchmark | Live contract test; 84 benchmark sessions total |
| 11. Resolve regressions | The benchmark exposed guard false-positives in v2 (heredocs, command boundaries, scratch variables); fixed, tested, re-measured: denials 5 → 0, cost −22% |
| 12. Remove redundancy | Core block halved; duplicate Codex ID tables collapsed to one file; duplicated installer hook code replaced by one function; three hardcoded top-model IDs derived from one source |
| 13. Documentation | README, operator guide, architecture, gap analysis, benchmark, limitations, changelog |
| 14. Report | This file |

## What needs the operator

1. **Decide whether to merge.** Given the benchmark, a reasonable position is: adopt v2 for
   its enforcement and recovery, accept roughly 10% more cost on small tasks, and judge it
   on real work over a couple of weeks. `./install.sh --rollback` undoes it.
2. **Run `tests/live-hooks.sh` on a Mac and on Linux** with the
   third-round code (it passed 7/7 on Windows with both the second- and third-round code). Still never
   done: macOS / bash 3.2; a real Linux re-run; an ops-guard ask on Write/Edit tools and the
   `harness untrust-verify` ask in a live session; `bench/run.sh` under `h_run_bounded`;
   upgrading the real `~/.claude` install, which is still v1.
3. **Feed the benchmark** with real defects so the next comparison can actually
   discriminate.

## Environment side effects of this work

- A personal cloud environment named `contextharness` was created (with approval) allowing
  two extra hosts, `thoughtfulbits.ai` and `x.ai`, so the requested articles could be read.
  It can be deleted or kept for future sessions on this repository.
- The benchmark and live tests made 84 + ~10 small headless model calls (about $6 of
  estimated usage in total).
