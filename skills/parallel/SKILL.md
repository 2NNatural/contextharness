---
name: parallel
description: Split a large task into independent pieces built in isolated git worktrees and integrate them safely. Use only when work divides into parts that touch different files and do not depend on each other's unfinished output - for example several unrelated features, a migration across many independent modules, or competing prototypes of one design.
---

# parallel — isolation first, and only when it pays

## Should this be parallel at all?
Multi-agent work costs several times the tokens of one agent. It pays for breadth
(independent pieces) and loses on coupled work. Go parallel only if ALL hold:
- three or more pieces, each a meaningful chunk of work;
- each piece owns a disjoint set of files;
- no piece needs another's unfinished output;
- there is a check per piece.
Otherwise use one `executor`, sequentially.

## Protocol
1. **Contract first.** Anything shared (an interface, a schema, a type) is decided and
   committed BEFORE fan-out. Shared files have exactly one owner.
2. **One worktree per worker.** Spawn each `executor` with `isolation: worktree`. Note
   that a worktree starts from the repository's default branch unless the project sets
   `worktree.baseRef` to `head` — commit the contract first so workers see it.
3. **Brief each worker** with: its files (and that everything else is read-only), the
   contract, its acceptance criteria, and the required report: `PASS | ISSUES | BLOCKED`,
   the commit SHA, and the commands it ran.
4. **Track in STATE.md**: piece, owner, status, branch. A worker that returns without the
   SHA and commands it was asked for is re-run once; after that it is a gap, and a gap is
   not a pass.
5. **Judge by side effects, not status text**: does the branch exist, does its check pass
   when YOU run it.
6. **Integrate one at a time** onto the working branch, running the project verify recipe
   after each merge. A conflict means the split was wrong: resolve it in one place with
   one owner, do not fan it back out.
7. **Final pass** on the integrated result: full verify, then `review` for Standard and
   above. Remove finished worktrees.

For competing designs: write the scoring rubric before spawning, keep it from the
candidates, take the winner and graft only proven pieces from the others.
