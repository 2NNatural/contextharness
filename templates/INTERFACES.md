# INTERFACES.md — Interface Inventory

> One row per link that crosses a process, service, or system boundary. Required by
> the harness Audit Standard (Pre-live gate) and read by the `/audit` skill. Create
> with: `cd <project> && <path-to-harness>/install.sh --init-inventory`. A link with
> no liveness evidence is reported as **BROKEN**, not as unknown. "Last verified
> live" must cite a real observation — a log line, a journal entry, or an observed
> external effect — with the date it was seen. A code reference, a test, or a
> README claim is **NOT** liveness evidence.

| Link | Mechanism | Direction | Join key | Last verified live (date + evidence) |
|---|---|---|---|---|
| *order-writer → fill-reconciler* | *ndjson spool path* | *writer → reader* | *client_order_id uppercase hex no 0x* | *2026-08-30 journalctl matched line* |
| | | | | **NEVER FIRED** |

## Column meanings

- **Link** — the producer → consumer endpoints, not a module name. Name the two
  actual processes/services on either side of the boundary.
- **Mechanism** — the concrete transport: file path + format, socket + protocol,
  queue + topic, HTTP endpoint, env var, sentinel/flag file, shared DB table.
- **Direction** — one-way or bidirectional. If evidence differs by direction, use
  two rows.
- **Join key** — the exact matched field, INCLUDING format (case, prefix, padding,
  encoding, timezone). Format drift is the most common silent seam failure, and the
  audit will demand a real sample from both sides.
- **Last verified live (date + evidence)** — `YYYY-MM-DD` plus verbatim truncated
  evidence. Use **NEVER FIRED** if it has never been observed in production — the
  audit reports it as broken.
