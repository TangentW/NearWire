# Review round 1

## Scope

Three independent reviewers examined the initial implementation for architecture, correctness, security, documentation, and specification alignment. This record consolidates overlapping findings by root cause.

## Findings and disposition

1. **Positive rates below one event per burst could never produce a whole token.** Resolved by defining positive capacity as `max(1, rate × burstDuration)`, adding a representable minimum positive rate, and covering construction, exhaustion, refill, resume, and delay boundaries.
2. **Already-expired incoming events could be admitted, replace live keep-latest state, or trigger overflow.** Resolved by checking the incoming deadline before coalescing and admission, reporting the expired ID, and adding normal, keep-latest, and full-queue regressions.
3. **Snapshot and scheduler expiration discarded exact IDs.** Resolved by returning expired IDs from snapshots and due batch attempts, including empty and paused attempts, with token-backed and zero-token regressions.
4. **Duplicate pending IDs made retention and affected-ID telemetry ambiguous.** Resolved by atomically rejecting duplicate IDs after existing expiration and before coalescing, with normal and keep-latest regressions.
5. **Keep-latest keys accepted C1 Unicode controls.** Resolved by validating against `CharacterSet.controlCharacters` and testing all C0, DEL, and C1 scalars.
6. **The implementation hard count exceeded the normative 10,000-entry limit.** Resolved by aligning code, diagnostics, tests, design, specification, and documentation at 10,000.
7. **Overflow, expiration, and batch dequeue used repeated array scans and removals.** Initial bulk planning removed repeated work inside one call; the later hard-bound sequence review led to the final ordinal dictionary, hash indexes, priority heaps, deadline heap, and bounded stale-node compaction design.
8. **Weighted-fairness tests did not prove credit continuity across calls.** Resolved with two continuously populated weighted cycles drained one event per call.
9. **The initial review had no final canonical validation evidence.** Deferred to the evidence task after review remediation is stable; it is not treated as an implementation defect.

All implementation findings from this round are remediated before round 2 begins.
