# Task 6.4 Control Composer and Privacy Evidence

Date: 2026-07-13

## Bounded input and preparation

- `testIncrementalTextBuffersEnforceEveryOperatorCapWithoutFullValueRescans` verifies multibyte
  UTF-16 replacement ranges, unchanged storage after rejection, all search/path/comparison/name/
  note/annotation caps, and 10,000 accepted capped edits with exactly 10,000 bounded storage copies
  and zero full-value rescans.
- The same test verifies both sides of the composer formula:
  `min(active content, (min(active model, 16 MiB) - 65,536) / 4)`. A smaller content limit remains
  authoritative even with a much larger model limit; maximum active content/model limits are
  reduced to the exact hard-model-derived 4,177,920-byte boundary.
- TTL coverage includes empty, plus sign, minus sign, leading/trailing space, more than nine digits,
  a decimal value beyond `UInt64`, zero, one, exact maximum, and one beyond the active maximum.
- `testComposerPreparerReportsBoundedFailuresWithoutEncodingInvalidInput` proves invalid JSON,
  reserved type, invalid TTL, and cancellation stop before encoding.
- `testComposerPreparationReplacesOneGenerationAndCountsOneSuccessfulPipeline` blocks preparation,
  supersedes the first attempt, rejects the stale result, and records exactly one input copy,
  content traversal, draft validation, and encode for the successful generation. MainActor state
  retains one bounded input buffer and one prepared Event and clears both explicitly.
- `testPreparedControlEventRejectsInvalidEncodedSizes` covers zero and 16-MiB-plus-one rejection;
  `testPreparedControlEventEncodesOnceAndClassifiesTargetsAuthoritatively` constructs the exact
  16-MiB boundary successfully and proves no target-side re-encode.

## Authoritative target classification

- `testPreparedControlEventEncodesOnceAndClassifiesTargetsAuthoritatively` covers all-occurrence
  duplicate rejection, wrong runtime, wrong generation, a capability never issued by the receiving
  same-runtime/same-generation manager, queue rejection, zero/17 target rejection, exact local
  wording, content-free diagnostics, shutdown admission sealing, and no old-capability retargeting.
- `testResolvedSessionRejectsControlWhileNegotiatingAndDisconnecting` resolves one real session and
  proves both negotiating and disconnecting state return `notActive`.
- `testSixteenControlTargetsPreserveMixedAuthoritativeOrder` creates 16 real manager-owned targets:
  four active queues that accept, four active queues with smaller negotiated Event limits that
  reject, four negotiating sessions, and four exact terminal-cache entries. One 16-target send
  preserves every input index and repeats the exact ordered outcomes `queued`, `queueRejected`,
  `notActive`, and `noLongerConnected`; only the four accepted targets say `Queued locally`.
- `testSameRouteReconnectKeepsOldTerminalCapabilityIndependent` proves a new connection capability
  neither removes nor satisfies the old same-route terminal capability.
- `testRecentRowsAreCappedAndExpireAtExactThirtySecondBoundary` creates 65 equal-time terminal
  entries from a deterministic token source. It proves the 64-entry physical cap, token-UUID
  tie-break eviction, retention at 30 seconds minus one nanosecond, and expiration at equality.
- `testControlComposerUsesOpaqueTargetsCancelsReplacedAttemptAndReportsLocalAdmission` blocks the
  preparation queue, supersedes an attempt by changing selection, publishes no late results, and
  then completes one valid attempt with typed result rows before sealing and clearing all state.

## Native editing and clipboard boundary

- `testNativeTextControlsBoundExactEditsAndDisableInspectorClipboardSurfaces` exercises a real
  `NSTextView` standard pasteboard read with `é🙂`, replaces the UTF-16 emoji range with `ab`, and
  then offers an over-cap multibyte paste. AppKit handles the paste command, but the synchronous
  bounded model rejects it before either model or control storage changes.
- Operator controls retain standard user-invoked copy, cut, and paste selectors. Received/stored
  Event controls are noneditable, nonselectable, cannot become first responder, have no menu or
  drag types, and reject copy, cut, and paste command validation. Content and callbacks clear on
  teardown and diagnostic reflection is redacted.
- `testControlComposerScalesToCompactWidthWithDeterministicEditorFocusOrder` verifies the actual
  Event type, JSON, and TTL editors at compact width. `testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt`
  proves the separately disclosed JSON file-export workflow remains reachable while runtime
  cleanup seals and clears composer state.
- Preference corruption/size tests and session-diagnostic tests prove bounded, content-free
  persisted presentation state. A scoped source scan finds no explicit pasteboard read, selection,
  context-menu, drag/share, preference, or logging path in the production Event UI/controllers;
  the only operator pasteboard read is AppKit's user-invoked editor behavior.

## Focused validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFoundationTests/testNativeTextControlsBoundExactEditsAndDisableInspectorClipboardSurfaces -only-testing:NearWireViewerTests/ViewerFoundationTests/testControlComposerScalesToCompactWidthWithDeterministicEditorFocusOrder -only-testing:NearWireViewerTests/ViewerFoundationTests/testIncrementalTextBuffersEnforceEveryOperatorCapWithoutFullValueRescans -only-testing:NearWireViewerTests/ViewerFoundationTests/testComposerPreparerReportsBoundedFailuresWithoutEncodingInvalidInput -only-testing:NearWireViewerTests/ViewerFoundationTests/testComposerPreparationReplacesOneGenerationAndCountsOneSuccessfulPipeline -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt -only-testing:NearWireViewerTests/ViewerFlowControlTests/testPreparedControlEventEncodesOnceAndClassifiesTargetsAuthoritatively -only-testing:NearWireViewerTests/ViewerFlowControlTests/testPreparedControlEventRejectsInvalidEncodedSizes -only-testing:NearWireViewerTests/ViewerFlowControlTests/testResolvedSessionRejectsControlWhileNegotiatingAndDisconnecting -only-testing:NearWireViewerTests/ViewerFlowControlTests/testSixteenControlTargetsPreserveMixedAuthoritativeOrder -only-testing:NearWireViewerTests/ViewerFlowControlTests/testControlComposerUsesOpaqueTargetsCancelsReplacedAttemptAndReportsLocalAdmission -only-testing:NearWireViewerTests/ViewerFlowControlTests/testSameRouteReconnectKeepsOldTerminalCapabilityIndependent -only-testing:NearWireViewerTests/ViewerFlowControlTests/testRecentRowsAreCappedAndExpireAtExactThirtySecondBoundary -only-testing:NearWireViewerTests/ViewerFlowControlTests/testPreferencesApplyPrecedenceBoundsAndCorruptionRecovery -only-testing:NearWireViewerTests/ViewerFlowControlTests/testOversizedPreferenceBlobIsRejectedBeforeDecodeAndRewrittenBoundedly -only-testing:NearWireViewerTests/ViewerFlowControlTests/testSessionSnapshotDiagnosticsExposeOnlyClosedState
```

Result: `TEST SUCCEEDED`; 16 tests executed, 0 failures.

## Complete Viewer validation

Command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
```

Result: `TEST SUCCEEDED`; 230 tests executed, 2 skipped, 0 failures.

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

! rg -n "NSPasteboard|Pasteboard|textSelection|contextMenu|onDrag|draggable|ShareLink|NSSharing|UserDefaults|print\(|NSLog|Logger" Viewer/NearWireViewer/UI/ViewerTextControls.swift Viewer/NearWireViewer/UI/ViewerEventExplorerView.swift Viewer/NearWireViewer/UI/ViewerControlComposerView.swift Viewer/NearWireViewer/Application/ViewerControlComposerController.swift Viewer/NearWireViewer/Application/ViewerEventExplorerController.swift
# exit 0; the scoped rg command produced no match
```
