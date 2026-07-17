# Implementation Validation

Date: 2026-07-17 (Asia/Shanghai)

## Focused NearWireUI validation

Command:

```text
CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMModuleCache \
swift test --disable-sandbox --scratch-path /tmp/NearWireSDKUIBuild \
  --filter NearWireUITests
```

Result: exit 0. Fifty NearWireUI tests passed with zero failures. The focused total includes seven
new Performance/latest-Viewer-Event tests plus existing connection, lifecycle, rendering, and
accessibility coverage.

## Complete Swift Package validation

Command:

```text
CLANG_MODULE_CACHE_PATH=/tmp/NearWireFullModuleCache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireFullSwiftPMModuleCache \
swift test --disable-sandbox --scratch-path /tmp/NearWireFullBuild \
  -Xswiftc -warnings-as-errors
```

Result: exit 0. The package built in Swift 5 language mode. 553 tests executed, 7 existing
environment-gated tests skipped, and 0 failures occurred.

## iOS maintained Demo build

Command:

```text
xcodebuild -project Demo/NearWireDemo.xcodeproj \
  -scheme NearWireDemo \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/NearWireDemoSDKUIBuild \
  CODE_SIGNING_ALLOWED=NO build
```

Result: exit 0 with `** BUILD SUCCEEDED **`. The Demo target compiled with
`SWIFT_VERSION = 5`, strict concurrency enabled, and warnings as errors. Its dependency graph
included NearWire, NearWireUI, and NearWirePerformance.

The built App contained exactly the two expected owning manifests:

```text
NearWireDemo.app/NearWire_NearWire.bundle/PrivacyInfo.xcprivacy
NearWireDemo.app/NearWire_NearWirePerformance.bundle/PrivacyInfo.xcprivacy
```

## Temporary UIKit consumer

Command:

```text
xcodebuild \
  -project /tmp/NearWireUIKitPreview/NearWireUIKitPreview.xcodeproj \
  -scheme NearWireUIKitPreview \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/NearWireUIKitPreviewDerived \
  CODE_SIGNING_ALLOWED=NO build
```

Result: exit 0 with `** BUILD SUCCEEDED **`. The disposable UIKit application imports the three
public products, injects one `NearWire` and one `NearWirePerformanceMonitor`, and embeds
`NearWirePanelView` through `UIHostingController`. The temporary application and copied package
remain under `/tmp` and are not repository artifacts.

## CocoaPods validation

Command:

```text
pod ipc spec NearWire.podspec
```

Result: exit 0. The parsed spec keeps SDK as the sole default subspec, makes UI depend on
Performance, and keeps Performance dependent on SDK with its separate privacy bundle.

Command:

```text
pod lib lint NearWire.podspec --allow-warnings --skip-tests
```

Result: exit 0 with `NearWire passed validation.` CocoaPods built the default SDK, Core, UI, and
Performance subspec combinations. The first sandboxed attempt could not connect to the configured
local proxy at `127.0.0.1:7890`; the identical lint command passed when allowed to use that
configured connection. This was an environment permission failure, not a source or spec failure.

## Package metadata and formatting

Command:

```text
CLANG_MODULE_CACHE_PATH=/tmp/NearWireMetadataModuleCache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireMetadataSwiftPMCache \
swift package --disable-sandbox \
  --scratch-path /tmp/NearWirePackageMetadata dump-package
```

Result: exit 0. The metadata reports no external package dependency, iOS 16, macOS 13, Swift
language version 5, NearWireUI dependencies on NearWire and NearWirePerformance, and separate
NearWire and NearWirePerformance resource ownership.

Command:

```text
swift format lint --strict <modified NearWireUI production and test Swift files>
```

Result: exit 0 with no formatting finding.

Command:

```text
git diff --check
```

Result: exit 0 with no whitespace error.

## Review disposition

The user explicitly directed that no further review be performed before commit and push. Pending
independent review work was stopped. This evidence records that disposition rather than claiming a
completed no-findings review.

## Spec-to-evidence audit

- UI composition, lifecycle ownership, monitor control, latest-Event filtering/bounding, and
  injected-instance replacement are covered by the 50 focused NearWireUI tests.
- Supported API boundaries, Swift 5 compilation, and interaction with the existing SDK and
  Performance behavior are covered by the 553-test warning-as-error package run.
- SwiftPM product composition and optionality are covered by `dump-package` plus the full package
  build.
- CocoaPods SDK/UI/Performance composition and privacy-resource ownership are covered by the parsed
  podspec, successful `pod lib lint`, and the maintained Demo artifact inspection.
- Public UIKit integration is covered by the disposable consumer build; English and Chinese usage
  are covered by the README updates.

All requirements and scenarios in this change have corresponding implementation and validation
evidence above. No requirement is left without evidence.
