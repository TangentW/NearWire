# Apply 5.2 Evidence: Bounded System Charts

Date: 2026-07-14

## Implemented behavior

- The Performance page now renders six macOS system Charts views: Frame Rate, CPU, Memory, Battery,
  Throughput, and Queues and Drops. The ten numeric metric series appear exactly once across those
  six groups.
- Each measured aggregate bucket creates one average `LineMark` and one min–max `RectangleMark`.
  Headers explicitly disclose that values are aggregated, distinguish the average line from the
  min–max envelope, and show the bucket and mark counts.
- Battery fraction is presented as percent. Memory and throughput axes use deterministic binary byte
  units; display, CPU, battery, and queue/drop axes use their declared units.
- Every chart shares the full selected monotonic range, expressed as elapsed Viewer time. No App
  wall clock is invented or substituted.
- A per-metric discontinuity makes its bucket an isolated line segment and resets the following
  segment. Missing measurement buckets also split a segment. Therefore a break inside one metric
  does not break unrelated metrics, while the existing Unplaced-gap rule that marks every metric in
  every bucket discontinuous produces no interbucket line at all.
- The chart projection validates the exact six-group/ten-metric inventory, 512-bucket cap, finite
  ordered min/average/max state, and global 12,288-mark cap before any chart is emitted. At the
  maximum 512 measured buckets, the actual two-marks-per-summary shape is 10,240 marks; the existing
  conservative six-chart bound remains exactly 12,288.
- Chart marks are generated lazily from the immutable bucket array. The presentation retains no
  copied point, sample, Event, or content array and adds no third-party dependency.
- Charts expose no copy, cut, drag, share, clipboard, export, restoration, preference, logging, or
  analytics surface for received metric values.

## Focused regression command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-5-2-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests -only-testing:NearWireViewerTests/ViewerPerformanceDashboardModelTests/testCurrentProjectionComposesSystemChartsWithoutStartingAnotherRuntime
```

Result:

```text
Executed 9 tests, with 0 failures (0 unexpected) in 0.080 (0.082) seconds
** TEST SUCCEEDED **
```

Coverage includes exact group/metric order, min/average/max and measurement count, 512-bucket mark
counts, the 12,288 conservative cap, per-metric discontinuity isolation, missing-bucket splits,
all-metric Unplaced-gap suppression, battery/byte/time formatting, and real Swift Charts composition
from a projected current publication without creating another runtime.

After the final formatting assertions were added, the same selection was rerun with
`xcodebuild test -quiet` and exited 0.

## Unsigned build

```text
xcodebuild build -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-5-2-compile CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
exit 0
```

## Static gates

```text
xcrun swift-format lint --strict Viewer/NearWireViewer/Application/ViewerPerformanceChartPresentation.swift Viewer/NearWireViewer/UI/ViewerPerformanceDashboardView.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
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
