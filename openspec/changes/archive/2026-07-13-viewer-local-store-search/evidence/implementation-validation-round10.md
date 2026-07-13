# Implementation Validation — Round 10

Date: 2026-07-13 (Asia/Shanghai)

Status: **superseded for completion purposes by `implementation-validation-round11.md`.** Fresh Round 10 security/performance/documentation review reproduced the same-coordinator recovery failure because this round's semaphore did not prove queue admission. The passing invocation below did occur, but its deterministic-evidence claim is withdrawn. The complete Viewer, SwiftPM, static, binary, and privacy results remain accurate for that earlier tree.

All passing results below are from the current tree after Round 9 remediation and the validation-discovered test synchronization correction. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## Focused remediation validation

The recorded focused command selected the seven Round 9 remediation regressions:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/NearWireViewerRound10Store ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testQueuedSettingsRecoveryIsRevokedByANewerNonrecoveringRevision \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRunningSettingsRecoveryIsRevokedBeforePublicationByNewerRevision \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRuntimeShutdownQuiescesMaintenanceBeforeOneTerminalFlush \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLatestOnlyChangeSignalCarriesSafeRecordingAndUpperRowSnapshot
```

Result:

```text
ViewerStoreTests: 7 tests, 0 failures
0.140 seconds test execution
/tmp/NearWireViewerRound10Store/Logs/Test/Test-NearWireViewer-2026.07.13_12-21-33-+0800.xcresult
** TEST SUCCEEDED **
```

Before the initial test synchronization correction, the same combination produced four assertions from `testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork` after two two-second polling expirations. The same test also passed independently in 0.014 seconds. The failure-consumption semaphore produced the passing result above, but `NW-ISPD10-001` later proved it could not distinguish retry admission from retry execution: a full lifecycle queue could reject the retry before the fault ran. The Round 10 focused result is therefore not accepted as reproducible completion evidence. Round 11 replaces it with an exact current-prefix barrier, a blocking admission proof, and fresh focused/full results.

## Complete unsigned Viewer regression

Final command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/NearWireViewerRound10Full ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Result:

```text
ViewerStoreTests: 79 tests, 1 explicit live-resource-audit skip, 0 failures
NearWireViewerTests.xctest: 160 tests, 1 skipped, 0 failures
6.394 seconds test execution
/tmp/NearWireViewerRound10Full/Logs/Test/Test-NearWireViewer-2026.07.13_12-22-55-+0800.xcresult
** TEST SUCCEEDED **
```

The one skip is the explicit machine-local live Application Support audit marker. The two configured-signing tests were excluded and are not counted as passing or skipped.

An earlier command used the wrong test class in both skip identifiers. It executed 162 tests and failed only `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`, as expected for an unsigned build. The corrected command above uses the source-declared class and is the authoritative result. The failed attempt is not represented as product evidence.

## Complete Swift package regression

Command:

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMModuleCache swift test --disable-sandbox --scratch-path /tmp/NearWireSwiftPMRound10FullBuild
```

Result:

```text
Build complete
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
2.054 seconds test execution
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

The strict validation result was rerun after the active design/spec synchronization and remained successful.

`xcrun swift-format lint --recursive Viewer/NearWireViewer/Store Viewer/NearWireViewerTests/ViewerStoreTests.swift` exited 0. It reports seven nonblocking `OnlyOneTrailingClosureArgument` API-shape suggestions and one test-only `ReplaceForEachWithForLoop` suggestion. No formatting error, new shell harness, nested manifest, nested podspec, third-party Core/SDK runtime dependency, or generated-project tool was introduced.

## Packaging, binary, and privacy validation

- `swift package --disable-sandbox --scratch-path /tmp/NearWirePackageDumpRound10 dump-package`, with isolated module caches, exited 0. It reports no external dependencies; iOS 16, macOS 13, Swift language version 5; and products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`.
- `find . -name Package.swift -o -name '*.podspec'` returned only `./NearWire.podspec` and `./Package.swift`.
- `ruby -c NearWire.podspec` returned `Syntax OK`.
- The restricted CocoaPods run entered CocoaPods 1.16.2 validation and then failed because the sandbox could not connect to `CoreSimulatorService`; it also emitted the existing invalid example-URL warning. A request to rerun the unchanged command outside the sandbox was rejected because the automatic approval service was at capacity. No passing result is claimed from either attempt.
- `Package.swift` and `NearWire.podspec` retain exactly the Round 9 hashes below, and all Round 9-to-Round 10 production changes are Viewer-only. The successful Round 9 `./Scripts/verify-podspec.sh` result therefore remains the applicable CocoaPods evidence for the unchanged SDK package inputs.
- `otool -L` on the final Viewer code dylib reports `/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)`.
- `cmp` verified the final built Viewer privacy manifest is byte-for-byte equal to the checked-in manifest.

Hashes:

```text
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1  Package.swift
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33  NearWire.podspec
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  final built NearWire.app privacy manifest
```

## Live filesystem/resource evidence

Round 9 remediation does not change store paths, creation modes, cleanup identity, or the live audit entry point. `resource-filesystem-audit-round6.md` remains applicable: owner-only main/WAL/SHM artifacts were observed, the exact prior store identity was restored, the audit store was removed, and no backup, quarantine, marker, or audit residue remained.

## Deferred validation

The following configuration-dependent tests remain explicitly deferred to `release-hardening`:

- `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`
- `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe`

They are not represented as passing in this change.
