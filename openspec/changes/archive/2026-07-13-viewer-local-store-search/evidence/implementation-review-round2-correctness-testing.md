# Implementation Review Round 2 — Correctness and Testing

Date: 2026-07-13

## Scope

This fresh independent review traced the current `viewer-local-store-search` implementation through runtime lifecycle, protocol-to-journal callbacks, failed ingress and retry, SQLite integrity, quota cleanup and reclaim, frozen query/export traversal, cancellation, and current tests/evidence. No production, test, specification, or documentation source was modified.

Severity meanings:

- **High:** a required lifecycle, capacity, or query contract is materially false and can lose journal state, prevent valid recovery, or return semantically incorrect results.
- **Medium:** a bounded but actionable correctness, atomicity, resource-bound, or evidence gap that must be resolved before completion.

Configured signing, entitlements, and stable-signer validation are explicitly deferred by the user and are not findings in this review.

## Round 1 disposition

The remediation materially fixed sequence-keyed uplink commits and terminal callbacks, immutable/versioned lifecycle schema, recording-local aliases, retained failed Event prefixes, child-before-parent orphan reconciliation, per-recording quota counters, phased non-Event reclaim, lease/deletion serialization, frozen cursor identity, complete export structure, retry/reopen composition, and maintenance triggers.

Round 1 findings 1, 3, 4, 6, 9, and 10 are resolved in their original form. Findings 2, 5, 7, 8, and 11 are improved but remain partially unresolved through the current findings below.

## Findings

### NW-LSS-IMPL-R2-CT-001 — High — Failed shutdown flush implicitly retries and reports success while close observations can be discarded

`ViewerStoreIngress.flush()` clears `writeFailed` and schedules another drain (`ViewerEventStore.swift:1089-1100`), although the approved failure boundary permits a new write attempt only after explicit retry or a relevant configuration/data action. If that drain fails, all flush waiters are resumed without a success/failure result (`ViewerEventStore.swift:1152-1164`). Runtime shutdown also ignores every device/recording close admission result (`ViewerStoreCoordinator.swift:459-490`), waits on this result-less flush, then clears the active recording and resumes cleanup regardless of persistence outcome (`ViewerStoreCoordinator.swift:491-515`). Finally, `ViewerStoreRuntime.runtimeEnded` detaches runtime state but does not close the coordinator's three SQLite connections (`ViewerStoreCoordinator.swift:1106-1121`), contrary to the finite-shutdown resource contract.

**Required resolution:** make flush return an exact terminal outcome without clearing the explicit-retry failure state; preserve or reconcile rejected structural closes; clear lifecycle state only after the outcome is recorded; checkpoint and close all connections on successful runtime shutdown, and release them on failure. Add deterministic tests for a pre-existing failed prefix, failure during flush, structural-lane saturation, close rejection, repeated shutdown, and next-open orphan repair.

### NW-LSS-IMPL-R2-CT-002 — High — A write that crosses capacity cannot trigger the cleanup needed to admit it

Quota reservation rejects when `current + bytes` exceeds capacity (`ViewerEventStore.swift:739-753`) and then invokes one recovery campaign after rolling back (`ViewerEventStore.swift:931-965`). However, capacity cleanup selects sessions only when the already-committed visible quota is itself above capacity (`ViewerStoreMaintenance.swift:338-365`). If current usage is 99% and the next valid reservation would cross 100%, recovery sees 99%, selects no capacity candidate, and the identical retry fails again. The store pauses even when an eligible closed session could have been reclaimed toward 85%, violating the required pre-admission campaign.

**Required resolution:** pass the pending checked reservation or an equivalent projected-usage target into the bounded campaign, trigger capacity selection when projected usage crosses 100%, and retry once after cleanup. Test exact 85/100 boundaries, below-capacity-plus-reservation crossing, protected versus eligible recordings, 32-session/eight-turn limits, and successful admission after reclaim.

### NW-LSS-IMPL-R2-CT-003 — High — Required query semantics and budget outcomes remain incomplete or incorrect

The query model has no terminal-disposition presence filter and no single JSON-scalar predicate with an OR-list (`ViewerStoreQuery.swift:13-32`). Viewer receive-time filtering is implemented against App `createdWallMs`, not Viewer `viewerWallMs` (`ViewerStoreQuery.swift:140-149`). JSON string containment casts every extracted scalar to text and can therefore match numbers or Booleans despite the string-only contract (`ViewerStoreQuery.swift:174-178`). Although disposition/version upper bounds are captured (`ViewerStoreQuery.swift:270-277`), the missing terminal predicate means the frozen disposition bound cannot govern required membership. Separately, VM-step and deadline exhaustion both interrupt SQLite (`ViewerSQLite.swift:142-149`) and are mapped to `.cancelled` (`ViewerSQLite.swift:247-250,297-304`), so callers cannot receive the specified safe refine-query/work-limit outcome distinct from user cancellation.

**Required resolution:** implement the missing terminal and scalar-OR query dimensions, use Viewer receive time, require `json_type(...)= 'text'` for string containment, apply frozen disposition membership, and distinguish budget exhaustion from generation cancellation. Add compiler truth tables and integrations covering every dimension, later transitions, wall-clock divergence, numeric/Boolean/string containment, scalar OR, equal-time bidirectional pagination, and deterministic budget/cancel races.

### NW-LSS-IMPL-R2-CT-004 — Medium — Annotation changes do not invalidate a manual-delete confirmation

`appendAnnotation` advances only `AnnotationVersions` (`ViewerStoreMaintenance.swift:266-299`). Manual deletion validates only the latest `RecordingVersions.revision` (`ViewerStoreMaintenance.swift:302-329`). A confirmation issued for recording revision 2 therefore remains valid after one or more annotation mutations, contrary to the explicit scenario that an annotation change makes the confirmation stale.

**Required resolution:** bind deletion confirmation to a mutation token that includes annotation state, or append an authoritative recording revision for annotation changes. Test rename, note, pin, annotation, lifecycle, lease, and concurrent delete winner/loser orders.

### NW-LSS-IMPL-R2-CT-005 — Medium — Gap aggregation can silently discard distinct losses and omits required range metadata

The coordinator retains at most 64 `(recording, device, reason)` gap keys, but silently drops a new key when that table is full (`ViewerStoreCoordinator.swift:627-643`). This is not the specified saturating per-recording aggregate and can lose loss-accounting exactly under multi-device/multi-reason pressure. Persisted gaps carry reason/count but the admission path does not populate first/last Viewer time, affected direction, or wire-sequence range (`ViewerEventStore.swift:533-571`), even though the schema has range columns and the design requires the coalesced gap to describe its affected interval.

**Required resolution:** use a bounded saturating aggregate with a defined fallback bucket that never silently loses count, persist its required range/direction metadata, and order the gap before later Events after recovery. Test more than 64 distinct keys, saturation overflow, multiple directions/devices, failed gap commit/retry, and recording end while unavailable.

### NW-LSS-IMPL-R2-CT-006 — Medium — Event reclaim exceeds the stated row/byte quantum through uncounted disposition children

The Event reclaim selector budgets only `Events.quotaBytes` and at most 1,024 Event rows (`ViewerStoreMaintenance.swift:434-456`), but the transaction first deletes all matching `EventDispositionVersions` and then the Events (`ViewerStoreMaintenance.swift:466-483`). Each Event can own initial and terminal disposition rows with their own reservations, so a nominal 4-MiB/1,024-Event selection can delete materially more than 4 MiB and more than 1,024 child rows. The current phased-reclaim test proves eventual deletion, not the per-turn bound.

**Required resolution:** include disposition row counts/reservations in Event-batch selection or reclaim them through a separately persisted bounded phase while preserving Event/FTS integrity. Add exact 1,024-row/4-MiB boundary, maximum dispositions per Event, rollback/resume, oversize Event, and impossible-head/later-tombstone tests.

### NW-LSS-IMPL-R2-CT-007 — Medium — Export replacement cannot preserve an existing destination after the final directory-sync failure

For an existing destination, export swaps the files, synchronizes the directory, unlinks the old destination now held at the temporary path, and performs another directory sync (`ViewerStoreExport.swift:604-640`). If that final `fsync` fails, the function throws after the prior destination has already been unlinked and cannot roll it back. Cancellation is checked before entering `atomicReplace`, but not at replace/directory-sync boundaries (`ViewerStoreExport.swift:174-180,573-579,604-651`). This violates the promised cancellation/failure atomic-file behavior.

**Required resolution:** define a single commit point that preserves the old file for every pre-commit error, retain rollback material until the durable commit succeeds, and check the generation at the replace/sync boundaries where cancellation can still win. Add injected failures and cancellation at open, write, flush, close, first sync, swap/rename, unlink, final sync, and rollback.

### NW-LSS-IMPL-R2-CT-008 — Medium — Current passing tests and evidence do not cover the remaining required failure surface

The current focused command builds and executes 24 `ViewerStoreTests` successfully, but it does not exercise the failure paths identified above or the task-plan matrices for busy/full/I/O/corruption, progress-budget distinction, lifecycle/control saturation, 20/41-MiB boundaries, 1/4/8/16-device contention, crash reconciliation limits, shutdown ownership, compiler truth tables, later transition membership, sustained-write export, lease expiry during export, bounded memory/WAL, or file-phase fault injection (`ViewerStoreTests.swift:17-1140`; `tasks.md:38-42`). Tasks 2.1 through 8.3 remain unchecked (`tasks.md:8-48`), and `implementation-validation-round1.md:29-45` still records the earlier 12-test result rather than this remediated tree.

**Required resolution:** add proportionate deterministic tests for each requirement/scenario and every remaining finding, update exact current-tree validation evidence, complete the spec-to-evidence audit, and mark tasks only after their stated evidence exists.

## Validation Results

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# no output; exit 0

xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache \
  test -only-testing:NearWireViewerTests/ViewerStoreTests
Test Suite 'ViewerStoreTests' passed.
Executed 24 tests, with 0 failures (0 unexpected).
** TEST SUCCEEDED **
```

The unsigned focused run is evidence for the current store tests only. Configured-signing, entitlement, and stable-signer checks remain deferred by user direction and are not counted as failures or findings.

## Verdict

**Approval withheld. Exact unresolved actionable finding count: 8 — 3 High, 5 Medium, 0 Low.**

The remediation is substantial and closes most Round 1 structural defects. Completion is still blocked by the shutdown/explicit-retry contract, projected-capacity cleanup, required query semantics, and five bounded correctness/evidence gaps above.
