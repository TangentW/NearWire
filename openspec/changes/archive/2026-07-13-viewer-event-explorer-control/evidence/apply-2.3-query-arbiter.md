# Task 2.3 Query Arbiter Evidence

Date: 2026-07-13

## Implemented contract

- Each explorer coordinator generation owns one non-MainActor
  `ViewerExplorerQueryArbiter`. It is the sole mutable owner of the current
  `ViewerEventTraversal` and refreshed query lease.
- Query replacement, page, detail, filtered-export scope creation, and traversal release serialize
  through the originating generation and arbiter. The same arbiter is the required serialization
  point for gap and causality services added by task 2.5; those operations cannot bypass it.
- Every accepted reader operation receives an immutable coordinator-generation/operation-UUID
  token before enqueue. Internal cancellation and generation ownership retires before arbitrary
  completion code; the controller separately owns any claimed MainActor result delivery.
- Queued cancellation marks only the queued token. Active cancellation interrupts only the exact
  active token. Cancellation of a completed, superseded, or old-generation token is a no-op for its
  successor.
- Generation replacement serializes detach/seal/publish, converts unfinished old-generation work
  to `storeReplaced`, joins operation ownership, closes the arbiter, and releases the originating
  traversal before replacement availability publishes. Deferred arbitrary callbacks run only after
  transition ownership is released.
- Filtered export freezes only immutable query and snapshot values. Export execution acquires and
  releases its own finite export lease and never transfers or refreshes the interactive query lease.
- Application-facing failures are closed categories. Operation tokens, query traversal, filtered
  export scope, arbiter, and gateway reflection expose no query, content, path, SQL, or raw error.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewaySealsOriginatingGenerationBeforePublishingReplacement -only-testing:NearWireViewerTests/ViewerStoreTests/testRuntimeSealsExplorerOperationsBeforeClosingOriginatingStore -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewaySerializesQueryPageDetailAndFilteredScope -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayCancellationIsQueuedCompletedAndActiveSuccessorSafe -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayReplacementRetiresOperationBeforeArbitraryCompletion -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayLinearizesExternalAndCallbackReplacementWithoutOrphanGeneration -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerQueryArbiterOwnsOneTraversalAndFilteredExportUsesIndependentLease
```

Result: covered by the fresh round-7 focused gateway run and the complete Viewer rerun recorded in
`implementation-review-round7-remediation.md`.

The tests prove serial query/page/detail/scope behavior, exact release after repeated query
replacement, idempotent traversal end/close, queued and completed cancellation successor safety,
active cancellation isolation, completion-inclusive generation joining, immutable frozen export
results, and an export lease that exists during execution and is absent after commit.

## Store regression suite

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests
```

Result: `TEST SUCCEEDED`; 104 tests executed, 1 test skipped, 0 failures. The skipped test is the
existing opt-in Application Support artifact audit, which requires the explicit machine-local
`/tmp/nearwire-live-container-audit.enabled` marker.

## Static and specification validation

- `xcrun swift-format` formatted all affected Swift files. Lint found only the unchanged pre-existing
  `ReplaceForEachWithForLoop` warning in `ViewerStoreTests.swift`.
- `git diff --check` passed.
- `openspec validate viewer-event-explorer-control --strict` reported
  `Change 'viewer-event-explorer-control' is valid`.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64` on this Apple-silicon host; this does not claim that
signing validation passed.
