# Pre-Implementation Architecture/API Review — Round 3

Date: 2026-07-13

## Verdict

**Approved for implementation. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

This fresh review used the current proposal, design, capability deltas, task plan, prior architecture report, and `pre-review-round2-remediation.md`. All four Round 2 architecture/API findings are resolved consistently across the normative artifacts, and the remediation introduces no new architecture, ownership, or scope contradiction.

## Round 2 Finding Verification

### 1. Durable transition identity — Resolved

Uplink Event rows and terminal transitions now use `(recordingID, deviceSessionID, direction, wireSequence)` as the unique durable journal key. The peer Event UUID is explicitly nonunique Event content. This matches the protocol's exact-device and contiguous per-direction sequence ownership, lets a buffered queue entry retain a stable key before SQLite assigns a row ID, and preserves idempotent duplicate versus conflicting-terminal detection even when a peer reuses an Event UUID at a later sequence.

Tasks 3.3 and 7.2 provide the implementation and integration evidence seams without transferring sequence or queue authority to storage.

### 2. Oversize physical reclaim — Resolved

Normal reclaim remains bounded to 1,024 child rows or 4 MiB. A FIFO-head legal oversize Event has a separate one-record Event-plus-FTS transaction bounded to a 41-MiB quota reservation, which safely covers `2 * 20 MiB + 1 KiB`. An impossible larger row fails closed and is isolated rather than forming a zero-progress retry loop or blocking later tombstones.

The one-record exception preserves Event/FTS atomicity, tombstone visibility, rollback, bounded campaign ownership, and physical recovery for every Event the writer can legally admit. Tasks 4.2 and 7.2 explicitly own this path and its failure/progress evidence.

### 3. Prior-process reconciliation ordering — Resolved

One reconciliation transaction now owns exactly one prior recording group, validates at most 16 open device children, appends all child interruption versions before the parent interruption version, and commits the group atomically. Schema state with more than 16 open children fails closed. Cleanup cannot select an unreconciled open parent, a new durable recording waits for zero remaining groups, and the eight-turn bound falls back to nondurable networking until an explicit later retry.

This provides causal child-before-parent closure without an unbounded startup chain or an intermediate cleanup race. Task 3.2 includes group bounds, corruption, nondurable fallback, and idempotent revision evidence.

### 4. Export alias contract — Resolved

Schema version 1 now uses two unambiguous namespaces consistently: `device-N` denotes a logical installation across reconnects, and `connection-N` denotes one exact device-session row. Export freezes AUTOINCREMENT row-ID bounds for base device/installation rows and every exported version/sample table; logical ordinals are display aliases only and cannot admit a delayed lower ordinal after lease capture.

The dedicated export reader, finite lease, paged metadata, no-alias-map rule, and exact omission/disclosure contract remain coherent with this naming decision and with the deferred export-selection UI.

## Architecture and Scope Recheck

- SQLite remains a Viewer-only system dependency with exactly one writer, one interactive reader, and one export reader on independent serial executors. No persistence type or dependency enters Core, SDK, the root package manifest, or the podspec.
- Logical recording/device contexts remain independent of storage availability. Durable parent/child/Event admission is causal, outage history is represented by bounded gaps, and structural lifecycle capacity cannot be consumed by Event traffic.
- Query and export use short read transactions, generation-bound cancellation, finite leases, append-only membership/version bounds, nonreused row IDs, and bounded plan/page work without a long WAL-pinning snapshot.
- Deterministic logical quota selection is distinct from allocated SQLite/WAL/SHM footprint. Tombstones hide complete recordings atomically; finite reclaim/checkpoint turns preserve rollback and active/pinned/leased protection.
- Immutable Event commits plus sequence-keyed append-only terminal transitions form a complete uplink disposition model without making persistence a delivery acknowledgement or protocol authority.
- Export preflight disclosure metadata and operator documentation belong to this change, while export selection/confirmation UI, event exploration, detail/timeline rendering, control composition, and performance charts remain in `viewer-event-explorer-control`.

## Validation

Current-tree commands run during this review:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
git diff --check
```

Results: strict validation passed (`Change 'viewer-local-store-search' is valid`), and `git diff --check` passed with no output.

## Approval Gate

The architecture/API pre-implementation gate is satisfied with **0 unresolved findings**. Implementation may begin only after the other required independent Round 3 review dimensions also report zero unresolved findings and task 1.2 is closed with evidence.
