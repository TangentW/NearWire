# Implementation Validation

Validation was completed on 2026-07-16 with Xcode 16 or later, Swift 5 language mode, and complete strict concurrency enabled by the maintained Xcode projects.

## Focused regressions

- Demo fixed recovery configuration and lifecycle forwarding: 1 test passed, 0 failures.
  - Result bundle: `/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireDemo-gooxuryewzfxmjaizmeuiivyppon/Logs/Test/Test-NearWireDemo-2026.07.16_02-47-02-+0800.xcresult`
- SDK suspended queue and fresh-route resume: 1 test passed, 0 failures.
  - Command: `swift test --filter SDKPublicConnectionOrchestrationTests.testSuspendQueueAndExplicitResumeUseFreshRouteWithDisabledPolicy`
- Viewer exact-route selection migration and fresh-epoch Timeline visibility: 1 test passed, 0 failures. The test uses the production composite journal and live memory window, and separately verifies that a historical recent selection is not retargeted.
  - Result bundle: `/private/tmp/nearwire-viewer-reconnect-dd/Logs/Test/Test-NearWireViewer-2026.07.16_02-49-27-+0800.xcresult`
  - The first default-DerivedData attempt compiled but could not load the test bundle because the existing App and test signatures had different Team IDs. The passing run used isolated temporary DerivedData and command-line ad-hoc signing; no project signing setting changed.

## Affected suites

- Demo unit and launch smoke: 4 unit tests and 1 UI smoke test passed, 0 failures.
  - Result bundle: `/Users/tangent/Library/Developer/Xcode/DerivedData/NearWireDemo-gooxuryewzfxmjaizmeuiivyppon/Logs/Test/Test-NearWireDemo-2026.07.16_02-35-16-+0800.xcresult`
- SDK public connection orchestration: 46 tests passed, 0 failures.
  - Command: `swift test --filter SDKPublicConnectionOrchestrationTests`
- Viewer full unit suite after the production selection change: 169 tests passed, 1 opt-in stable-signer probe skipped, 0 failures. The command exited successfully using the same isolated temporary DerivedData and ad-hoc signing override.
  - Result bundle path: `/private/tmp/nearwire-viewer-reconnect-dd/Logs/Test/Test-NearWireViewer-2026.07.16_02-49-46-+0800.xcresult`

## Consumer builds

- Root Swift Package consumer through `NearWireDemo`: generic iOS Simulator Debug build passed with code signing disabled.
- CocoaPods consumer through `NearWireDemoCocoaPods`: `pod install --no-repo-update` and generic iOS Simulator Debug build passed in an isolated temporary repository copy. No generated Pods or workspace files were written into the maintained checkout.

## Final source and specification gates

- `git diff --check`: passed.
- Complete strict concurrency remains enabled for Demo and Viewer targets.
- `openspec validate integrate-demo-lifecycle-recovery --strict`: passed. The following PostHog DNS flush error was telemetry-only and did not affect validation: `getaddrinfo ENOTFOUND edge.openspec.dev`.
