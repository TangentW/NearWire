# Task 2.6 History Mutation and Export Gateway Evidence

Date: 2026-07-13

## Implemented contract

- Recording catalog pages now carry their immutable coordinator/store-generation snapshot. A row
  can create one immutable `ViewerStoreRecordingTarget` bound to that generation, recording row,
  and exact revision. Rename, note, pin/unpin, and annotation requests accept only this target and
  run through the runtime-owned gateway and originating maintenance service.
- Recording update returns a fresh generation-bound target. Stale recording revisions return the
  closed `busy` category. Annotation appends additionally validate the expected recording revision
  and reject tombstoned recordings without weakening the existing bounded text validator, writer
  ordering, capacity accounting, or recovery policy.
- Delete preparation returns an opaque generation-bound confirmation containing the existing exact
  recording-revision, annotation-upper-bound, active-recording, lease-protection, single-use, and
  60-second-expiry authority. A stale annotation/revision, active recording, read/export lease,
  expired token, reused token, or old coordinator changes nothing and returns a closed category.
- Queued mutations may be cancelled before they start. Once a writer mutation starts, cancellation
  is intentionally a no-op so a committed write cannot be reported as cancelled. Coordinator
  replacement still seals and joins that exact non-interruptible writer operation before closing
  its originating store.
- Complete and filtered export preflight return one opaque `ViewerStoreExportTicket` with the safe
  event count and existing unencrypted/pseudonym/content/provider disclosure. The complete ticket
  freezes all export table upper bounds at preflight; the filtered ticket freezes the current query
  and query snapshot without sharing its interactive lease.
- Export execution accepts only that generation-bound ticket plus the operator-selected
  destination. It uses the dedicated export reader and independent finite lease, preserves bounded
  streaming and the nonsymlink/0600 temporary sibling, and atomically replaces the destination only
  after cancellation and lease validation. Destination URLs are not retained. Old-generation
  tickets fail as `storeReplaced` before creating a file.
- Recording targets, delete confirmations, export tickets, gateway operations, and services expose
  closed reflection. Application code receives no SQLite connection/statement/pointer, store path,
  SQL, raw store error, temporary filename, or filesystem phase.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayRoutesRevisionBoundHistoryMutationsAndRejectsOldGeneration -only-testing:NearWireViewerTests/ViewerStoreTests/testExplorerGatewayFreezesPreflightedExportsAndCancellationPreservesDestination -only-testing:NearWireViewerTests/ViewerStoreTests/testDeleteConfirmationIsSingleUseAndInvalidatedByAnnotation
```

Result: `TEST SUCCEEDED`; 3 tests executed, 0 failures.

The tests prove generation/revision binding, exact validator/writer reuse, truthful active-mutation
cancellation, annotation-invalidated delete confirmation, single-use delete, no stale-generation
retargeting, complete and filtered preflight counts, complete and filtered frozen upper bounds,
independent filtered scope, closed reflection, cancelled-export destination preservation, atomic JSON
execution, and rejection of an old-generation ticket before file creation.

## Store regression suite

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests
```

Result: `TEST SUCCEEDED`; 114 tests executed, 1 test skipped, 0 failures. This includes the existing
history revision, active/read-lease delete protection, pin/cleanup, recovery, export disclosure,
frozen query/gap export, file-commit fault, cancellation, hard-link, parent-substitution, and lease-
expiry coverage. The skip is the opt-in Application Support artifact audit requiring the explicit
machine-local marker.

## Viewer regression suite

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 196 tests executed, 2 tests skipped, 0 failures. One skip is the explicitly
deferred configured-signing entitlement gate; the other is the opt-in Application Support artifact
audit.

## Static and specification validation

- `xcrun swift-format lint` passed for the affected gateway, catalog, export, and arbiter production
  files. It reported only existing style warnings in unchanged maintenance/test regions.
- `git diff --check` passed.
- `openspec validate viewer-event-explorer-control --strict` reported
  `Change 'viewer-event-explorer-control' is valid`. The optional PostHog flush could not resolve its
  analytics host in the restricted environment after local validation completed.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64`; this does not claim configured signing validation passed.
