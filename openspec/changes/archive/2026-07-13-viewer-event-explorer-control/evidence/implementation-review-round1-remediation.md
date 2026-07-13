# Implementation Review Round 1 Remediation

Date: 2026-07-13

## Result

All six round-1 findings, representing five independent root causes because exact SQLite
cancellation was reported by two reviewers, were remediated. Focused regressions, the complete root
package suite, the complete unsigned Viewer suite, formatting, diff hygiene, and strict OpenSpec
validation pass. A fresh independent review round is still required before tasks 7.1 or 7.2 may be
checked.

Configured signing and embedded-entitlement verification remains deferred to Goal-level
`release-hardening` by the product-owner decision and was not treated as a round-1 finding.

## ARCH-001 and CT-002 — exact successor-safe cancellation

- The gateway now carries its immutable operation UUID into the query arbiter, catalog, query,
  diagnostic, and export services.
- `ViewerSQLiteConnection` binds that UUID to the active SQLite generation under the same state lock
  used by cancellation. A cancellation records only the requested UUID and calls
  `sqlite3_interrupt` only when that UUID is still active.
- Cancellation that arrives before the SQLite turn is remembered and fails that exact turn before
  body execution. The generation gateway clears the remembered UUID from every relevant reader only
  after completion, before a serial successor can start.
- Export's file-phase cancellation also binds its active generation to the originating operation UUID,
  so a late export cancellation cannot cancel a new export.
- `testSQLiteOperationCancellationNeverInterruptsAnActiveSuccessor` holds successor B active on the
  SQLite connection, applies completed operation A's cancellation, and proves B succeeds. It also
  proves pre-active cancellation fails only its exact operation and succeeds after exact cleanup.
- Existing queued/completed/active gateway, frozen export cancellation, and blocked-operation matrix
  tests pass with the exact path.

## CT-001 — recording tombstone snapshot bound

- The recording catalog now binds `snapshot.tombstoneUpperRowID` to its own SQL parameter. Installation
  alias and tombstone bounds are no longer accidentally shared.
- The regression creates two tombstones but only one installation alias. Both deleted recordings stay
  absent from a fresh catalog, so equal first-row IDs can no longer mask the error.

## CT-003 — cancellable live evaluation

- Every live evaluation now owns a lock-protected cancellation object passed into the evaluator's
  existing checkpoints.
- Pause, traversal replacement, and controller sealing cancel the active evaluation before joining it.
- The cleanup regression blocks after the evaluator has entered checkpointed work, cancels it through
  the production coordinator, releases only the injected clock observation point, and proves cleanup
  joins with no late presentation or accessibility state.

## SPD-001 — precomputed callback content representation

- `WireEventRecord` now precomputes canonical content bytes and exact record byte accounting while the
  validated wire record is constructed. Record accounting uses a bounded null-content wrapper plus
  the canonical content byte count instead of re-traversing the content.
- `WireReceivedEvent` carries those immutable bytes through receiver admission. Downlink journal input
  carries the same bytes from its prepared wire record.
- The production manager is compile-time routed through the observation initializer that requires the
  precomputed canonical bytes. The normalized observation no longer calls `deterministicData()` on the
  protocol journal callback path.
- Core and Viewer regressions prove exact precomputed byte equality, receiver propagation, and direct
  consumption by the durable projection. The complete package suite confirms wire sizes and golden
  compatibility remain unchanged.

## SPD-002 — bounded session churn

- Pending session metadata remains capped at the 16-session product limit. Updates coalesce by
  connection ID; terminal pending entries are deterministically replaced when a fresh active session
  needs capacity, with saturating diagnostic loss.
- Projected ended-session state is reclaimed as soon as no retained live Event references it.
- If every metadata slot is occupied and a new active session arrives, the oldest ended session is
  reclaimed deterministically; any still-retained Events for that ended session are released off the
  ingress lock and counted as live-window overflow. Active sessions are never displaced for churn.
- The regression blocks the projection queue across 1,000 distinct start/end pairs and proves the
  pending cardinality remains exactly 16. It then fills all projected slots with ended sessions and
  retained Events, admits a fresh active session, and proves exact 16-session residency, fresh Event
  visibility, and one disclosed overflow.

## SPD-003 — latest-only preparation ownership

- Renderer and composer preparation now use one bounded worker plus one latest pending request.
- Replacing a pending request releases its content immediately and returns a content-free cancelled
  result. The executing request observes token cancellation at its existing checkpoints.
- One worker receipt, rather than one work item per submission, is joined during cleanup. The retained
  request limit is two regardless of submission count.
- Blocked-queue regressions prove 64 renderer submissions retain only the latest pending request, and
  composer replacement behaves identically. Superseded completions are content-free and the latest
  generation alone can update its model.

## Validation

Focused regressions:

```text
WireEventTests.testRecordPrecomputesCanonicalContentAndCarriesItToReceiverAdmission
ViewerStoreTests.testRecordingCatalogIgnoresEventCommitsAndRestartsForRenamePinAndTombstone
ViewerStoreTests.testSQLiteOperationCancellationNeverInterruptsAnActiveSuccessor
ViewerFoundationTests.testBlockedLiveEvaluationJoinsAfterSealWithoutLatePresentation
ViewerFoundationTests.testLiveSessionMetadataStaysBoundedAndFreshActiveSessionSurvivesChurn
ViewerFoundationTests.testInspectorPreparationCancelsReplacedGenerationAndClearsCanonicalBuffer
ViewerFoundationTests.testComposerPreparationReplacesOneGenerationAndCountsOneSuccessfulPipeline
ViewerFoundationTests.testCommittedObservationConsumesPrecomputedCanonicalContent
all passed
```

Complete root package suite:

```text
swift test
Executed 537 tests, with 0 failures
```

Complete unsigned Viewer suite:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
Executed 241 tests, with 2 tests skipped and 0 failures
** TEST SUCCEEDED **
```

The full Viewer run also repeated the 100,000-Event/10,000-gap migration gates:

```text
heap-growth=22265904
database-high-water=26894336
wal-high-water=0
temp-high-water=0
samples=6

cancellation-acknowledgement-ns=101017834
cancellation-heap-growth=245760
database-high-water=26894336
wal-high-water=0
temp-high-water=0
samples=2
```

The assertions gate no more than 128 MiB heap growth and no more than 250 ms injected cancellation;
the observed values remain diagnostic host context only.

Static gates:

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
```

No shell harness was added and no validation gate was weakened.
