# Pre-Implementation Round 3 Security, Performance, and Documentation Review

Date: 2026-07-13

## Scope

This is a fresh current-snapshot review of the `viewer-local-store-search` proposal, design, capability deltas, task plan, prior security/performance/documentation reviews, and both remediation records. No production or test source was reviewed or modified.

The review verified the Round 2 fixes and re-examined sensitive Event storage, SQLite/filesystem/input boundaries, connection and task ownership, memory/disk/transaction limits, tombstone and reclaim progress, query/export snapshot isolation, transition identity, alias disclosure, safe errors/reflection, privacy-manifest gates, and documentation/test coverage.

## Verdict

**Approved for implementation.** Both Round 2 findings are resolved, the additional snapshot and bounded-campaign refinements introduce no new security, performance, or documentation contradiction, and no actionable finding remains in this review dimension.

## Round 2 Finding Verification

### `NW-SPD2-001` — Resolved

Normal physical reclaim remains capped at 1,024 rows or 4 MiB of reserved data. The artifacts now add one explicit one-record Event-plus-FTS reclaim mode capped at a 41-MiB quota reservation, covering the maximum legal 20-MiB journal observation under the `2 * bytes + 1 KiB` quota formula. A corrupt or impossible larger head fails safely and is isolated rather than creating a zero-progress retry loop or permanently blocking later tombstones. Tasks require maximum-boundary, impossible-head, FTS, and bounded-turn evidence.

### `NW-SPD2-002` — Resolved

This change now owns English operator documentation and bounded export-preflight disclosure metadata. Both state that aliases are pseudonyms rather than redaction, Event/App content may identify secrets or people, output is unencrypted and outside Viewer quota/retention/cleanup, and destination providers may sync or back it up. The actual export selection and confirmation UI is consistently deferred to `viewer-event-explorer-control`, so the current requirement is testable without broadening this change.

## Current-Snapshot Review

### Sensitive local data and filesystem handling

- The Event-content persistence boundary remains Viewer-only and absent from Core, SDK, the root package dependency graph, `UserDefaults`, logs, analytics, clipboard, safe status/recent rows, interpolation, reflection, accessibility values, and underlying-error surfaces.
- Raw frames, pairing/Bonjour values, endpoints, exact session epochs, queue keys/contents, certificates, private keys, and Keychain selectors remain excluded from persistence and export.
- Application Support is `0700`; database, active WAL/SHM, rollback/migration, and export-temporary artifacts are regular nonsymlink `0600` files. The plan includes no-follow use where supported, pre/post-WAL inspection, memory-only SQLite temporaries, safe closed errors, and active-sidecar tests.
- `secure_delete=ON` is defense in depth. Documentation correctly treats retention as logical deletion and disclaims guaranteed erasure from WAL history, filesystem snapshots, or backups.

### Bounded writer, cleanup, and reconciliation ownership

- Event ingress, structural lifecycle capacity, write quanta, oversize mode, drain/successor count, gap coalescing, failure retry ownership, and protocol-executor work all have explicit finite bounds.
- Journal admission uses precomputed deterministic sizes and copy-on-write ownership. Encoding, content traversal, deep copy, SQLite binding, and other linear work occur only on the writer executor.
- Maintenance performs exactly one bounded mutation per turn, owns at most eight immediate turns per trigger, and owns no more than one task plus one dirty successor. Logical deletion is one bounded tombstone selection; physical rows and FTS content are reclaimed through normal or one-record oversize transactions.
- Quota-accounted visible bytes are distinct from physical database/WAL/SHM footprint. Checked schema-owned reservations, a 64-MiB available-volume floor, bounded campaigns, and capacity pause avoid a false physical-amplification promise.
- Orphan reconciliation handles exactly one prior recording group per transaction, validates at most 16 child devices, closes children before the parent in the same commit, and stops after eight group turns. Remaining work forces nondurable operation until explicit retry instead of an unbounded startup chain. Cleanup cannot select an unreconciled open parent.

### Query, SQLite-input, and read-resource boundaries

- Exactly one writer, one interactive reader, and one export reader are isolated on separate serial executors. Read operations use short transactions, generation-bound cancellation, fixed VM/time budgets, and never wait on UI/file output while holding a read transaction.
- Search values and JSON paths are bounded parameters. FTS5 terms use fixed quote doubling and quoted-AND compilation; Event-type prefix uses binary `substr` equality; JSON string containment uses `instr`; raw SQL, identifiers, functions, collations, ordering fragments, FTS operators, and wildcard syntax are not accepted from callers.
- Keyset traversal freezes Event, recording-version, device-version, transition, gap, and drop row-ID bounds under finite leases. Covering time/row-ID indexes and `EXPLAIN QUERY PLAN` gates reject supported plans that require unbounded temporary Event/metadata sorts, while progress budgets bound residual predicate scans.
- Append-only metadata and transition tables prevent later names, notes, nicknames, terminal outcomes, drops, or gaps from entering an earlier traversal.

### Export snapshot, aliases, and disclosure

- Export freezes AUTOINCREMENT bounds for base device rows, base installation-alias rows, Events, every relevant version/transition/sample table, and annotations. Stable ordinals are display aliases only and cannot admit a lower ordinal committed after lease capture.
- `device-N` identifies one logical installation across reconnects; `connection-N` identifies one exact device-session row. Stored ordinals and paged metadata remove the unbounded alias dictionary while keeping the two identities unambiguous.
- A single 60-minute export lease protects the source from cleanup/manual deletion. Short bounded read pages avoid a long WAL snapshot; lease expiry or source inconsistency cancels safely.
- Memory is limited to one bounded Event, one 200-row data/metadata page, and a 64-KiB output buffer. Temporary output is owner-only and nonsymlink; flush/close, atomic replacement, parent synchronization, and pre-commit cancellation cleanup are explicit.
- The bounded preflight metadata and operator documentation carry the required unencrypted, pseudonym-only, outside-retention, sync/backup disclosure without claiming that this change implements the deferred confirmation UI.

### Event identity, disposition, and safe failure

- Uplink durable identity is `(recordingID, deviceSessionID, direction, wireSequence)`; peer Event UUID is nonunique content and cannot ambiguously receive a later transition.
- Terminal disposition transitions are append-only and idempotent. Conflicting terminal outcomes fail with a closed store-integrity category and cannot change protocol state; missing transitions create bounded gap accounting rather than false finality.
- Downlink rows remain labeled only `transportAdmitted` and do not claim peer receipt, processing, acknowledgement, or delivery.
- SQLite, indexing, query, cleanup, and export failures expose only closed local categories and cannot terminate or mutate a device protocol session.

### Documentation, privacy, and evidence plan

- Exact recording-name, note, and annotation scalar/UTF-8/control-character limits are specified and covered by tasks.
- Operator documentation covers quota versus physical footprint, history retention versus Event TTL and secure erasure, sidecar ownership, gaps/reconciliation, recovery, local/export encryption limits, alias disclosure, exclusions, and the next Viewer change.
- The implementation gate requires identifying the actual volume-capacity API, reassessing the Viewer privacy manifest and Required Reason implications, validating existing declarations, and inspecting the built manifest rather than assuming the prior artifact remains correct.
- Tasks include proportionate deterministic unit, integration, adversarial query/export, resource-bound, permissions, failure-injection, packaging, documentation, and current-tree evidence.

## Validation

Commands rerun on the reviewed snapshot:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
git diff --check
```

Results:

```text
Change 'viewer-local-store-search' is valid
git diff --check: passed, exit 0, no output
```

## Unresolved Count

**0 actionable findings remain unresolved. Round 3 security/performance/documentation pre-review is approved.**
