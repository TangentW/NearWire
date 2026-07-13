# Implementation Validation — Round 11

Date: 2026-07-13 (Asia/Shanghai)

Completion status: superseded by Round 12. These results remain accurate for the Round 10 remediation tree, but the subsequent Round 11 architecture/API review found one zero-observation runtime-start ownership gap. The finding was remediated and freshly validated in `implementation-validation-round12.md`.

All passing results below are from the current tree after Round 10 remediation. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## Focused Round 10 remediation

The two direct finding regressions first passed together:

```text
ViewerStoreTests.testDirectMaterializationFailureAndFailedRetryCannotReopenIngress
ViewerStoreTests.testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork
2 tests, 0 failures
0.046 seconds test execution
/tmp/NearWireViewerRound11Focused/Logs/Test/Test-NearWireViewer-2026.07.13_12-43-23-+0800.xcresult
** TEST SUCCEEDED **
```

The final focused command selected those two regressions plus every Round 9 remediation regression:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/NearWireViewerRound11Focused ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testQueuedSettingsRecoveryIsRevokedByANewerNonrecoveringRevision \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRunningSettingsRecoveryIsRevokedBeforePublicationByNewerRevision \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRuntimeShutdownQuiescesMaintenanceBeforeOneTerminalFlush \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLatestOnlyChangeSignalCarriesSafeRecordingAndUpperRowSnapshot \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testDirectMaterializationFailureAndFailedRetryCannotReopenIngress
```

Result:

```text
ViewerStoreTests: 8 tests, 0 failures
0.167 seconds test execution
/tmp/NearWireViewerRound11Focused/Logs/Test/Test-NearWireViewer-2026.07.13_12-43-40-+0800.xcresult
** TEST SUCCEEDED **
```

The first two-test attempt after adding the initial-start marker failed only because the older same-coordinator assertion still expected five missing observations. The database correctly contained six: one failed-start marker plus five rejected session observations. Updating the exact semantic expectation to six produced both passing results above. The failed attempt is not represented as passing evidence.

## Complete Store regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/NearWireViewerRound11Store ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -only-testing:NearWireViewerTests/ViewerStoreTests

ViewerStoreTests: 79 tests, 1 explicit live-resource-audit skip, 0 failures
4.528 seconds test execution
/tmp/NearWireViewerRound11Store/Logs/Test/Test-NearWireViewer-2026.07.13_12-43-52-+0800.xcresult
** TEST SUCCEEDED **
```

## Complete unsigned Viewer regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/NearWireViewerRound11Full ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe

NearWireViewerTests.xctest: 160 tests, 1 skipped, 0 failures
7.044 seconds test execution
/tmp/NearWireViewerRound11Full/Logs/Test/Test-NearWireViewer-2026.07.13_12-44-24-+0800.xcresult
** TEST SUCCEEDED **
```

The one skip is the explicit machine-local live Application Support audit marker. The two configured-signing tests were excluded and are not counted as passing or skipped.

## Complete Swift package regression

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMModuleCache swift test --disable-sandbox --scratch-path /tmp/NearWireSwiftPMRound11FullBuild

Build complete
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
2.452 seconds test execution
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

- `swift package --disable-sandbox --scratch-path /tmp/NearWirePackageDumpRound11 dump-package`, with isolated module caches, exited 0. It reports no external dependencies; iOS 16, macOS 13, Swift language version 5; and products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`.
- `find . -name Package.swift -o -name '*.podspec'` returned only `./NearWire.podspec` and `./Package.swift`.
- The root package and podspec hashes remain unchanged from the successful Round 9 CocoaPods validation. Round 10-to-11 production changes are Viewer-only, so that successful unchanged-input CocoaPods result remains applicable. No fresh pass is claimed after the sandbox-external approval service rejected the Round 10 rerun request.
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
