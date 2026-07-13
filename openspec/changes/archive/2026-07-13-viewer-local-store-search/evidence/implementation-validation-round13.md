# Implementation Validation — Round 13

Date: 2026-07-13 (Asia/Shanghai)

> Superseded for completion purposes by `implementation-validation-round14.md`. Round 13 remains
> historical evidence for the tree before the queued-reopen cancellation remediation; it does not
> establish the Round 13 findings as resolved.

All passing results below are from the current tree after Round 12 remediation. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## Direct lifecycle regressions

The four direct regressions cover repeated same-generation start, sequential automatic reopen success, automatic reopen failure followed by explicit recovery, and Viewer application Retry plus TLS identity reset through one shared store runtime:

```text
ViewerStoreTests: 4 tests, 0 failures
0.102 seconds test execution
/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-32-25-+0800.xcresult
** TEST SUCCEEDED **
```

All four then passed 20 iterations each:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound13Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound13ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound13ModuleCache \
  test -test-iterations 20 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRepeatedRuntimeStartPreservesOriginalContextAndRecoveryOwnership \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testSequentialRuntimeAutomaticallyReopensAfterCompletedShutdown \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testFailedAutomaticSequentialReopenRetainsMarkerForExplicitRetry \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testApplicationRetryAndIdentityResetReuseOneStoreRuntimeAutomatically

ViewerStoreTests: 80 tests, 0 failures
1.748 seconds test execution
/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-35-27-+0800.xcresult
** TEST SUCCEEDED **
```

The first four-test attempt exposed two test-only assumptions and is not represented as passing evidence. Ancient synthetic runtime timestamps caused startup retention to correctly reclaim runtime A, and synchronous RunLoop polling prevented MainActor application status progress. The tests now use current wall time for retention-sensitive sequential recordings and the existing application-status publication pattern. The unchanged production remediation then passed in the fresh results above. The failed result is saved at `/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-29-42-+0800.xcresult`.

## Focused recovery and lifecycle regression

The final focused command selected the four Round 12 remediation regressions and all ten applicable Round 9 through Round 11 recovery and queue regressions:

```text
ViewerStoreTests: 14 tests, 0 failures
0.280 seconds test execution
/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-32-59-+0800.xcresult
** TEST SUCCEEDED **
```

## Complete Store regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound13Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound13ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound13ModuleCache \
  test -only-testing:NearWireViewerTests/ViewerStoreTests

ViewerStoreTests: 83 tests, 1 explicit live-resource-audit skip, 0 failures
4.283 seconds test execution
/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-33-21-+0800.xcresult
** TEST SUCCEEDED **
```

## Complete unsigned Viewer regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound13Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound13ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound13ModuleCache \
  test \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe

NearWireViewerTests.xctest: 164 tests, 1 skipped, 0 failures
6.849 seconds test execution
/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-33-47-+0800.xcresult
** TEST SUCCEEDED **
```

The one skip is the explicit machine-local live Application Support audit marker. The two configured-signing tests were excluded and are not counted as passing or skipped.

## Complete Swift package regression

```text
env CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound13ModuleCache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/NearWireSwiftPMRound13ModuleCache \
  swift test --disable-sandbox \
  --scratch-path /private/tmp/NearWireSwiftPMRound13FullBuild

Build complete
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
2.001 seconds test execution
exit 0
```

The seven existing environment-dependent skips are not represented as passes. SwiftPM reported that the user-level cache is read-only, used the isolated build and module-cache paths, and completed successfully.

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

`xcrun swift-format lint --recursive Viewer/NearWireViewer/Store Viewer/NearWireViewerTests/ViewerStoreTests.swift` exited 0. It reports seven nonblocking `OnlyOneTrailingClosureArgument` API-shape suggestions and one test-only `ReplaceForEachWithForLoop` suggestion. The changed production and test files were formatted before validation.

The isolated `swift package dump-package` check exited 0 and reports no external dependencies; iOS 16, macOS 13, Swift language version 5; and products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`. No new shell harness, nested manifest, nested podspec, third-party Core/SDK runtime dependency, or generated-project tool was introduced.

The root package and podspec hashes remain unchanged from the successful Round 9 CocoaPods validation. Round 12-to-13 production changes are Viewer-only, so that successful unchanged-input CocoaPods result remains applicable. No fresh CocoaPods pass is claimed.

`otool -L` on the final Viewer code dylib reports `/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)`. `cmp` verified the final built Viewer privacy manifest is byte-for-byte equal to the checked-in manifest.

```text
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1  Package.swift
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33  NearWire.podspec
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  final built NearWire.app privacy manifest
```

## Deferred validation

The following configuration-dependent tests remain explicitly deferred to `release-hardening`:

- `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`
- `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe`

They are not represented as passing in this change.
