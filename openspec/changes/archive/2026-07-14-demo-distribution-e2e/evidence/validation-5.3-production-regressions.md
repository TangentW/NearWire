# Focused Production Regression Evidence

## Result

Task 5.3 passed on 2026-07-14.

The existing SDK reply metadata, route-affinity drop, production TLS bidirectional connection, and Viewer bidirectional route tests passed. The production TLS test initially skipped under the restricted outer sandbox because Security trust evaluation was unavailable; the identical existing test was rerun outside that restriction and passed without changing source or expectations.

## Commands and exact outcomes

```sh
swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter 'NearWireEventAPITests/testReply(FillsCorrelationAndReplyToIdentity|IsDroppedInsteadOfCrossingSessionRoute)|SDKSessionAdmissionTests/testPublicConnectUsesProductionTLSBidirectionalEventsAndRealProcessLease'
# 3 selected; 2 passed, production TLS test skipped in restricted Security sandbox, 0 failed

swift test --disable-sandbox --skip-build --filter 'SDKSessionAdmissionTests/testPublicConnectUsesProductionTLSBidirectionalEventsAndRealProcessLease'
# outside the restricted sandbox: 1 passed, 0 failed, 0 skipped

xcodebuild -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-demo-viewer-tests -clonedSourcePackagesDirPath /tmp/nearwire-demo-viewer-test-packages CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test -only-testing:NearWireViewerTests/ViewerFlowControlTests/testBidirectionalEventExchangeUsesNegotiatedEpochAndRoutes
# xcresult: Passed; 1 passed, 0 failed, 0 skipped
```

The Demo test target contains only `DemoLogicTests.swift`, the UI target contains only the launch smoke, and neither target defines a transport, wire codec, TLS channel, alternate queue, mock session, or protocol owner.
