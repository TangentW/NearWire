# Implementation Review Round 3 Remediation

Date: 2026-07-14

## Result

All three round-3 findings, representing one session-lifecycle root cause reported by all reviewers
and one independent store-change backlog root cause, were remediated. Focused regressions, affected
legacy live-window regressions, the complete root package suite, the complete unsigned Viewer suite,
formatting, diff hygiene, and strict OpenSpec validation pass. A fresh three-dimension review is still
required before tasks 7.1 or 7.2 may be checked.

Configured signing and embedded-entitlement verification remains deferred to Goal-level
`release-hardening` by the product-owner decision and is not treated as a round-3 finding.

## ARCH3-001, CT-R3-001, and SPD-R3-001 — authoritative bounded session lifecycle

- The ingress owner now retains the exact current active-session metadata set, capped at 16, rather
  than retaining the first 16 pending starts. Ending a session removes it from that active set even
  while projection is blocked, so later active generations replace obsolete metadata.
- The projection mirrors at most 16 resident session IDs under the ingress lock. Termination storage
  remains capped at 16, but a terminal transition for a resident ID replaces a nonresident terminal
  if necessary. A session is reserved as resident only while it is still active under the same lock,
  closing the start/end race around projection materialization.
- Drain applies resident terminations first, then current active metadata, then Events. An Event for a
  lifecycle-managed session is admitted only when its connection is currently active or already
  resident. Intermediate generations that start and end entirely while blocked are released and
  disclosed as bounded live-window overflow rather than becoming stale-active session rows.
- Internal direct-observation mode remains supported until the first lifecycle callback, preserving
  deterministic live-window tests and internal consumers that intentionally inject observations
  without a manager. Production composite-journal flow always supplies lifecycle callbacks.
- The three-generation regression projects 16 A sessions, blocks projection, ends A, starts and ends
  16 B sessions, then starts 16 C sessions. Only active C sessions and Events survive.
- The single-slot regression keeps 15 sessions active, churns the remaining slot through more than 16
  complete generations while blocked, then proves the newest active session, metadata, and Event
  replace the old slot without retaining any intermediate generation.

## SPD-R3-002 — latest-only store-change delivery and gateway ownership

- `ViewerStoreChangeCoalescer` allows at most one scheduled MainActor task and one dirty state. A burst
  replaces that state instead of enqueuing one task per store notification.
- `ViewerEventExplorerController` permits at most one change-snapshot request in flight plus one dirty
  successor. Repeated notifications do not cancel and enqueue additional gateway operations.
- Completion consumes the dirty bit once and starts one successor. Sealing clears the bit and joins
  the one tracked operation through existing cleanup ownership.
- A 100,000-submit regression proves one MainActor task and one delivery. A gateway regression blocks
  the first snapshot request, sends 10,000 notifications, proves exactly one gateway operation and
  one dirty successor are retained, then proves exactly two requests total and zero cleanup work.

## Validation

Focused new and cancellation regressions:

```text
ViewerFoundationTests.testBlockedProjectionReconcilesEndedReplacementBeforeFreshGeneration
ViewerFoundationTests.testBlockedProjectionRetainsTerminalTransitionsBeforeReplacementSessions
ViewerFoundationTests.testBlockedSingleSlotChurnPreservesLatestActiveGeneration
ViewerFoundationTests.testLiveSessionMetadataStaysBoundedAndFreshActiveSessionSurvivesChurn
ViewerFoundationTests.testStoreChangeCoalescerRetainsOneMainActorTaskAcrossLargeBurst
ViewerStoreTests.testStoreChangeBurstRetainsOneGatewayRequestAndOneDirtySuccessor
ViewerStoreTests.testGatewayRegistersCancellationBeforeCompletionClearsEveryReader
Executed 7 tests, with 0 failures
```

Affected direct-observation compatibility regressions:

```text
ViewerFoundationTests.testCommittedObservationComparatorAndLiveIngressPreserveTheFirstValue
ViewerFoundationTests.testHundredThousandLiveOffersUseOneBoundedDrainAndRefreshWake
ViewerFoundationTests.testLiveIngressAdmitsOneMaximumEventAndRejectsTheTwentyMiBOverflow
ViewerFoundationTests.testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState
ViewerFoundationTests.testLiveRefreshIsLatestOnlyTenHertzAndPausedPresentationSchedulesNothing
ViewerFoundationTests.testUntrackedDuplicatesUseDurableAuthorityAndShutdownSealsCallbacks
plus the two new churn tests and the blocked gateway test
Executed 9 tests, with 0 failures
```

The first focused rerun had four failures: the store-change test used insufficient MainActor yields,
and the prior churn fixture did not force each historical session to become resident before ending.
The tests now wait for the delivery expectation and exact projection boundary. No product assertion
was weakened.

The first complete Viewer rerun exposed the direct-observation compatibility regression described
above and later crashed after dependent empty-window assertions. The implementation now distinguishes
direct observation from lifecycle-managed flow. The affected suite and a fresh complete suite pass.

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
Executed 247 tests, with 2 tests skipped and 0 failures
** TEST SUCCEEDED **
```

The result bundle is:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/
  Logs/Test/Test-NearWireViewer-2026.07.14_00-23-47-+0800.xcresult
```

The full Viewer run repeated the 100,000-Event/10,000-gap migration gates:

```text
heap-growth=21200920
database-high-water=26894336
wal-high-water=0
temp-high-water=0
samples=6

cancellation-acknowledgement-ns=322250
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

openspec validate viewer-event-explorer-control --strict
Change 'viewer-event-explorer-control' is valid
exit 0
```

The OpenSpec command emitted only a failed optional analytics flush because network access is
restricted; local validation completed with exit 0. No shell harness was added and no validation gate
was weakened.
