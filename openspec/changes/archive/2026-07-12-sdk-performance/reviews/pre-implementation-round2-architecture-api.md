# Pre-Implementation Architecture and API Review — Round 2

## Scope

Independently re-reviewed `AGENTS.md`, every active `sdk-performance` proposal/design/spec/task/evidence artifact, the Round 1 architecture report, the current Core V1 performance schema, `NearWireBuiltins` SPI, public buffer diagnostics, and root SwiftPM/CocoaPods boundaries. This review verified each prior architecture finding and then traced the remediated monitor lifecycle and iOS collector choices. No production, test, specification, task, evidence, or other report file was modified.

## Prior Finding Verification

### Public API size and exactness — resolved

The unsupported public snapshot/metric facade has been removed. The supported surface is now limited to configuration, error/code, lifecycle state, and monitor. The design specifies every supported property, initializer, actor method, state case, and closed error-code inventory, while the boundary spec explicitly forbids any public snapshot, metric, battery/thermal, unavailable, collector, clock, lease, or test-seam declaration. Tasks require an exact normalized SwiftPM/CocoaPods schema and mutation checks.

### Lifecycle state/error contract — partially resolved; see Finding 1

`currentState` is now actor-isolated and authoritative. The public Stopped/Running/Failed transition table defines successful start/restart, Running idempotency, setup/lease/platform errors from Stopped and Failed, post-start failure, stop winner order, deinit, and stream publication. The remaining omission is reentrancy while a start attempt is still pre-commit.

### Battery ownership — resolved

Configuration now explicitly selects managed or unmanaged battery-switch behavior. Managed mode claims only NearWire ownership, stops fighting an observed external disable, and documents that an external true-over-true write cannot be detected. Hosts that own the global switch must select unmanaged mode, under which NearWire never mutates it. The specification no longer promises isolation that the UIKit Boolean cannot provide.

### Unavailable inventory and precedence — resolved

The design/spec now contain a closed metric-key table with group, unit/source, and support class. Disabled group wins first, stable unsupported wins next, and supported attempted reads yield either one value or one unavailable reason. Keys are unique and sorted. `droppedEventCount` is explicitly a saturated cumulative terminal-removal count and excludes coalescing, explicit clear, and admission rejection.

## New and Remaining Findings

### P1 — High: The lifecycle omits an internal Starting phase, so actor reentrancy can violate start/stop and idempotency guarantees

**Confidence: 10/10**

The transition table treats setup as if actor serialization made it atomic from Stopped/Failed to Running. In Swift, an actor method is reentrant whenever setup awaits MainActor display/device creation or another asynchronous dependency. Until Running commits, public state remains Stopped or Failed and the artifacts define no internal in-flight start token/phase.

Two valid races are therefore unspecified:

1. `start()` claims or partially creates resources and suspends; `stop()` enters, sees public Stopped, returns as a no-op; the original `start()` resumes and commits Running after stop returned.
2. A second `start()` enters while the first is suspended pre-commit; it may attempt another setup, receive the same monitor's own lease conflict, or create duplicate partial resources instead of providing deterministic same-monitor idempotency.

The existing generation language covers a current **run** and late run failure, not a pre-commit start attempt. Task 4.2 mentions cancellation but does not require concurrent start/start and start/stop barriers before Running.

**Required remediation:** add one exact internal start-attempt token/phase without expanding the public state enum. Define concurrent same-monitor `start()` behavior (join one attempt or deterministic successful no-op), make `stop()` invalidate/cancel and await an in-flight attempt before returning Stopped, and require every setup continuation to verify the exact attempt token before acquiring the next resource or committing Running. Extend the transition table/spec/tasks with start/start, start/stop, stop-before-lease, stop-during-MainActor-setup, and stale setup completion after restart.

### P2 — Medium: Display maximum-FPS/source semantics are still not implementable unambiguously without screen context

**Confidence: 9/10**

The API injects no view, window, scene, or screen, while the metric table promises `display.maximumFramesPerSecond` from the “current screen.” An App may have multiple scenes or an external display, so there is no single current screen for a process-wide monitor. Using `UIScreen.main` would also contradict the modern context-based direction: Apple deprecates/discourages it and directs callers to obtain the screen through a window scene ([Apple `UIScreen.main`](https://developer.apple.com/documentation/uikit/uiscreen/main)). The design does not state whether maximum FPS comes from the same display link's timing, a selected scene, the device-integrated display, or becomes unavailable under ambiguity.

This also affects whether the generic main-run-loop `CADisplayLink` callback cadence and maximum-FPS value describe the same display.

**Required remediation:** choose one supportable V1 semantic before implementation. Prefer deriving both cadence and maximum from the same display-link/display context when possible; otherwise rename/document the metric as integrated/main-display capability and define the exact source, or mark maximum FPS unavailable when no unambiguous context is provided. Add multi-scene/external-display source-seam tests and ensure warnings-as-errors builds do not depend on deprecated `UIScreen.main`.

## Verified Architecture Decisions

- Platform-neutral snapshot validation remains in Core; all UIKit/QuartzCore/Darwin/Mach collection stays in the optional SDK target.
- The monitor uses the narrow built-in SPI and ordinary keep-latest queue rather than a transport or persistence side path.
- CPU baseline recovery, FPS timestamp formula, drop-counter semantics, macOS unsupported behavior, resource bounds, and optional privacy-resource packaging are concrete enough for implementation, subject to the two findings above.
- The optional product/subspec remains absent from the default SDK integration, and public module parity is explicitly test-gated.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: passed.
- `git diff --check -- openspec/changes/sdk-performance`: passed.

## Verdict

**Changes required. Unresolved actionable finding count: 2 — one High and one Medium.** Do not begin implementation until pre-commit start reentrancy and display-context semantics are total.
