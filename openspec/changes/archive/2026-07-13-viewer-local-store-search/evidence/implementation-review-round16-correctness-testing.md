# Implementation Review Round 16 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

Round 15 finding `NW-LSS-IMPL-R15-CT-001` is resolved. Ending the final current runtime now
captures and waits for the one active reopen construction even when that construction belongs to
a superseded predecessor. A late noncurrent predecessor cleanup still captures only its own exact
request lease and therefore cannot wait for, cancel, or drain valid newer ownership.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain
explicitly deferred, by user direction, to goal-level `release-hardening`. They are neither an
actionable finding nor represented as passing evidence in this review.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both
capability specifications, and task plan; all three Round 15 implementation-review reports;
`implementation-remediation-round15.md`; `implementation-validation-round16.md`; and the current
Viewer store/runtime, SQLite, maintenance, query, export, session-manager, application-lifecycle,
tests, operator documentation, package, project, privacy, and evidence paths.

The review first reproduced the missing final-C-first state transition from the Round 15 finding,
then retraced initial unavailable startup, explicit retry with and without a runtime, intentional
coordinator detach, automatic sequential reopen, request admission, generation invalidation,
constructor failure, stale replacement disposal, same-ID start, distinct-runtime supersession,
late predecessor cleanup, matching and nonmatching runtime end, terminal close, recovery-claim
publication, worker handoff, 64-generation coalescing, and real application shutdown.

Production, test, specification, task, package, project, privacy, and operator-documentation files
were not modified by this review. This report is the only file added.

## Round 15 Finding Disposition

### `NW-LSS-IMPL-R15-CT-001` — Resolved

The new cleanup-authority split closes both orderings without introducing a global drain:

- `detachRuntime(logicalID:)` determines current-runtime ownership while holding the runtime lock.
  If the ending logical ID is the current context, it captures `reopenConstruction?.lease`
  regardless of the construction request's predecessor ID, then invalidates the current request
  generation and clears the context (`ViewerStoreCoordinator.swift:1822-1843`). The ownership
  transition and lease capture are therefore atomic with respect to construction admission.
- If the ending logical ID is not current, cleanup instead uses
  `reopenConstructionLeaseLocked(for:)`, which returns a lease only for an automatic or
  runtime-bound explicit request carrying that exact logical ID
  (`ViewerStoreCoordinator.swift:1830-1832`, `2001-2012`). Late B cleanup can wait for B, but it
  cannot capture a valid C or D construction.
- `runtimeEnded` performs the asynchronous lease wait only after `detachRuntime` unlocks, and only
  then shuts down an installed coordinator owned by that logical runtime
  (`ViewerStoreCoordinator.swift:1802-1820`). No execution gate, SQLite construction, coordinator
  close, `DispatchGroup` wait, or async coordinator shutdown occurs while the runtime lock is held.
- The construction lease is installed after the first request/generation validation and before the
  execution gate or coordinator constructor. Its one deferred finish occurs only after constructor
  failure, valid publication, or full close of a constructed replacement that lost authority
  (`ViewerStoreCoordinator.swift:1891-1976`, `2044-2059`). Multiple cleanup calls may safely wait
  for the same one-shot `DispatchGroup` lease (`ViewerStoreCoordinator.swift:1299-1321`).

For the reported A/B/C ordering, B owns the active lease when C becomes current. Ending C now
captures B's lease, invalidates C, and remains incomplete. Releasing B constructs the replacement;
the publication check rejects stale B, closes all replacement resources, and only then completes
the lease. C can finish afterward. A later `runtimeEnded(B)` sees no B construction and cannot
touch later D ownership.

For the inverse ordering, late B cleanup while C is current still obtains only B's exact lease. If
B has already finished and valid C construction has begun, the helper returns nil for B. This
preserves the previously required newer-runtime isolation rather than making current-runtime
shutdown a process-global wait for future work.

## Deterministic Regression Assessment

`testFinalCurrentRuntimeWaitsForSupersededReopenConstruction`
(`ViewerStoreTests.swift:2012-2123`) directly exercises the previously untested branch:

1. A starts durably and ends, creating the one legitimate next-runtime automatic-reopen reason.
2. B starts and pauses after its request has passed validation and its construction lease has been
   installed.
3. C supersedes B and becomes the final current runtime.
4. C ends before late B cleanup. The test observes `runtimeEndWaiting` and proves C has not
   completed while B remains gated.
5. Releasing the gate proves the ordered resource sequence
   `runtimeEndWaiting`, `coordinatorConstructed`, `staleCoordinatorClosed`, followed by C
   completion.
6. The database still contains only A; neither B nor C has an active recording, and runtime status
   is unavailable.
7. Late `runtimeEnded(B)` is harmless. Later D receives exactly one automatic construction attempt
   and exactly one `storageUnavailable` gap, then shuts down normally.

The assertions are tied to the actual missing branch rather than scheduler timing alone. The gate
blocks after lease reservation, the completion counter proves wait-before-release, ordered
content-free resource events prove close-before-completion, the recording count excludes hidden B
or C materialization, and the later-D assertions prove retained authority was neither lost nor
duplicated.

## Request, Generation, Coalescing, and Shutdown Audit

### Request authority and recovery

- Initial construction failure leaves storage unavailable and grants no automatic next-runtime
  authority. A no-coordinator Retry creates a typed explicit request only. The persistent
  `needsRuntimeReopen` reason is set only when a coordinator owned by an ending runtime is
  intentionally detached, and terminal close clears it.
- Automatic and runtime-bound explicit requests require the exact current runtime ID. A no-runtime
  explicit request requires a nil runtime context. Every construction rechecks request equality,
  attempt generation, current runtime shape, and coordinator absence before opening resources and
  again before publication.
- Same-ID `runtimeStarted` remains a true early return. A distinct runtime invalidates reopen and
  recovery generations before installing its context. Stale failure clears only a still-current
  request; it cannot erase a newer coalesced request.
- Recovery completion remains bound to the exact recovery generation, coordinator object,
  coordinator-runtime ID, and current runtime ID. Invalidated callbacks cannot publish into a
  successor. Failed recovery saturating-merges the claimed missed-observation count back with
  observations accumulated during the attempt.

### Physical worker bound

- `reopenWorkerScheduled` remains the single physical worker-chain token, while
  `reopenScheduled`, `reopenRequest`, and `reopenAttemptGeneration` describe the latest logical
  request. Repeated supersession replaces one latest request rather than retaining one block per
  generation (`ViewerStoreCoordinator.swift:1855-1889`).
- One running turn performs at most one construction. On return it schedules at most one latest
  successor. Constructor failure or terminal invalidation creates no polling, timer, recursive
  retry, or unbounded task/value chain.
- A newer runtime may start while an older cleanup waits. The older waiter owns only the lease it
  captured. Once that lease finishes, the serial worker may service the latest valid request; the
  old cleanup does not wait for or cancel that newer construction.

### Shutdown ownership

- Matching installed-coordinator shutdown still closes device/recording lifecycle state through
  the bounded coordinator path. Late old-runtime cleanup cannot detach a replacement coordinator
  because coordinator detachment requires the exact coordinator runtime ID.
- Ending the current context now waits any construction already active at that ownership
  transition. Ending a noncurrent context waits only its exact active request. Terminal
  `closeStorage` captures the one active construction, invalidates all logical authority under the
  lock, waits outside the lock, and then closes the installed coordinator
  (`ViewerStoreCoordinator.swift:1484-1501`).
- A request that is queued logically but has not passed the first construction guard has no lease
  and no resource ownership. If shutdown invalidates it first, the worker fails its initial locked
  guard and performs no execution-gate, filesystem, SQLite, maintenance, status, gap, or recording
  work.
- `ViewerMultiDeviceSessionManager.beginShutdown()` memoizes one shutdown task, waits for all
  device terminals, and calls the journal's exact runtime end once. Application retry, identity
  reset, close, and termination reuse the existing cleanup receipt rather than creating competing
  runtime-end owners.

No lock cycle, generation ABA, lost automatic reason, duplicate successor, stale publication,
premature construction-lease release, or unbounded shutdown work was found in the reviewed paths.

## Prior Finding and Evidence Audit

All earlier correctness/testing findings remain resolved on the current tree. The review
specifically rechecked the previously remediated boundaries for failed-prefix retention, terminal
flush behavior, writer-serialized capacity admission, exact query/filter validation, recovery
claim ownership, settings/recovery generation supersession, cumulative drops, initial-outage gap
ownership, same-runtime idempotence, sequential automatic reopen, maintenance-before-terminal
flush ordering, reader-after-schema opening, and closed diagnostic surfaces. The Round 15 lease
change is isolated to runtime cleanup authority and does not reopen those paths.

The historical Round 15 architecture and security reports approved the then-reviewed exact-ID
lease paths, while the independent Round 15 correctness report found the missing final-C-first
cross-ID ordering. The latter correctly withheld the round gate. Round 16 remediation and
validation supersede that incomplete historical approval; no current evidence claims that the old
implementation passed the missing branch.

Saved Round 16 counts match the current tree:

- nine selected scenarios times 20 iterations equals 180 executions;
- the new regression increases the Store suite from 91 to 92 tests;
- the unsigned Viewer suite increases from 172 to 173 tests;
- the one Store/Viewer skip is the explicit machine-local live Application Support audit marker;
- the two configured-signing probes are excluded, not counted as passed or skipped; and
- the package result discloses all seven condition-based skips and does not represent them as
  passes.

The Round 16 record also keeps unchanged-input package/CocoaPods evidence distinct from fresh
Viewer validation, identifies the initial restricted-cache manifest failure before the successful
isolated rerun, and does not claim fresh CocoaPods or configured-signing success. No inaccurate
test count, exclusion, skip, source/product freshness, or completion claim was found.

## Non-actionable Terminal Worker Tail

The previously documented terminal-close handoff interleaving remains bounded and non-actionable
under the goal threshold. A worker may sample a successor before terminal close invalidates it and
submit one closure afterward. That closure fails the first locked guard, clears only physical
worker occupancy, and returns. It cannot enter the execution gate, open or close a filesystem or
SQLite resource, run maintenance, publish status, claim a gap, materialize a recording, or schedule
another successor. It is constant-bounded and content-free.

Accordingly, this review treats it as an audit observation, not as literal proof that the private
serial queue is empty at return and not as an approval blocker. Any material side effect or
generation-dependent accumulation would change that conclusion; neither exists in the current
implementation.

## Fresh Independent Validation

The reviewed production dylib and test executable are newer than both reviewed source files:

```text
ViewerStoreCoordinator.swift                    2026-07-13 14:34:01
ViewerStoreTests.swift                          2026-07-13 14:34:01
NearWire.debug.dylib                            2026-07-13 14:35:58
NearWireViewerTests executable                  2026-07-13 14:36:00
```

An initial sandboxed `xcodebuild test-without-building` invocation was blocked before test
execution because Xcode/SwiftPM attempted to write restricted user cache paths. The approved rerun
used the identical test selection and current products and succeeded. The environment-only first
failure is not represented as a product test failure or hidden as a pass.

### Nine remediation scenarios, 20 iterations each

```text
ViewerStoreTests: 180 tests, 0 skipped, 0 failures
3.432 seconds test execution
/tmp/NearWireViewerRound16Focused/Logs/Test/
  Test-NearWireViewer-2026.07.13_14-42-48-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

The selection covered failed and cancelled initial explicit Retry, matching runtime-end
construction cancellation, terminal-close construction cancellation, newer-runtime supersession,
final-current C ending before late B cleanup, 64-generation coalescing, terminal discard of a
coalesced successor, and real application rapid stop.

### Complete Store regression

```text
ViewerStoreTests: 92 tests, 1 explicit live-resource-audit skip, 0 failures
4.268 seconds test execution
/tmp/NearWireViewerRound16Focused/Logs/Test/
  Test-NearWireViewer-2026.07.13_14-42-59-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Specification and hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output
```

These fresh results agree with the authoritative saved Round 16 completion record. The configured
signing, entitlement, and stable-signer probes remain deferred to `release-hardening` and are not
part of this verdict.

## Completion Gate

Round 16 correctness/testing approval is granted with exactly **zero** unresolved actionable
findings: **0 High, 0 Medium, 0 Low**. `NW-LSS-IMPL-R15-CT-001` is closed, all prior findings remain
resolved, and no further correctness/testing remediation is required before the independent round
gate and spec-to-evidence audit proceed.
