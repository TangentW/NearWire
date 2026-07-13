# Implementation Validation — Round 12

Date: 2026-07-13 (Asia/Shanghai)

Completion status: superseded by Round 13. These results remain accurate for the Round 11 remediation tree, but the subsequent Round 12 architecture/API review found two lifecycle-state gaps. Both were remediated and freshly validated in `implementation-validation-round13.md`.

All passing results below are from the current tree after Round 11 remediation. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## Direct and stress regressions

The two direct zero-observation regressions first passed together:

```text
ViewerStoreTests.testUnavailableRuntimeReopensAfterExplicitRetry
ViewerStoreTests.testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime
2 tests, 0 failures
0.042 seconds test execution
/tmp/NearWireViewerRound12Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-03-41-+0800.xcresult
** TEST SUCCEEDED **
```

Both regressions then passed 100 iterations each:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerRound12Stress \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound12ModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireRound12ModuleCache \
  test -test-iterations 100 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testUnavailableRuntimeReopensAfterExplicitRetry \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime

ViewerStoreTests: 200 tests, 0 failures
3.623 seconds test execution
/tmp/NearWireViewerRound12Stress/Logs/Test/Test-NearWireViewer-2026.07.13_13-07-02-+0800.xcresult
** TEST SUCCEEDED **
```

## Focused recovery and queue regression

The final focused command selected the two Round 11 regressions and all eight Round 9/10 recovery regressions:

```text
ViewerStoreTests: 10 tests, 0 failures
0.212 seconds test execution
/tmp/NearWireViewerRound12Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-05-23-+0800.xcresult
** TEST SUCCEEDED **
```

An earlier 10-test attempt failed only because `testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes` still expected its former total of two. The current semantics correctly produced three: one generation-start marker and two deliberate nondurable policy observations. The exact assertion was updated to three, and the passing result above is fresh. The failed result at `/tmp/NearWireViewerRound12Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-04-36-+0800.xcresult` is not represented as passing evidence.

## Complete Store regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerRound12Store \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound12ModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireRound12ModuleCache \
  test -only-testing:NearWireViewerTests/ViewerStoreTests

ViewerStoreTests: 79 tests, 1 explicit live-resource-audit skip, 0 failures
4.309 seconds test execution
/tmp/NearWireViewerRound12Store/Logs/Test/Test-NearWireViewer-2026.07.13_13-05-36-+0800.xcresult
** TEST SUCCEEDED **
```

## Complete unsigned Viewer regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerRound12Full \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound12ModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireRound12ModuleCache \
  test \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe

NearWireViewerTests.xctest: 160 tests, 1 skipped, 0 failures
6.379 seconds test execution
/tmp/NearWireViewerRound12Full/Logs/Test/Test-NearWireViewer-2026.07.13_13-06-00-+0800.xcresult
** TEST SUCCEEDED **
```

The one skip is the explicit machine-local live Application Support audit marker. The two configured-signing tests were excluded and are not counted as passing or skipped.

## Complete Swift package regression

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound12ModuleCache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMRound12ModuleCache \
  swift test --disable-sandbox \
  --scratch-path /tmp/NearWireSwiftPMRound12FullBuild

Build complete
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
1.985 seconds test execution
exit 0
```

The seven existing environment-dependent skips are not represented as passes. SwiftPM reported that the user-level cache is read-only, used the isolated build and module-cache paths, and completed successfully.

## OpenSpec, hygiene, and formatting

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches
```

`xcrun swift-format lint --recursive Viewer/NearWireViewer/Store Viewer/NearWireViewerTests/ViewerStoreTests.swift` exited 0. It reports seven nonblocking `OnlyOneTrailingClosureArgument` API-shape suggestions and one test-only `ReplaceForEachWithForLoop` suggestion. The changed production and test files were formatted before validation. No new shell harness, nested manifest, nested podspec, third-party Core/SDK runtime dependency, or generated-project tool was introduced.

## Packaging, binary, and privacy validation

- `swift package --disable-sandbox --scratch-path /tmp/NearWirePackageDumpRound12 dump-package`, with isolated module caches, exited 0. It reports no external dependencies; iOS 16, macOS 13, Swift language version 5; and products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`.
- `find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print` exited 0 with no nested manifest or podspec.
- The root package and podspec hashes remain unchanged from the successful Round 9 CocoaPods validation. Round 11-to-12 production changes are Viewer-only, so that successful unchanged-input CocoaPods result remains applicable. No fresh CocoaPods pass is claimed.
- `otool -L` on the final Viewer code dylib reports `/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)`.
- `cmp` verified the final built Viewer privacy manifest is byte-for-byte equal to the checked-in manifest.

Hashes:

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
