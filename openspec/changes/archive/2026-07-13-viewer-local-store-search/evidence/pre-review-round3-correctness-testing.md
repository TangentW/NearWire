# Pre-Implementation Round 3 Correctness and Testing Review

Date: 2026-07-13

## Scope

This is a fresh current-snapshot review of the `viewer-local-store-search` proposal, design, capability deltas, tasks, Round 1 and Round 2 review reports, and both remediation records. No production or test source was reviewed or modified.

The review independently rechecked the corrected transition identity, orphan-reconciliation transaction shape, oversize write/reclaim inverse, query/export snapshot membership, append-only metadata versioning, export alias meaning, and whether the task plan can produce proportionate evidence for each contract.

## Verdict

**Approved for implementation. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

The current artifacts are internally coherent and each reviewed scenario has an implementable, bounded test oracle.

## Current-Snapshot Verification

### Sequence-keyed Event disposition transitions

The durable uplink Event key is `(recordingID, deviceSessionID, direction, wireSequence)`. Each record in a valid batch owns a contiguous unique wire sequence, while peer Event UUID remains ordinary potentially repeated content. A later transition carries the same store-independent journal key, so it can correlate before a SQLite row ID exists and cannot attach to a later Event that reuses the peer UUID.

The state machine remains one-way and complete: an Event is initially terminal or `buffered`; a buffered Event may append one `consumerAccepted`, `expired`, `overflowDisplaced`, or `sessionEnded` outcome. Identical duplicates are idempotent, conflicting terminal outcomes fail only the store, a missing initial Event produces gap accounting, and an earlier overflow victim emits its own sequence-keyed transition. Storage never participates in sequence or queue ownership.

The implementation evidence should use the same peer UUID at two accepted later sequences, exercise both identical and different terminal outcomes, replay one identical transition, and inject a conflicting transition. Task 3.3 defines the key and Task 7.2's transition/disposition integration scope can own this compact state-machine matrix.

### One-group child-before-parent orphan reconciliation

One reconciliation transaction handles exactly one prior recording group. It validates no more than the protocol's 16 possible open device children, appends every child interruption version first, then appends the parent interruption version, and commits all or none. More than 16 open children is schema corruption and fails closed.

There is no observable closed-parent/open-child interval because both layers commit atomically. Cleanup cannot select an unreconciled open parent between group turns. Reconciliation owns at most eight immediately chained group turns, and a new durable recording waits until no prior open group remains; if the bound is exhausted, networking continues with a nondurable context until an explicit later retry. This is finite and preserves causal parent/child history across rollback, crash, and repeated reopen.

Task 3.2 and Task 7.2 can directly cover zero, one, sixteen, and corrupt seventeen-child groups; injected failure before parent insertion; all-or-none rollback; multiple groups across the eight-turn bound; cleanup exclusion between turns; retry completion; and duplicate idempotent close revisions.

### Oversize Event write and reclaim symmetry

Normal write transactions remain bounded to 256 observations or 4 MiB, with one checked Event observation allowed to use one-record mode up to 20 MiB. Normal physical reclaim remains bounded to 1,024 child rows or 4 MiB. When the FIFO reclaim head is one legal oversize Event, a one-record Event-plus-FTS transaction may use a hard 41-MiB quota reservation. That is a finite ceiling above `2 * 20 MiB + 1 KiB`, matching the Event quota formula.

The reclaimer therefore has a progress path for every legal stored Event without splitting Event/FTS atomicity. An impossible larger value fails safely and is isolated rather than repeatedly blocking later tombstones. Task 4.2 specifies normal reclaim, the oversize exception, impossible-head isolation, resume, checkpoint behavior, and capacity recovery. Task 7.2 can prove the inverse with one combined fixture: admit the maximum legal Event, tombstone its recording, reclaim Event and FTS state atomically, inject rollback, restart/resume, verify physical status, and show no zero-progress retry loop.

### Frozen query and export membership

Query cursors freeze nonreused `AUTOINCREMENT` upper IDs for Events and all query-membership-changing recording/device/disposition/gap/drop version or sample tables. A finite recording lease prevents cleanup/manual deletion from removing original membership. Later pages use short transactions and explicit forward/backward keyset inequalities over `(viewerMonotonicNanoseconds, eventRowID)`; equal monotonic times remain stable and later appends remain above the captured bounds.

Export additionally freezes base `device_sessions` and `installation_aliases` row-ID upper bounds, plus Events and every exported append-only metadata/version/sample table. Logical ordinals are display values only. A device or alias whose logical ordinal was allocated earlier but whose base row commits after lease capture has a later row ID and cannot enter a subsequent metadata page. Recording/device mutable metadata is append-only and selected at or below the corresponding captured version ID, so later rename, note, pin, nickname, partial-history, terminal, disposition, gap, drop, or annotation revisions cannot leak into the frozen result.

The finite leases, expiry/source-inconsistency failure, short page transactions, cleanup winner, and nonreused row IDs provide an implementable snapshot without pinning WAL. Task 5.2/5.3 and Task 7.3 can cover delayed lower-ordinal base insertion, later metadata versions, later transitions/samples, cleanup/manual-delete races, lease expiry, both pagination directions, and sustained writes.

### Unambiguous bounded aliases

Schema-version-1 alias meaning is now exact:

- `device-N` represents one logical peer installation and remains shared across its reconnects.
- `connection-N` represents one exact durable device-session row.

Event rows reference both identities where applicable. Export reads the stored ordinals from bounded metadata pages and never builds an all-device alias dictionary, so arbitrarily many sequential reconnect rows do not change the constant alias-memory claim. The raw installation identifier, internal connection identifier, and exact session epoch remain omitted. Many-reconnect tests can assert stable `device-N`, distinct `connection-N`, correct Event references, raw-identifier absence, deterministic repeat output, and bounded peak ownership.

## Test-Plan Proportionality

The task plan is proportionate to the change:

- Tasks 7.1 and 7.2 use focused database and stateful integration fixtures for schema ownership, append-only uniqueness, transition identity/state, causal lifecycle admission, reconciliation rollback, size boundaries, tombstone/reclaim progress, quota thresholds, failure/retry, and shutdown.
- Task 7.3 combines compiler-level truth tables with representative pairwise SQLite integrations instead of a Cartesian product. Stateful cases cover frozen keyset traversal, delayed inserts and versions, cleanup leases, large export, cancellation, memory/VM/WAL ownership, and atomic file phases.
- Deterministic `EXPLAIN QUERY PLAN` gates validate supported compiler shapes against unbounded Event/metadata sorts. Moderate deterministic datasets plus explicit page/buffer/task/transaction counters can prove resource bounds without requiring millions of rows in routine CI.
- Tasks 7.4 and 7.5 provide the matching English operator documentation, disclosure fixtures, packaging inspection, exact validation commands, and saved current-tree evidence.

The broad Task 7.2 and 7.3 bullets should be implemented as the concrete boundary matrices described above; doing so remains within their existing scope and does not require a larger indiscriminate test suite.

## Validation

Current-tree commands:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
git diff --check
```

Results:

```text
Change 'viewer-local-store-search' is valid
```

`git diff --check` produced no output.

## Unresolved Count

**Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low. Approved for implementation.**
