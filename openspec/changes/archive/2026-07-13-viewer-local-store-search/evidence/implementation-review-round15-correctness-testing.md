# Independent Implementation Review — Round 15 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 0 Medium, 1 Low.**

All three Round 14 findings are resolved on their reported direct paths. Explicit retry no longer
creates cross-runtime automatic authority. An authorized construction now owns a request- and
generation-bound completion lease, and matching runtime end plus terminal close wait for that
lease. Reopen work now coalesces any number of superseding logical requests behind one physical
worker and one latest successor. The eight direct remediation scenarios are well asserted and
passed 20 iterations each both in the saved validation and this independent review.

One adjacent shutdown-completion cell remains. When current runtime C supersedes a paused
construction owned by B and C ends before late cleanup for B arrives, C waits only for a lease
whose request ID equals C. It can therefore report the last active runtime closed while stale B
still opens and closes SQLite resources. The race is finite and cannot publish a stale coordinator,
so it is Low; it nevertheless means the claimed runtime shutdown boundary does not own all SQLite
and startup-maintenance work.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain
explicitly deferred, by user direction, to goal-level `release-hardening`. They are neither
findings nor represented as passing here.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both
capability specifications, and tasks; all three Round 14 implementation-review reports;
`implementation-remediation-round14.md`; `implementation-validation-round15.md`; the current
runtime/coordinator, construction lease, worker, SQLite construction/close, application lifecycle,
new and adjacent Store tests, and Viewer local-store/operator documentation.

The review re-audited all three Round 14 findings, then traced initial unavailable startup,
explicit retry failure/cancellation/success, intentional detach, same-ID start, sequential
automatic reopen, generation invalidation, construction lease enter/finish/wait, constructor
failure, stale close, valid publication and recovery admission, matching and nonmatching runtime
end, newer-runtime supersession, final-runtime end, terminal close, worker request coalescing,
successor sampling/enqueue, failure with and without a successor, application Retry/termination,
and saved evidence accounting.

## Round 14 Finding Disposition

### `NW-LSS-IMPL-R14-ARCH-001` — resolved

- No-coordinator `retryStorage()` now admits only a typed explicit request; it no longer writes
  `needsRuntimeReopen` (`ViewerStoreCoordinator.swift:1732-1800`).
- Only intentional detachment of a coordinator that owned a logical runtime sets the
  process-lifetime next-runtime reason (`ViewerStoreCoordinator.swift:1822-1850`). A successful
  replacement consumes it, and terminal close clears it.
- Failed explicit construction clears only a still-current explicit request. Cancelling an
  explicit request with runtime A invalidates its generation, but neither path grants automatic
  authority to B.
- `testFailedInitialExplicitRetryDoesNotAuthorizeLaterRuntime` and
  `testCancelledInitialExplicitRetryDoesNotAuthorizeLaterRuntime` use an unsupported schema,
  repair it, prove B performs no automatic construction or recording, and then prove B's own
  explicit retry creates exactly one partial recording-level gap
  (`ViewerStoreTests.swift:1149-1297`).

### `NW-LSS-IMPL-R14-CT-001` — resolved for matching-request runtime end and terminal close

- The worker validates request authority under the runtime lock and reserves one
  `ReopenConstruction` containing the exact request, generation, and entered completion lease
  before releasing that lock (`ViewerStoreCoordinator.swift:1889-1908`). The gate and all
  filesystem/SQLite work now occur after lease ownership exists.
- The defer path identity-checks and clears only the matching construction, then finishes the
  lease after constructor failure, valid publication/admission, or stale replacement close
  (`ViewerStoreCoordinator.swift:1902-1974`, `2042-2057`).
- Matching runtime end finds the exact request's lease and awaits it without holding `NSLock`.
  Terminal close captures any construction lease, invalidates all logical authority, waits outside
  the lock, and then closes an installed coordinator (`ViewerStoreCoordinator.swift:1484-1501`,
  `1802-1850`, `1999-2010`).
- The matching-end, terminal-close, late-old-runtime, and real-application tests block after lease
  reservation, prove shutdown remains incomplete, observe constructed/stale-closed resource
  events, and complete only after release (`ViewerStoreTests.swift:1216-1297`, `1744-2010`,
  `5750-5806`).

The original precheck-to-constructor race is therefore closed. Finding
`NW-LSS-IMPL-R15-CT-001` below concerns a different lease identity when the runtime being ended is
the newer current runtime rather than the older request that owns the construction.

### `NW-ISPD14-001` — resolved for unbounded accumulation

- `reopenScheduled`/`reopenRequest` now represent logical latest authority, while
  `reopenWorkerScheduled` separately represents one physical queued/running worker
  (`ViewerStoreCoordinator.swift:1357-1361`, `1982-1997`).
- Superseding runtime generations replace the one latest request while the worker remains occupied;
  they do not enqueue one closure per generation. After one turn, the worker schedules at most one
  latest successor (`ViewerStoreCoordinator.swift:1853-1887`).
- Current constructor failure clears its request and creates no successor. Stale failure/close
  preserves only a still-authorized latest request. Terminal close clears the latest request. No
  polling, timer, recursive call stack, or per-generation retained closure remains.
- `testRepeatedRuntimeSupersessionCoalescesOneReopenSuccessor` applies 64 superseding logical IDs
  behind one blocked turn and proves exactly two execution-gate turns, only the last recording, and
  one final gap. `testTerminalCloseDiscardsCoalescedReopenSuccessor` proves one gate turn and no
  recording after terminal close (`ViewerStoreTests.swift:2012-2168`).

The prior linear queue-growth defect is resolved.

## Finding

### `NW-LSS-IMPL-R15-CT-001` — Low — Ending the final current runtime does not wait for a stale predecessor's active construction lease

**Confidence: 10/10.**

`detachRuntime` captures a construction lease only through
`reopenConstructionLeaseLocked(for: logicalID)`. That helper returns a lease only when the active
construction's typed request carries the same logical ID as the runtime being ended
(`ViewerStoreCoordinator.swift:1822-1842`, `1999-2010`). This is correct for late cleanup of old B:
it waits B's construction without draining valid newer C ownership.

It is incomplete in the inverse order:

1. runtime A cleanly detaches and grants the one next-runtime automatic reason;
2. runtime B starts, its automatic worker reserves B's construction lease, and the post-check gate
   pauses it;
3. runtime C supersedes B, invalidates B's logical authority, and becomes the one current context
   with a coalesced C request;
4. current runtime C ends before `runtimeEnded(B)` arrives.

At step 4, `matchesCurrentRuntime` is true for C, so `detachRuntime` invalidates C and clears the
last context. The active construction still belongs to B, so the exact-ID helper returns no lease.
No coordinator has been published, so the coordinator-generation guard also returns nil. As a
result, `runtimeEnded(C)` completes immediately. Releasing B afterward still constructs a full
`ViewerStoreCoordinator`, opening/probing the writer, query, and export connections, reconciling
orphans, and triggering startup maintenance. Its pre-publication check rejects stale B and closes
the replacement, but that resource work occurs after the last current runtime reported shutdown
complete (`ViewerStoreCoordinator.swift:1802-1819`, `1828-1842`, `1889-1936`).

This is the same bounded resource class as Round 14 CT, but a distinct cross-ID ordering. It cannot
publish B, cannot materialize C, retains at most one construction, and eventually closes all three
connections, so severity is Low. It still violates the active finite-shutdown contract: once the
last current runtime is cleared, no predecessor construction is valid successor ownership, and
cleanup completion must own its release.

The current newer-runtime regression exercises the opposite cleanup order. It starts C, then calls
`runtimeEnded(B)` while B's gate is paused and correctly proves that old B cleanup waits B's lease
(`ViewerStoreTests.swift:1908-2010`). It releases B before later ending C. Neither that test, the
64-generation coalescing tests, nor the application test ends the newest current runtime while the
construction lease still belongs to a stale predecessor.

Required resolution:

1. When ending the current runtime removes the last context, wait for any active construction that
   is already stale or is made stale by that end, even if its request ID belongs to a predecessor.
   Keep the existing exact-ID wait for noncurrent late cleanup so old B never drains valid C.
2. Preserve valid newer-runtime overlap and keep all waits outside `NSLock`. Multiple cleanup calls
   may safely await the same one-shot lease; do not create polling or a global drain of future
   successor ownership.
3. Add a deterministic B-construction/C-current-end regression. Prove C's end remains incomplete,
   release the gate, observe B constructed and explicitly closed, then prove C completes with no B
   or C recording and unavailable status. A later D should receive exactly one automatic attempt
   and one unavailable gap; late `runtimeEnded(B)` must be harmless.

### Non-actionable worker-tail observation

There is a narrow terminal-close interleaving between `processReopenWorkerTurn` sampling
`reopenScheduled` and dispatching its successor (`ViewerStoreCoordinator.swift:1870-1887`). Close
can clear logical authority and return after the construction lease has finished, then the old
worker can enqueue one successor closure. That closure fails the first locked guard, performs no
gate, filesystem, SQLite, maintenance, status, or recording work, clears physical occupancy, and
returns. It cannot accumulate beyond the already-proved one-worker/one-successor bound and has no
normal-work or architecture effect. Under the goal's review threshold, this bounded empty tail is
recorded for audit completeness but is not an actionable finding or approval blocker.

## Complete State-Machine and Failure Audit

- Initial bootstrap/path/schema failure remains unavailable and explicit-retry-only. Failed or
  cancelled explicit requests do not mutate automatic authority. Intentional coordinator detach is
  the only automatic reason, and successful replacement or terminal close consumes it.
- Same-ID start remains a true early return. Distinct runtime start invalidates recovery and logical
  reopen generations before installing the new context and one outage marker.
- Construction lease enter and finish are identity checked. All filesystem, SQLite, gate, resource
  observer, close, and wait work remains outside the runtime lock. Multiple waits on the dispatch
  group are safe; `finish()` has one defer-owned call.
- Constructor failure clears only a still-current request. If a newer latest request exists, the
  stale failure preserves it for the single coalesced successor. A valid publication clears the
  request and schedules no automatic successor even if recovery admission/materialization later
  fails; the existing generation-bound recovery claim is retained for explicit retry.
- Recovery completion still requires the exact recovery generation, coordinator object, current
  runtime ID, and coordinator-runtime ID. Failed claims saturating-merge their missed observations;
  invalidated callbacks cannot publish into a replacement runtime.
- Physical queue growth is now constant-bounded. The terminal-close sample/dispatch tail is one
  guard-only closure with no resource or state side effect and is non-actionable as described above.
- Matching runtime end, terminal construction cancellation, old-runtime cleanup with a valid newer
  context, and application rapid-stop wait correctly on the paths their tests exercise. The
  unresolved lease issue is specifically final-current C ending while stale predecessor B owns the
  only construction.

## Determinism, Coverage, and Evidence Accuracy

- The unsupported-schema explicit-retry tests establish both failure and cancellation escapes.
  The cancellation variant repairs the schema before the gated constructor, proving a stale
  successful construction is closed and still grants no later automatic authority.
- The execution gate now blocks after request validation and lease reservation. Lock-protected
  counters and ordered content-free resource events prove wait-before-release and close-after-
  construction on matching-ID and terminal paths.
- The 64-generation tests genuinely accumulate supersession within one runtime object. Gate count
  two proves one stale physical turn plus one coalesced latest successor; intermediate recording
  absence and one final gap prove logical ownership. This is stronger than repeated independent
  fixtures.
- The application test keeps its blocking semaphore wait in `Task.detached`, then starts
  termination on the `MainActor` and proves the model reaches `stopping` before gate release. Its
  100-yield handoff is bounded and passed 20 iterations, though an awaited status observation would
  express the scheduling edge more directly. This is not an actionable failure in the current
  evidence.
- Saved counts are consistent with the current tree: eight tests times 20 equals 160; the Store
  suite increased from 87 to 91 by four new tests and has one explicit live-resource-audit skip;
  the unsigned Viewer suite increased from 168 to 172, has the same one skip, and excludes rather
  than passes the two configured-signing probes. The Viewer-only remediation legitimately reuses
  the previously built unchanged Core/SDK package tree, and unchanged-input CocoaPods evidence is
  not claimed as a fresh pass.
- Current tests do not cover the unresolved final-C-first ordering. Passing stress cannot prove a
  branch for which no test seam/assertion exists. Gate count also cannot observe the non-actionable
  guard-only worker tail, but that tail has no resource or state consequence.

## Fresh Validation

The reviewed production binary and test bundle are newer than the current reviewed source. This
review reused those current Round 15 products and ran read-only `test-without-building`.

### Eight remediation scenarios, 20 iterations each

```text
ViewerStoreTests: 160 tests, 0 failures
2.758 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-27-58-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Complete Store regression

```text
ViewerStoreTests: 91 tests, 1 explicit live-resource-audit skip, 0 failures
4.269 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-28-39-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Specification and hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output
```

These passing results validate the implemented branches but do not exercise or disprove
`NW-LSS-IMPL-R15-CT-001`.

## Completion Gate

Round 15 correctness/testing approval is withheld with exactly **one** unresolved actionable
finding: **0 High, 0 Medium, 1 Low**. Approval requires final-current runtime end to own a stale
predecessor construction, a deterministic regression for that missing ordering, fresh affected and
complete validation, and a new independent correctness/testing review with zero unresolved
findings.
