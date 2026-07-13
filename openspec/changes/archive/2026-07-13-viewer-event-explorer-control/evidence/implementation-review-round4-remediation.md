# Implementation Review Round 4 Remediation

Date: 2026-07-14

## Result

The architecture/API review reported zero findings. The correctness review found one direct-to-
lifecycle transition defect, and the security/performance/documentation review found one unbounded
store-status loading path. Both findings are remediated. Focused regressions, the complete root
package suite, the complete unsigned Viewer suite, the unsigned production build, package-boundary
inspection, source resource validation, formatting, diff hygiene, and strict OpenSpec validation pass.
A fresh three-dimension review is still required before tasks 7.1 or 7.2 may be checked.

Configured signing and embedded-entitlement verification remains deferred to Goal-level
`release-hardening` by the product-owner decision and is not treated as a round-4 finding.

## CT-R4-001 — explicit direct-to-lifecycle transition

- A later Event disposition no longer changes the projection into lifecycle-managed mode. Only an
  actual `sessionStarted` or `sessionEnded` callback can establish that boundary.
- The first lifecycle callback marks an atomic transition. Before applying lifecycle work, projection
  reconciles direct-observation sessions against the authoritative active-session metadata and the
  exact set of session terminations retained in the same drain.
- Direct-only sessions absent from both sets are removed with their Events, authority entries, and
  conflict markers. Window-overflow disclosure is incremented for each displaced Event.
- Sessions explicitly ending in the transition drain remain long enough to receive their terminal
  metadata. This preserves the Event as an ended-session row rather than deleting it before the
  termination can apply.
- The direct-mode regression applies a later disposition across 16 direct sessions and proves they
  remain direct until a managed session starts. It then proves only the authoritative managed session
  and Event survive, with exactly 16 disclosed window overflows.

The first complete Viewer run exposed the explicit-termination boundary not covered by the initial
focused set: the existing bounded-projection regression begins with direct Event observations and
uses `sessionEnded` as its first lifecycle callback. The transition initially removed that exact
session because it was no longer active, so the later assertion could not find its Event. The retained
transition set now includes both active and explicitly terminating connections. The original failing
case and the adjacent lifecycle regressions pass without widening any bound or assertion.

## SPD-R4-001 — bounded, joined store-status loading

- `ViewerStoreStatusRefreshCoordinator` owns status loading on one serial queue. It retains at most
  one running load and one dirty successor regardless of notification volume.
- Completion does not advance to the successor until its MainActor delivery finishes, so the
  application also retains at most one pending status-delivery task.
- Deactivation rejects new requests, clears the dirty successor, suppresses delivery from an already
  running load, and returns a finite task that joins the complete retained load chain.
- `ViewerApplicationModel.prepareForTermination()` deactivates status loading before runtime cleanup
  and awaits both owners before returning.
- A sustained regression blocks the first and second loads, sends 100,000 requests at each boundary,
  and proves exactly three loads and three deliveries: the running load, its one dirty successor, and
  one successor retained during the second blocked load. A second blocked coordinator proves cleanup
  waits for the load and suppresses its delivery.
- The previously added controller/gateway regression still proves that 10,000 store changes retain
  one gateway request plus one dirty successor and execute exactly two requests total.

## Focused validation

The final focused execution covered the original complete-suite failure and both neighboring
lifecycle boundaries:

```text
ViewerFoundationTests.testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState
ViewerFoundationTests.testDirectObservationModeSurvivesDispositionAndReconcilesAtLifecycleTransition
ViewerFoundationTests.testBlockedProjectionReconcilesEndedReplacementBeforeFreshGeneration
Executed 3 tests, with 0 failures
```

Before the complete-suite correction, the six initial round-4 regressions also passed:

```text
ViewerFoundationTests.testApplicationModelStartsOnceAndStopsIdempotently
ViewerFoundationTests.testBlockedProjectionReconcilesEndedReplacementBeforeFreshGeneration
ViewerFoundationTests.testBlockedSingleSlotChurnPreservesLatestActiveGeneration
ViewerFoundationTests.testDirectObservationModeSurvivesDispositionAndReconcilesAtLifecycleTransition
ViewerFoundationTests.testStoreStatusRefreshRetainsOneLoadAndOneDirtySuccessorAcrossSustainedBurst
ViewerStoreTests.testStoreChangeBurstRetainsOneGatewayRequestAndOneDirtySuccessor
Executed 6 tests, with 0 failures
```

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
Executed 248 tests, with 2 tests skipped and 0 failures
** TEST SUCCEEDED **
```

The result bundle is:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/
  Logs/Test/Test-NearWireViewer-2026.07.14_00-41-18-+0800.xcresult
```

The complete Viewer run repeated the 100,000-Event/10,000-gap migration gates:

```text
heap-growth=23642136
database-high-water=26894336
wal-high-water=0
temp-high-water=0
samples=6

cancellation-acknowledgement-ns=438375
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

plutil -lint Viewer/NearWireViewer/Resources/Info.plist \
  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy \
  Viewer/NearWireViewer/Resources/NearWireViewer.entitlements
all files: OK

xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
exit 0
```

The first root-suite and one Viewer-suite invocation were sandbox-limited because SwiftPM/Xcode
could not write their user module caches. The same unchanged commands passed with the required cache
access. The first post-fix format lint identified one call-site line break, which was corrected by
`swift-format`; a fresh strict lint passes. No product assertion or validation command was weakened,
and no shell validation harness was added.

## Debug report

```text
Symptom:         A complete Viewer run could not unwrap the Event after a direct-mode session ended.
Root cause:      First lifecycle reconciliation retained active sessions but not same-drain explicit
                 terminations, deleting the exact session and Event before termination applied.
Fix:             Reconcile against active plus explicitly terminating connection IDs.
Evidence:        Original failing test, adjacent focused tests, and all 248 Viewer tests pass.
Regression test: ViewerFoundationTests.testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState
Status:          DONE
```
