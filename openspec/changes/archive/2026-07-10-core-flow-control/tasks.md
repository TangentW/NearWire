## 1. Pending Model and Configuration

- [x] 1.1 Add `critical` to internal event priority and cover Codable round trip plus exhaustive ordering.
- [x] 1.2 Implement typed flow-control errors with stable codes, paths, and Equatable diagnostics.
- [x] 1.3 Implement validated queue limits with 1,000-event, 4 MiB, and 256 KiB defaults plus hard coherent bounds.
- [x] 1.4 Implement validated normal and keep-latest policies and keep-latest key limits.
- [x] 1.5 Implement generic Sendable pending events with stable ID, value, priority, TTL, policy, byte cost, and origin-local enqueue time but no session or sequence fields.
- [x] 1.6 Add configuration, policy, key, byte-cost, Sendable, and session-neutral ownership tests.

## 2. Bounded Queue Semantics

- [x] 2.1 Implement deterministic insertion ordinals, normal admission, and keep-latest in-place replacement with full new metadata.
- [x] 2.2 Implement same-clock expiration before admission, selection, and telemetry with atomic backward-clock and overflow failure.
- [x] 2.3 Implement repeated lowest-priority oldest overflow eviction across both count and byte limits, including incoming-event eviction.
- [x] 2.4 Implement exact enqueue, expiration, eviction, dequeue, and clear results with saturating cumulative counters.
- [x] 2.5 Implement queue snapshots with current count, bytes, priority counts, and oldest same-clock wait after expiration.
- [x] 2.6 Add count-first, bytes-first, multiple-eviction, incoming-drop, coalescing-growth, TTL-reset, clock-failure, clear, saturation, and invariant tests.

## 3. Weighted Fair Selection

- [x] 3.1 Implement 1/2/4/8 weighted round-robin credits for low, normal, high, and critical lanes.
- [x] 3.2 Preserve logical insertion order within each priority, handle keep-latest promotion or demotion, and skip empty lanes without wasting capacity.
- [x] 3.3 Implement non-destructive fair candidate planning so a byte-limited batch can stop without skipping or removing the next candidate.
- [x] 3.4 Add full-cycle ratio, continuous low-lane progress, empty-lane, FIFO, promotion, demotion, and repeated-cycle tests.

## 4. Effective Rates and Token Bucket

- [x] 4.1 Implement finite bounded event-rate values and independent conservative uplink/downlink negotiation with zero-rate pause.
- [x] 4.2 Implement explicit-monotonic token refill, fractional tokens, whole-event availability, exact consumption, bounded burst capacity, and next-token delay.
- [x] 4.3 Implement atomic backward-clock rejection and dynamic rate or burst reconfiguration with old-rate refill, clamping, pause, and no synthetic resume burst.
- [x] 4.4 Add below/equal/above-rate, initial burst, fractional boundary, capacity clamp, zero pause, resume, reconfiguration, clock reversal, and large-time tests.

## 5. Batch Planning

- [x] 5.1 Implement validated batch count, byte, and 500 ms interval limits with queue single-event compatibility.
- [x] 5.2 Implement immutable nonempty batches with exact total byte accounting.
- [x] 5.3 Implement caller-driven due checks, expiration, token allowance, fair bounded selection, exact token consumption, and next-deadline advancement without catch-up bursts.
- [x] 5.4 Preserve the next fair event when it cannot fit remaining batch bytes and advance due deadlines on empty or paused attempts.
- [x] 5.5 Add early, exactly-due, late, missed-interval, empty, paused, count-bound, byte-bound, token-bound, unused-token, and next-event preservation tests.

## 6. Documentation and Distribution Safety

- [x] 6.1 Add English flow-control documentation covering pending ownership, accounting, defaults, policy, TTL, priority, fairness, rates, bursts, batches, telemetry, and non-delivery semantics.
- [x] 6.2 Keep queue, bucket, and scheduler implementations free of timers, sleeping, UI imports, network I/O, persistence, locks, and third-party dependencies.
- [x] 6.3 Format all Swift source and confirm the locked SwiftPM and CocoaPods target, product, provenance, dependency, and source-mapping contracts remain unchanged.
- [x] 6.4 Verify all new public cross-module values are Sendable and no supported SDK signature exposes internal flow-control types.

## 7. Validation, Review, and Archive

- [x] 7.1 Run focused NearWireFlowControl and affected NearWireCore tests plus full iOS Simulator, macOS Core, strict-concurrency, CocoaPods, boundary, distribution, English, and OpenSpec gates.
- [x] 7.2 Capture exact commands, run identity, outputs, test counts, failures, expected notes, and residual limitations under the change evidence directory.
- [x] 7.3 Run independent architecture/API, correctness/testing, and security/performance/documentation review round 1 and record every finding.
- [x] 7.4 Resolve every finding, add regression coverage, recapture affected evidence, and repeat fresh review rounds until all three dimensions report zero unresolved findings.
- [x] 7.5 Complete a requirement-by-requirement audit, mark every task complete, validate strictly, archive the change into baseline specs, and commit it before `core-wire-protocol` enters apply.
