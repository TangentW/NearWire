# Apply 5.4 Evidence: Accessibility, Privacy, and Scalable Layout

Date: 2026-07-14

## Implemented behavior

- Each system Chart replaces its default mark-level accessibility representation with one
  deterministic English chart description and evenly distributed bucket summaries. The existing
  bounded selector returns every bucket when there are at most 64 and exactly 64 unique indices,
  including the first and last, when there are up to 512.
- Each bucket summary combines Viewer-relative time, every metric name and unit in that chart,
  minimum/average/maximum/count or explicit no-measurement state, continuity, availability, and
  retained availability counts. The summaries are generated from the currently presented immutable
  buckets; no second sample array, persistent accessibility store, or raw Event content is retained.
- Multi-series charts use deterministic solid, long-dash, and short-dash line styles in addition to
  color and legends. Current cards, availability rows, notices, selection, discontinuity, empty,
  loading, and error states all expose text or shape semantics and do not depend on color alone.
- Range controls use a horizontal-first `ViewThatFits` layout with a vertical fallback. Cards remain
  adaptive, availability uses its existing wide table/compact stack fallback, and dashboard
  composition was exercised at 360-, 540-, and 980-point widths.
- Accessibility labels and hints are deterministic English. Current cards and availability rows
  combine metric, unit, value/state, and retained counts. Chart presentation values and timestamps
  use redacted descriptions and empty reflection mirrors.
- Source inspection found no pasteboard, clipboard, copy, cut, drag, share, file-export, preference,
  restoration, logging, analytics, or print sink in the Performance presentation/model/controller
  boundary. Clearing the model therefore removes the only source from which accessibility labels are
  generated.

## Focused regression command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-5-4-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests
```

Result:

```text
Executed 26 tests, with 0 failures (0 unexpected) in 0.193 (0.198) seconds
** TEST SUCCEEDED **
```

Coverage includes the exact 64-summary cap and first/last inclusion at 512 buckets, deterministic
metric/unit/time/statistics/discontinuity/availability text, redacted point/projection reflection,
360/540/980-point composition, six-chart bounds, model/controller clearing, and mode/range lifecycle
ordering.

## Unsigned build

```text
xcodebuild build -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-5-4-compile CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
exit 0
```

## Static gates

```text
xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformanceChartPresentation.swift Viewer/NearWireViewer/UI/ViewerPerformanceDashboardView.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

rg -n -i "NSPasteboard|clipboard|copy|cut|onDrag|draggable|ShareLink|fileExporter|AppStorage|SceneStorage|UserDefaults|restoration|Logger|os_log|print\\(" Viewer/NearWireViewer/UI/ViewerPerformanceDashboardView.swift Viewer/NearWireViewer/Application/ViewerPerformanceChartPresentation.swift Viewer/NearWireViewer/Application/ViewerPerformanceDashboardModel.swift Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift
no matches (expected exit 1)

plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj Viewer/NearWireViewer/Resources/Info.plist Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK
Viewer/NearWireViewer/Resources/Info.plist: OK
Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy: OK

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

The build and test commands intentionally disable code signing. They do not claim signed embedded
entitlement or stable-signer validation. Those externally configured checks remain deferred to the
Goal-level `release-hardening` change.
