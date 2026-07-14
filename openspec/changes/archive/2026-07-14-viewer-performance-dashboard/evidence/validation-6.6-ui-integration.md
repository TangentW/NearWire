# Validation 6.6 Evidence: UI and Integration

Date: 2026-07-14

## Coverage

- Target compilation and analysis coordination require exactly one selected App device. Empty or
  ambiguous selection presents fixed guidance and starts no Performance traversal.
- Events-to-Performance and Performance-to-Events tests hold the outgoing traversal behind a gate
  and prove it releases and joins before the successor owner activates. A rapid superseding mode
  change cannot start the abandoned traversal.
- Presentation tests assert the shared ordered 16-metric inventory, the fixed 12 current-card
  subset, every title and unit, measured zero, closed availability states, six chart groups, and the
  exact global mark bound at 512 buckets.
- One model-owned crosshair synchronizes all charts. Controller tests prove a fixed crosshair and
  aggregate-tooltip reservation, idempotent reselection, metric-specific representative lookup,
  rejection for a metric without a representative, and complete release on clear or replacement.
- Keyboard navigation is factored as a stateless presentation function used by SwiftUI's
  `onMoveCommand`. Tests cover first right/left selection, bucket-edge clamping, series movement,
  cyclic up/down selection, and rejection of an empty bucket set without adding retained state.
- Accessibility tests prove exactly 64 unique, evenly selected summaries at 512 buckets including
  the first and last. Labels include deterministic English Viewer time, metric, unit, min/average/
  max/count, discontinuity, and availability text. Chart projection and point reflection is
  redacted, and the dashboard composes at 360, 540, and 980 points.
- Raw traceability uses the selected metric's canonical representative journal key. Resolver tests
  cover stale source rejection before Store access, exact durable identity, live-to-durable
  continuity, exact live fallback, deleted/evicted guidance, storage-unavailable guidance, and
  joined cancellation without substituting a nearby Event.
- Controller, model, analysis coordinator, and raw resolver tests end with cleared presentation,
  released traversal work, zero raw-resolution work, and no stale generation accepted after scope,
  range, mode, or source replacement.

## Focused UI and integration command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-performance-6-6-tests \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests \
  -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceRawEventResolverTests

ViewerAnalysisModeCoordinatorTests: Executed 6 tests, with 0 failures.
ViewerPerformanceDashboardControllerTests: Executed 7 tests, with 0 failures.
ViewerPerformanceDashboardModelTests: Executed 6 tests, with 0 failures.
ViewerPerformancePresentationTests: Executed 10 tests, with 0 failures.
ViewerPerformanceRawEventResolverTests: Executed 4 tests, with 0 failures.
Selected tests: Executed 33 tests, with 0 failures (0 unexpected) in 0.217 seconds.
** TEST SUCCEEDED **
```

## Privacy and static gates

```text
rg -n -i \
  'NSPasteboard|clipboard|copy|cut|onDrag|draggable|ShareLink|fileExporter|AppStorage|SceneStorage|UserDefaults|restoration|Logger|os_log|print\(' \
  Viewer/NearWireViewer/UI/ViewerPerformanceDashboardView.swift \
  Viewer/NearWireViewer/Application/ViewerPerformanceChartPresentation.swift \
  Viewer/NearWireViewer/Application/ViewerPerformanceDashboardModel.swift \
  Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift
no matches (expected exit 1)

xcrun swift-format lint --strict \
  Viewer/NearWireViewer/Application/ViewerPerformanceChartPresentation.swift \
  Viewer/NearWireViewer/UI/ViewerPerformanceDashboardView.swift \
  Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

plutil -lint \
  Viewer/NearWireViewer.xcodeproj/project.pbxproj \
  Viewer/NearWireViewer/Resources/Info.plist \
  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
all files: OK

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

Testing is unsigned and does not claim the deferred Goal-level signed entitlement or stable-signer
validation.
