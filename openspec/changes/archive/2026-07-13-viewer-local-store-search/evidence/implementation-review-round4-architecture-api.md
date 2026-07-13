# Implementation Review Round 4 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

The current `viewer-local-store-search` implementation now matches the approved Viewer-only architecture and internal API boundaries. All four Round 3 architecture/API findings are resolved, and this fresh review found no new actionable architecture or API issue.

The two configured-signing tests remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. That deferral is not treated as a finding or as passing evidence in this review.

## Scope and Review Basis

This review re-read `AGENTS.md`; the active proposal, design, both capability specifications, and task plan; the current production, integration, test, operator-documentation, and evidence files; the complete current working-tree diff; `implementation-review-round3-architecture-api.md`; and `implementation-remediation-round3.md`.

The architecture review traced:

- Viewer-only SQLite ownership and the absence of a Core/SDK persistence dependency;
- complete pre-transaction logical and physical reservation planning;
- immutable Event identity and append-only disposition/gap semantics;
- query validation, frozen traversal identity, and bounded internal query APIs;
- latest-only change/status delivery through the store, runtime adapter, and application model;
- maintenance, export, runtime-generation, and shutdown ownership; and
- the maintained macOS 13, Swift 5 language-mode, manually maintained Xcode-project boundary.

## Commands and Saved Evidence

The following current-tree gates were rerun during this review:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output
```

`implementation-validation-round4.md` records the complete unchanged-tree regression:

```text
ViewerFlowControlTests: 23 tests, 0 failures
ViewerFoundationTests: 54 tests, 0 failures
ViewerStoreTests: 44 tests, 0 failures
NearWireViewerTests.xctest: 121 tests, 0 failures
NearWirePackageTests.xctest: 531 tests, 0 failures
```

The same evidence records system-SQLite linkage, the built privacy manifest, root SwiftPM/CocoaPods boundaries, the near-maximum Event measurement, and the exact two configured-signing exclusions. `resource-filesystem-audit-round4.md` records the sustained-write, WAL, peak-process-memory, filesystem-identity, export-substitution, distribution, and privacy results.

## Round 3 Finding Disposition

### 1. Complete transaction quota planning — Resolved

`ViewerEventStore.writeTransaction` computes the checked net-new reservation on the writer executor before `BEGIN IMMEDIATE`. Event batches use `plannedEventReservation`, which includes an optional initial-disposition row and verifies duplicate immutable Events. Structural writes use `plannedStructuralReservation`, including lifecycle closes, terminal dispositions, missing-initial transition gaps, policy/drop samples, and ordinary gap versions. Recording/device admission also plans base/version rows and a conditional installation alias before mutation.

The same planned value drives projected logical-capacity admission, the single bounded cleanup recovery, and `ViewerStoreDiskGuard.requireReserve`. Idempotent duplicate Events and no-op structural observations plan zero, so a full quota cannot cause unrelated history deletion merely to admit a no-op.

Regression evidence: `testWholeTransactionPlanIncludesInitialDispositionAndDuplicateIsZeroQuota`, `testProjectedReservationCrossingCapacityReclaimsEligibleHistoryThenAdmits`, and the disk-guard boundary tests.

### 2. Missing-initial transition identity — Resolved

A terminal transition without its immutable Event creates a versioned transition gap identified by recording, device, direction, wire sequence, and terminal disposition. The disposition is encoded in the bounded reason (`missingInitialEvent.<disposition>`). Repeating the same transition remains idempotent even when the later callback carries a different wall/monotonic observation time. A different terminal disposition for the same transition identity produces a store-only integrity conflict.

The handled missing-parent case does not poison the writer or alter protocol ownership. Regression evidence: `testMissingInitialTransitionBecomesIdempotentGapWithoutPoisoningWriter`.

### 3. Event-type and JSON-index query grammar — Resolved

Exact Event types now use the same 128-byte dot-separated ASCII segment grammar as the shared Event model. Prefixes use the same closed segment grammar while allowing a partial final segment or one trailing dot. Single-value and OR-list exact filters share that validator. JSON array indexes accept ASCII decimal digits only, so impossible paths fail in the compiler rather than reaching SQLite.

All values remain parameter-bound; Event-type prefix still uses binary `substr` equality rather than `LIKE`. Regression evidence: `testQueryCompilerRejectsImpossibleEventTypesAndNonASCIIJSONIndexes`.

### 4. Safe latest-only notification payload — Resolved

`ViewerStoreChangeSnapshot` carries at most 32 safe changed recording row IDs, the greatest committed Event row bound, and the latest closed `ViewerStoreStatus`. `ViewerStoreStatusSignal` owns one latest-only pending snapshot, unions only the bounded ID hints, retains the greatest Event bound, and replaces status with the latest snapshot. The runtime adapter republishes through the same snapshot provider, while the application status model consumes the authoritative signal without moving SQLite work onto `MainActor`.

The payload contains no Event type/content, peer identity, query/path values, SQL, database path, or result array. The 32-ID bound is the explicit approved design contract; delivery remains a store-change notification even when the bounded ID hints are truncated. Regression evidence: `testLatestOnlyChangeSignalCarriesSafeRecordingAndUpperRowSnapshot` and `testApplicationStorageSettingsValidatePersistAndRefreshSafeStatus`.

## New Findings

None.

The remediation did not introduce a second protocol owner, public SDK persistence API, Core database abstraction, nested manifest, third-party Core/SDK dependency, unbounded change-notification payload, or a Viewer UI feature reserved for `viewer-event-explorer-control`.

## Approval Gate

**Architecture/API review is approved with zero unresolved findings.** The change may proceed to the remaining independent Round 4 review dimensions and, only after all dimensions and the spec-to-evidence audit are clean, to archive. The two configured-signing gates remain visible for the separate goal-level `release-hardening` change.
