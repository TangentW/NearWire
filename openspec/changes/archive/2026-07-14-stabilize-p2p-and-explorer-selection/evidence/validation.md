# Validation Evidence

Date: 2026-07-15

## OpenSpec

Command:

```sh
env OPENSPEC_TELEMETRY=0 openspec validate stabilize-p2p-and-explorer-selection --strict
```

Result: passed with `Change 'stabilize-p2p-and-explorer-selection' is valid`.

## Swift Package

Command:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-stabilize-clang \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-stabilize-swiftpm \
  swift test --disable-sandbox --quiet \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

Result: passed, 546 tests executed with 0 failures under complete strict concurrency and warnings-as-errors. This includes the secure-transport parameter assertions for both App and Viewer roles, exact-match browser quiescence and retention, cancellation during the post-match authorization suspension, setup/handshake/attachment failure release, and active lifetime teardown.

Focused discovery and session admission command:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/nearwire-stabilize-clang \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nearwire-stabilize-swiftpm \
  swift test --disable-sandbox --quiet \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors \
  --filter '(ViewerDiscoveryTests|BonjourBrowserAdapterTests|SDKSessionAdmissionTests)'
```

Result: passed, 104 tests executed, 2 expected restricted-sandbox TLS skips, and 0 failures. The focused cases prove that a match detaches all browser callbacks and pairing-derived coordinator state without cancelling the browser, later result changes perform no work, repeated release cancels the driver once, and every covered terminal path releases the session-owned discovery operation exactly once.

## Viewer Test Suite

Command:

```sh
xcodebuild -quiet \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  test
```

Result: passed; 412 tests executed, 2 expected environment-dependent skips, and 0 failures. This run includes the final deferred-selection, pause-time ownership, and traversal-ownership implementation.

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.15_06-44-23-+0800.xcresult
```

## Focused Viewer Regressions

Command:

```sh
xcodebuild \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  test \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testDeferredEventSelectionIsGenerationBoundLatestOnlyAndResident \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerSuppressesBoundaryRequestsWithoutTraversalOwnership \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testRetainedRefreshFailuresRestoreSelectionReloadState \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerControllerOwnsTraversalAcrossRefreshPaginationAndDetail \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testQueryUsesDimensionAndValueOrWithStableBidirectionalKeysets \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testGapTraversalFreezesLatestRevisionsAndUsesBoundedBidirectionalLanes
```

Result: `** TEST SUCCEEDED **`; 6 focused tests executed with 0 failures. The real-Store controller test explicitly held the coordinator in release and loading, verified zero predecessor Event/gap/detail requests, then verified exactly one successor detail request and single-flight ready-state pagination.

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.15_06-05-51-+0800.xcresult
```

## Pause Ownership Regression

Command:

```sh
xcodebuild -quiet \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  test \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testDeferredEventSelectionIsGenerationBoundLatestOnlyAndResident \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerTraversalOwnershipAdmitsOnlyReadyStoreRowWork \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testPauseDuringReleaseDoesNotClaimTraversalOwnership \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerSuppressesBoundaryRequestsWithoutTraversalOwnership \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerControllerOwnsTraversalAcrossRefreshPaginationAndDetail
```

Result: passed; 5 tests executed with 0 failures. The cases prove that every paused state is non-queryable, pause during release cannot manufacture ownership, Performance-to-Event durable reveal waits for ready traversal ownership, and an older deferred list selection cannot overwrite the exact reveal intent.

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.15_06-38-00-+0800.xcresult
```

## Store-Generation Reveal Regression

Command:

```sh
xcodebuild -quiet \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  test \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testDeferredEventSelectionIsGenerationBoundLatestOnlyAndResident \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerControllerOwnsTraversalAcrossRefreshPaginationAndDetail \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testStoreRematerializationClearsReusedRowIDsUntilReplacementCatalogsCommit
```

Result: passed; 3 tests executed with 0 failures. The cases prove that a nonresident successor drops the pending exact reveal, Store rematerialization invalidates it before a reused Event row ID can cross generations, and exact reveal remains the latest selection intent.

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.15_06-43-51-+0800.xcresult
```

## iOS Demo Build

Command:

```sh
xcodebuild build \
  -project Demo/NearWireDemo.xcodeproj \
  -scheme NearWireDemo \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/nearwire-stabilize-demo \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='-strict-concurrency=complete'
```

Result: `** BUILD SUCCEEDED **` for both arm64 and x86_64 iOS Simulator slices with an iOS 16 deployment target.

## Patch Hygiene

Command:

```sh
git diff --check
```

Result: passed with no whitespace errors.
