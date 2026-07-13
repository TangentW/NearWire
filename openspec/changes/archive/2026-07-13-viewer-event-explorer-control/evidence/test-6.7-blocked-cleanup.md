# Task 6.7 Blocked Cleanup Evidence

Date: 2026-07-13

## Combined cleanup receipt

- `ViewerAsyncWorkTracker` gives renderer preparation, composer preparation, their controller result
  deliveries, and explorer coordination exact active-work sets plus nonblocking async joins. The
  controller-level cleanup receipt is idempotent and waits for work that was accepted before
  sealing, including claimed MainActor result application, rather than treating cancellation
  delivery as completion.
- `ViewerEventExplorerController.sealAndClear()` seals the coordinator, renderer preparation, and
  controller operation owner before clearing the filter draft, validation, timeline, selection,
  canonical detail, raw chunks, derived renderer output, accessibility output, and refresh state.
  `ViewerControlComposerController.sealAndClear()` joins preparation and result delivery before
  releasing composer content and validation state.
- `ViewerApplicationModel.beginStopRuntime()` includes both presentation receipts in the same
  finite cleanup receipt as admission and runtime components. Window close, listener failure,
  retry, TLS reset, full identity reset, and process termination therefore share one ordering rule:
  seal, cancel, join, release content, then permit a replacement runtime.

## Blocked operation and lease matrix

- `testExplorerGatewaySealsBlockedOperationMatrixAndReleasesTraversalLease` creates a real store,
  frozen query traversal, and queued catalog, page, detail, gap, causality, and filtered-export
  operations. Coordinator replacement blocks until the active operation is released; every old
  callback resolves as `storeReplaced`; the old traversal lease is released exactly once; and a
  revision-bound manual delete subsequently creates exactly one tombstone.
- The fixture uses a current recording timestamp so the real startup maintenance owner cannot
  legitimately expire it while the suite is running. The earlier 1970-era fixture exposed this
  race only in a complete run. After correction, the matrix passed 10 repeated iterations.
- `testRuntimeSealsExplorerOperationsBeforeClosingOriginatingStore` separately proves that runtime
  storage close waits for a blocked gateway operation and leaves the closed gateway unavailable.

## Renderer, live evaluation, composer, and termination

- `testBlockedRendererAndComposerCleanupJoinsAndReleasesAllContent` blocks both preparation queues,
  seals them, and proves their receipts do not complete early. Released work reports cancellation,
  pending counts reach zero, no result applies late, both models contain no prior content, and
  reflection remains redacted even for cancelled values.
- `testExplorerHundredThousandRendererReplacementsCancelBeforeDeliveryClaim` and
  `testControlComposerHundredThousandReplacementsCancelBeforeDeliveryClaim` each hold the
  preparation executor, issue 100,000 controller replacements, and prove zero delivery claims,
  one retained request, constant two-owner pending work before sealing, and zero work after release.
- `testExplorerCleanupJoinsClaimedContentBearingRendererDelivery` and
  `testControlComposerCleanupJoinsClaimedContentBearingDelivery` pause a successful content-bearing
  result immediately after atomic delivery claim. Cleanup remains incomplete until release lets the
  MainActor discard the sealed result; both preparation and delivery counts then reach zero.
- `testBlockedLiveEvaluationJoinsAfterSealWithoutLatePresentation` blocks live filter evaluation,
  invalidates its presentation generation, joins the coordinator, and verifies zero pending work
  and no late timeline publication.
- `testTerminationJoinsBlockedExplorerCleanupAndFreshRuntimeHasNoPriorContent` begins with an invalid
  filter draft, validation message, selected canonical detail, Generic renderer tree, raw chunk,
  accessibility output, and composer content. Termination remains incomplete while explorer work
  is blocked. After release, the combined receipt completes with zero pending work and every
  content-bearing presentation buffer cleared. A late renderer result is rejected, reflection is
  redacted, and a newly started runtime contains none of the prior content.
- `testLocalNetworkFailureUsesFixedRecoveryAndStaleCallbacksStayStopped`,
  `testIdentityResetWaitsForAdmissionCleanupReceipt`, and
  `testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt` cover listener failure, both TLS
  and full reset, and normal running-root termination through the same joined cleanup path.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testBlockedRendererAndComposerCleanupJoinsAndReleasesAllContent -only-testing:NearWireViewerTests/ViewerFoundationTests/testBlockedLiveEvaluationJoinsAfterSealWithoutLatePresentation -only-testing:NearWireViewerTests/ViewerFoundationTests/testTerminationJoinsBlockedExplorerCleanupAndFreshRuntimeHasNoPriorContent -only-testing:NearWireViewerTests/ViewerFoundationTests/testLocalNetworkFailureUsesFixedRecoveryAndStaleCallbacksStayStopped -only-testing:NearWireViewerTests/ViewerFoundationTests/testIdentityResetWaitsForAdmissionCleanupReceipt -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewaySealsBlockedOperationMatrixAndReleasesTraversalLease -only-testing:NearWireViewerTests/ViewerStoreTests/testRuntimeSealsExplorerOperationsBeforeClosingOriginatingStore
```

Result: `TEST SUCCEEDED`; 8 tests executed, 0 failures.

Focused matrix repetition:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewaySealsBlockedOperationMatrixAndReleasesTraversalLease -test-iterations 10
```

Result: `TEST SUCCEEDED`; 10 iterations executed, 0 failures.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result after round-7 delivery-ownership coverage: `TEST SUCCEEDED`; 266 tests executed, 2 skipped,
0 failures. The current result bundle is recorded in
`implementation-review-round7-remediation.md`.

One skip is the explicit machine-local Application Support audit marker gate. The configured
signing entitlement assertion remains deferred to Goal-level release hardening as approved by the
user. This unsigned run makes no release-signing claim.

## Static and specification validation

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid
```
