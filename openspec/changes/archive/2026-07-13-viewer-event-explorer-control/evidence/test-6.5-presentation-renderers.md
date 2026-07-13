# Task 6.5 Presentation and Renderer Evidence

Date: 2026-07-13

## Presentation generations and bounded refresh

- `testExplorerCoordinatorPauseBeforeCompletionAndRapidGenerationsPublishOnlyLatest` blocks the
  initial live evaluation, invalidates its generation by pausing before completion, and proves that
  the released stale result publishes no rows. It then issues Resume, Jump to Latest, and filter
  replacement generations before predecessor releases finish. Only the final token and filter
  publish, with exactly four requests, four releases, four release completions, zero durable
  queries, and two live snapshots.
- `testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity` verifies that Pause
  freezes presentation without stopping live/store progress, exact transient-to-durable identity
  reconciliation preserves selection, Resume and Jump start fresh traversals, and stale tokens do
  not mutate rows or detail. It also covers the separate diagnostic gap lane and content-free
  reflection.
- `testLiveRefreshIsLatestOnlyTenHertzAndPausedPresentationSchedulesNothing` and
  `testExplorerModelCoalescesOneLatestRefreshAtTenHertzAndFreezesOnPause` offer 100,000 change
  tokens and prove latest-only coalescing, one scheduled wake, exact 10-Hz eligibility, saturated
  counters, no paused wake, and one successor after resume.
- `testExplorerModelCapsEveryResidentListAndReloadsOnlyExactSelection` exercises bidirectional long
  scrolling across full resident windows, deterministic eviction/reload anchors, 200 recording,
  200 device, 600 Event, 128 gap, 16-selection, and one-detail caps. Evicted selection causes only
  its exact reload and never retains a second detail.

## Renderer limits and adversarial shapes

- `testRendererRegistryPreparesBoundedRawTreeLogTableAndNumericFallbacks` verifies immutable
  renderer selection and Generic fallback; 64-KiB raw chunks; 128-child tree expansion; 4,096-node,
  preview, derived-text, and focused-VoiceOver caps; independent 1-MiB log input, 64-KiB log output,
  4-KiB log chunks, and deadline/cancellation fallback; independent 1-MiB table input, 4,096-row
  scan, 64-row page, 128-row retained, 512-KiB derived-text, and deadline/cancellation fallback; and
  the one-detail 200-row/8-MiB numeric scan. Mixed boolean, null, real, string, control, and
  bidirectional scalar values are escaped structurally rather than copied into unsafe presentation.
- `testRendererExtremeValidatedShapesRemainBounded` supplies depth 128, a 100,000-entry
  duplicate-key object, a 1-MiB key, a 1-MiB log message, and an exact 16-MiB canonical Event.
  Generic/log/table fallback remains deterministic; table work stops after 4,096 rows and retains
  128; accessibility text remains at most 512 bytes; and the maximum Event is exposed only through
  256 bounded 64-KiB raw chunks. Every retained-value and derived-byte counter remains within its
  declared limit, and reflection stays redacted.
- The registry test separately forces cancellation and logical-deadline exhaustion for log and
  table preparation, proving that one specialized renderer cannot consume another renderer's byte,
  row, or time budget.

## Selection cancellation and stale-update absence

- `testInspectorPreparationCancelsReplacedGenerationAndClearsCanonicalBuffer` queues 64 rapid
  selections behind one blocked preparation. The first 63 results are cancelled or stale and cannot
  apply; only selection 64 publishes. The inspector retains one canonical content buffer and one
  bounded renderer result, then `clear()` releases identity, canonical content, preparation, and
  prevents the formerly current result from applying later.
- Reflection assertions across coordinator, timeline, renderer preparation, and inspector values
  verify closed/redacted diagnostics and absence of Event content.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveRefreshIsLatestOnlyTenHertzAndPausedPresentationSchedulesNothing -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerModelCapsEveryResidentListAndReloadsOnlyExactSelection -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerModelCoalescesOneLatestRefreshAtTenHertzAndFreezesOnPause -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorPauseBeforeCompletionAndRapidGenerationsPublishOnlyLatest -only-testing:NearWireViewerTests/ViewerFoundationTests/testRendererRegistryPreparesBoundedRawTreeLogTableAndNumericFallbacks -only-testing:NearWireViewerTests/ViewerFoundationTests/testRendererExtremeValidatedShapesRemainBounded -only-testing:NearWireViewerTests/ViewerFoundationTests/testInspectorPreparationCancelsReplacedGenerationAndClearsCanonicalBuffer
```

Result: `TEST SUCCEEDED`; 8 tests executed, 0 failures.

## Full-suite cleanup synchronization investigation

The first complete Viewer run exposed one pre-existing timing assumption in
`testListenerGenerationCancellationDoesNotAffectOtherGeneration`: the fake channel's cancellation
callback is invoked before `channel.cancel()` returns, while admission-budget release is correctly
published afterward by the asynchronous cleanup owner. The test now waits for eventual
generation-specific occupancy and awaits the manager's cleanup receipt at shutdown instead of
treating callback delivery as cleanup completion. Production admission behavior was unchanged.

The corrected test passed 50 repeated iterations:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testListenerGenerationCancellationDoesNotAffectOtherGeneration -test-iterations 50
```

Result: `TEST SUCCEEDED`; 50 iterations executed, 0 failures.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 232 tests executed, 2 skipped, 0 failures.

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
