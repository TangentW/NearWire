# Apply Evidence: Task 2.4 Gateway and Gap Integration

Date: 2026-07-14

## Implemented behavior

- Added one generation-bound Performance traversal to the existing Store Explorer gateway and query
  arbiter. Starting an Event or Performance traversal ends the prior mode before acquiring the next
  finite query lease.
- Frozen Performance scopes now bind Store generation, exact recording/device IDs, inclusive Viewer
  monotonic bounds, and Event/gap upper row IDs captured after visibility validation.
- Routed Event pages and gap pages through the existing serialized operation queue, cancellation
  registration, replacement sealing, joined cleanup, and content-free failure mapping.
- Added discarded-success cleanup: cancellation or replacement after a page candidate completes but
  before delivery ends the exact Performance traversal and releases its lease once.
- Added latest-revision exact-device plus recording-wide gap paging on the existing
  `GapTimelineAllDevices` index, with no temporary sort and no schema change.
- Normalized Store reasons and directions into closed kind/applicability enums. Namespace, reason,
  and direction strings never leave Store-local scanning.
- Classified the complete frozen gap metadata scope into a saturating applicable/uncertain count and
  `hasMoreApplicableGaps`. Generic `hasMoreRows` remains independent.
- Applicable overflow is based on evidence beyond the 128-detail projection cap, not the 32-row
  Store page cap. A 129th irrelevant row changes only generic pagination; a 129th performance or
  uncertain row also changes applicable overflow.
- Bounded complete classification at 2,000,000 SQLite VM instructions and an injected
  250,000,000-nanosecond monotonic deadline. Time, VM, or accepted-plan exhaustion returns
  `hasMoreApplicableGaps = true` conservatively; cancellation still propagates.

## Focused regression suite

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWire-performance-24-final-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceGatewayFreezesEventUpperAndMapsClosedGapMetadata -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceGapClassificationSeparatesGenericAndApplicableOverflow -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceGatewayCancellationAfterPageCandidateReleasesTraversal -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerQueryArbiterOwnsOneTraversalAndFilteredExportUsesIndependentLease -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCandidateScanAdvancesAcrossResidualNonmatches -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCandidateScanCapsEmittedCarriersWithoutSkipping -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCandidateScanRetriesAggregateByteBoundaryAndMarksOversized -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCandidateScanUsesInjectedEqualityAndTerminalNoProgress
```

Exact result:

```text
Test Suite 'ViewerStoreTests' passed.
Executed 8 tests, with 0 failures (0 unexpected) in 0.159 (0.160) seconds
Test Suite 'Selected tests' passed.
Executed 8 tests, with 0 failures (0 unexpected) in 0.159 (0.161) seconds
** TEST SUCCEEDED **
```

The focused cases additionally prove:

- Event and gap upper bounds exclude rows committed after the traversal freeze;
- all Store kind and applicability families map to closed values without reflecting source strings;
- one shared query lease remains one across paging and returns to zero after end;
- two otherwise identical 129-row scopes distinguish an irrelevant-only tail from an applicable
  tail;
- injected 250-ms classification equality fails closed;
- cancellation after a successful but not-yet-delivered page returns `cancelled`, releases the
  traversal lease, and clears the SQLite operation cancellation registration;
- the pre-existing Event traversal and independent export-lease behavior remains unchanged.

## Build and static validation

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWire-performance-24-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **

xcrun swift-format lint --strict Core/Sources/NearWireCore/Builtins/Performance/PerformanceSnapshot.swift Core/Tests/NearWireCoreTests/PerformanceSnapshotTests.swift SDK/Sources/NearWirePerformance/Internal/PerformanceSnapshotProjection.swift SDK/Tests/NearWirePerformanceTests/PerformanceSamplerProjectionTests.swift Viewer/NearWireViewer/Application/ViewerPerformanceProjection.swift Viewer/NearWireViewer/Store/ViewerPerformanceStore.swift Viewer/NearWireViewer/Store/ViewerSQLite.swift Viewer/NearWireViewer/Store/ViewerStoreMaintenance.swift Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift Viewer/NearWireViewer/Store/ViewerExplorerQueryArbiter.swift Viewer/NearWireViewer/Store/ViewerStoreExplorerGateway.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

One intermediate sandboxed rerun failed before compilation because Xcode/SwiftPM could not write
user module-cache paths. The identical standalone `xcodebuild` command was rerun with the already
approved Xcode permission and passed as recorded above. No validation gate was weakened.

`git diff -- Viewer/NearWireViewer/Store/ViewerStoreSchema.swift Package.swift NearWire.podspec`
was empty. Schema version remains 2, and no table, index, trigger, migration, package dependency, or
runtime dependency was added.
