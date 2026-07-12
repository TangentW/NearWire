# Pre-Implementation Round 5 Correctness and Testing Review

Date: 2026-07-12

## Scope

Independently reviewed all current active `sdk-performance` artifacts, every prior correctness report and remediation record, and the relevant existing Core schema, NearWire diagnostics, and queue behavior. This report is the only file modified.

## Findings

**Zero actionable findings.**

## Verification

### Failure-targeted cleanup and actor reentrancy

The remaining Round 4 finding is resolved. A post-start sampling or submission failure now invalidates the exact run and enters the same internal Stopping phase used by explicit stop, with one nonthrowing cleanup Task, exact token/receipt, and pending Failed target. The worker releases every task-owned external resource before emitting its receipt; only exact receipt validation can discard the predecessor handle and publish Failed. Failed is therefore never visible while old display, battery, monitor-lease, baseline, accumulator, session, or Task resources remain live.

Explicit stop joining that barrier atomically changes the pending target to Stopped, joins the same cleanup, and suppresses Failed. A start entering during cleanup acquires nothing, awaits the receipt, checks its own cancellation, and only then begins or joins one fresh Starting attempt. Multiple stops share one receipt; multiple starts converge after cleanup; cancelled cleanup waiters do not cancel cleanup or an unrelated successor. Exact predecessor handles and token validation prevent stale receipt/failure paths from releasing or overwriting successor resources.

The transition table and tests now cover slow sampling/submission failure cleanup, receipt-before-publication ordering, start and stop during failure cleanup, stop target override, cancelled waiters, duplicate/stale terminal callbacks, exact resource counts, no generation overlap, and publication winner sequences.

### Earlier correctness contracts

All prior findings remain closed:

- Drop accounting includes only overflow, expiry, and routing terminal removals; admission rejection, coalescing, and explicit clear are excluded and saturation is JSON-safe.
- Stopped/Starting/Running/Stopping/Failed behavior, shared start cancellation, explicit-stop cleanup, stale generations, and setup error/publication outcomes are total.
- First sampling waits one full interval from a fresh epoch; header boundary, half-up millisecond rounding, clamping, delayed/no-catch-up scheduling, slow collection, and restart reset are specified and testable.
- CPU uses an optional successful-to-successful baseline. Initial/repeated failure, first-valid baseline establishment, second-valid emission, post-baseline recovery, invalid pair rebaseline, real zero, multi-core values, and restart reset are complete.
- FPS callback ownership, minimum count, exact formula, invalid timestamps, reset, delayed cadence, and stable-unsupported maximum FPS are complete.
- The closed metric-key inventory and disabled/unsupported/attempted precedence guarantee one sorted unavailable record per absent field and prohibit present/unavailable conflicts.
- State subscribers are bounded independently from run resources, cancel by exact identity, persist across stop/restart, and finish on deinit.
- Managed/unmanaged battery behavior, observable external conflict, macOS unsupported start, keep-latest queue delivery, optional packaging, and content-safe error/state streams have proportionate deterministic and platform test gates.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.

## Verdict

**Pre-implementation correctness/testing approval granted. Unresolved actionable finding count: 0.**
