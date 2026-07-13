# Implementation Validation — Round 5

Date: 2026-07-13 (Asia/Shanghai)

All results are from the current tree after Round 4 remediation. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## OpenSpec and diff hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output
```

## Complete unsigned Viewer regression

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Result bundle:

```text
/tmp/NearWireViewerDerived/Logs/Test/Test-NearWireViewer-2026.07.13_08-40-15-+0800.xcresult
```

Exact `xcresulttool` metrics and command result:

```text
testsCount: 126
testsSkippedCount: 1
failures: 0
** TEST SUCCEEDED **
```

The one skip is the explicitly opt-in live Application Support audit. The two configured-signing tests were excluded from this unsigned command and are not counted as skips or passes.

The focused `ViewerStoreTests` regression executed 49 tests with one opt-in skip and zero failures. It recorded:

```text
NearWire incremental reclaim freelist: 2112 -> 2048
NearWire incremental reclaim page count: 2161 -> 2097
NearWire incremental reclaim main size: 8851456 -> 8851456
NearWire incremental reclaim main allocated bytes: 8851456 -> 8851456
NearWire incremental reclaim WAL allocated bytes: 0 -> 12288
NearWire near-maximum deterministic Event bytes: 15729853
NearWire sustained WAL allocated bytes: 2076672
```

## Root Swift package regression

Command:

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMModuleCache swift test --disable-sandbox --scratch-path /tmp/NearWireSwiftPMBuild
```

Exact summary:

```text
NearWirePackageTests.xctest: 531 tests, 7 skipped, 0 failures
All tests: 531 tests, 7 skipped, 0 failures
```

The explicit SwiftPM sandbox disablement avoids nesting SwiftPM's sandbox inside the managed execution sandbox; compiler and package scratch data remain under `/tmp`. No test or source gate was weakened.

## Packaging, binary, and privacy inspection

- `swift package --disable-sandbox --scratch-path /tmp/NearWirePackageDump dump-package`: no external dependencies; iOS 16 and macOS 13; Swift language version 5; products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`.
- `find`: only root `./Package.swift` and `./NearWire.podspec`.
- `ruby -c NearWire.podspec`: `Syntax OK`.
- Existing `Scripts/verify-podspec.sh`: passed unchanged under CocoaPods 1.16.2; only the pre-existing invalid-example-URL warning was emitted.
- Built Viewer debug dylib: `/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)`.
- Built Viewer privacy manifest matches the checked-in manifest byte-for-byte and declares UserDefaults reason `CA92.1`, linked/nontracking Device ID for app functionality, and tracking false.

Hashes:

```text
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1  Package.swift
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33  NearWire.podspec
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  built NearWire.app/Contents/Resources/PrivacyInfo.xcprivacy
```

The first restricted CocoaPods invocation could not reach the configured local proxy at `127.0.0.1:7890`; the unchanged repository verification script passed with approved external access.

## Deferred validation

The following unchanged tests require project-specific signing configuration and remain explicitly deferred to `release-hardening`:

- `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`
- `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe`

They are not represented as passing in this change.
