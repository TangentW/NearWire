# Implementation Review Round 3 — Architecture/API

Date: 2026-07-13

## Verdict

**Not approved. Exact unresolved actionable finding count: 4 — 2 High, 2 Medium, 0 Low.**

## Validation Basis

This was a fresh review of the stable current tree after the final Round 3 remediation. It covered `AGENTS.md`, the active proposal, design, both capability specifications, task plan, all three Round 2 implementation reports, current production/test/documentation source, the complete current diff, and `implementation-validation-round3.md`.

The following local gates were rerun on the reviewed snapshot:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output
```

The current saved validation additionally records 35 focused Viewer store tests, 112 complete unsigned Viewer tests, and 531 root package tests passing, plus SQLite linkage, built privacy-manifest, and root-package inspection. Configured signing, entitlement assertions, and stable-signer validation are explicitly deferred by the user to goal-level `release-hardening`; they are not findings here.

Round 2's aggregate pipeline-bound, duplicate Event UUID, missing-row writer poisoning, nondurable-ended-device, mutable-gap, reclaim/free-page, general query snapshot, export replacement, and MainActor maintenance findings are resolved in their original forms. Runtime generations now isolate late prior-runtime callbacks and shutdown, the protocol-to-writer pipeline shares one reservation budget, gap snapshots are append-only, reclaim work is phased and counted, query scalars are type-strict, and export cancellation is sealed with a final lease validation.

## Findings

### 1. High — Capacity pre-admission does not reserve the complete transaction quota

The approved design requires the checked quota for each complete write batch to drive the pre-admission cleanup campaign (`openspec/changes/viewer-local-store-search/design.md:125`). `appendEvents` supplies only the sum of `ViewerPreparedEventObservation.quotaBytes` as `plannedReservation` (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:400-410`), but every Event with an initial disposition subsequently reserves another structural quota row (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:960-982`). All structural transactions—including recording/device starts, lifecycle closes, dispositions, policy/drop/gap versions—use the default planned reservation of zero (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:414-415`, `:1019-1055`).

Consequently, a transaction can pass projected-capacity selection and then fail on an omitted disposition/structural reservation. At exactly capacity, a required device or recording close calls recovery with zero projected bytes; maintenance triggers capacity selection only when `quota + pendingReservationBytes` is above capacity (`Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:425-457`), so eligible closed history is not selected and the close remains unwritable. An Event whose Event-row quota fits but whose initial disposition crosses capacity has the same failure. The current projected-capacity test covers an Event-row crossing, not these omitted transaction-owned rows.

Required resolution: compute one overflow-checked net quota plan for every transaction before its first mutation, including initial dispositions, aliases, base/version rows, lifecycle transitions, and gap/sample rows. Pass that complete plan into the bounded campaign and retry once. Idempotent duplicate writes must use their actual net reservation rather than delete unrelated history to admit a no-op. Add exact-capacity tests for Event-plus-disposition batches, device/recording starts and closes, duplicate Events, gaps, and policy/drop transitions.

### 2. High — Missing-initial transition gaps do not preserve transition identity or duplicate semantics

When a terminal transition has no Event row, the store now appends a safe gap instead of failing the writer, but the gap records only the constant reason `missingInitialEvent`, direction, wire sequence, time, and count (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:447-479`). It does not retain the terminal disposition value. Gap idempotence compares the complete stored range/time aggregate and returns only when those values are identical; otherwise it requires the new count to increase (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:608-637`).

Two conflicting terminal transitions for the same missing Event can therefore be treated as identical when their timestamps match because `.expired` versus `.consumerAccepted` is absent from the durable identity. Conversely, a duplicate-identical terminal callback observed at a later Viewer wall time has the same count but a different range and is promoted to a store-integrity failure, which again stops the bounded ingress. This does not satisfy the required idempotent-identical/conflicting-terminal distinction or the rule that a missing initial row is ignored with gap accounting.

Required resolution: give a missing-initial transition gap a stable identity containing recording, device, direction, wire sequence, and terminal disposition. Treat a repeated identical transition as idempotent independently of observation wall time, reject a different terminal disposition as a store-only conflict, and extend gap interval/count only through an explicitly identified aggregate update. Add same-value/different-time and different-value/same-time tests through the live ingress.

### 3. Medium — Event-type query inputs bypass the Event-type grammar

Exact and prefix Event-type predicates use the generic NFC search-text validator with a 512-byte limit (`Viewer/NearWireViewer/Store/ViewerStoreQuery.swift:68-83`); multi-value exact matching uses the same generic text-selection helper. Persisted Event types, however, follow the closed dot-separated ASCII grammar and configured Event-type byte limit (`Core/Sources/NearWireCore/Event/EventType.swift:70-99`). The design explicitly requires validated exact Event types and a validated Event-type prefix (`openspec/changes/viewer-local-store-search/design.md:140`; capability spec `viewer-local-store-search/spec.md:194`).

The compiler therefore accepts Unicode, whitespace, malformed separators, SQL/FTS-looking strings, and over-limit values as valid Event-type filters. Values remain parameter-bound, so this is not injection, but the closed query API returns a valid compiled traversal for inputs the capability says must be rejected.

Required resolution: use the canonical Event-type validator for exact values and define one closed ASCII prefix grammar, including whether a trailing dot and a partial final segment are allowed. Apply it to single and OR-list predicates, use the Event model's byte limit, and add malformed/Unicode/control/trailing-dot/maximum-bound tests.

### 4. Medium — The latest-only change-notification API omits its required safe payload

The design requires one latest-only commit notification containing safe changed recording IDs, the new upper row ID, and store status so the later explorer can selectively rerun persisted queries (`openspec/changes/viewer-local-store-search/design.md:148`). The current `ViewerStoreStatusSignal` stores only a zero-argument handler and publishes no value (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:212-247`). Writer and maintenance commits call that status-only signal (`Viewer/NearWireViewer/Store/ViewerEventStore.swift:1039-1041`; `Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift:231-235`). No other store change model or upper-row notification exists.

Required resolution: introduce one bounded latest-only immutable change snapshot carrying only changed recording IDs, committed upper Event row ID, and safe status/category. Coalesce replacements without retaining Event/query content or one result set per subscriber, and keep the application status presentation as a consumer of that same authoritative seam.

## Approval Gate

Resolve all four findings, add requirement-matched evidence, and obtain a fresh architecture/API review with **0 unresolved findings** before completing this OpenSpec change. Signing, entitlement, and stable-signer gates remain deferred exclusively to the user-directed final `release-hardening` change.
