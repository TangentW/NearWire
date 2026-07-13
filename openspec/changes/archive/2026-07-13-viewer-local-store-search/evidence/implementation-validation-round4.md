# Implementation Validation — Round 4

Date: 2026-07-13 (Asia/Shanghai)

All results are from the current tree after Round 3 remediation. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## OpenSpec and diff hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output
```

## Complete unsigned Viewer regression

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Exact summary:

```text
ViewerFlowControlTests: 23 tests, 0 failures
ViewerFoundationTests: 54 tests, 0 failures
ViewerStoreTests: 44 tests, 0 failures
NearWireViewerTests.xctest: 121 tests, 0 failures
** TEST SUCCEEDED **
```

The output also recorded:

```text
NearWire near-maximum deterministic Event bytes: 15729853
NearWire sustained WAL allocated bytes: 2076672
```

## Root Swift package regression

Command: `swift test`

Exact summary:

```text
NearWirePackageTests.xctest: 531 tests, 0 failures
All tests: 531 tests, 0 failures
```

The first restricted invocation failed because compiler and SwiftPM caches were not writable. The identical command passed with approved cache access.

## Focused near-maximum payload measurement

Command: `/usr/bin/time -l` followed by the focused `xcodebuild` test for `ViewerStoreTests/testNearMaximumPayloadUsesBoundedOversizeTransaction`.

Exact relevant result:

```text
NearWire near-maximum deterministic Event bytes: 15729853
Executed 1 test, with 0 failures
test duration: 0.132 seconds
maximum resident set size: 206372864 bytes
peak memory footprint: 107627576 bytes
** TEST SUCCEEDED **
```

## Packaging, binary, and privacy inspection

- `swift package dump-package`: no external dependencies; iOS 16 and macOS 13; Swift language version 5; products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`.
- `find`: only root `./Package.swift` and `./NearWire.podspec`.
- `ruby -c NearWire.podspec`: `Syntax OK`.
- Existing `Scripts/verify-podspec.sh`: passed unchanged under CocoaPods 1.16.2; only the pre-existing invalid-example-URL warning was emitted.
- Built Viewer: `/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)`.
- Built privacy manifest: UserDefaults reason `CA92.1`; linked/nontracking Device ID for app functionality; tracking false.

Manifest hashes:

```text
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1  Package.swift
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33  NearWire.podspec
```

## Deferred validation

The following tests are unchanged and explicitly deferred to `release-hardening` because they require configured signing:

- `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`
- `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe`

They are not represented as passing in this change.
