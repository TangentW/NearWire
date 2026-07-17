# Implementation validation

Date: 2026-07-17

## Focused behavior

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/NearWireGapCapacityBuild \
  CODE_SIGNING_ALLOWED=NO test -quiet \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveProjectionUsesExpandedSessionCapacityWithoutAnIndependentRowCap \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testTimelineRowStatusDoesNotAttributeSessionWideGapToAnEvent \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testPerformanceFreezeDrainsIngressAndReportsBoundedApplicableLoss \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveIngressAdmitsItsByteBoundAndRejectsTheSixtyFourMiBOverflow
```

Result: passed, exit 0.

The diagnostic-loss projection assertion was also exercised with:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/NearWireGapCapacityBuild \
  CODE_SIGNING_ALLOWED=NO test -quiet \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testBlockedProjectionReconcilesEndedReplacementBeforeFreshGeneration \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testLiveIngressAdmitsItsByteBoundAndRejectsTheSixtyFourMiBOverflow
```

Result: passed, exit 0.

The review regression for evaluation-independent global diagnostics was exercised with:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/NearWireGapCapacityBuild \
  CODE_SIGNING_ALLOWED=NO test -quiet \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testGlobalGapLanePublishesBeforeEvaluationDelivery \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testTimelineRowStatusDoesNotAttributeSessionWideGapToAnEvent
```

Result: passed, exit 0.

The superseded-evaluation regression was exercised with:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/NearWireGapCapacityBuild \
  CODE_SIGNING_ALLOWED=NO test -quiet \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testSupersededEvaluationCannotStarveGlobalGapLane \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testGlobalGapLanePublishesBeforeEvaluationDelivery
```

Result: passed, exit 0.

## Complete Viewer tests

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/NearWireGapCapacityFinalFullBuild \
  CODE_SIGNING_ALLOWED=NO test -quiet \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasRequiredFoundationNetworkEntitlements
```

Final post-review result: passed, exit 0, in 46.0 seconds.

The excluded test examines the signature of the running test host and cannot pass when
`CODE_SIGNING_ALLOWED=NO`. A separate signed attempt reached test-host loading but failed before the
test ran because the locally signed App and XCTest bundle have different Team IDs. No project or
signing configuration was changed for this scope.

## Maintained build

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/NearWireGapCapacityBuildWarnings \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_SUPPRESS_WARNINGS=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build -quiet
```

Result: passed, exit 0.

`SWIFT_SUPPRESS_WARNINGS=NO` is explicit because Xcode otherwise applies warning suppression to
local Swift Package dependency targets, which conflicts with the command-line warnings-as-errors
gate.

## Specification and source checks

Commands and results:

```text
openspec validate centralize-viewer-gap-warning-and-expand-memory --strict
Change 'centralize-viewer-gap-warning-and-expand-memory' is valid

jq empty Viewer/NearWireViewer/Resources/Localizable.xcstrings
exit 0

git diff --check
exit 0
```

`swift format format --in-place` was applied to the modified Swift files before the final diff was
minimized. A whole-file strict lint also reports pre-existing style findings in those large files,
including unrelated `forEach` uses and indentation outside this change; they were not mechanically
rewritten as part of this narrow scope.
