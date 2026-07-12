# Pre-Implementation Round 2 Correctness and Testing Review

Date: 2026-07-12

## Scope

Independently re-reviewed `AGENTS.md`, every active `sdk-performance` proposal/design/specification/task/evidence artifact, the prior correctness report, and the relevant Core performance schema, NearWire diagnostics, queue, and keep-latest behavior. This report is the only file modified by the review.

## Prior Finding Resolution

All five Round 1 correctness findings are resolved in the normative plan:

1. **Dropped-event accounting:** resolved. The count now includes only overflow, expiry, and routing terminal-removal counters, clamps to `Int64.max`, and explicitly excludes admission rejection, coalescing, and owner clear. Tests cover repeated retained rejection and each included/excluded counter.
2. **Lifecycle state outcomes:** resolved. The complete transition table defines Stopped/Running/Failed start and stop behavior, pre-commit failures, caller cancellation, stop-versus-failure winner order, restart, stale generation suppression, and publication counts.
3. **CPU baseline recovery:** resolved. CPU uses its own successful-to-successful CPU/time pair; read failure preserves it, invalid arithmetic resets it, and tests cover first sample, recovery, regression, non-positive time, overflow, real zero, and values above 100.
4. **FPS formula:** resolved. Callback ownership, two-sample minimum, exact `(count - 1) / elapsed` formula, boundary serialization, invalid timestamp behavior, reset, delayed sampling, and independent maximum-FPS availability are specified and covered.
5. **Unavailable precedence:** resolved. The closed key inventory, group ownership, disabled-over-unsupported precedence, present-versus-unavailable exclusion, uniqueness, sorting, and exhaustive key/reason tests are explicit.

## Remaining Findings

### 1. P2 / Medium — The first sampling deadline and header epoch are undefined

**Confidence: 10/10**

The design says the sampling Task “sleeps between turns,” records elapsed time “since the prior sample,” and schedules a delayed successor from completion, but it never defines whether `start()` produces an immediate first sample or sleeps one configured interval first. There is no prior sample for the first `sampleIntervalMilliseconds`, so an immediate implementation could emit a near-zero/clamped interval with unavailable first-baseline CPU/FPS, while another conforming implementation could establish baselines at committed start and emit first only after one interval.

The exact boundary instant is also needed to make wall time, header elapsed duration, display accumulator consumption, and next-deadline tests agree. “Exact interval” in task 4.2 does not supply the missing expected value.

**Required resolution:** define one sampling epoch, preferably: successful start records the initial monotonic/header baseline and collector baselines, the first due turn occurs after one configured interval, each turn captures the header boundary at a named point, and the next sleep begins from completed-turn time without catch-up. Define the exact millisecond rounding rule and positive/JSON-safe clamp. Add deterministic tests for first turn, first header, slow collection, delayed wake, half-millisecond rounding boundary, and restart resetting the epoch/partial display state.

### 2. P2 / Medium — The inactive subscriber resource bound contradicts the public state-stream contract

**Confidence: 10/10**

The state stream is intentionally available before start, immediately yields Stopped, and retains one latest value per subscriber. However, the resource section says “Before start: zero ... subscriber.” A consumer can legally obtain and consume `states` while the monitor remains Stopped, so this hard bound is false unless it means “when no consumer has subscribed.” It also conflicts with the planned exact inactive resource-count evidence.

**Required resolution:** state subscriber bounds independently of run state: zero sampling/collector resources while Stopped, plus exactly one bounded continuation per live caller-created state subscription at any lifecycle state. Update resource tests to cover pre-start subscriptions, multiple subscribers, independent cancellation, stop/restart persistence, deinit finish, and zero continuation retention after termination.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.

## Verdict

**Unresolved actionable finding count: 2 Medium. Pre-implementation correctness/testing approval remains withheld pending resolution and a fresh review.**
