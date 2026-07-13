# Implementation Review Round 6 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 2 — 0 High, 2 Medium, 0 Low.**

Round 5 remediation resolves the blocked-maintenance-action fallback and unauthorized shutdown retry findings in their reported forms. It also adds a shared write-failure classifier and publishes maintenance failures as authoritative store status. However, that status transition is not connected to ingress admission or drain ownership, so automatic Event writes can continue after a maintenance storage failure. A fresh boundary scan also found that the floor-only checkpoint still checks filesystem reserve before entering the serialized writer executor.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to goal-level `release-hardening`. That deferral is not a finding and is not represented as passing evidence in this review.

## Scope and Evidence Basis

This fresh independent review read `AGENTS.md`; the active proposal, design, both capability specifications, and task plan; the complete current production, integration, test, operator-documentation, and working-tree diff; all three Round 5 implementation-review reports; `implementation-remediation-round5.md`; `implementation-validation-round6.md`; and `resource-filesystem-audit-round6.md`.

The review retraced all Round 5 architecture findings and rechecked store/ingress failure ownership, explicit recovery boundaries, shutdown attempt count, action-specific maintenance selection, physical-reserve serialization, SQLite executor confinement, runtime-generation isolation, Sendable/lock ownership, Core/SDK/Viewer boundaries, package structure, and deferred UI/API scope.

Fresh local gates on the reviewed tree:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output
```

The saved Round 6 validation reports 56 focused ViewerStore tests with one explicit opt-in live-container skip and zero failures, 133 unsigned Viewer tests with the same opt-in skip and zero failures, 533 root package tests with seven existing skips and zero failures, and 100 successful iterations of the late-runtime regression. The two configured-signing tests were excluded from the unsigned command and are not counted as passes or skips.

## Round 5 Architecture Finding Disposition

- **Blocked expensive maintenance action:** resolved. `ViewerStoreMaintenance.run` catches capacity failure at selection and reclaim boundaries and permits one eligible floor-only checkpoint or free-page action while retaining the eight-turn bound. `testMaintenanceRunBypassesBlockedReclaimForOneFloorOnlyAction` drives the production campaign and proves the blocked Event and tombstone remain intact while physical recovery progresses.
- **Unauthorized shutdown retry:** resolved. `ViewerStoreCoordinator.runtimeEnded` calls `ingress.flush()` exactly once and performs no store retry, ingress reset, second flush, or terminal maintenance scan. The new regressions cover failure during shutdown, a pre-existing failed prefix, capacity failure, finite resource closure, and next-open orphan reconciliation.
- **Maintenance metadata failure classification:** partially resolved. The centralized classifier correctly distinguishes capacity, storage-integrity, and operation-local errors, and maintenance failures now publish `writeFailed`. Finding 1 below remains because the published state does not control ingress admission or automatic drain ownership.

The Round 5 correctness flake, writer ordering for manual deletion/orphan reconciliation, direct Event-carrier reflection, live-resource evidence, and encryption disclosure are also resolved in their reported forms. Finding 2 is a separate remaining serialization gap in the checkpoint path.

## Findings

### NW-LSS-IMPL-R6-ARCH-001 — Medium — Maintenance `writeFailed` is presentation-only and does not stop automatic ingress

`ViewerStoreMaintenance.capacityCheckedWrite` now classifies storage, I/O, corruption, and unavailable-store errors as `writeFailed` and invokes `storeStateReporter(.writeFailed)` (`ViewerStoreMaintenance.swift:923-983`). In the live composition, that callback reaches only `ViewerEventStore.noteMaintenanceWriteState`, whose implementation calls `setState` and publishes the status signal (`ViewerStoreCoordinator.swift:191-201`; `ViewerEventStore.swift:1514-1524`). It does not set `ViewerStoreIngress.writeFailed`, cancel a scheduled drain, or install a write gate shared with `ViewerEventStore.writeTransaction`.

Consequently, after an annotation or recording-metadata storage failure, `ViewerStoreIngress.admit` still accepts new Event and structural observations because it checks only its own private `writeFailed` flag (`ViewerEventStore.swift:1666-1718`). A scheduled or newly admitted drain then calls `appendEvents`/`appendStructural`; `writeTransaction` does not consult the store's current status and sets it back to `available` after any successful automatic write (`ViewerEventStore.swift:1428-1465,1771-1824`). The store can therefore leave the reported `writeFailed` state without the explicit retry, successful reopen, or relevant configuration/data trigger required by the design. It can also keep accepting Event ownership instead of coalescing the bounded gap required for a write-failed state.

`testMaintenanceMutationFailuresReportAuthoritativeStateAndRollback` proves rollback and the immediate status value for three injected phases, but closes the pool immediately afterward. It does not admit another Event, observe ingress refusal/gap behavior, or prove that no automatic writer attempt occurs (`ViewerStoreTests.swift:3057-3105`).

Required resolution:

- Replace the presentation-only callback with one shared failure controller or coordinator-owned transition that atomically updates safe status, stops new Event admission and automatic drain attempts, and preserves only the already-bounded structural recovery ownership for storage-integrity failures.
- Keep operation-local stale revision, lease contention, cancellation, work-limit, and invalid-caller failures out of that global gate.
- Permit the shared gate to reopen only after the already-approved explicit retry, successful reopen, or relevant configuration/data action succeeds; do not let an unrelated automatic Event write clear it.
- Add deterministic maintenance-failure regressions that prove subsequent Event and structural offers do not trigger SQLite work, Event loss coalesces into one bounded gap, queued ownership remains bounded, and one successful explicit recovery resumes exactly one finite attempt.

### NW-LSS-IMPL-R6-ARCH-002 — Medium — Checkpoint reserve admission remains outside writer serialization

`ViewerStoreMaintenance.checkpointOneStep` reads WAL size and calls `requireMaintenanceReserve(0)` before entering `pool.writer.run`; only `sqlite3_wal_checkpoint_v2` is executed on the writer (`ViewerStoreMaintenance.swift:803-821`). Another queued writer can therefore consume the capacity observed by the checkpoint between its floor check and the checkpoint mutation. This is the same check-then-act boundary that Round 5 remediation correctly removed from manual deletion and orphan reconciliation, but it remains in the floor-only checkpoint path.

The active design requires maintenance to identify the exact action before disk admission, apply the action-specific floor-only plan, and preserve the physical floor for bounded work (`design.md:108,123-125`). The single serial writer connection is the only boundary that can order this admission against every other SQLite mutation. `reclaimFreePagesOneStep` already performs its floor check inside `pool.writer.run` immediately before the pragma (`ViewerStoreMaintenance.swift:824-833`), demonstrating the intended ownership pattern.

Current checkpoint coverage invokes the operation sequentially and verifies low-floor rejection, but it does not interleave a checkpoint reserve probe with another admitted writer (`ViewerStoreTests.swift:2873-2938`). Thus the passing regression does not establish that checkpoint admission and mutation observe one serialized capacity decision.

Required resolution:

- Move the floor-only reserve check into the checkpoint's `pool.writer.run` closure immediately before `sqlite3_wal_checkpoint_v2`.
- Keep the no-work WAL inspection bounded; if it remains outside the writer, treat it only as a hint and revalidate the actionable condition on the writer turn.
- Add a deterministic interleaving regression in which checkpoint admission observes sufficient reserve, another writer is queued, and only the correctly serialized operation may consume the apparent post-floor capacity. Prove the checkpoint fails before mutation when the current floor is no longer safe.

## Architecture and Boundary Recheck

- SQLite remains macOS Viewer-only with one writer, one interactive-query reader, and one export reader. No database abstraction or third-party runtime dependency entered Core or SDK.
- The additional Core reflection conformances remain on internal SPI transport carriers and do not create a supported SDK API or expose Event content through generic diagnostics.
- Runtime generations continue to isolate late callbacks and replacement coordinators. The session manager remains authoritative for protocol, sequence, rate, mailbox, and terminal state; persistence does not mutate those authorities.
- Preparation and ingress ownership remain bounded with the reserved lifecycle partition and no task-per-Event or unbounded retry loop.
- Shutdown now owns one finite flush attempt and closes all three SQLite connections on both success and failure.
- Manual deletion and orphan reconciliation now compute/check their exact plans on the writer executor. Query and export pointers remain confined to their own serial executors.
- The manually maintained Xcode project, macOS 13 deployment target, Swift 5 language mode, root-manifest-only structure, system-SQLite linkage, and Viewer-only dependency boundary remain intact.
- No timeline browser, search UI, detail renderer, export selection UI, control composer, performance chart, server, cloud service, or SDK persistence API was added through this change.

## Approval Gate

Approval requires resolving both findings, saving proportionate focused and complete validation, and obtaining a fresh independent architecture/API review with **zero unresolved findings**. Configured signing and signer-bound entitlement probes remain deferred exclusively to `release-hardening` and are not part of this finding count.
