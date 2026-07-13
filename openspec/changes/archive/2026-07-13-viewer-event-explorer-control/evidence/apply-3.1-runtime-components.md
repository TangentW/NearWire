# Task 3.1 Runtime Components Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerRuntimeDependencies` now owns one `makeRuntimeComponents(runtimeLogicalID:)` factory.
  `ViewerApplicationModel.startRuntime()` generates one explicit logical runtime ID and invokes that
  factory exactly once for each start. The old untyped handoff-owner factory, concrete session-
  manager property, and application downcast have been removed.
- Each `ViewerRuntimeComponents` bundle carries the exact runtime ID, a nonzero process-issued
  manager generation, one object serving both admission handoff and typed session control, one live
  projection, one composite journal, generation-matched explorer inputs, and one idempotent cleanup
  receipt. Construction rejects mismatched IDs, generations, live inputs, or facade identity.
- `ViewerMultiDeviceSessionManager` no longer creates a hidden runtime UUID. Its required initializer
  receives the bundle runtime ID and manager generation, starts the composite journal with that exact
  ID, and exposes only the typed control operations required by the application.
- The process-lifetime `ViewerStoreRuntime` remains outside the per-start factory. Live dependencies
  capture that one runtime and its explorer gateway while creating a fresh manager, live window,
  composite journal, cleanup receipt, runtime ID, and manager generation for every start.
- Stop first invalidates application presentation generations, deactivates coalescers, seals manager
  control admission, and seals live presentation. It then joins component cleanup with admission,
  session, and composite-journal shutdown under the existing finite cleanup receipt. The composite
  journal awaits durable `runtimeEnded` before clearing live state.
- Close, termination, retry, TLS reset, full reset, identity-load failure, listener-construction
  failure, listener failure, and collision exhaustion all enter the same idempotent cleanup path.
  Retry and reset wait for that receipt before constructing a new bundle. Failed store recordings
  are closed rather than left active; a blocked automatic store reopen is cancelled and joined.
- Runtime component roots, explorer inputs, live windows, composite journals, and cleanup receipts
  expose closed, content-free reflection.

## Focused runtime validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testRuntimeComponentsKeepOneTypedManagerAndClearLiveStateAfterDurableShutdown -only-testing:NearWireViewerTests/ViewerFoundationTests/testApplicationCreatesOneRuntimeBundlePerStartAndCleansFailedRuntimeBeforeRetry
```

Result: `TEST SUCCEEDED`; 2 tests executed, 0 failures.

The tests prove exact runtime and manager-generation propagation, same-object handoff/control
ownership, one bundle per start, fresh IDs and generations on retry, control/presentation sealing
before shutdown, durable journal completion before live clearing, failed-runtime cleanup before a
new start, and closed reflection.

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerStoreTests/testApplicationFailuresCloseEveryRecordingWhileReusingOneStoreRuntime -only-testing:NearWireViewerTests/ViewerStoreTests/testApplicationRapidStopCancelsPausedAutomaticReopen
```

Result: `TEST SUCCEEDED`; 2 tests executed, 0 failures.

The tests prove that the process store runtime is reused, every materialized recording is terminal
after application failure, retry/reset do not leave active recordings, and termination cancels and
joins a blocked automatic reopen without publishing a stale coordinator.

## Foundation and Store regression

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests -only-testing:NearWireViewerTests/ViewerStoreTests -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 171 tests executed, 2 tests skipped, 0 failures. One skip is the explicitly
deferred configured-signing entitlement gate; the other is the opt-in Application Support artifact
audit requiring its machine-local marker.

## Static and specification validation

- Search found no remaining `makeHandoffOwner`, application `sessionManager`, or
  `as? ViewerMultiDeviceSessionManager` use.
- `xcrun swift-format lint` passed for the affected production and test files. It reported one
  pre-existing `ReplaceForEachWithForLoop` warning in an unchanged test helper.
- `git diff --check` passed.
- `openspec validate viewer-event-explorer-control --strict` reported
  `Change 'viewer-event-explorer-control' is valid`. The optional PostHog flush could not resolve its
  analytics host in the restricted environment after local validation completed.

## Environment boundary

Configured signing and entitlement validation remains deferred to final `release-hardening` by the
user-approved Goal policy. Compilation and tests use `CODE_SIGNING_ALLOWED=NO`,
`ONLY_ACTIVE_ARCH=YES`, and `ARCHS=arm64`; this does not claim configured signing validation passed.
