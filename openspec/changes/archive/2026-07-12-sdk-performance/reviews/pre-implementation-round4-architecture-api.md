# Pre-Implementation Architecture and API Review — Round 4

## Scope

Independently reviewed the complete current `sdk-performance` proposal, design, specifications, tasks, validation and three remediation records, all prior architecture reports, the other Round 3 reviews, and the relevant Core schema, NearWire built-in SPI/diagnostics, privacy ownership, and SwiftPM/CocoaPods boundaries. This review re-traced setup, run, and cleanup actor reentrancy; public-state publication; display semantics; resource generations; and every earlier API finding. No production, test, specification, task, evidence, or other report file was modified.

## Round 3 Finding Verification

### Stopping/cleanup barrier — resolved

The lifecycle now has private Idle, Starting, Running, and Stopping phases without expanding the public Stopped/Running/Failed enum.

- Stop invalidates the exact setup/run token and installs one nonthrowing cleanup Task/token before awaiting.
- Stopping admits no successor acquisition and owns only predecessor resources awaiting release.
- Concurrent stops join the same cleanup and return only after it completes.
- Start during Stopping awaits the exact cleanup, checks only its own cancellation, and then begins or joins one fresh Starting attempt. Multiple waiting starts converge on that successor attempt.
- Cancellation of a start waiting only for cleanup cannot cancel cleanup or a successor.
- Predecessor handles release only predecessor resources; cleanup completion validates its own token and cannot release or overwrite a restarted generation.
- Slow or noncooperative cleanup remains fail-closed rather than permitting overlap.

The normative transition table, capability scenarios, resource bounds, implementation task, and deterministic barriers all describe the same behavior for partial setup, MainActor setup, active run teardown, concurrent start/stop/stop, cancellation, and stale cleanup.

## Complete Prior Finding Audit

- **Public API:** remains narrowly limited to configuration, content-safe error/code, lifecycle state, and actor monitor. Snapshot/metric/collector/clock/lease/test types remain internal, and exact SwiftPM/CocoaPods declaration parity plus mutation rejection is required.
- **State/error semantics:** `currentState` is actor-isolated and authoritative. Stream publication, pre-commit errors, Running failures, restart, stop winner order, generations, deinit, Starting, and Stopping are total.
- **Battery ownership:** managed mode is explicitly best-effort and coordinates NearWire claims only; unmanaged mode is the required host-owned path and never mutates the global switch.
- **Metric semantics:** CPU baseline recovery, display timestamp ownership/formula, unavailable key inventory/precedence, and cumulative terminal drop count are deterministic.
- **Display context:** estimated cadence uses main-display link timestamps only; maximum FPS is stable unsupported; deprecated `UIScreen.main`/`UIScreen.screens` and scene guessing are prohibited.
- **Distribution:** platform-neutral schema remains in Core; iOS collectors remain in the optional SDK target; macOS start is unsupported before resources; event submission uses the ordinary built-in keep-latest path.
- **Privacy packaging:** base Device ID and optional linked Performance Data manifests are owned by their collecting components, separately packaged through SwiftPM/CocoaPods, and validated over the installation-correlated envelope. The default SDK does not gain Performance source or Performance data declaration.

## New-Issue Search

Reviewed cleanup/public-state ordering, cancellation propagation, multiple waiters, generation reuse, deinit, resource overlap, same/different monitor lease behavior, internal snapshot construction, optional-resource isolation, and public module equivalence. No new actionable architecture or public API issue was found.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: passed.
- `git diff --check -- openspec/changes/sdk-performance`: passed.
- `./Scripts/verify-english.sh`: passed with the expected human-review note.

## Verdict

**Architecture/API pre-implementation approval granted. Explicit unresolved actionable finding count: 0.** Implementation remains gated on the complete multi-dimension pre-review workflow, but no architecture/API remediation remains.
