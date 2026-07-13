# Implementation Validation — Round 7

Date: 2026-07-13 (Asia/Shanghai)

All results are from the current tree after Round 6 remediation. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## OpenSpec and diff hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches
```

All Swift files touched by remediation were formatted with the Xcode 16 `swift-format` tool before the complete build. Compilation remains the language-mode gate; no new formatter script or repository-wide style gate was introduced.

## Focused remediation regressions

The Core Event/queue reflection selection passed 49 tests with zero failures.

The following Viewer storage boundary regressions passed together with zero failures:

```text
testMaintenanceWriteFailureStopsIngressUntilExplicitRecovery
testSQLiteWriterLockReportsWriteFailedWhileStaleRevisionRemainsLocal
testManualDeleteClassifiesStorageAndCapacityFailuresWithoutMutation
testCheckpointReserveSharesWriterOrderingWithEventWrite
```

Result bundle:

```text
/tmp/NearWireViewerRound7Derived/Logs/Test/Test-NearWireViewer-2026.07.13_09-55-11-+0800.xcresult
```

The rejected cumulative-drop observation regression also passed:

```text
testRejectedCumulativeDropSampleCreatesGapBeforeLaterSample
/tmp/NearWireViewerRound7Derived/Logs/Test/Test-NearWireViewer-2026.07.13_10-00-09-+0800.xcresult
```

The two new Viewer flow-control reflection/cumulative-drop tests passed with zero failures.

## Complete unsigned Viewer regression

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerRound7Derived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

The restricted attempt was blocked before compilation by sandbox access to FSEvents/CoreSimulator and user caches. The identical approved command then passed:

```text
NearWireViewerTests.xctest: 140 total tests
139 passed, 1 skipped, 0 failed
/tmp/NearWireViewerRound7Derived/Logs/Test/Test-NearWireViewer-2026.07.13_10-00-31-+0800.xcresult
** TEST SUCCEEDED **
```

`xcresulttool get test-results summary` independently confirmed `totalTestCount: 140`, `passedTests: 139`, `skippedTests: 1`, `failedTests: 0`, and `result: Passed`. The one skip is the explicit machine-local live Application Support audit marker; its separately completed current implementation audit remains recorded in `resource-filesystem-audit-round6.md`.

The two configured-signing tests were excluded from this unsigned command and are not counted as passing or skipped.

## Complete root Swift package regression

Command:

```text
env DO_NOT_TRACK=1 swift test --scratch-path /tmp/NearWireSwiftPMRound7Scratch
```

The restricted attempt could not write the compiler ModuleCache and did not compile the manifest. The identical approved command completed:

```text
NearWirePackageTests.xctest: 534 tests, 0 failures
All tests: 534 tests, 0 failures
exit 0
```

The complete stdout/stderr log was retained at `/tmp/NearWireSwiftPMRound7-full.log` while preparing this evidence. One earlier direct current-tree run had reported a single timing-sensitive failure with its failure line lost to output truncation. The preserved-log rerun above completed cleanly, and two additional `--skip-build` repetitions independently executed all 534 tests with zero failures in 1.850 and 1.847 seconds. Their logs are `/tmp/NearWireSwiftPMRound7-repeat1.log` and `/tmp/NearWireSwiftPMRound7-repeat2.log`; none contains a failed or skipped test entry.

## Packaging, binary, and privacy inspection

- `swift package --disable-sandbox --scratch-path /tmp/NearWirePackageDumpRound7 dump-package` passed with no external dependency; iOS 16, macOS 13, Swift language version 5, and products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`.
- `/usr/bin/find . -name Package.swift -o -name '*.podspec'` returned only `./Package.swift` and `./NearWire.podspec`.
- `ruby -c NearWire.podspec` returned `Syntax OK`.
- `./Scripts/verify-podspec.sh` passed under CocoaPods 1.16.2. Its restricted attempt could not connect to the configured local proxy at `127.0.0.1:7890`; the identical approved command completed with the existing invalid-example-URL warning and `NearWire passed validation`.
- `otool -L` on `/tmp/NearWireViewerRound7Derived/Build/Products/Debug/NearWire.app/Contents/MacOS/NearWire.debug.dylib` reports `/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)`.
- `cmp` verified the built Viewer privacy manifest is byte-for-byte equal to the checked-in manifest.

Hashes:

```text
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1  Package.swift
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33  NearWire.podspec
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  built NearWire.app/Contents/Resources/PrivacyInfo.xcprivacy
```

## Live filesystem/resource evidence

The storage paths, file-mode implementation, audit entry point, and cleanup contract remain unchanged by Round 6 remediation. `resource-filesystem-audit-round6.md` is the current implementation's separately opted-in live audit: the built Viewer held the owner-only main/WAL/SHM files, the exact prior store identity was restored, the audit store was removed, and no backup, quarantine, marker, or audit residue remained.

## Deferred validation

The following tests require project-specific signing configuration and remain explicitly deferred to `release-hardening`:

- `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`
- `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe`

They are not represented as passing in this change.
