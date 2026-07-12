# Implementation Validation

Date: 2026-07-13

## Focused Viewer Flow-Control Suite

Command:

```text
xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-flow-final-r4 CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests
```

Result: passed, exit 0. The xcresult summary reported 22 passed, 0 failed, and 0 skipped.

The formerly intermittent bidirectional test was also executed 50 times without rebuilding:

```text
xcodebuild test-without-building -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-r2-new-regressions CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests/testBidirectionalEventExchangeUsesNegotiatedEpochAndRoutes -test-iterations 50
```

Result: passed, exit 0, 50 of 50 repetitions passed.

The retained-suffix/later-service ordering regression was also executed 20 times without rebuilding:

```text
xcodebuild test-without-building -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-service-order-fix-2 CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:NearWireViewerTests/ViewerFlowControlTests/testRetainedEventContinuationDefersALaterBatchServiceTurn -test-iterations 20
```

Result: passed, exit 0, 20 of 20 repetitions passed.

## Viewer Regression Suite

Command:

```text
xcodebuild test -quiet -workspace NearWire.xcworkspace -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-viewer-final-r4 CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement -skip-testing:NearWireViewerTests/ViewerFoundationTests/testStableSignerUpdateBoundaryProbe
```

Result: passed, exit 0. The xcresult summary reported 76 passed, 0 failed, and 0 skipped among the selected tests.

The two excluded packaging tests require configured signing identities or a signed build. Per the product-owner decision, the stable-signer A/unrelated/B sequence and final signed entitlement verification are deferred to the goal-level `release-hardening` terminal change. They do not block this unsigned behavioral change.

## Swift Package Regression Suite

Command:

```text
swift test
```

Result: passed, exit 0. The suite executed 531 tests with 0 failures.

The focused Core queue suite also executed 39 tests with 0 failures, including live oldest-wait behavior after keep-latest replacement, priority removal, and clear.

## Repository Bootstrap Gate

A complete gate run before the Round 3 architecture remediation passed with the following command and summaries:

Command:

```text
./Scripts/verify-bootstrap.sh
```

Result: passed, exit 0, with no gate weakened or skipped. Exact terminal summaries included:

```text
Totals: 29 passed, 0 failed (29 items)
iOS 16 Swift Package test sources compiled.
527 passed, 4 skipped, 0 failed (531 total iOS tests)
Executed 206 tests, with 0 failures
Real TLS active-session integration passed.
Public connect production TLS integration passed.
NearWire passed validation.
CocoaPods podspec verification passed.
All bootstrap quality gates passed.
```

The only CocoaPods warning was the existing placeholder source URL `https://example.invalid/nearwire`.

After the retained-suffix deferral and oldest-wait heap changes, the exact command was rerun three times without changing or weakening the script. The current-tree attempts exposed three different pre-existing asynchronous timing failures:

1. Exit 65 in `SDKSessionAdmissionTests.testTransportBlockWithWholeTokensDoesNotPollUntilCapacityProgress` during the iOS test stage.
2. The iOS stage passed 528 tests with 4 existing skips and 0 failures, then the Core harness exited 1 because `SecureByteChannelTests.testSendsAreFIFOAndBackpressureIsAtomic` observed its driver before the asynchronous send arrived. The same harness run passed all 39 `BoundedEventQueueTests`, including the new heap-indexed oldest-wait test.
3. Exit 65 in `ViewerDiscoveryTests.testIngressCoalescesSnapshotsAndGivesTerminalPriority` during the iOS test stage.

Each failing test passed immediately when rerun alone, with exit 0. None is on the changed Viewer service-order path or the changed queue telemetry-index path. The full current-tree Swift Package run passed 531 tests, the focused Core queue run passed 39 tests, the focused Viewer run passed 22 tests, and the selected Viewer regression run passed 76 tests. This environment limitation is recorded rather than hiding it by changing timeouts, disabling tests, or weakening `verify-bootstrap.sh`; the next independent review must decide whether the combined current-tree evidence is proportionate for this narrow remediation.

## Format, Diff, and OpenSpec

Commands and results:

```text
swift format lint --strict --recursive <all changed Swift production and test paths>
# exit 0, no diagnostics

git diff --check
# exit 0, no output

env DO_NOT_TRACK=1 openspec validate viewer-multidevice-flow-control --strict --no-interactive
Change 'viewer-multidevice-flow-control' is valid
```

## Coverage Notes

The focused Viewer suite uses an injected monotonic scheduler and isolated `UserDefaults` stores. It covers automatic and approval handoff, complete and partial retained suffixes, 16-session ownership, exact duplicate routes, route variants, initial and dynamic policy behavior, exact timeout, zero rates, 64-row recent expiry, mailbox advisory and authoritative backpressure, contiguous sequence retry, 70-message continuation, retained receipt time versus a later batch wake in both submission orders, exact sub-millisecond receiver TTL, blocked consumer isolation, terminal consumer churn without cross-session starvation, typed drop-summary coalescing, preference corruption and bounds, safe diagnostics, oldest-wait telemetry, nickname continuity, and bidirectional SDK-compatible wire Events.

The package and bootstrap suites add Core decoder/channel, queue, token, batching, SDK admission, TLS, distribution, privacy-resource, SwiftPM, CocoaPods, and module-boundary coverage.
