# Task 2.2 Explorer Gateway Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerStoreRuntime` owns one `ViewerStoreExplorerGateway` for its process-lifetime store
  boundary. Application dependencies still receive no `ViewerStoreCoordinator.Services`, SQLite
  connection, path, or SQL value.
- Each accepted operation receives an immutable token containing the originating coordinator
  generation and a unique operation UUID.
- The gateway serializes operations inside their originating generation. Generation replacement
  seals admission, changes active operations to the single `storeReplaced` result, cancels query and
  export work, joins the generation, and only then publishes the replacement generation.
- Runtime close and runtime end seal and join the matching originating generation before the
  coordinator closes its SQLite pool. A token from an old generation cannot cancel work in its
  successor.
- Gateway and token reflection are closed and content-free.

## Focused validation

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewaySealsOriginatingGenerationBeforePublishingReplacement -only-testing:NearWireViewerTests/ViewerStoreTests/testRuntimeSealsExplorerOperationsBeforeClosingOriginatingStore test
```

Result: `TEST SUCCEEDED`; 2 tests executed, 0 failures.

The tests block an originating operation, prove replacement/runtime close waits, release the
operation, verify the exact `storeReplaced` result, verify the replacement generation succeeds,
verify stale cancellation does not affect it, and verify a closed runtime reports `unavailable`.

`xcrun swift-format` completed for affected Swift files and `git diff --check` passed.
