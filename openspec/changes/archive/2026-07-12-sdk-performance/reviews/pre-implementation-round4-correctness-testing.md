# Pre-Implementation Round 4 Correctness and Testing Review

Date: 2026-07-12

## Scope

Independently reviewed all current active `sdk-performance` artifacts, prior correctness reports, Round 3 remediation, and relevant existing schema/diagnostics/queue behavior. This report is the only file modified.

## Prior Finding Resolution

- **Stopping barrier:** resolved for explicit stop. The internal Stopping phase owns one exact cleanup token and nonthrowing cleanup Task, rejects successor acquisition, joins concurrent stops, makes starts await cleanup before beginning/joining a fresh attempt, isolates waiting-start cancellation, and prevents predecessor cleanup from releasing successor resources. Tasks cover partial and MainActor setup, active sampling, slow/noncooperative cleanup, multiple callers, cancellation, generation overlap, and stale cleanup.
- **Initial CPU baseline failure:** resolved. An individual initial CPU read failure allows Running with an empty baseline; repeated failures remain temporarily unavailable; the first valid pair establishes without emitting; only a second valid strictly later pair emits; invalid pairs rebaseline; memory and other groups remain independent; only collector-session construction can fail start. Deterministic initial/repeated failure, two-success recovery, invalid pair, and restart tests are required.

All earlier correctness findings remain resolved.

## Remaining Finding

### P2 / Medium — Post-start failure cleanup is not explicitly serialized by the Stopping barrier

**Confidence: 9/10**

The new barrier is defined specifically for `stop()` during Starting or Running. A current-run sampling, snapshot, or event-submission failure is still described only as “invalidate run, clean resources, Failed.” The plan does not say whether:

1. the run Task completes all task-owned cleanup before re-entering the actor to commit Failed; or
2. the actor installs the same Stopping cleanup barrier, awaits it, and then commits Failed if the exact failure token still wins.

Without one of those rules, actor reentrancy during failure cleanup remains ambiguous. Publishing Failed before cleanup would allow a concurrent `start()` from Failed to acquire successor resources while the failed generation still owns its display link, battery claim, or monitor lease. Retaining public Running until cleanup while allowing `start()` to use the normal Running no-op would instead return success to a caller even though the run is already terminal and will shortly publish Failed. Stop racing this window also lacks a single cleanup owner.

The exact run-token winner rule prevents stale state publication, but does not alone establish resource serialization or the return value of a start entering during failure cleanup.

**Required resolution:** state that every post-start terminal failure either finishes all run-owned cleanup inside the run Task before reporting the terminal result, or enters one exact Stopping barrier shared with stop. Define `start()` and `stop()` behavior during that failure-cleanup window, including which public state remains visible and whether a waiting start begins fresh after cleanup. Add deterministic barriers at sampling and submission failure, then race start, stop, and duplicate failure callbacks; assert one cleanup owner, no resource overlap, one winning Failed-or-Stopped publication, no spurious Running no-op/lease conflict, and no stale release of a restarted run.

## Validation

- `DO_NOT_TRACK=1 openspec validate sdk-performance --strict --no-interactive`: **PASS**.
- Scoped `git diff --check`: **PASS**.

## Verdict

**Unresolved actionable finding count: 1 Medium. Pre-implementation correctness/testing approval remains withheld pending resolution and one fresh review.**
