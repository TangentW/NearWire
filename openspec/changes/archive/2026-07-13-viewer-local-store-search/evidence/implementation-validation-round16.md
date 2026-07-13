# Implementation Validation — Round 16

Date: 2026-07-13 (Asia/Shanghai)

This is the current completion-validation record after Round 15 remediation. It supersedes Round
15 for completion purposes. Configured signing, entitlement assertions, and the stable-signer
update-boundary probe remain deferred, by user direction, to goal-level `release-hardening` and
are not represented as passing here.

## Repeated remediation stress

The final tree ran all nine explicit-authority, construction-quiescence, superseded-predecessor,
worker-coalescing, runtime-replacement, terminal-close, and real-application scenarios 20 times
each:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound16Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound16ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound16ModuleCache \
  test -test-iterations 20 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testFailedInitialExplicitRetryDoesNotAuthorizeLaterRuntime \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testCancelledInitialExplicitRetryDoesNotAuthorizeLaterRuntime \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testTerminalCloseCancelsPausedAutomaticReopen \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testNewerRuntimeSupersedesPausedAutomaticReopen \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testFinalCurrentRuntimeWaitsForSupersededReopenConstruction \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRepeatedRuntimeSupersessionCoalescesOneReopenSuccessor \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testTerminalCloseDiscardsCoalescedReopenSuccessor \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testApplicationRapidStopCancelsPausedAutomaticReopen

ViewerStoreTests: 180 tests, 0 failures
4.012 seconds test execution
/tmp/NearWireViewerRound16Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-35-42-+0800.xcresult
** TEST SUCCEEDED **
```

## Complete Store regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound16Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound16ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound16ModuleCache \
  test -only-testing:NearWireViewerTests/ViewerStoreTests

ViewerStoreTests: 92 tests, 1 explicit live-resource-audit skip, 0 failures
4.458 seconds test execution
/tmp/NearWireViewerRound16Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-36-15-+0800.xcresult
** TEST SUCCEEDED **
```

## Complete unsigned Viewer regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound16Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound16ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound16ModuleCache test \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe

NearWireViewerTests.xctest: 173 tests, 1 skipped, 0 failures
7.031 seconds test execution
/tmp/NearWireViewerRound16Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-36-31-+0800.xcresult
** TEST SUCCEEDED **
```

The one skip is the explicit machine-local live Application Support audit marker. The two
configured-signing tests were excluded and are not counted as passing or skipped.

## Complete Swift package regression

Round 13 built the current Core/SDK tree. Later production and test remediation is Viewer-only,
so the isolated package build products were reused and every package test was executed:

```text
env CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound16SwiftModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound16SwiftModuleCache \
  swift test --disable-sandbox --skip-build \
  --scratch-path /private/tmp/NearWireSwiftPMRound13FullBuild

NearWirePackageTests.xctest: 536 tests, 7 condition-based skips, 0 failures
All tests: 536 tests, 7 condition-based skips, 0 failures
2.632 seconds test execution
exit 0
```

The seven skips are pre-existing environment/platform gates for restricted trust/network
services, unrestricted real-TLS or real-process proofs, or packaged-runtime source-tree access.
They are not regressions in this Viewer-only remediation and are not represented as passing.

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
Viewer/NearWireViewerTests/ViewerStoreTests.swift` exited 0. It reports seven nonblocking
`OnlyOneTrailingClosureArgument` API-shape suggestions and one test-only
`ReplaceForEachWithForLoop` suggestion. No formatting error is present.

An initial default `swift package dump-package` attempt was blocked because SwiftPM tried to use a
restricted default module cache and its own unavailable nested sandbox. The same manifest was then
evaluated successfully with an isolated module cache and `--disable-sandbox`:

```text
env SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/NearWireRound16ManifestModuleCache \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound16ManifestModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound16ManifestModuleCache \
  swift package --disable-sandbox \
  --scratch-path /private/tmp/NearWireRound16DumpPackage dump-package

exit 0
```

The result has no external dependencies; iOS 16 and macOS 13 platforms; Swift language version 5;
and products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`. No new
shell harness, nested manifest, nested podspec, third-party Core/SDK runtime dependency, or
generated-project tool was introduced.

The root package and podspec hashes remain unchanged from the successful Round 9 CocoaPods
validation. The current remediation is Viewer-only, so that unchanged-input CocoaPods result
remains applicable. No fresh CocoaPods pass is claimed.

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
