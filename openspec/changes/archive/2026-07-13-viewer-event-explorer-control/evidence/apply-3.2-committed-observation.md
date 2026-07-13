# Task 3.2 Committed Observation Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerCommittedEventObservation` is now the single immutable value created at the protocol
  commit boundary and shared by the live and durable paths. It carries an opaque observation ID,
  exact runtime/connection/direction/sequence identity, the validated wire envelope, one Viewer
  wall/monotonic receive-time pair, bounded frozen session metadata, deterministic accounting, and
  the initial disposition.
- Construction validates the exact source, target, and session epoch before journal admission. The
  manager creates committed observations only after the existing protocol ownership checks, so an
  invalid source, target, or epoch cannot appear in either presentation or persistence.
- `ViewerDurableEventProjection` is the sole duplicate comparator. It includes the persisted Event
  fields, nearest-millisecond App-created time, and initial disposition. It intentionally excludes
  session identity invariants, session metadata, Viewer receive time, and deterministic accounting.
- The live window linearizes exact-key ownership before store fan-out. An identical projection is
  idempotent, a conflicting projection preserves the first value with a typed presentation
  conflict, and store results are correlated by the opaque observation ID so a stale callback
  cannot evict a later reuse of the same key.
- Eviction removes the exact key without retaining a tombstone. A later value is admitted as a new
  candidate, lost duplicate horizon is disclosed, and the durable store supplies the remaining
  identical-versus-conflict decision whenever a row already exists.
- Durable duplicate handling reads the existing Event and initial-disposition rows, applies the
  same projection comparator, and returns `.identical` or `.journalConflict`. It never rewrites
  first receive times, metadata, accounting, content, quota, or disposition, and a duplicate
  conflict does not mark the store corrupt or unavailable.
- Store ingress carries the exact committed observation through materialization and batching; it
  does not re-encode the Event or sample a second receive time. Live, store, manager, and callback
  roots retain content-free redacted reflection.
- Manager shutdown now publishes the terminal empty active-session snapshot through the previously
  installed handler before replacing it with a no-op. This correctness fix was exposed by the full
  regression suite and prevents stale application session rows after shutdown.

## Behavioral coverage

The complete Viewer suite includes the following new or strengthened scenarios:

- `testCommittedObservationComparatorAndLiveIngressPreserveTheFirstValue` covers normalized
  millisecond equality, metadata/receive-time/accounting exclusions, persisted-field conflicts,
  live identical/conflict outcomes, exact callback correlation, eviction without tombstones, lost
  horizon disclosure, and redacted reflection.
- `testSessionIdentityViolationsNeverCreateCommittedObservations` proves source, target, and epoch
  violations close as protocol errors before any committed journal value exists.
- `testDuplicatePeerEventIdentifiersRetainIndependentJournalOwnership` proves one exact receive
  time per committed observation and independent connection ownership for reused Event IDs.
- `testDurableDuplicateComparatorPreservesFirstReceiveAndAccountingValues` proves store equality
  and typed conflict behavior while preserving the complete first durable value and quota.
- Existing disposition, admission, shutdown, store recovery, and runtime lifecycle tests were
  migrated to the committed-observation journal API and continue to pass.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 201 tests executed, 2 tests skipped, 0 failures. One skip is the explicitly
deferred configured-signing entitlement gate. The other is the opt-in Application Support artifact
audit that requires its machine-local marker.

## Static and specification validation

- `xcrun swift-format lint --strict` passed for every production and test file affected by task 3.2.
- `git diff --check` passed.
- `env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive`
  reported `Change 'viewer-event-explorer-control' is valid`.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64`; this evidence does not claim configured signing passed.
