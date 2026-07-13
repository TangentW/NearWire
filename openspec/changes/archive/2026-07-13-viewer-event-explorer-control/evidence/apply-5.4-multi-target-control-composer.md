# Task 5.4 Multi-Target Control Composer Evidence

Date: 2026-07-13

## Implemented contract

- `ViewerControlComposerController` owns one bounded `ViewerControlComposerModel`, one replaceable
  preparation generation, and one existing runtime session-control authority. SwiftUI receives only
  content-free target presentation rows; exact manager-issued runtime/generation/connection/token
  capabilities remain private to the controller.
- Operators explicitly select between one and sixteen active Apps. A target disappearing, changing
  its opaque capability, or becoming inactive removes it from selection and cancels an in-flight
  preparation. There is no implicit target selection or retargeting.
- The composer accepts bounded Event type and JSON content, low/normal/high priority, empty or
  bounded positive TTL, and normal/keep-latest policy. It reuses the task-4.5 incremental buffers
  and one encode-once prepared draft, then submits the exact captured capabilities in input order.
- Each attempt is replaceable and latest-only. Preparation cancellation publishes no stale result;
  manager admission remains authoritative for active state, runtime/generation/token validity,
  duplicate targets, negotiated limits, queue capacity, and shutdown.
- The latest result contains at most sixteen content-free per-target rows in requested order. The
  successful status is exactly `Queued locally`; typed rejections use the manager's closed safe
  wording. The UI explicitly says local queuing is not delivery, receipt, acknowledgement,
  execution, or processing.
- Runtime shutdown seals the controller, cancels preparation, clears selected targets, input
  buffers, results, and opaque capabilities, and permits no late publication. Reflection contains
  neither Event type nor content.

No templates, favorites, independent send history, reserved platform Event type entry, retry,
delivery claim, preferences, restoration, clipboard history, or third-party dependency was added.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests/testControlComposerUsesOpaqueTargetsCancelsReplacedAttemptAndReportsLocalAdmission -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt -only-testing:NearWireViewerTests/ViewerFoundationTests/testComposerPreparerReportsBoundedFailuresWithoutEncodingInvalidInput -only-testing:NearWireViewerTests/ViewerFoundationTests/testComposerPreparationReplacesOneGenerationAndCountsOneSuccessfulPipeline -only-testing:NearWireViewerTests/ViewerFlowControlTests/testPreparedControlEventEncodesOnceAndClassifiesTargetsAuthoritatively
```

Result: `TEST SUCCEEDED`; 5 tests executed, 0 failures.

These tests prove private opaque target use, exact selection-loss cancellation, no stale publication,
one preparation pipeline and one encoding, authoritative local admission, ordered typed results,
exact `Queued locally` wording, bounded/redacted resident state, and shutdown clearing.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 222 tests executed, 2 skipped, 0 failures.

One skip is the explicit machine-local Application Support audit marker gate. The
configured-signing application entitlement assertion is the other skip and remains intentionally
deferred to the user-approved Goal-level release-hardening verification. This unsigned validation
does not claim release-signing evidence.

## Destination selection diagnostic

The first complete-suite command used the underspecified destination `platform=macOS`. Xcode found
both arm64 and x86_64 destinations for this Apple Silicon Mac, selected the x86_64 compile path, and
failed before testing because the local package modules were unavailable for that architecture:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
# exit 65
# Unable to resolve module dependency: 'NearWireCore'
# Unable to resolve module dependency: 'NearWireTransport'
# Unable to resolve module dependency: 'NearWireFlowControl'
```

The repository's established arm64 destination command above then built and executed the complete
suite. No test, source, or validation gate was weakened to address the destination ambiguity.

## Static and specification validation

Commands and results:

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
# exit 0, no output

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
# Change 'viewer-event-explorer-control' is valid

rg -n "template|favorite|send history|delivery|delivered|acknowledg|processing|UserDefaults|Pasteboard|NSPasteboard" Viewer/NearWireViewer/Application/ViewerControlComposerController.swift Viewer/NearWireViewer/UI/ViewerControlComposerView.swift
# The sole match is the explicit non-delivery disclaimer. No forbidden feature or persistence match exists.
```
