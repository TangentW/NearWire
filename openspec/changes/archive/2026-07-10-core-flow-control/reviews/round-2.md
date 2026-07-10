# Review round 2

## Result

Fresh architecture, correctness, and security reviews after round-1 remediation found six remaining root causes. All implementation and coverage findings below were resolved before round 3. Canonical evidence is intentionally marked stale until the corrected source stops changing.

## Findings and resolutions

### 1. Hard-bound operation sequences still accumulated quadratic work — P1

The array-backed implementation rebuilt or sorted the live queue for each admission and single-event drain. It was replaced with ordinal-keyed storage, constant-time event-ID and keep-latest indexes, per-priority minimum heaps, a deadline minimum heap, event-ID stale-node validation, and bounded heap compaction. The scheduler no longer transactionally copies the full queue. Regressions fill and drain all 10,000 entries one at a time, exercise repeated keep-latest priority changes, and run 2,000 one-event scheduled flushes.

### 2. Minimum-rate delay could wake before a token existed — P2

Floating-point rounding made the initial duration estimate slightly early at the supported minimum rate. Delay calculation now replays the exact refill projection and advances the duration until it guarantees at least one whole token. The minimum-rate regression consumes the initial token, waits exactly the returned duration, and proves one token is available.

### 3. Queue and batch incompatibility failed too late — P2

The normative scenario required scheduler construction to reject an incompatible pairing, but the initial scheduler accepted it and failed during the live drain loop. Scheduler construction now requires and stores exact queue limits, validates maximum event bytes immediately, and rejects a different queue configuration at runtime. Tests cover construction-time rejection and atomic mismatch protection.

### 4. Canonical event-model documentation omitted critical priority — P2

`Documentation/Event-Model.md` still listed only low, normal, and high. The canonical table now includes critical and retains the non-delivery-guarantee boundary.

### 5. Burst-duration reconfiguration lacked claimed coverage — P2

Tests now prove that decreasing burst duration clamps existing tokens, increasing it does not manufacture tokens, and invalid burst reconfiguration leaves the bucket unchanged.

### 6. Canonical validation evidence became stale — P2

Run `20260710T225851Z-11602` validated the first-round source, not these remediations. Tasks 7.1 and 7.2 were reopened. A new canonical run will replace every raw log only after the corrected source and tests are stable.
