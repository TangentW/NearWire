# Pre-Implementation Architecture and API Review — Round 3

## Scope

Independently reviewed the current `sdk-performance` proposal, design, specifications, tasks, validation/remediation evidence, both prior architecture reports, the other Round 2 review findings, and the relevant Core schema, NearWire SPI/diagnostics, and package boundaries. This review specifically traced the new Starting attempt model through Swift actor reentrancy and verified the revised display-source contract. No production, test, specification, task, evidence, or other report file was modified.

## Prior Finding Verification

### Pre-commit Starting/reentrancy — substantially resolved, but teardown reentrancy remains

The artifacts now define one private Starting phase with an exact attempt token, shared setup Task/outcome, prior public state, token checks before every acquisition and Running commit, same-monitor start joining, cancellation propagation, and stop invalidation/await. Start-attempt and run generations are separate, and tasks require stop-before-lease, stop-during-MainActor-setup, stale setup after restart, and concurrent start/start barriers. These changes close the two Round 2 races during setup itself.

Finding 1 below is a distinct adjacent gap: another actor call can enter while `stop()` is suspended awaiting either setup or run cleanup.

### Display context and maximum FPS — resolved

V1 no longer guesses a screen capability. The monitor uses main-display `CADisplayLink.timestamp` values only for explicitly estimated callback cadence, prohibits deprecated `UIScreen.main`/`UIScreen.screens`, and records `display.maximumFramesPerSecond` as stable unsupported whenever display collection is enabled. The closed inventory, unavailable precedence, specification, tasks, and documentation requirements agree. No view/window/scene parameter or new public API is needed.

### Earlier architecture findings — remain resolved

- Public declarations remain limited to exact configuration, error/code, state, and monitor families; snapshot/metric/collector values stay internal.
- `currentState` remains actor-isolated and authoritative, with the nonisolated hub limited to bounded latest-value streams.
- Managed/unmanaged battery behavior states the unavoidable host-ownership limitation and does not claim external isolation.
- Metric inventory, unavailable precedence, and cumulative drop semantics remain complete and deterministic.

## Finding

### P1 — High: No teardown phase governs `start()` while `stop()` is suspended awaiting cleanup

**Confidence: 10/10**

The actor now has internal Idle, Starting, and Running phases (`design.md:93`), but no Stopping/Cleaning phase. Both required stop paths await asynchronous work:

- stop during Starting invalidates/cancels and awaits the setup attempt;
- stop during Running invalidates/cancels and awaits the run cleanup before publishing Stopped.

Those awaits permit actor reentrancy. The artifacts do not define what a new `start()` does while that stop is suspended.

For a Running stop, public state may still be Running until cleanup completes. A reentrant `start()` can therefore take the documented Running no-op path and return success; the older stop then publishes Stopped, leaving a caller whose successful start did not result in a running monitor. If Stopped/Idle is committed before awaiting cleanup instead, a reentrant start can begin a new attempt while old display/battery/monitor-lease resources are still unwinding. The same ambiguity exists after a Starting attempt is invalidated but before its partial resources finish cleanup. Concurrent stop/stop joining is also not defined normatively even though tasks request a test.

This is not solved by attempt/run generation checks alone: those prevent stale commits, but they do not serialize the externally observable meaning of a new start against an in-progress stop or prevent resource overlap unless a teardown gate exists.

**Required remediation:** add one internal non-public Stopping/Cleaning phase with an exact cleanup Task/token for both setup and run teardown. Define that concurrent stops join the same cleanup. Define `start()` during cleanup to await that exact cleanup and then begin/join one fresh attempt (or return a specified cancellation/error), never to report the Running no-op and never to acquire resources early. Require token checks so old cleanup cannot release a restarted attempt's resources. Add transition rows/spec scenarios/tasks for start-during-stop from Starting and Running, stop/stop joining, cleanup failure/noncooperation, and restart immediately after cleanup.

## Other Architecture Checks

- The optional privacy resource remains isolated to the Performance product/subspec and the default SDK remains resource-free.
- Core-vs-SDK placement, macOS unsupported start, ordinary keep-latest SPI delivery, no public snapshot schema, and SwiftPM/CocoaPods parity remain coherent.
- No additional actionable API-surface or platform-collector issue was found in this round.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: passed.
- `git diff --check -- openspec/changes/sdk-performance`: passed.

## Verdict

**Changes required. Explicit unresolved actionable finding count: 1 High.** Implementation remains gated until teardown reentrancy is specified with one exact cleanup phase and start/stop ordering contract.
