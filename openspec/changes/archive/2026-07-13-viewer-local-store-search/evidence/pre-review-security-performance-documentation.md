# Pre-Implementation Security, Performance, and Documentation Review

Date: 2026-07-13

## Scope

This review covers the current proposal, design, capability deltas, task plan, and pre-implementation validation for `viewer-local-store-search`. It is intentionally limited to the pre-implementation artifact gate. No production or test source was reviewed or modified.

The review focused on sensitive local Event data, SQLite and query-input boundaries, filesystem paths and permissions, safe errors and reflection, bounded memory/disk/task work, cleanup and pinned-session protection, unencrypted export disclosure, privacy-manifest implications, and whether the task plan can produce evidence for those claims.

## Verdict

**Not approved for implementation.** The overall trust boundary is strong, but the artifacts still contain seven actionable findings. The change should remain at task 1.2 until all seven are resolved and a fresh review reports zero unresolved findings.

## Findings

### NW-SPD-001 — High — Cleanup transaction work is not bounded

The design goal says cleanup and transaction work are bounded, but the cleanup requirement selects every expired session and then as many additional sessions as necessary to reach the 85% low-water mark in one immediate transaction. A recording session may contain an arbitrarily large number of Events, and the configured store may be as large as 1 TiB. Cascading the Events and external-content FTS rows for one or many such sessions can therefore monopolize the only store executor, create a very large WAL transaction, and delay writes, queries, export, cancellation, and shutdown ownership far beyond the finite writer quantum.

Required resolution:

- Define a finite maintenance quantum measured by sessions plus database work, rows, pages, or elapsed/SQLite progress steps, and yield between quanta.
- Reconcile that quantum with whole-session deletion. If deletion of one very large session must remain atomic, explicitly bound the maximum possible session size or redesign deletion/index cleanup so one session cannot create unbounded executor work.
- Specify how the 85% target is reached across repeated bounded maintenance turns without creating an unbounded task chain or busy retry loop.
- Add stress and cancellation evidence for a near-capacity database, a single very large session, FTS cascades, rollback, and shutdown during maintenance.

### NW-SPD-002 — High — Long searches and exports can monopolize the sole SQLite owner or pin WAL indefinitely

Page-size limits bound returned values, not query work. An arbitrary valid JSON-path predicate can scan a very large store before producing 200 rows. Likewise, an export matching millions of Events may hold one read transaction for its entire duration. The design currently combines one serial SQLite owner with either a long read transaction or unspecified bounded read pages. On that model, a search/export can starve journal writes and cause avoidable ingress gaps; on a separate-reader model, a long WAL snapshot can prevent checkpoint progress and let WAL storage grow beyond the intended capacity behavior. A frozen upper row ID alone also does not explain how cleanup/deletion is prevented from changing a multi-page export.

Required resolution:

- Choose and document the exact read/write connection and executor ownership model.
- Add a bounded SQLite progress/step or time budget and cancellation checks for search work, not only returned-page bounds.
- Define how exports yield between bounded pages without losing snapshot membership or allowing automatic/manual deletion of their source session, and how cancellation releases every read transaction promptly.
- Define and test the WAL-growth/capacity behavior during long export, plus continued finite writer service or an explicitly documented bounded-loss outcome.

### NW-SPD-003 — Medium — Export alias metadata is explicitly unbounded

The export requirement claims bounded memory but allows memory proportional to `alias metadata`. Only concurrent live devices are capped at 16; one long recording can accumulate an unbounded number of reconnect-created device-session rows. Preparing a complete in-memory alias map therefore violates the no-full-result-materialization claim even when Events themselves are streamed.

Required resolution:

- Generate aliases through a deterministic paged/SQL mapping or another bounded lookup strategy rather than materializing every device alias.
- State a numeric alias-cache bound and eviction/reload behavior if a cache is retained.
- Add a synthetic export with a very large number of device sessions, not only millions of Events across `several devices`, and measure peak memory.

### NW-SPD-004 — Medium — Sensitive SQLite sidecars and deletion remnants are outside the permission and retention contract

The artifacts require an owner-only database file, but WAL and shared-memory files can contain the same Event content and are not named in the permission requirement. Temporary journal files, migration files, FTS shadow content, and replacement paths also need the same closed filesystem policy. In addition, logical row deletion and incremental free-page reclamation do not guarantee secure erasure: deleted Event content may remain in free pages, WAL, filesystem snapshots, or backups. The current statement that history is deleted after retention can be misread as a secure-delete promise.

Required resolution:

- Extend the owner-only requirement and tests to the Application Support directory and every SQLite-created database, WAL, SHM, rollback-journal, temporary, and migration artifact; validate regular-file/no-symlink expectations before opening or replacing sensitive files.
- Decide whether V1 uses a supported SQLite secure-delete mode. Regardless of that decision, document retention as logical application cleanup rather than guaranteed secure erasure and disclose possible persistence in filesystem snapshots/backups.
- Inspect permissions both while WAL is active and after checkpoint/close, not only the main database path.

### NW-SPD-005 — Medium — Constant-bounded journal admission does not define where full-content accounting and JSON encoding occur

The protocol executor must offer observations in constant-bounded work, while ingress admission is byte-exact and includes the full immutable observation. The artifacts do not say whether computing that byte count, producing canonical JSON, or copying up to the negotiated Event maximum occurs on the protocol executor. Re-encoding or deep-copying content at the journal boundary would make admission proportional to Event size and could violate the new multi-device constant-bounded requirement even though the resulting queue has a byte cap.

Required resolution:

- Specify a prevalidated/precomputed size reservation or another constant-time admission mechanism and the ownership/COW rules for Event content.
- State explicitly that canonical JSON encoding, SQLite binding, and any linear content walk occur only after admission on the store executor.
- Extend task 3.3 evidence to measure protocol-executor work for maximum-size single Events and maximum valid batches, including rejected ingress offers.

### NW-SPD-006 — Medium — Literal prefix and containment semantics need an exact SQL rule

Binding parameters prevents SQL injection, but it does not by itself make `%`, `_`, escape characters, NULs, or FTS quotes literal. The spec says wildcard-like input is literalized or rejected, yet the design does not define how Event-type prefix matching and JSON string containment preserve literal semantics. An implementation using `LIKE ?` can silently treat user text as wildcard syntax without changing the SQL plan, so the existing scenario is not precise enough to reject that bug.

Required resolution:

- Define the concrete literal strategy for every textual operator: for example, a range or `substr` comparison for type prefix, `instr` for containment, and a single reviewed FTS5 quote/escape routine for full text.
- Define rejection or normalization for embedded NUL/control characters and malformed UTF-8 at every boundary.
- Expand adversarial tests to assert result semantics for `%`, `_`, backslash/escape, double quote, FTS operators, SQL comments, NUL/control input, and Unicode normalization—not merely that the query does not inject SQL.

### NW-SPD-007 — Low — Export privacy disclosure and user-authored text bounds are not testable enough

Task 7.4 mentions unencrypted local data and exports, but the artifacts do not require documentation to say that deterministic device aliases are pseudonyms only: Event content and App metadata may still identify people, devices, accounts, or secrets. Exported files leave the app container, are outside Viewer capacity/retention cleanup, and may be copied, synced, backed up, or shared. Separately, recording names, notes, and annotations are called `bounded` without numeric UTF-8 limits, leaving storage, export, and later UI resource claims non-testable.

Required resolution:

- Require operator/export documentation to state that aliasing does not redact Event content, exports are unencrypted, exported files are outside Viewer quota/retention/cleanup, and the destination provider may sync or back them up.
- Give recording names, session notes, and annotations exact UTF-8 byte/count limits and define control-character handling.
- Add documentation assertions/fixtures and boundary tests for those statements and limits.

## Confirmed Strengths

- Event persistence is Viewer-only and deliberately absent from Core, SDK, the root package manifest, logs, analytics, clipboard, safe snapshots, and `UserDefaults`.
- Raw wire frames, pairing/Bonjour data, endpoints, exact session epochs, queue keys, certificates, Keychain selectors, SQL, paths, and underlying errors are excluded from safe surfaces and export.
- SQLite inputs are prepared and parameter-bound; ordering, collation, identifiers, functions, and raw expressions are closed implementation choices.
- Unknown schema, corruption, migration failure, and missing SQLite features fail closed without destructive automatic recreation or terminating network sessions.
- Ingress count/byte caps, finite write quanta, coalesced gaps, saturating counters, one drain plus one successor, and nonpolling failure states form a sound bounded network/storage boundary once finding NW-SPD-005 is resolved.
- Active and pinned sessions are protected from automatic cleanup, and revision-bound manual deletion is an appropriate stale-confirmation defense.
- Atomic temporary-file replacement and cleanup-on-cancellation are appropriate export foundations.
- The modified `viewer-multidevice-flow-control` delta now preserves the complete canonical content-free telemetry requirement and places the new bounded journal seam under an added requirement.
- Task 7.5 correctly requires reassessing and inspecting the built privacy manifest. Because data remains local to the Viewer or is exported by explicit user action, the artifacts do not currently establish a new developer data-collection path; implementation evidence must still verify APIs used for storage accounting and the final manifest declarations.

## Unresolved Count

**7 actionable findings remain unresolved: 2 high, 4 medium, and 1 low. Approval is withheld.**
