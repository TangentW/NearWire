# Validation Evidence

Date: 2026-07-15

## Focused regression validation

The final focused suites covered simultaneous Event and Performance ownership, singleton-window
transitions, independent Device selection, active and paused raw reveal, durable-detail rejection,
transient eviction, Store replacement, same-turn close, cancellation/join, publication coalescing,
minimum-size UI, and runtime-unavailable recovery.

Independent final review runs reported:

- `ViewerAnalysisModeCoordinatorTests`: 26 passed, 0 failed.
- Exact-reveal concurrency and fallback set: 5 passed, 0 failed.
- Final architecture lifecycle set: 4 passed, 0 failed.

## Full Viewer suite

Command:

```sh
xcodebuild -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasRequiredFoundationNetworkEntitlements \
  -resultBundlePath /tmp/NearWirePerformanceFinal.xcresult test
```

Result: passed, 453 tests passed, 2 tests skipped, 0 tests failed, 455 tests total.

The signing-dependent entitlement test was excluded from the unsigned suite because an unsigned
test host cannot expose the required signed application entitlements. A signed app build succeeded.
The local signed product was then inspected with `codesign` and contained:

- `com.apple.security.app-sandbox = true`
- `com.apple.security.network.client = true`
- `com.apple.security.network.server = true`
- Team identifier `9PA6Z533LV`

A focused signed XCTest launch was also attempted. Xcode rejected the injected test bundle because
the locally signed host and non-platform XCTest bundle had different Team IDs. This is a local test
injection limitation, not a source or application-build failure. No signing configuration is part of
this change.

## Build validation

Strict-concurrency Viewer build:

```sh
xcodebuild -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete build
```

Result: passed.

Signed Viewer application build:

```sh
xcodebuild -quiet -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS' build
```

Result: passed.

Demo Swift Package integration build:

```sh
xcodebuild -quiet -project Demo/NearWireDemo.xcodeproj -scheme NearWireDemo \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Result: passed.

## Specification and repository checks

```sh
env DO_NOT_TRACK=1 openspec validate dedicated-viewer-performance-window --strict --no-interactive
git diff --check
```

Result: both passed.
