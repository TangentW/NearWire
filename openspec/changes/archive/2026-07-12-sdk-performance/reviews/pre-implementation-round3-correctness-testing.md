# Pre-Implementation Round 3 Correctness and Testing Review

Date: 2026-07-12

## Scope

Independently reviewed all current active `sdk-performance` artifacts, both prior correctness reports, Round 2 remediation, and the relevant Core schema, NearWire diagnostics, queue, and lifecycle source. This report is the only file modified.

## Prior Finding Resolution

- **First sampling epoch and rounding:** resolved. Setup establishes a fresh epoch immediately before Running; no immediate sample is emitted; the first turn waits one full configured interval; boundaries are captured after wake and before reads; elapsed time includes prior collection plus the next sleep; half milliseconds round upward and clamp to `1...Int64.max`; restart resets epoch, CPU baseline, and display accumulation. Deterministic first-turn, slow-collection, delayed-wake, half-boundary, clamp, and restart tests are required.
- **State-subscriber resource bound:** resolved. Caller-created continuations are now bounded independently from run state, remain live across stop/restart, terminate by exact identity, and finish on deinit. Inactive/run resource evidence explicitly separates those continuations from collector resources.
- **Starting reentrancy:** partially resolved. One exact Starting token/task, joined concurrent starts, shared cancellation, token checks before each acquisition/commit, stop-before-commit invalidation, and waiter outcome consistency are defined and testable.

All five Round 1 correctness findings remain resolved.

## Remaining Findings

### 1. P1 / High — `start()` during `stop()` cleanup is still undefined and can overlap generations/resources

**Confidence: 10/10**

The actor declares only Idle, Starting, and Running internal phases. `stop()` invalidates and cancels a Starting attempt or Running run, then awaits its cleanup. That await is actor-reentrant. The plan does not define what another `start()` call does after invalidation but before the old setup/run has actually released its display link, battery claim, monitor lease, collector session, and Task.

If stop changes the phase to Idle before awaiting, the new start can begin a second setup while old resources remain live, violating exact bounds or receiving a spurious `monitorAlreadyRunning` from the old lease. If the phase remains Starting/Running, the new start may incorrectly join an already-cancelled attempt or be treated as a Running no-op. The stale-token rule prevents old completion from mutating the new run, but it does not by itself serialize external resource teardown with new acquisition.

The transition table covers stop during Starting and restart after prior failure, while task 4.3 mentions stale setup after restart; neither specifies the start-during-stop outcome.

**Required resolution:** add an internal Stopping/Cleaning barrier or equivalent exact cleanup Task. A `start()` entering during stop cleanup must have one normative behavior—preferably await that cleanup and then start fresh—without joining cancelled work, throwing a lease-conflict caused by its own predecessor, or overlapping resource counts. Define cancellation of that waiting start and multiple start/stop callers. Add barriers at partial setup, MainActor setup, active sampling, and noncooperative dependency cleanup; assert no generation overlap, exact publication sequences, one lease/session maximum, and no stale cleanup release of the successor.

### 2. P2 / Medium — Initial CPU baseline failure conflicts with the requirement to establish baselines before Running

**Confidence: 9/10**

The plan says setup establishes CPU/display baselines immediately before Running commits. Separately, CPU read failure is an individual temporarily-unavailable metric that preserves the prior successful pair, and failed individual reads must not discard other groups. On the initial baseline read there is no prior successful pair to preserve.

It is therefore unclear whether an initial `getrusage` failure makes `start()` fail with `collectorSetupFailed`, allows Running with no CPU baseline, or disables CPU for the run. These produce different lifecycle and first/recovery sample behavior. The CPU recovery scenario only covers a failure between two valid readings, not failure before the first valid pair.

**Required resolution:** define initial-baseline failure explicitly. A conservative rule is to allow Running, mark CPU temporarily unavailable, let the first later valid reading establish a baseline without emitting CPU, and emit only after a second valid strictly-later pair; memory and other groups continue independently. Add deterministic sequences for initial failure then two successes, repeated initial failures, initial invalid/regressing clock data, stop/restart before baseline, and confirm no setup failure/public Failed state unless collector-session construction itself—not an individual reading—fails.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.

## Verdict

**Unresolved actionable finding count: 2 — one High and one Medium. Pre-implementation correctness/testing approval remains withheld pending resolution and another fresh review.**
