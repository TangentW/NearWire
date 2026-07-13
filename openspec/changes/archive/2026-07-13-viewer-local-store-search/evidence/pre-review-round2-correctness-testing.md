# Pre-Implementation Round 2 Correctness and Testing Review

Date: 2026-07-13

## Scope

This is a fresh review of the current `viewer-local-store-search` proposal, design, capability deltas, tasks, Round 1 remediation record, and prior correctness/testing report. No production or test source was reviewed or modified.

The review re-tested all six Round 1 findings and checked the revised contracts across lifecycle ordering, Event-disposition transitions, oversize observation admission and reclaim, cleanup thresholds and tombstones, pagination leases, export snapshots, stored aliases, and proportional test coverage.

## Verdict

**Approved for implementation.** All six Round 1 correctness/testing findings are coherently resolved in the current artifacts. Two cross-boundary issues found during this Round 2 pass were remediated before finalization: legal oversize Events now have a bounded physical-reclaim path, and export now freezes base device/alias row IDs rather than treating logical alias ordinals as snapshot bounds.

## Round 1 Finding Verification

| Prior finding | Round 2 status | Current-artifact evidence |
| --- | --- | --- |
| `NW-LSS-CT-PRE-001` final disposition unknowable at Event commit | Resolved | Uplink persistence is now an immutable Event with either an immediate terminal admission disposition or `buffered`, followed by at most one append-only idempotent terminal transition. The artifacts define consumer acceptance, later expiry, overflow displacement, session end, duplicate/conflicting transitions, a missing-initial-Event case, and transition-loss gaps without giving storage protocol authority. |
| `NW-LSS-CT-PRE-002` legal observation exceeds ingress/write quantum | Resolved | Default ingress is 32 MiB, normal writes remain 4 MiB, and one legal Event may use a checked one-record oversize transaction up to 20 MiB. Session construction proves the negotiated maximum fits both the oversize bound and default ingress; an impossible larger record becomes a gap before queue admission and cannot block the head. Physical SQLite amplification is no longer equated with logical batch bytes. |
| `NW-LSS-CT-PRE-003` lifecycle loss leaves protected orphan rows | Resolved | Logical contexts exist independently of storage, durable parents are admitted causally, Event traffic cannot consume the 36-value structural lane, unavailable-start retry backfills only live devices with partial history, and devices fully contained in an outage remain represented by a gap. Prior-process reconciliation is bounded to 32 rows per turn and eight turns; a new durable recording waits for completion while networking may continue non-durably. |
| `NW-LSS-CT-PRE-004` 85% cleanup not safely computable from physical pages/WAL | Resolved | Selection now uses overflow-safe schema-owned quota reservations, not live page/WAL size. A transaction atomically tombstones whole recordings and subtracts their exact quota counters; later bounded turns reclaim rows and perform checkpoint/free-page work. The 85%-to-100% writable result, above-100% pause, protected/leased behavior, rollback, reclaim failure, and physical-footprint distinction are explicit. |
| `NW-LSS-CT-PRE-005` upper Event ID does not freeze pagination | Resolved | Query traversal holds one finite recording lease, cleanup/manual deletion skip the source, and cursors freeze nonreused `AUTOINCREMENT` upper bounds for Events and every query-membership-changing append-only version/sample table. Forward/backward tuple inequalities, equal-time tie breaking, idle/absolute expiry, stale-cursor rejection, short transactions, per-page work budgets, and covering-index/plan gates are specified. |
| `NW-LSS-CT-PRE-006` export snapshot and aliases are unbounded/ambiguous | Resolved | Export has one finite deletion-protection lease, short bounded read pages, a 60-minute absolute limit, paged stored aliases, bounded buffers, source-consistency failure, and atomic-file cancellation rules. It freezes base device-session and installation-alias `AUTOINCREMENT` row IDs plus every exported append-only version/sample bound. Stable logical ordinals are display aliases only, so delayed lower-ordinal admission cannot enter the frozen result. No long SQLite snapshot or complete alias map is retained. |

## Round 2 Cross-Boundary Recheck

### Oversize Event admission and physical reclaim

The final artifacts close both directions of the size contract. One legal Event observation may use a one-record write transaction up to 20 MiB. Normal reclaim remains limited to 1,024 rows or 4 MiB, while a FIFO-head oversize Event may use one atomic Event-plus-FTS reclaim transaction up to a checked 41-MiB quota reservation. An impossible larger row fails safely without blocking later tombstones. The bound matches the maximum `2 * 20 MiB + 1 KiB` quota formula rounded upward and preserves finite executor ownership.

### Frozen export base membership

The export lease now captures upper nonreused row IDs for `device_sessions` and `installation_aliases`, in addition to Events and all exported append-only version/sample tables. Metadata pages apply those row-ID bounds. A structural admission that commits after lease creation cannot enter merely because its previously assigned logical alias ordinal is below a displayed ordinal. Cleanup/manual deletion still lose to the finite source lease, and source inconsistency or lease expiry cancels safely.

## Test-Plan Assessment

The revised test plan is proportionate and implementable. Task 7.2 covers lifecycle outage/retry/reconciliation, structural-lane saturation, initial and terminal disposition states, transition loss, maximum observation/oversize boundaries, bounded ingress, exact 85%/100% quota behavior, huge-session tombstone/reclaim, impossible-head isolation, protected leases, failure injection, and shutdown. The maximum-observation and huge-session clauses must be exercised together to prove the 41-MiB one-row reclaim path makes progress after tombstoning.

Task 7.3 uses compiler truth tables plus representative pairwise database integrations instead of a Cartesian product. It includes both keyset directions, equal timestamps, concurrent inserts/transitions, deletion leases, expiry, operation-cancel races, many-device/many-Event export, sustained writes, memory/VM/WAL ownership, and atomic-file cancellation. The base-device/base-alias row-ID contract is directly implementable with a deterministic delayed-admission race fixture.

Large-data bounds can be proved with moderate deterministic fixtures and instrumentation of page, buffer, task, transaction, and alias ownership rather than generating millions of rows in routine CI. The covering-index and deterministic `EXPLAIN QUERY PLAN` gates make the per-page execution budgets testable without relying only on wall-clock timing.

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
