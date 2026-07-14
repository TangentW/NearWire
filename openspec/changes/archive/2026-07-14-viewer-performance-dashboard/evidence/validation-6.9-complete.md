# Validation 6.9 Evidence: Complete Build, Test, and Static Gates

Date: 2026-07-14

## Result

The unsigned Viewer production build, complete applicable Viewer suite, complete root Swift Package
suite, Swift formatting, package and Xcode-project inspection, plist and privacy inspection, and
strict OpenSpec validation pass.

Configured distribution signing, the running signed-product entitlement assertion, and the
stable-signer cross-update test remain outside this change. They are intentionally deferred to the
Goal-level `release-hardening` change and are not claimed by this evidence.

## Unsigned Viewer production build

```text
xcodebuild build -workspace NearWire.xcworkspace -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-performance-6-9-build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64

** BUILD SUCCEEDED **
```

The build resolved only the repository-local `NearWire` package. Xcode emitted the existing notice
that App Intents metadata extraction was skipped because the target has no AppIntents dependency.

## Complete Viewer suite

```text
xcodebuild test -quiet \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-performance-6-9-viewer-tests-clean \
  -resultBundlePath /tmp/NearWire-Viewer-Performance-6-9-clean-20260714-1229.xcresult \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement

exit 0
```

The exact result summary was read with:

```text
xcrun xcresulttool get test-results summary \
  --path /tmp/NearWire-Viewer-Performance-6-9-clean-20260714-1229.xcresult

result: Passed
totalTestCount: 369
passedTests: 367
skippedTests: 2
failedTests: 0
expectedFailures: 0
```

The result's test operation completed in 45.449 seconds. The 100,000-input deterministic projection
test is part of this complete suite. The two self-skips are the stable-signer packaging probe without
its explicit signed phase configuration and the live Application Support artifact audit without its
machine-local opt-in marker. The running-product entitlement test is command-excluded because an
unsigned host cannot provide its stated evidence. None is counted as signed-product validation.

Xcode emitted its existing macOS 13 target/XCTest 14 linker warning and signed XCTest-library copy
warnings. They did not affect compilation or execution.

### Environmental interruption and clean rerun

The first complete-suite attempt reached an environmental failure while Xcode collected its log
archive:

```text
OSLogErrorDomain Code=28
No space left on device
```

The data volume had only 138 MiB available. SQLite migration tests then reported failures while
creating their fixtures, so that run was not accepted as product evidence. Only this change's
rebuildable `/private/tmp/nearwire-performance-*` DerivedData and failed result bundle were removed;
no repository evidence or user data was changed. Available capacity became 14 GiB. The same test
selection, signing policy, architecture, and assertions were run from fresh DerivedData and produced
the passing result above. No test or implementation was weakened.

## Complete root Swift Package suite

```text
swift test

NearWirePackageTests.xctest: Executed 539 tests, with 0 failures (0 unexpected).
All tests: Executed 539 tests, with 0 failures (0 unexpected) in 2.101 seconds.
exit 0
```

The first sandboxed invocation did not compile the manifest because the compiler could not write
`~/.cache/clang/ModuleCache`. The unchanged command passed with standard compiler-cache access. No
package option, test selection, or assertion changed.

## Swift, resource, and OpenSpec gates

```text
xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

plutil -lint \
  Viewer/NearWireViewer.xcodeproj/project.pbxproj \
  Viewer/NearWireViewer/Resources/Info.plist \
  Viewer/NearWireViewer/Resources/NearWireViewer.entitlements \
  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
all four files: OK

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

## Package and project boundary inspection

```text
swift package dump-package
exit 0
```

The dumped root manifest confirms:

- no package dependencies;
- iOS 16 and macOS 13 minimum platforms;
- Swift language version 5;
- the existing `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`
  products;
- Core, SDK, and tests remain in their assigned repository directories.

```text
rg --files Core SDK Viewer Demo -g 'Package.swift' -g '*.podspec'
no matches (expected exit 1)

ls -l Package.swift NearWire.podspec
both root files exist
```

No nested manifest or podspec was added. The Viewer project continues to own Viewer-only source and
the root package continues to contain no Viewer runtime target or dependency.

```text
xcodebuild -showBuildSettings \
  -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' | \
  rg '^    (CODE_SIGN_ENTITLEMENTS|ENABLE_APP_SANDBOX|ENABLE_HARDENED_RUNTIME|MACOSX_DEPLOYMENT_TARGET|PRODUCT_BUNDLE_IDENTIFIER|PRODUCT_NAME|SWIFT_STRICT_CONCURRENCY|SWIFT_VERSION) ='

CODE_SIGN_ENTITLEMENTS = NearWireViewer/Resources/NearWireViewer.entitlements
ENABLE_APP_SANDBOX = YES
ENABLE_HARDENED_RUNTIME = YES
MACOSX_DEPLOYMENT_TARGET = 13.0
PRODUCT_BUNDLE_IDENTIFIER = com.nearwire.viewer
PRODUCT_NAME = NearWire
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_VERSION = 5.0
```

`rg -n 'Viewer(Performance|AnalysisMode).*\.swift'` against `project.pbxproj` confirms all eleven
new Store, application, coordination, presentation, and UI files have file references, groups, and
Sources build-phase entries. The successful clean build and complete test suite provide compilation
evidence for those entries.

## Plist and privacy inspection

`Info.plist` retains the `_nearwire._tcp` Bonjour service, local-network usage text, app identity,
and macOS deployment substitution. It adds no dashboard-specific service or background mode.

```text
plutil -p Viewer/NearWireViewer/Resources/NearWireViewer.entitlements
com.apple.security.app-sandbox = true
com.apple.security.network.server = true
```

The entitlement source remains limited to the established Viewer listener boundary. The unsigned
build does not prove the entitlements embedded in a configured signed product.

```text
plutil -p Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
NSPrivacyTracking = false
NSPrivacyAccessedAPITypes = UserDefaults / CA92.1
NSPrivacyCollectedDataTypes = linked DeviceID for App Functionality, not tracking
```

The performance dashboard introduced no new required-reason API or collected-data declaration.

```text
rg -n -i \
  'NSPasteboard|clipboard|copy|cut|onDrag|draggable|ShareLink|fileExporter|AppStorage|SceneStorage|UserDefaults|restoration|Logger|os_log|print\(' \
  Viewer/NearWireViewer/UI/ViewerPerformanceDashboardView.swift \
  Viewer/NearWireViewer/Application/ViewerPerformanceChartPresentation.swift \
  Viewer/NearWireViewer/Application/ViewerPerformanceDashboardModel.swift \
  Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift \
  Viewer/NearWireViewer/Application/ViewerPerformanceRawEventResolution.swift
no matches (expected exit 1)
```

No copy, share, drag, derived export, persistence, or logging surface was added for received metrics.
