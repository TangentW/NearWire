# Apply 5.3 Evidence: Crosshair, Tooltip, Controls, and Raw Traceability

Date: 2026-07-14

## Implemented behavior

- The Performance page exposes the fixed one-minute, five-minute, fifteen-minute, and current-session
  ranges plus Pause and Resume. A paused range change clears the current cursor, retains only the
  desired successor, starts no traversal, and Resume starts exactly one fresh projection.
- One model-owned crosshair synchronizes all six charts. Pointer hover and drag select the bounded
  bucket nearest the Viewer-time position and the measured series nearest the pointer value. Focused
  chart overlays support left/right bucket movement and up/down series movement without retaining a
  second point model.
- Exactly one aggregate tooltip is visible, under the active chart. It reports the Viewer-time bucket
  span, per-series minimum/average/maximum/count, continuity, availability, and nonmeasurement counts.
  The controller charges exactly one 64-byte crosshair and one 2,048-byte tooltip reservation and
  releases both on clear, replacement, mode transition, and cleanup.
- `Open Source Event` is enabled only when the selected metric accumulator has a deterministic
  representative. The UI sends only the bucket index and metric to the analysis coordinator. The
  controller resolves the metric-specific journal key, and the existing raw resolver performs the
  authoritative durable-then-live lookup before Explorer selection. No bucket, tooltip, decoded
  metric, Event content, or nearest unrelated Event crosses that boundary.
- Deterministic English UI covers one-device guidance, loading, waiting, empty, retained refresh,
  live-window-only, storage-unavailable, invalid chart data, and general failure states.
- The Performance page adds no copy, cut, drag-and-drop, share, clipboard, file-export, preference,
  restoration, logging, analytics, or derived-data export surface. Existing JSON export remains an
  Events-mode action over authoritative raw Events only.

## Focused regression command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-5-3-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests -only-testing:NearWireViewerTests/ViewerPerformanceDashboardControllerTests -only-testing:NearWireViewerTests/ViewerAnalysisModeCoordinatorTests -only-testing:NearWireViewerTests/ViewerPerformanceRawEventResolverTests
```

Result:

```text
Executed 29 tests, with 0 failures (0 unexpected) in 0.158 (0.164) seconds
** TEST SUCCEEDED **
```

Coverage includes six-chart composition, bounded marks, crosshair validation and cleanup, exact
tooltip/crosshair ledger accounting, paused range retention, traversal-ordered mode switching,
metric-specific durable and live raw resolution, live-to-durable continuity, stale/deleted/evicted
guidance, and joined cancellation.

## Unsigned build

```text
xcodebuild build -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-5-3-compile CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
exit 0
```

## Static gates

```text
xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformanceDashboardModel.swift Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift Viewer/NearWireViewer/Application/ViewerAnalysisModeCoordinator.swift Viewer/NearWireViewer/UI/ViewerPerformanceDashboardView.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

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
