# Implementation Review Round 7 Remediation

Date: 2026-07-14

## Result

Both unique round-7 findings are remediated. The gateway replacement set passes five focused tests,
the renderer/composer delivery set passes four focused tests, and the complete Viewer/package/build
and static validation gate passes. A fresh three-discipline review round remains required before
this change can close.

Configured signing and embedded-entitlement verification remains deferred to Goal-level
`release-hardening` by product-owner decision and is not a finding in this change.

## ARCH-R7-001 — linearizable gateway replacement

- A dedicated replacement transition owner serializes detach, predecessor seal/join, and successor
  publication without holding the generation-state lock or invoking arbitrary callbacks.
- Active operations retire cancellation, exact operation, lease, and group ownership before client
  completion. Queued rejections are collected as deferred deliveries after their ownership retires.
- Deferred callbacks run only after transition ownership is released. Reentrant installation may
  therefore replace the just-published generation deterministically, while an earlier external
  installer cannot later overwrite that callback-installed generation.
- The three-coordinator regression blocks generation A's callback, starts external installation B,
  installs and submits work to C from A's callback, then proves C is the final generation, its work
  remains gateway-owned until release, all predecessor work is joined, and every count reaches zero.

Focused result:

```text
testExplorerGatewayReplacementRetiresOperationBeforeArbitraryCompletion
testExplorerGatewayActiveCompletionCanInstallReplacementReentrantly
testExplorerGatewayLinearizesExternalAndCallbackReplacementWithoutOrphanGeneration
testExplorerGatewayQueuedRejectionCanSealReentrantlyWhileActiveWorkFinishes
testExplorerGatewaySealsOriginatingGenerationBeforePublishingReplacement
Executed 5 tests, with 0 failures
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_01-53-42-+0800.xcresult
```

## SPD-R7-001 — tracked renderer and composer result delivery

- The generic delivery gate now covers store operations, renderer generations, and composer
  attempts. A controller cancels its current gate before service replacement/cancellation can
  report a stale result.
- Cancellation that wins retires the exact delivery identity and creates no MainActor task. A
  callback that wins claims once, and its identity remains active until the MainActor removes or
  discards that exact result, even after supersession or sealing.
- Explorer and composer cleanup independently join their bounded preparation worker and delivery
  tracker. Pending-work diagnostics include both owners.
- Two 100,000-replacement controller regressions keep the preparation executor blocked, retain one
  pending request, hold exactly two owners before sealing and one blocked worker after sealing,
  create zero result-delivery claims for cancelled generations, and finish with zero work.
- Two content-bearing success regressions block immediately after delivery claim and prove the
  cleanup receipt cannot finish until the MainActor discards the sealed renderer/composer result.

Focused command:

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerHundredThousandRendererReplacementsCancelBeforeDeliveryClaim \
  -only-testing:NearWireViewerTests/ViewerFoundationTests/testExplorerCleanupJoinsClaimedContentBearingRendererDelivery \
  -only-testing:NearWireViewerTests/ViewerFlowControlTests/testControlComposerHundredThousandReplacementsCancelBeforeDeliveryClaim \
  -only-testing:NearWireViewerTests/ViewerFlowControlTests/testControlComposerCleanupJoinsClaimedContentBearingDelivery
```

Exact result:

```text
Executed 4 tests, with 0 failures
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_02-06-24-+0800.xcresult
```

The first focused execution exposed only a test-observer scheduling race: each cleanup receipt had
already completed and every pending count was zero, but the separate observer task had not yet
incremented its counter. The tests now yield until that observer runs while retaining the strict
pre-release assertion that its count is zero. The unchanged product behavior then passed. A separate
sandboxed invocation failed before build because user compiler caches and CoreSimulator logs were
unwritable; the unchanged command passed with standard Xcode cache/service access. No product gate
or assertion was weakened.

## Complete validation after remediation

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement
Executed 266 tests, with 2 tests skipped and 0 failures
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireViewer-diwiikamyvtifibnyesrqkerxuca/Logs/Test/Test-NearWireViewer-2026.07.14_02-12-02-+0800.xcresult
```

```text
swift test
Executed 537 tests, with 0 failures

xcodebuild build -workspace NearWire.xcworkspace -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **

xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
```

`swift package dump-package` and source plist validation pass. The package has no dependencies,
keeps iOS 16/macOS 13 and Swift 5, and contains only Core/SDK targets and the four expected products.
The Viewer project retains macOS 13, Swift 5, complete strict concurrency, its local root-package
reference, and no remote package or shell-script phase.
