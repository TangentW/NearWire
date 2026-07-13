# Implementation Review Round 5 Remediation

Date: 2026-07-14

## Result

All five round-5 findings are remediated: one architecture/API conflict-marker finding, one
correctness short-session finding, and three security/performance ownership findings. New focused
regressions, affected recovery regressions, the complete root package suite, the complete unsigned
Viewer suite, the unsigned production build, package-boundary inspection, formatting, diff hygiene,
and strict OpenSpec validation pass. A fresh three-dimension review is still required before tasks 7.1
or 7.2 may be checked.

Configured signing and embedded-entitlement verification remains deferred to Goal-level
`release-hardening` by the product-owner decision and is not treated as a round-5 finding.

## ARCH-R5-001 — direct-only conflict markers retire at lifecycle reconciliation

- Direct-to-lifecycle reconciliation now removes every conflict marker whose journal key belongs to
  an obsolete connection ID, even when `journalConflict` already removed the transient Event from the
  live window.
- The bounded marker ring is rebuilt from at most 512 retained keys, preserving order and every marker
  outside the exact obsolete direct-connection set. Round 6 later extended the same retirement rule
  to managed ended-session reclamation and terminal capacity eviction.
- A direct observation is offered, removed by durable conflict, and verified as one resident conflict
  marker. Starting the first managed lifecycle session removes the obsolete session and marker while
  leaving window-overflow at zero.

## CT-R5-001 — bounded terminal metadata for short sessions

- Pending termination state can carry the exact frozen metadata for a session that starts and ends
  before it ever becomes projected. Metadata moves from the active map into the terminal record, so
  active plus pending-terminal frozen metadata remains capped at 16.
- When a new active session needs metadata capacity, redundant metadata for an already projected
  terminal session is released first. If pressure requires dropping an unprojected terminal record,
  one diagnostic loss discloses it and the latest active generation retains priority.
- Drain materializes an exact ended session from retained terminal metadata before processing its
  already accepted Event. The Event then retains later disposition and session-ended state without a
  capacity overflow.
- Duplicate terminal callbacks preserve an earlier retained metadata value instead of replacing it
  with `nil`.
- One blocked-queue regression exercises `start -> offer -> later disposition -> end` both as the
  first lifecycle transition and after lifecycle mode is established. Both paths retain the Event and
  terminal state with zero window overflow and zero diagnostic loss.

## SPD-R5-001 — snapshot work occurs after bounded status coalescing

- `ViewerStoreStatusSignal.publish` now performs only lock-protected dirty-state and changed-ID
  coalescing. It retains at most 32 deterministic recording IDs, one scheduled worker, and one dirty
  successor.
- The snapshot provider, including SQLite status and filesystem footprint work, runs only on that
  retained worker after coalescing. It is no longer invoked once per successful Event transaction.
- Deactivation clears pending state, rejects later publication, suppresses delivery from a blocked
  provider, and joins the retained provider/delivery chain before coordinator storage closes.
- A blocked-provider regression publishes 100,000 changes, proves the first provider remains the only
  running provider plus one dirty successor, proves exactly two providers and deliveries total, and
  proves the changed-ID set never exceeds 32. A separate blocked provider proves cleanup waits and
  delivers nothing after deactivation.

## SPD-R5-002 — removable bounded gateway work

- Each coordinator generation retains at most 16 operations. The seventeenth request completes with
  the existing safe `busy` category.
- Accepted queued operations live in one removable ID queue driven by one scheduled serial drain.
  Requests no longer enqueue one capturing `DispatchQueue` closure each.
- Queued cancellation atomically removes the record and payload, invokes its cancellation completion,
  clears operation-specific cancellation state, and leaves the completion group immediately. Sealing
  similarly rejects and releases every queued request before joining only the exact active work.
- Controller slot cancellation bounds obsolete work-tracker identities. Round 6 later strengthened
  callback delivery with an atomic cancellation/claim bridge so a cancelled callback creates no
  untracked MainActor task.
- A blocked-reader regression first proves one active plus 15 queued requests is the hard bound and
  the next request is `busy`. It then cancels 100,000 queued replacements and proves all complete as
  cancelled while the gateway retains exactly the one active operation and zero pending operations.

## SPD-R5-003 — zero-owner authority is removed

- Completing a deferred duplicate now removes the authority record when its pending count reaches
  zero and no current transient value remains.
- All window-removal paths continue through `releaseAuthority`; a record is retained only while a
  deferred duplicate can legitimately claim it.
- A 600-generation single-slot regression keeps 15 anchor sessions, blocks each projection turn,
  offers one duplicate, ends the current session, and admits its replacement. It crosses the complete
  576-entry authority horizon and proves every fresh Event remains accepted, ownerless authority stays
  zero, total authority equals the one retained Event, and both disclosed losses per generation are
  counted exactly.

## Focused validation

```text
ViewerFoundationTests.testLifecycleTransitionClearsDetachedDirectConflictMarker
ViewerFoundationTests.testShortLifecycleManagedSessionRetainsEventBeforeFirstAndEstablishedDrain
ViewerFoundationTests.testDuplicateSessionChurnReleasesOwnerlessAuthorityAcrossCapacityHorizon
ViewerStoreTests.testExplorerGatewayCancellationIsQueuedCompletedAndActiveSuccessorSafe
ViewerStoreTests.testQueuedGatewayCancellationRemainsBoundedAcrossHundredThousandReplacements
ViewerStoreTests.testChangeSignalCoalescesSnapshotProviderBeforeWorkAndJoinsDeactivation
Executed 6 tests, with 0 failures
```

The first focused run had one test-only failure: the duplicate-churn fixture expected one overflow per
generation, but it intentionally produces two independent disclosed losses, one displaced resident
Event and one rejected stale duplicate. The expected exact count was corrected from 600 to 1,200; no
implementation or bound changed.

The first complete Viewer run then exposed four recovery tests that depended on the removed
synchronous status-provider work as an implicit delay. They waited for available state and an active
recording but asserted the asynchronous storage-unavailable gap immediately afterward. Each wait now
includes that exact durable gap postcondition. The four focused regressions and a fresh complete suite
pass; no product assertion was removed or widened.

## Complete validation

Root package suite:

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
Executed 253 tests, with 2 tests skipped and 0 failures
** TEST SUCCEEDED **
```

The result bundle is:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/
  Logs/Test/Test-NearWireViewer-2026.07.14_01-07-22-+0800.xcresult
```

The complete Viewer run repeated the 100,000-Event/10,000-gap migration gates:

```text
heap-growth=21184512
database-high-water=26894336
wal-high-water=0
temp-high-water=0
samples=6

cancellation-acknowledgement-ns=577667
cancellation-heap-growth=245760
database-high-water=26894336
wal-high-water=0
temp-high-water=0
samples=2
```

The assertions gate no more than 128 MiB heap growth and no more than 250 ms injected cancellation;
the observed values remain diagnostic host context only.

Unsigned production build and static gates:

```text
xcodebuild build -workspace NearWire.xcworkspace -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **

swift package dump-package
exit 0

xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
exit 0
```

One focused rerun required standard Xcode/SwiftPM cache access after the sandbox denied user-cache
writes. The unchanged command passed with that access. No shell validation harness was added.
