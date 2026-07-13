# Task 6.3 Shared Observation and Live Projection Evidence

Date: 2026-07-13

## Shared observation and duplicate authority

- `testCommittedObservationComparatorAndLiveIngressPreserveTheFirstValue` blocks the projection
  drain and submits an accepted value, an equivalent duplicate, and a same-header content
  conflict. Only the first callback and durable commit occur before the drain; after the drain the
  duplicate is `identical` and the changed canonical content is `presentationConflict`. This proves
  that the fixed header is not treated as an equality hash. The test also proves that changed
  session metadata, deterministic accounting, Viewer receive times, and App-created timestamps
  that round to the same millisecond remain equal while preserving the first values.
- The same test exercises every persisted projection field independently: Event ID, Event type,
  canonical content, normalized App-created millisecond, App monotonic timestamp, priority, TTL,
  schema version, correlation ID, reply-to ID, and initial disposition. Every changed field is
  unequal to the first durable projection and is classified as a live presentation conflict.
- `testUntrackedDuplicatesUseDurableAuthorityAndShutdownSealsCallbacks` fills all 64 ingress slots,
  proves that an identical and a conflicting duplicate rejected as `untracked` by live ingress
  still reach the durable authority, and receives `identical` and `journalConflict` respectively.
  It verifies 66 exact durable calls, two ingress-overflow markers, joined runtime clearing, and a
  later `.sealed` callback with no durable commit.
- `testDurableDuplicateComparatorPreservesFirstReceiveAndAccountingValues` verifies durable
  idempotence, immutable first Viewer receive/accounting/content values, one row, zero duplicate
  quota growth, typed `journalConflict`, and continued store availability. The separate append-only
  test proves that a changed initial disposition conflicts.
- `testSessionIdentityViolationsNeverCreateCommittedObservations` separately mutates source,
  target, and session epoch and proves each protocol violation closes the connection before a
  journal observation can be committed.

## Scope, filtering, and reconciliation

- `testExplorerScopePreservesLogicalSelectionAcrossPartialMaterialization` covers no durable
  recording, zero and partial device materialization, exact cardinalities 1 through 16, all
  devices, and historical durable-only scope. Logical device IDs remain authoritative while only
  positive durable IDs compile into SQL. Atomic filter replacement issues a new token and rejects
  publication under the replaced token.
- `testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity` proves the atomic
  current transient-to-durable transition by exact journal identity, without a duplicate timeline
  row or lost selection.
- `testLiveEvaluatorMatchesMetadataJSONPresenceAndExcludesTransientFullText` covers type equality
  and prefix, content literal, App identifier/version, direction, priority, inclusive exact Viewer
  receive-time boundaries, JSON existence, integer-any, string containment, null, real, boolean,
  gap, drop, and terminal-disposition predicates. Durable-only IDs do not guess live identity, and
  transient FTS returns the fixed recorded-data guidance.
- `testLiveEvaluatorMatchesSQLiteForSharedPredicatesAndExplicitlyExcludesFTS` compares durable and
  live results for every shared predicate family, including Unicode-normalized JSON equality and
  containment, while proving the deliberate FTS difference.
- `testLiveEvaluatorReturnsNoPartialCompletionOnCancellationDeadlineOrShapeOverflow` proves no
  partial completion and exercises the exact maximum shape: 512 Events, 32 predicates, depth 16,
  16,384 predicate checks, and 262,144 JSON-node visits.

## Bounds, state transitions, recovery, and reconnect

- `testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState` proves the 64-record
  ingress and 512-record resident bounds, exact one-drain/one-dirty-successor and callback
  diagnostics, O(1)-key eviction horizon, disposition/drop/session transitions, store unavailable
  and recovered markers, accepted-awaiting-visibility state, exact durable visibility removal, and
  joined runtime clearing.
- `testLiveIngressAdmitsOneMaximumEventAndRejectsTheTwentyMiBOverflow` proves one maximum 16-MiB
  journal Event plus fixed overhead is admitted to the 20-MiB ingress, the next value is rejected,
  exactly two 16-MiB accounted resident entries reach the 32-MiB window limit, and one further
  entry evicts exactly the oldest value with one window-overflow marker.
- `testIngressRetainsFailedPrefixUntilExplicitRetry`,
  `testMidRuntimeNondurableDeviceObservationsBecomeRecordingGapAfterRetry`, and
  `testSameCoordinatorRecoveryDoesNotDuplicateDurableLiveDevices` prove failed-prefix retention,
  explicit recovery, exact store rows/status/gaps, and stable live-to-durable device identity.
- `testTerminalClearsQueuedUplinkAndSameRouteReconnectReusesSequenceZero` proves that a terminal
  session clears queued uplink work while a same-route reconnect receives new connection/session
  identity and may independently commit sequence zero.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testRuntimeComponentsKeepOneTypedManagerAndClearLiveStateAfterDurableShutdown -only-testing:NearWireViewerTests/ViewerFoundationTests/testCommittedObservationComparatorAndLiveIngressPreserveTheFirstValue -only-testing:NearWireViewerTests/ViewerFoundationTests/testUntrackedDuplicatesUseDurableAuthorityAndShutdownSealsCallbacks -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveIngressAdmitsOneMaximumEventAndRejectsTheTwentyMiBOverflow -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveEvaluatorMatchesMetadataJSONPresenceAndExcludesTransientFullText -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveEvaluatorReturnsNoPartialCompletionOnCancellationDeadlineOrShapeOverflow -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerScopePreservesLogicalSelectionAcrossPartialMaterialization -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCoordinatorPausesPresentationAndReconcilesExactDurableIdentity -only-testing:NearWireViewerTests/ViewerStoreTests/testDurableDuplicateComparatorPreservesFirstReceiveAndAccountingValues -only-testing:NearWireViewerTests/ViewerStoreTests/testAppendOnlyDispositionPolicyAndDropSamplesAreIdempotentAndDetectConflicts -only-testing:NearWireViewerTests/ViewerStoreTests/testLiveEvaluatorMatchesSQLiteForSharedPredicatesAndExplicitlyExcludesFTS -only-testing:NearWireViewerTests/ViewerStoreTests/testIngressRetainsFailedPrefixUntilExplicitRetry -only-testing:NearWireViewerTests/ViewerStoreTests/testMidRuntimeNondurableDeviceObservationsBecomeRecordingGapAfterRetry -only-testing:NearWireViewerTests/ViewerStoreTests/testSameCoordinatorRecoveryDoesNotDuplicateDurableLiveDevices -only-testing:NearWireViewerTests/ViewerFlowControlTests/testSessionIdentityViolationsNeverCreateCommittedObservations -only-testing:NearWireViewerTests/ViewerFlowControlTests/testTerminalClearsQueuedUplinkAndSameRouteReconnectReusesSequenceZero
```

Result: `TEST SUCCEEDED`; 17 tests executed, 0 failures.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 228 tests executed, 2 skipped, 0 failures.

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
