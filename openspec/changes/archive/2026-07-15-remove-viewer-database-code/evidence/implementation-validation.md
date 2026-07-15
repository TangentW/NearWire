# Implementation Validation

## Clean Viewer test build

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-remove-db-build CODE_SIGNING_ALLOWED=NO build-for-testing
```

Result: exit `0`, `** TEST BUILD SUCCEEDED **`. The maintained Viewer and its test target compile in Swift 5 language mode with Strict Concurrency enabled. The only linker diagnostics are the existing macOS 13 deployment versus XCTest 14 compatibility warnings.

## Focused regression closure

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-remove-db-build CODE_SIGNING_ALLOWED=NO test-without-building \
  -only-testing:NearWireViewerTests/ViewerWorkspacePresentationTests/testWorkspaceOperationsPublishImmediateExclusiveAndCancellableStates \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testMemorySessionTransferRoundTripsCurrentEventsAndMetadata \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testMemorySessionImportRejectsInvalidAndOverCapacityFilesWithoutReplacement \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testMemorySessionImportCancellationDoesNotReplaceCurrentSession \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testPerformanceDashboardControllerPublishesCurrentMemoryProjectionAndRawLocator -quiet
```

Result: exit `0`. The tests exercise workspace operation states, a real current-memory Session JSON round trip, imported-versus-active Clear behavior, invalid and over-capacity rejection without replacement, active import cancellation without replacement, and Performance target-to-freeze-to-publication with exact raw Event reveal.

## Full maintained Viewer suite

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-remove-db-build CODE_SIGNING_ALLOWED=NO test-without-building \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasRequiredFoundationNetworkEntitlements -quiet
```

Result: exit `0`. The full maintained Viewer suite succeeds after the focused transfer and Performance coverage was added. The entitlement test is excluded because the validation build intentionally uses `CODE_SIGNING_ALLOWED=NO`; signing behavior is outside this change.

## Final format and specification checks

Commands:

```sh
git diff --check
jq empty Viewer/NearWireViewer/Resources/Localizable.xcstrings
openspec validate remove-viewer-database-code --strict
```

Result: all exit `0`; OpenSpec reports `Change 'remove-viewer-database-code' is valid`. The CLI's optional PostHog telemetry flush cannot resolve `edge.openspec.dev` in the restricted environment, but validation itself succeeds and exits zero.
