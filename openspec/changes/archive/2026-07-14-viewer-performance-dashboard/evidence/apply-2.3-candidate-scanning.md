# Apply Evidence: Task 2.3 Candidate Scanning

Date: 2026-07-14

## Implemented behavior

- Added a forward-only Store candidate scan over the existing
  `EventTimelineByDevice` index with stable `(viewerMonotonicNs, rowID)` ordering.
- Kept `eventType` as an exact residual comparison so matching and nonmatching rows both advance
  the last-examined continuation.
- Classified `length(contentJSON)` before content access. Rows above 65,536 bytes emit only an
  oversized marker; eligible rows are fetched by exact row ID only after aggregate-byte admission.
- Enforced 512 emitted carriers, 4,096 examined candidates, 4,194,304 copied bytes, 5,000,000
  SQLite VM instructions, and an injected 50,000,000-nanosecond monotonic turn.
- Stopped before examining an eligible row that would cross the copied-byte limit, so the next
  continuation retries that exact row.
- Made equality after an examined row return progress and made time/VM exhaustion before any
  candidate a terminal `workLimitExceeded` failure.
- Added cancellation forwarding for the future query-arbiter integration and exposed the service
  through the existing Store coordinator services without adding schema or package dependencies.

## Focused tests

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWire-performance-23-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCandidateScanAdvancesAcrossResidualNonmatches -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCandidateScanCapsEmittedCarriersWithoutSkipping -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCandidateScanRetriesAggregateByteBoundaryAndMarksOversized -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCandidateScanUsesInjectedEqualityAndTerminalNoProgress
```

Exact result:

```text
Test Suite 'ViewerStoreTests' passed.
Executed 4 tests, with 0 failures (0 unexpected) in 0.097 (0.098) seconds
** TEST SUCCEEDED **
```

The focused cases prove:

- the first turn over 4,097 ordinary Events examines exactly 4,096 and returns an advanced empty
  continuation, while the second emits the following snapshot exactly once;
- 513 matching Events split as 512 plus 1 without duplication;
- 66 matching rows with exact 65,536-byte content and one 65,537-byte tail split at exactly
  4,194,304 copied bytes, retry the unexamined row, and retain only metadata for the oversized row;
- injected 50-ms equality yields after one examined match, equality before the first candidate is
  terminal, and the production SQLite budget is exactly 5,000,000 VM steps with no host deadline.

## Build and static validation

```text
xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWire-performance-23-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **

xcrun swift-format lint --strict Core/Sources/NearWireCore/Builtins/Performance/PerformanceSnapshot.swift Core/Tests/NearWireCoreTests/PerformanceSnapshotTests.swift SDK/Sources/NearWirePerformance/Internal/PerformanceSnapshotProjection.swift SDK/Tests/NearWirePerformanceTests/PerformanceSamplerProjectionTests.swift Viewer/NearWireViewer/Application/ViewerPerformanceProjection.swift Viewer/NearWireViewer/Store/ViewerPerformanceStore.swift Viewer/NearWireViewer/Store/ViewerSQLite.swift Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

`git diff -- Viewer/NearWireViewer/Store/ViewerStoreSchema.swift Package.swift NearWire.podspec`
was empty. Schema version remains 2, and no performance table, index, trigger, package dependency,
or migration was introduced.
