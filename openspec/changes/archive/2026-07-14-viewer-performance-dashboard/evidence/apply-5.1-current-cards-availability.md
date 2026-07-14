# Apply 5.1 Evidence: Current Cards and Availability

Date: 2026-07-14

## Implemented behavior

- The Viewer root now exposes one shared Events/Performance analysis switch. Performance reuses the
  existing source/device selection and composer; it does not create a second protocol, Store, live
  ingress, Event Explorer, or composer owner.
- The Performance page renders 12 current cards for estimated and maximum FPS, CPU, memory, battery
  level/state, thermal state, low-power mode, App-to-Viewer queue depth, drops, and conditional
  uplink/downlink byte rates.
- Every card has a deterministic English title, SF Symbol, declared unit, closed state text, and a
  combined accessibility label. Measured zero remains numeric zero and is never replaced by an
  unavailable or empty state.
- A fixed section always enumerates the exact ordered 16-key Core inventory, grouped as Process,
  Display, Device, and Transport. GPU utilization, power, Celsius temperature, and Viewer-to-App
  queue depth remain visible there even though they are not current cards. The UI never fabricates
  numeric values for unavailable-only metrics.
- Availability rows disclose measured, invalid, permission-denied, temporarily-unavailable,
  disabled, unsupported, and not-collected retained counts. Before a completed projection they show
  fixed waiting text rather than inferred data.
- Current cards use an adaptive grid. Availability uses a four-column table when it fits and a
  vertically stacked 16-item layout at compact widths, preserving every state and unit without
  horizontal overflow.
- Received metric values have no copy, cut, drag, share, clipboard, export, restoration, preference,
  logging, or analytics surface in this page.

## Focused regression command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-5-1-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests -only-testing:NearWireViewerTests/ViewerFoundationTests/testRootViewComposesWithoutStartingRuntime -only-testing:NearWireViewerTests/ViewerFoundationTests/testRunningRootComposesEventExplorerAndRuntimeCleanupSealsIt
```

Result:

```text
Executed 6 tests, with 0 failures (0 unexpected) in 0.259 (0.261) seconds
** TEST SUCCEEDED **
```

Coverage includes the exact 16-key presentation inventory, explicit 12-card subset, unique keys,
units and symbols, measured-zero formatting, byte-rate formatting, categorical unknown/false,
closed unavailable/not-collected/stale states, every retained availability count, compact and wide
SwiftUI composition, root composition, runtime startup, and joined cleanup.

The compact availability fallback was then added and the same six-test selection was rerun with
`xcodebuild test -quiet`; it exited 0. The test build compiles the full Viewer target, including the
new source entry in the hand-maintained Xcode project.

## Static gates

```text
xcrun swift-format lint --strict Viewer/NearWireViewer/UI/ViewerPerformanceDashboardView.swift Viewer/NearWireViewer/UI/ViewerRootView.swift Viewer/NearWireViewerTests/ViewerFoundationTests.swift
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
