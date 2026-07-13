# Implementation Validation — Round 8

Date: 2026-07-13 (Asia/Shanghai)

All results are from the current tree after Round 7 remediation. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## OpenSpec, formatting, and diff hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches
```

Every Swift file changed in this remediation was formatted with Xcode 16 `swift-format`. No shell harness, nested manifest, podspec, or generated project tool was added.

## Focused state, drop, and reflection regressions

- Five new Viewer storage tests for stale queued-writer rejection, direct/materialization failure, typed recovery, cleanup-before-drop-validation, and `Int64` saturation/gaps passed together with zero failures.
- The expanded manual-delete matrix passed all nine storage/corruption/capacity and before-begin/body/commit combinations.
- `ViewerStoreTests` passed 66 tests with one explicit live-resource-audit skip and zero failures:

```text
/tmp/NearWireViewerRound8Derived/Logs/Test/Test-NearWireViewer-2026.07.13_10-43-55-+0800.xcresult
```

- Core `EventDraft` queue reflection and secure-transport reflection passed together with zero failures.
- Viewer active `EventDraft`/`WireReceivedEvent` queue and handoff reflection passed with zero failures:

```text
/tmp/NearWireViewerRound8Derived/Logs/Test/Test-NearWireViewer-2026.07.13_10-34-55-+0800.xcresult
```

## Investigation and repeated SwiftPM evidence

The first durable Round 8 complete-package log reproduced the earlier unidentified failure as:

```text
PerformanceMonitorTests.testStateStreamsYieldCurrentAndCancelIndependently
Timed out waiting for stream termination.
/tmp/NearWireSwiftPMRound8-full.log
```

After removing the test's cancellation-bypassing manual loop break, that exact test passed 100 independent `swift test --skip-build --filter ...` processes. Logs: `/tmp/NearWirePerformanceStream-repeat-1.log` through `-100.log`.

The first attempted complete-suite stability sequence then identified a second independent test observation race:

```text
SDKSessionAdmissionTests.testTransportBlockWithWholeTokensDoesNotPollUntilCapacityProgress
operationEntries: expected 1, observed 2
/tmp/NearWireSwiftPMRound8-repeat-2.log
```

After waiting for the progress-driven outbound turn to complete before establishing the stability baseline, that exact test passed 100 independent processes. Logs: `/tmp/NearWireTransportBlock-repeat-1.log` through `-100.log`.

Final complete-suite command, repeated in 20 independent processes:

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMModuleCache swift test --disable-sandbox --skip-build --scratch-path /tmp/NearWireSwiftPMRound8Build
```

Every run passed. The final run reports:

```text
NearWirePackageTests.xctest: 535 tests, 0 failures
All tests: 535 tests, 0 failures
1.853 seconds test execution
exit 0
```

Logs: `/tmp/NearWireSwiftPMRound8-stability-1.log` through `-20.log`. A scan found no failed test case, failed suite, or error line in any of the 20 logs.

## Complete unsigned Viewer regression

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerRound8FinalDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Result:

```text
NearWireViewerTests.xctest: 146 total tests
145 passed, 1 skipped, 0 failed
/tmp/NearWireViewerRound8FinalDerived/Logs/Test/Test-NearWireViewer-2026.07.13_11-00-37-+0800.xcresult
** TEST SUCCEEDED **
```

`xcresulttool get test-results summary` independently confirmed `totalTestCount: 146`, `passedTests: 145`, `skippedTests: 1`, `failedTests: 0`, and `result: Passed`. The one skip is the explicit machine-local live Application Support audit marker. The two configured-signing tests were excluded and are not counted as passing or skipped.

## Packaging, binary, and privacy inspection

- `swift package --disable-sandbox --scratch-path /tmp/NearWirePackageDumpRound8 dump-package` passed: no external dependency; iOS 16, macOS 13, Swift language version 5; products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`.
- `/usr/bin/find . \( -name Package.swift -o -name '*.podspec' \) -print` returned only `./Package.swift` and `./NearWire.podspec`.
- `ruby -c NearWire.podspec` returned `Syntax OK`.
- `./Scripts/verify-podspec.sh` passed the current SecureByteChannel source under CocoaPods 1.16.2 with only the existing invalid-example-URL warning.
- `otool -L` on the current Viewer code dylib reports `/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)`.
- `cmp` verified the current built Viewer privacy manifest is byte-for-byte equal to the checked-in manifest.

Hashes:

```text
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1  Package.swift
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33  NearWire.podspec
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  built NearWire.app/Contents/Resources/PrivacyInfo.xcprivacy
```

## Live filesystem/resource evidence

Round 7 remediation does not change store paths, file creation modes, cleanup identity, or the live audit entry point. `resource-filesystem-audit-round6.md` remains the current implementation's separately opted-in live audit: owner-only main/WAL/SHM artifacts were observed, the exact prior store identity was restored, the audit store was removed, and no backup, quarantine, marker, or audit residue remained.

## Deferred validation

The following tests require project-specific signing configuration and remain explicitly deferred to `release-hardening`:

- `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`
- `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe`

They are not represented as passing in this change.
