# Implementation Validation

Date: 2026-07-15 (Asia/Shanghai)

## Red Boundary Evidence

1. Before changing defaults, the focused Core, queue, wire, and SDK command below executed five
   tests and reported ten failures. The failures exposed the previous 262,144-byte content and
   single-Event defaults, the 4 MiB total queue, and the 1 MiB Event frame:

   `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter 'testDefaultContentLimitIsExactlyOneMiB|testDefaultAndInvalidConfiguration|testProductionDefaultsCarryExactlyOneMiBContentThroughOneEventFrame|testDefaultConfigurationIsBoundedAndDirectional|testDefaultBufferAcceptsOneMiBContentAndRejectsOneByteOverAtomically'`

2. Before changing the production wire defaults, the focused Viewer admission regression exited 65
   because the production SDK Event-record offer could not reach handoff.

## Focused Green Tests

1. The five-test boundary command above exited 0 with five tests passed and zero failures.
2. The focused Viewer admission handoff test exited 0 after negotiating the production offer.
3. `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter SDKSessionAdmissionTests`
   - Exit status: 0
   - Result: 74 tests passed, 0 failures.
   - This rerun followed a discovered mismatch between the larger default SDK buffer and the active
     pump's old per-turn accounting quantum. The quantum was aligned to 4,259,840 bytes.
4. `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter WirePreHandshakeCodecTests`
   - Exit status: 0
   - Result: 11 tests passed, 0 failures.
5. The focused exact production-record test exited 0 and pinned the reviewed record maximum at
   1,049,539 bytes.
6. The focused Viewer control-composer boundary test exited 0 after its exact-size JSON fixture was
   generalized from four strings to the number required by the active content limit.
7. The review-remediation compatibility regression first failed because an explicit 4 MiB total
   inherited the larger 4,259,840-byte single-Event default. After the public initializer was split
   into explicit and implicit single-Event forms, all six `NearWireConfigurationTests` passed.

## Complete Suites

1. `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
   - Exit status: 0
   - Result: 545 tests passed, 0 failures in 2.088 seconds on the final source revision.
   - A prior run executed concurrently with the Demo build reported three timing-sensitive
     failures. The immediate isolated run above passed; the Demo build also exited 0.
2. `xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-one-mib-viewer-tests CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-strict-concurrency=complete' -quiet`
   - Exit status: 65
   - Initial result: 398 tests executed, 394 passed, 2 skipped, and 2 failed. One failure identified
     the fixed-size control-composer boundary fixture and was corrected as described above. The
     other was the expected signing-only entitlement assertion on an unsigned application.
3. The same Viewer command with
   `-skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement`
   - Exit status: 0
   - Result from `xcresulttool`: 397 tests total, 395 passed, 2 skipped, 0 failures.

The Viewer project suppresses warnings in its local Swift package integration, so adding
`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` conflicts with an existing `-suppress-warnings` flag. Strict
concurrency remained enabled; the unsupported warnings-as-errors override was not used.

## Unsigned Builds

1. `xcodebuild build -project Demo/NearWireDemo.xcodeproj -scheme NearWireDemo -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/nearwire-one-mib-demo-build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-strict-concurrency=complete' -quiet`
   - Exit status: 0.
2. `xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-one-mib-viewer-build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-strict-concurrency=complete' -quiet`
   - Exit status: 0.

No signing, Xcode project, or scheme configuration was changed for these validations.
