## Audit Standard (all projects, all code)

Applies to EVERY request containing "audit", "review", "check", "verify", "is this safe",
or the shorthand **"syntax + code + unknowns"**. That shorthand EXPANDS to this whole
standard; the owner never has to ask for these scopes by name. Origin: a production
post-mortem in which four failures each lived *between* components that had audited clean
in isolation (a control wrote a flag no one read; a "live" channel was dead code silently
replaced by a fallback; a reconciler absorbed state it did not own; a capped log pipe
killed connection handlers). Component-scoped diff review cannot see these.

The three shorthand words map as follows. "Syntax" = sections A and C below. "Code" =
sections B and D. "Unknowns" = section E. All five sections are always in scope.

### A. Seams — the part no diff review covers
1. **Enumerate every boundary** of the audited code: files written for another process,
   sockets, channels, queues, sentinel or flag conventions, shared state files, env and
   config read by others, network calls another side depends on, and the *join key*
   between systems. Then **trace one hop past each boundary** and confirm the other side
   actually produces or consumes it, in the same format. "Out of scope" is not accepted.
2. **Join-key check.** For every cross-system match (IDs, keys, filenames, identifiers),
   show a REAL sample from both sides and prove the match function joins them. Format
   drift in join keys is the most common silent seam failure.
3. **Fallbacks and dead paths.** List every fallback, default, retry, and feature flag on
   the path. A fallback that can take over *silently* is a finding: it must log loudly and
   be counted. Identify any code that looks live but is unreachable in production.
4. **Prod-config path.** Audit the branch selected by the PRODUCTION configuration (env,
   mode, backend, flags), not the richest implementation in the file.

### B. Evidence discipline
5. **Documentation is a claim, not evidence.** Anything asserted in READMEs, handoffs,
   plans, comments, or memory must be verified against code or live behavior. Output a
   list: *claims verified* vs *claims assumed*.
6. **Liveness per link.** For every inter-process or inter-service link, cite evidence it
   has executed at least once for real (log line, journal entry, observed external effect).
   **Never fired = report as broken.**
7. **Cause, not effect.** An observed outcome (resource gone, file present, test green)
   counts only if the causing code path is identified. Right effect via the wrong cause is
   a failed check.
8. **Reverse dependencies.** For every changed artifact, list who else reads it (search the
   whole tree, not the diff). Blast radius before correctness.

### C. Failure paths — assume every external thing fails
9. **External calls.** Each has a timeout, a bounded retry (no unbounded loops on rate
   limits or server errors), and a stated behavior on failure. Name what the caller does on
   timeout, partial result, and exception mid-loop.
10. **Restart and crash safety.** What happens if the process dies mid-write, is restarted,
    or receives a duplicate or replayed message? Writes to shared files are atomic;
    handlers idempotent; state another process reads is versioned or checksummed.
11. **Backpressure and limits.** Unbounded buffers, unbounded pagination, capped readers on
    pipes, log and file growth, rate limits, memory growth. Name the bound or its absence.
12. **Concurrency.** Shared mutable state across threads or processes, ordering
    assumptions, lock scope, time-of-check vs time-of-use. Name the invariant and where it
    can break.
13. **Time.** Timezones, DST, clock skew, expiry vs close vs finalization semantics, stale
    caches. Every timestamp comparison names its zone and source.

### D. Irreversible actions and kill switches
14. **Inventory irreversible side effects** (money movement, external sends, deletes,
    writes to systems of record) and the guard on each. Guards are verified by cause
    (rule 7), never by absence of incidents.
15. **Audit the off switch first.** Every automation has a stop, cancel, or rollback path
    verified end to end in prod config. A stop path that has never fired is broken.
16. **Negative tests.** For every "must not happen", cite a test or check that asserts the
    absence (nothing sent, nothing deleted, nothing written), not just the positive path.

### E. Observability and unknowns
17. **Post-hoc legibility.** After a failure, logs alone must show which path ran and why.
    A failure mode that would be invisible in logs is a finding.
18. **Unknowns are a section, not a footnote.** List what could not be verified, why, and
    what evidence would close each gap. Silence about a scope means it was skipped.

### Required output shape
Findings ranked by severity, each with a concrete failure scenario (inputs and state that
produce the wrong outcome). Then four explicit lists, always present even when empty:
- **Claims verified / assumed**
- **Links with liveness evidence / never fired**
- **Irreversible actions and their verified guards**
- **Unknowns and how to close them**

### Pre-live gate (before any deploy, release, or live run)
- Exercise every operator control (start, stop, pause, undo, kill, rollback) in the LIVE
  config and trace each to an observed external effect with the causing code identified.
- Ask and answer: **"What are we relying on today that has never fired in production?"**
  Every item is exercised or declared broken.
- Verify the rollback and stop path against the live system, not a mock.
- Keep an interface inventory (link, mechanism, last verified live) current per project.

### Routing note
Audits route to `architect` (read-only) at effort high or above with this standard pasted
verbatim into the prompt; `oracle` when the seam inventory exceeds one context window.
`scout` may gather liveness evidence (log lines) but never issues the verdict. `executor`
never audits its own change.
