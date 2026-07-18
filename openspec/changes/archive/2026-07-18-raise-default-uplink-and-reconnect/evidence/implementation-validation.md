# Implementation Validation

## Swift Package tests

Command:

```sh
SWIFT_MODULECACHE_PATH=/tmp/nearwire-swift-module-cache \
CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache \
swift test
```

Result: exit `0`. All 555 tests passed with zero failures after the first review fixes. This covers the Core rate and queue
primitives, SDK defaults and lifecycle orchestration, explicit recovery opt-out, the SDK active
Event pump, the default one-second automatic recovery path, and the package's public products.

## Swift Package Release build

Command:

```sh
SWIFT_MODULECACHE_PATH=/tmp/nearwire-swift-module-cache \
CLANG_MODULE_CACHE_PATH=/tmp/nearwire-clang-module-cache \
swift build -c release
```

Result: exit `0`. All root-package products compiled in Swift 5 language mode. SwiftPM required
execution outside the managed filesystem sandbox because its own nested `sandbox-exec` could not
start inside that sandbox; the source and command were otherwise unchanged.

## Viewer clean test build

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-uplink-validation \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing -quiet
```

Result: exit `0`. The Viewer and test target compiled successfully. Diagnostics were limited to
Xcode's existing XCTest deployment-version and non-stripping notes.

## Viewer maintained suite

Command:

```sh
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-uplink-validation \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasRequiredFoundationNetworkEntitlements \
  -skip-testing:NearWireViewerTests/ViewerLocalizationTests/testViewerSourceBoundaryCoversFixedLocalizationCallsAndAppKitPanels \
  -quiet
```

Result: exit `0`. This includes the flow-control suite, preference migration, live projection,
Performance freeze, and the 100,000-offer bounded-ingress stress test. The entitlement packaging
probe is intentionally excluded from the unsigned build.

The localization source-boundary test was also excluded because the current Xcode 26.5 host stops
responding after that test starts and leaves the coordinator waiting for a worker; the same behavior
reproduces when the localization suite is run alone. All eight preceding localization tests pass,
and a standalone Foundation invocation of the test's complete Swift-source enumeration and both
regular-expression scans exits `0` over every Viewer Swift source. This change modifies no Viewer
UI string or localization catalog.

Focused reruns of the tests added or adjusted for recovery and ingress bounds also passed:

- `testDefaultConfigurationSchedulesAutomaticRecoveryAfterOneSecond`
- `testLiveProjectionAdmitsFullMinimumAccountedIngressCapacity`
- `testHundredThousandLiveOffersUseOneBoundedDrainAndRefreshWake`
- `testLiveProjectionEnforcesIngressAndWindowBoundsAndTracksRuntimeState`
- `testPerformanceFreezeDrainsIngressAndReportsBoundedApplicableLoss`

The complete maintained Viewer command above was rerun after adding the 2,048-entry minimum-accounted
capacity test and exited `0` against the final reviewed source.

## CocoaPods

Commands:

```sh
pod ipc spec NearWire.podspec
pod lib lint NearWire.podspec --allow-warnings --skip-tests
```

Result: both exit `0`; CocoaPods reports `NearWire passed validation.` The first lint attempt inside
the managed sandbox could not reach the machine's configured proxy at `127.0.0.1:7890`. The
identical command passed after network access was permitted.

## Formatting and specification gates

Commands:

```sh
xcrun swift-format lint --strict \
  SDK/Sources/NearWire/NearWirePublicModels.swift \
  SDK/Sources/NearWire/Session/SDKSessionTransportCore.swift \
  SDK/Tests/NearWireTests/NearWireConfigurationTests.swift \
  SDK/Tests/NearWireTests/SDKPublicConnectionOrchestrationTests.swift \
  SDK/Tests/NearWireTests/SDKSessionAdmissionTests.swift \
  Viewer/NearWireViewer/Application/ViewerLiveEventProjection.swift \
  Viewer/NearWireViewer/Session/ViewerDevicePreferences.swift \
  Viewer/NearWireViewer/Session/ViewerMultiDeviceSession.swift \
  Viewer/NearWireViewerTests/ViewerFlowControlTests.swift
git diff --check
openspec validate raise-default-uplink-and-reconnect --strict
```

Result: all exit `0`; OpenSpec reports
`Change 'raise-default-uplink-and-reconnect' is valid`. The optional PostHog telemetry flush cannot
resolve `edge.openspec.dev` in the restricted environment after validation succeeds and does not
change the exit status.

`ViewerFoundationTests.swift` is validated by its compiled and passing focused/full tests. A
whole-file strict format lint still reports two pre-existing `forEach` style findings at lines 266
and 274, outside the changed ingress tests; they were not rewritten as unrelated work.
