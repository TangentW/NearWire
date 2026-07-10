## Why

NearWire now has a validated event model, but a producer can still outpace a connection or consumer indefinitely. The next dependency for transport and SDK work is a deterministic Core layer that bounds memory, expires stale work, coalesces state updates, schedules priorities fairly, and converts negotiated event rates into safe batches without promising delivery.

## What Changes

- Add a generic in-memory pending-event representation that keeps queue policy and accounting metadata separate from session sequence allocation.
- Add configurable event-count, byte-count, single-event, and batch limits with safe defaults and validation.
- Add `.normal` and validated `.keepLatest(key:)` queue policies.
- Add deterministic coalescing, TTL expiration, priority-aware overflow eviction, explicit clearing, and cumulative queue telemetry.
- Add weighted fair dequeue across low, normal, high, and critical priority lanes while preserving FIFO order within each lane.
- Add finite event-rate values, conservative Viewer/App rate negotiation, a monotonic token bucket with bounded bursts, pause-at-zero behavior, and dynamic reconfiguration.
- Add a deterministic batch scheduler that combines rate-approved events subject to event-count, byte-count, and flush-interval limits without starting timers itself.
- Add the `critical` internal event-priority value needed by weighted scheduling and overflow protection.
- Add adversarial and deterministic tests for every limit, overflow, expiration, coalescing, fairness, rate, clock, and batching boundary.
- Add English flow-control documentation and preserve the existing dependency, platform, and distribution graph.

## Capabilities

### New Capabilities

- `bounded-event-queue`: Bounded in-memory queueing, normal and keep-latest policies, local TTL, fair priorities, overflow behavior, clearing, and telemetry.
- `event-rate-control`: Effective-rate negotiation, token-bucket admission, pause and reconfiguration semantics, and count/byte/interval-bounded batch planning.

### Modified Capabilities

- `event-model`: Extend internal event priority with `critical` so later queues can protect urgent business events without creating a separate delivery guarantee.

## Impact

- Adds production source under `Core/Sources/NearWireFlowControl` and focused tests under `Core/Tests/NearWireFlowControlTests`.
- Adds one additive priority case to the internal `NearWireCore.EventPriority` value.
- Adds no target, product, package, pod, UI framework, timer, network API, persistence, or third-party dependency.
- Establishes the queue and rate primitives later consumed by the SDK and Viewer, but does not choose session disconnect policy, allocate wire sequence numbers, send network frames, or expose public SDK queue types.
