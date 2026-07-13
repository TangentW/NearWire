# Implementation Validation — Round 6

Date: 2026-07-13 (Asia/Shanghai)

All results are from the current tree after Round 5 remediation. Configured signing and entitlement validation remain deferred, by user direction, to the goal-level `release-hardening` change.

## OpenSpec and diff hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output
```

The Swift files modified during the final remediation were formatted with the Xcode 16 `swift-format` tool. A broad ad hoc strict-style lint was not adopted as a new repository gate because the repository has no checked-in strict formatter configuration and the active change contains previously accepted SQL-oriented formatting; production and test compilation remain the authoritative language/style gate.

## Focused Viewer storage regression

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerRound5FixDerived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -only-testing:NearWireViewerTests/ViewerStoreTests
```

Result:

```text
ViewerStoreTests: 56 tests, 1 skipped, 0 failures
/tmp/NearWireViewerRound5FixDerived/Logs/Test/Test-NearWireViewer-2026.07.13_09-21-17-+0800.xcresult
** TEST SUCCEEDED **
```

The one skip is the explicit machine-local live Application Support audit marker. That audit was run separately and passed, as recorded in `resource-filesystem-audit-round6.md`.

The late-runtime replacement regression also passed 100 consecutive iterations without increasing its timeout:

```text
/tmp/NearWireViewerRound5FixDerived/Logs/Test/Test-NearWireViewer-2026.07.13_09-20-58-+0800.xcresult
exit 0
```

## Complete unsigned Viewer regression

Command:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/NearWireViewerRound6Derived ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Result:

```text
NearWireViewerTests.xctest: 133 tests, 1 skipped, 0 failures
/tmp/NearWireViewerRound6Derived/Logs/Test/Test-NearWireViewer-2026.07.13_09-23-02-+0800.xcresult
** TEST SUCCEEDED **
```

The two configured-signing tests were excluded from the unsigned command and are not counted as passes or skips.

## Root Swift package regression

Command:

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMModuleCache swift test --disable-sandbox --scratch-path /tmp/NearWireSwiftPMRound6Build
```

Final exact result:

```text
NearWirePackageTests.xctest: 533 tests, 7 skipped, 0 failures
All tests: 533 tests, 7 skipped, 0 failures
exit 0
```

During remediation, the first complete package run found that `testLanePreflightFailureIsTerminalAndRetainsNoPayload` depended on private `Mirror` layout that had intentionally been closed by the new decoder redaction. The test was corrected to use `retainedByteCount` and to expect the four-byte parsed length prefix without any copied 1,024-byte payload. `WireFrameTests` then passed 15 of 15, and the complete 533-test package run passed.

SwiftPM emitted only managed-sandbox cache warnings for the read-only user cache. Build and package scratch data remained under `/tmp`.

## Packaging, binary, and privacy inspection

- `swift package --disable-sandbox --scratch-path /tmp/NearWirePackageDumpRound6 dump-package`, with the same `/tmp` module-cache environment, passed: no external dependencies; iOS 16 and macOS 13; Swift language version 5; products `NearWire`, `NearWireUI`, `NearWirePerformance`, and internal `NearWireCore`.
- `find . \( -name Package.swift -o -name '*.podspec' \) -print` returned only `./Package.swift` and `./NearWire.podspec`.
- `ruby -c NearWire.podspec` returned `Syntax OK`.
- `./Scripts/verify-podspec.sh` passed unchanged under CocoaPods 1.16.2 with only the pre-existing invalid-example-URL warning. The restricted first attempt could not connect to the configured local proxy at `127.0.0.1:7890`; the identical command passed with approved external access.
- `otool -L` on the built Viewer code dylib reported `/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)`.
- `cmp` verified the built Viewer privacy manifest is byte-for-byte equal to the checked-in manifest.

Hashes:

```text
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1  Package.swift
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33  NearWire.podspec
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  Viewer/NearWireViewer/Resources/PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9  built NearWire.app/Contents/Resources/PrivacyInfo.xcprivacy
```

## Live filesystem/resource audit

`resource-filesystem-audit-round6.md` records the separate opted-in audit. The live store opened successfully, `lsof` observed the built Viewer holding the owner-only main/WAL/SHM artifacts, clean-close metadata was captured, the exact prior Application Support store identity was restored, the audit store was deleted, and no backup, quarantine, prior-audit, or marker residue remained.

## Deferred validation

The following unchanged tests require project-specific signing configuration and remain explicitly deferred to `release-hardening`:

- `ViewerFoundationTests.testRunningApplicationHasOnlyFoundationNetworkEntitlement`
- `ViewerFoundationTests.testStableSignerUpdateBoundaryProbe`

They are not represented as passing in this change.
