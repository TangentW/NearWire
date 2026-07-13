# Implementation Validation — Round 14

Date: 2026-07-13 (Asia/Shanghai)

> Superseded for completion purposes by `implementation-validation-round15.md`. Round 14 remains
> historical evidence for the generation-bound cancellation tree before explicit-retry authority,
> construction-quiescence, and physical-worker boundedness remediation.

This is the current completion-validation record after Round 13 remediation. It supersedes Round
13 for completion purposes. Configured signing, entitlement assertions, and the stable-signer
update-boundary probe remain deferred, by user direction, to goal-level `release-hardening` and
are not represented as passing here.

## Disclosed initial test issue

The first four-test command ran after the production remediation but before correcting the
application test's synchronous `MainActor` wait:

```text
ViewerStoreTests: 4 tests, 3 assertion failures in
testApplicationRapidStopCancelsPausedAutomaticReopen, 0 unexpected failures
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-51-26-+0800.xcresult
** TEST FAILED **
```

The three coordinator-level cancellation tests passed. The application test blocked `MainActor`
while synchronously waiting for runtime B, preventing the state transition it intended to test.
The wait was moved to `Task.detached`; no production code changed for this correction. The direct
application regression then passed:

```text
ViewerStoreTests: 1 test, 0 failures
0.019 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-54-24-+0800.xcresult
** TEST SUCCEEDED **
```

One intervening sandboxed `xcodebuild` invocation exited 74 before building or testing because
Xcode/SwiftPM could not write user cache diagnostics. The same command was rerun with the
required local Xcode service/cache access and produced the successful result above. This was an
execution-environment failure, not a product pass or failure.

## Focused recovery and lifecycle regression

The final focused command selected all four Round 13 cancellation regressions and eight adjacent
explicit retry, repeated-start, recovery-claim, sequential-runtime, and application lifecycle
regressions:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound14Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound14ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound14ModuleCache test \
  [12 explicit ViewerStoreTests selections]

ViewerStoreTests: 12 tests, 0 failures
0.228 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-54-57-+0800.xcresult
** TEST SUCCEEDED **
```

## Repeated cancellation stress

Each of the four new cancellation regressions passed 20 iterations:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound14Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound14ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound14ModuleCache \
  test -test-iterations 20 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testTerminalCloseCancelsPausedAutomaticReopen \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testNewerRuntimeSupersedesPausedAutomaticReopen \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testApplicationRapidStopCancelsPausedAutomaticReopen

ViewerStoreTests: 80 tests, 0 failures
1.186 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-56-54-+0800.xcresult
** TEST SUCCEEDED **
```

## Complete Store regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound14Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound14ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound14ModuleCache \
  test -only-testing:NearWireViewerTests/ViewerStoreTests

ViewerStoreTests: 87 tests, 1 explicit live-resource-audit skip, 0 failures
4.133 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-55-19-+0800.xcresult
** TEST SUCCEEDED **
```

## Complete unsigned Viewer regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound14Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound14ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound14ModuleCache test \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe

NearWireViewerTests.xctest: 168 tests, 1 skipped, 0 failures
6.827 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-55-45-+0800.xcresult
** TEST SUCCEEDED **
```

The one skip is the explicit machine-local live Application Support audit marker. The two
configured-signing tests were excluded and are not counted as passing or skipped.

## Complete Swift package regression

Round 13 already built the current Core/SDK tree. Round 14 production and test changes are
Viewer-only, so the isolated build products were reused and every package test was executed:

```text
CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound14SwiftModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound14SwiftModuleCache \
  swift test --disable-sandbox --skip-build \
  --scratch-path /private/tmp/NearWireSwiftPMRound13FullBuild

NearWirePackageTests.xctest: 536 tests, 0 skipped, 0 failures
All tests: 536 tests, 0 skipped, 0 failures
2.821 seconds test execution
exit 0
```

## OpenSpec, hygiene, formatting, and packaging

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches

find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print
exit 0, no output

ruby -c NearWire.podspec
Syntax OK
```

`xcrun swift-format lint --recursive Viewer/NearWireViewer/Store
Viewer/NearWireViewerTests/ViewerStoreTests.swift` exited 0. It reports the same seven
nonblocking `OnlyOneTrailingClosureArgument` API-shape suggestions plus one test-only
`ReplaceForEachWithForLoop` suggestion. All changed Round 13 production and test files were
formatted before validation.

The isolated `swift package dump-package` command exited 0 and reports no external dependencies;
iOS 16, macOS 13, Swift language version 5; and products `NearWire`, `NearWireUI`,
`NearWirePerformance`, and internal `NearWireCore`. No new shell harness, nested manifest, nested
podspec, third-party Core/SDK runtime dependency, or generated-project tool was introduced.

The root package and podspec hashes remain unchanged from the successful Round 9 CocoaPods
validation. Round 13-to-14 production changes are Viewer-only, so that unchanged-input CocoaPods
result remains applicable. No fresh CocoaPods pass is claimed.

`otool -L` on the final Viewer code dylib reports system
`/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)`. `cmp` verified
the built Viewer privacy manifest is byte-for-byte equal to the checked-in manifest.

```text
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1  Package.swift
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33  NearWire.podspec
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  checked-in Viewer privacy manifest
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  built Viewer privacy manifest
```

## Deferred validation

The following configuration-dependent tests remain explicitly deferred to `release-hardening`:

- `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`
- `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe`

They are not represented as passing in this change.
