# Pre-Implementation Architecture and API Review

## Scope

Reviewed `AGENTS.md`, the performance and repository-boundary sections of `NearWire-Platform-Architecture.md`, the existing Core V1 performance schema, the `NearWireBuiltins` SPI, root SwiftPM/CocoaPods mappings, current public buffer diagnostics, and every active `sdk-performance` proposal, design, specification, task, and pre-validation artifact. This was a lightweight pre-implementation review; no production, test, specification, or task source was modified.

## Findings

### P1 — High: The proposed public facade is both unnecessarily broad and not specified exactly enough to freeze safely

**Confidence: 10/10**

The monitor API never returns a snapshot, exposes a snapshot stream, or accepts caller-created metric values. It only samples internally and sends a reserved event through SPI. Nevertheless the design proposes ten public snapshot/metric/unavailable types in addition to configuration, error, state, and monitor. Those value types have no stated App-side use in this change, duplicate the internal Core schema, and create a large permanent source/serialization compatibility surface.

At the same time, the supposed “exact approved” API is not actually enumerated. The design lists type names but omits their exact properties, initializer labels and throwing behavior, enum cases/raw values, conformance sets, static members, and availability. `NearWirePerformanceError.Code` is shown as `{ ... }`, and the boundary spec asks a future gate to enforce an exact declaration delta that no artifact currently defines.

**Required remediation:** keep the supported surface to configuration, error, state, and monitor unless there is a concrete current consumer for public snapshot construction/decoding. Conversion values can remain internal wrappers over Core SPI. If public snapshot values are intentionally required, add an explicit complete declaration schema for every type/member/conformance and justify the consumer workflow before implementation; make mutation/API gates derive from that approved schema rather than inferring it from implementation.

### P2 — Medium: Monitor failure transitions are not total, and `currentState` adds an unexplained cross-actor synchronization contract

**Confidence: 10/10**

The artifacts define post-start sampling/submission failure as Failed, but do not define the observable state after lease contention, unsupported macOS start, partial collector setup failure, a failed restart from Failed, or cancellation racing `start()`. It is unclear whether a throwing `start()` publishes Failed, preserves Stopped, or preserves a prior Failed value. That ambiguity affects `currentState`, stream ordering, restart behavior, and stale-run rejection tests.

The public sketch also makes `currentState` nonisolated, unlike the existing `NearWire.currentState` actor-isolated snapshot. That requires a second locked/atomic state source outside the actor and an explicit winner rule with stream publication, but the design merely says the actor owns a latest-state hub.

**Required remediation:** add a complete transition table for Stopped/Running/Failed across successful start, idempotent start, lease contention, unsupported platform, partial setup error, post-start error, explicit stop, cancellation, restart, and deinit. State whether each throwing pre-run failure publishes. Prefer actor-isolated `currentState` for consistency and one source of truth, or specify the exact synchronized snapshot/hub design and atomic publication ordering required by the nonisolated API.

### P2 — Medium: The battery “lease restoration” guarantee cannot safely account for host ownership

**Confidence: 9/10**

`UIDevice.current.isBatteryMonitoringEnabled` is App-global mutable state. Apple documents that toggling it controls battery readings and battery notifications for the App ([Apple documentation](https://developer.apple.com/documentation/uikit/uidevice/isbatterymonitoringenabled)). The proposed reference count coordinates NearWire monitors only. Restoring the value observed by the first NearWire claimant can overwrite a host or another framework that changes the same property while monitoring is active; the module cannot distinguish another owner setting `true` from its own retained `true` value.

Therefore the current claim that stop/deinit restores the shared resource without host interference is stronger than the API can implement.

**Required remediation:** choose and document an honest ownership policy before implementation. Options include requiring host-managed battery monitoring, adding an explicit module-managed policy with a documented no-concurrent-mutation contract, or treating restoration as best effort and never claiming ownership isolation beyond NearWire's own monitors. Tests must cover initially enabled/disabled state and the selected host-interference rule; the specification must not promise exact restoration that cannot be observed safely.

### P2 — Medium: Unavailable reasons lack a deterministic precedence and complete metric-key inventory

**Confidence: 10/10**

The design simultaneously requires stable `unsupported` records for GPU, power, temperature, byte rates, and downlink depth; `disabled` records for every field in a disabled group; unique metric keys; and sorted output. When a group is disabled, an inherently unsupported field in that group qualifies for both reasons, but no precedence is defined. The artifacts also do not enumerate the exact stable field keys belonging to each group, so JSON parity and mutation tests cannot establish the promised deterministic list.

**Required remediation:** specify the complete V1 metric-key table, group ownership, unit/source, support class, and reason precedence. A simple total rule is: disabled overrides every field in that disabled group; when enabled, stable unsupported applies before read attempts; permission/temporary applies only to supported attempted reads; each key appears once, sorted. Also state that `droppedEventCount` is the saturated cumulative instance statistic (if that is intended), not an interval delta.

## Verified Decisions

- Platform-neutral schema remains correctly placed in Core; UIKit, QuartzCore, Darwin, and Mach collection remains in the optional SDK target.
- `task_info` and `task_vm_info_data_t.phys_footprint` are documented Apple kernel interfaces, so the proposed memory source is not inherently a private-symbol design ([Apple `task_info`](https://developer.apple.com/documentation/kernel/1537934-task_info), [Apple `task_vm_info_data_t`](https://developer.apple.com/documentation/kernel/task_vm_info_data_t)). Device/release validation is still appropriate.
- `CADisplayLink` is supportable for callback-cadence estimation when documented as an estimate and invalidated on teardown; it must not be presented as rendered frames or GPU utilization ([Apple `CADisplayLink`](https://developer.apple.com/documentation/quartzcore/cadisplaylink)).
- Reusing `sendPlatformEvent` with one exact keep-latest key correctly preserves the ordinary NearWire queue/transport boundary.
- The optional SwiftPM product, optional CocoaPods subspec, macOS compile-only path, and absence of third-party runtime dependencies are directionally correct.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: passed.
- Current artifacts remain pre-implementation; no Performance production/test source beyond the bootstrap marker was changed by this review.

## Verdict

**Changes required. Four actionable findings: one High and three Medium.** Resolve the public API decision first, then make lifecycle, battery ownership, and unavailable semantics total before implementation begins.
