# Implementation Validation

Date: 2026-07-15 (Asia/Shanghai)

## Red Regression Evidence

Before the production change, the new Core regression failed while decoding the SDK-sized peer
offer with `invalidConfiguration` at `hello.maximumEventBytes`. The Viewer regression likewise
could not reach admission handoff. This reproduced the runtime failure after Bonjour, TCP, and TLS
had already succeeded.

## Focused Tests

1. `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter WirePreHandshakeCodecTests`
   - Exit status: 0
   - Result: 11 tests passed, 0 failures.
2. `xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-hello-limit-handoff -only-testing:NearWireViewerTests/ViewerFoundationTests/testAdmissionManagerHandsOffProductionSDKEventRecordOffer CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-strict-concurrency=complete' -quiet`
   - Exit status: 0
   - Result: the production SDK Event-record offer reached automatic handoff, negotiated down to
     the Viewer limit, and shut down cleanly.

## Complete Test Suites

1. `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
   - A first run performed concurrently with the Demo build reported one test failure among 541.
   - An immediate isolated rerun exited 0 with 541 tests passed and 0 failures in 2.002 seconds.
2. `xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-hello-limit-viewer-full CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-strict-concurrency=complete'`
   - Exit status: 65.
   - Result: 398 tests executed; the only failures were the two assertions in
     `testRunningApplicationHasOnlyFoundationNetworkEntitlement`. An intentionally unsigned test
     application has no embedded network entitlement, so this signing-only test cannot pass under
     `CODE_SIGNING_ALLOWED=NO`.
3. The same Viewer command with
   `-skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement`
   - Exit status: 0
   - Result: 397 tests passed, 2 tests skipped, 0 failures in 37.495 seconds.

The Viewer project suppresses warnings in its local Swift package integration, so adding
`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` conflicts with an existing `-suppress-warnings` flag. Strict
concurrency remained enabled; the unsupported warnings-as-errors override was not used.

## Unsigned Builds

1. `xcodebuild build -project Demo/NearWireDemo.xcodeproj -scheme NearWireDemo -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/nearwire-hello-limit-demo CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-strict-concurrency=complete'`
   - Exit status: 0
   - Result: `BUILD SUCCEEDED`.
2. `xcodebuild build -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/nearwire-hello-limit-viewer-build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-strict-concurrency=complete' -quiet`
   - Exit status: 0.

No signing or Xcode project configuration was changed for these validations.
