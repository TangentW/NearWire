# Implementation Validation — Round 9

Date: 2026-07-13 (Asia/Shanghai)

All results are from the current tree after Round 8 remediation. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## OpenSpec, hygiene, and formatting

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches
```

The changed Viewer Swift files were formatted with Xcode `swift-format`. A recursive lint completed with exit 0; remaining diagnostics are nonblocking API-shape suggestions for named closure arguments and one test-only `forEach`. No shell harness, nested manifest, nested podspec, third-party Core/SDK runtime dependency, or generated-project tool was added.

## Focused recovery and concurrency validation

The corrected recovery matrix passed after introducing generation-bound nonrecovering maintenance authorization:

```text
ViewerStoreTests.testRecoveryMatrixAllowsOnlyApprovedSuccessfulActions
1 test, 0 failures
/tmp/NearWireViewerRound9FocusedArm64/Logs/Test/Test-NearWireViewer-2026.07.13_11-42-13-+0800.xcresult
```

The complete store suite then passed:

```text
ViewerStoreTests: 73 tests, 1 explicit live-resource-audit skip, 0 failures
/tmp/NearWireViewerRound9StoreArm64/Logs/Test/Test-NearWireViewer-2026.07.13_11-42-36-+0800.xcresult
** TEST SUCCEEDED **
```

This suite includes deterministic coverage for direct failure publication before writer release, reversed relay callback delivery, generation-bound approved recovery, scheduled maintenance failure, dirty settings successors, runtime-end recovery invalidation, concurrent metadata/Event capacity admission, shutdown, reflection, query/export, and filesystem/resource ownership.

## Complete unsigned Viewer regression

Final current-tree command after formatting:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerRound9FinalDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Result:

```text
ViewerFoundationTests: 54 tests, 0 failures
ViewerStoreTests: 73 tests, 1 skipped, 0 failures
NearWireViewerTests.xctest: 154 tests, 1 skipped, 0 failures
6.279 seconds test execution
/tmp/NearWireViewerRound9FinalDerived/Logs/Test/Test-NearWireViewer-2026.07.13_11-47-32-+0800.xcresult
** TEST SUCCEEDED **
```

The one skip is the explicit machine-local live Application Support audit marker. The two configured-signing tests were excluded and are not counted as passing or skipped. A separate `xcresulttool` summary attempt could not materialize its internal `TestReport` cache under the current sandbox permissions; no result is claimed from that auxiliary parser, and the complete `xcodebuild` result above is retained as the authoritative execution evidence.

## Complete Swift package regression

Command:

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMModuleCache swift test --disable-sandbox --scratch-path /tmp/NearWireSwiftPMRound9FullBuild
```

Result:

```text
Build complete
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
2.092 seconds test execution
exit 0
```

The seven existing environment-dependent skips are not represented as passes. The new `WireHello` diagnostic regression is included in the 536-test result.

## Packaging, binary, and privacy validation

- `swift package --disable-sandbox --scratch-path /tmp/NearWirePackageDumpRound9 dump-package`, with isolated `/tmp` module caches, passed: no external dependencies; iOS 16, macOS 13, Swift language version 5; products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`.
- `find . -name Package.swift -o -name '*.podspec'` returned only `./Package.swift` and `./NearWire.podspec`.
- `ruby -c NearWire.podspec` returned `Syntax OK`.
- The first CocoaPods attempt inherited an inaccessible `127.0.0.1:7890` proxy; the second reached CocoaPods but the sandbox denied CoreSimulatorService. Neither executed a complete lint and neither is behavioral evidence. The unchanged validation command was then run outside the sandbox with proxy variables removed and passed under CocoaPods 1.16.2. The only remaining warning is the existing invalid example URL.
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

Round 8 remediation does not change store paths, creation modes, cleanup identity, or the live audit entry point. `resource-filesystem-audit-round6.md` remains applicable: owner-only main/WAL/SHM artifacts were observed, the exact prior store identity was restored, the audit store was removed, and no backup, quarantine, marker, or audit residue remained.

## Deferred validation

The following configuration-dependent tests remain explicitly deferred to `release-hardening`:

- `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`
- `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe`

They are not represented as passing in this change.
