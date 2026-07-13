# Independent Implementation Review — Round 14 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 0 Medium, 1 Low.**

The Round 13 ownerless-publication defect is resolved for every newly tested cancellation path.
Automatic and explicit reopen requests now carry typed runtime authority and a monotonic attempt
generation; runtime replacement, matching runtime end, and terminal close invalidate obsolete
requests; both pre-construction and pre-publication checks reject stale authority; and a stale
constructed replacement is closed rather than installed. The four new regressions are
deterministic on the ordering they exercise, including the corrected detached wait that lets the
`MainActor` advance.

One narrower shutdown-completion race remains between the first authority check and synchronous
coordinator construction. A matching runtime end or terminal close can invalidate the request and
return while that already-authorized queue turn is opening SQLite and running startup work. The
second check prevents publication and eventually closes the replacement, but shutdown has already
reported completion before those resources are opened and released. The current tests gate only
before the first check, so they cannot exercise this window.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain
explicitly deferred, by user direction, to goal-level `release-hardening`. They are neither a
finding nor represented as passing in this review.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both
capability specifications, and tasks; all three Round 13 implementation-review reports;
`implementation-remediation-round13.md`; `implementation-validation-round14.md`; the current
runtime/coordinator, SQLite construction and close paths, application lifecycle composition,
new and adjacent Store tests, and current Viewer local-store/operator documentation.

The review traced initial bootstrap, explicit retry with and without a runtime, intentional
coordinator detach, sequential automatic reopen, construction failure, matching and nonmatching
runtime end, terminal close, same-ID start, newer-runtime supersession, late old-runtime cleanup,
pre- and post-construction invalidation, publication, recovery-claim ownership, status publication,
application Retry/termination, queue ordering, and generation wrap behavior. It also rechecked the
saved result accounting and the requirements-to-tests coverage affected by Round 13 remediation.

## Round 13 Finding Disposition

### `NW-LSS-IMPL-R13-ARCH-001` / `NW-ISPD13-001` — resolved on the reported ownerless-publication path

- `ReopenRequest.automatic` binds the exact logical runtime ID, while explicit retry captures the
  current runtime ID or a deliberate no-runtime state. Request admission stores one monotonic
  `reopenAttemptGeneration` (`ViewerStoreCoordinator.swift:1301-1304`, `1889-1897`).
- A distinct runtime start, a matching runtime end, and terminal `closeStorage` invalidate the
  prior attempt under the runtime lock. Request validation requires the same type, generation,
  coordinator absence, and current runtime identity (`ViewerStoreCoordinator.swift:1442-1455`,
  `1458-1490`, `1772-1795`, `1900-1927`).
- `attemptReopen` validates after its execution gate and again before publication. If authority is
  stale after construction, it explicitly closes the replacement and never stores it in
  `coordinator` (`ViewerStoreCoordinator.swift:1814-1855`).
- Cancellation leaves `needsRuntimeReopen` available after ordinary runtime detach, so a later
  distinct runtime receives one bounded automatic attempt. Terminal close deliberately clears
  that reason. Construction failure clears only a still-current request and leaves recovery
  ownership for a later explicit attempt.
- A newer runtime invalidates the older request before replacing the context. The serial reopen
  queue then rejects the old turn and admits only the request matching the newer context. Late
  cleanup for the superseded logical ID fails both the context and coordinator-generation guards.

The four Round 14 regressions correctly prove the pre-construction branches they name:

1. ending the triggering runtime while the execution gate is paused prevents publication and
   preserves one later-runtime automatic recovery;
2. terminal close while paused prevents an idle coordinator and durable recording;
3. a newer runtime supersedes the paused request, owns one recording-level unavailable gap, and is
   unaffected by late cleanup of the older runtime;
4. real application Retry followed by rapid termination cancels the queued automatic reopen and
   leaves the first recording closed.

The original Low defect could install an ownerless coordinator after the gate. That state is no
longer reachable on these paths. The finding below concerns completion ordering after the new first
check has already succeeded, not the removed ownerless-publication branch.

## Finding

### `NW-LSS-IMPL-R14-CT-001` — Low — Shutdown can return while a stale reopen is still constructing and reopening store resources

**Confidence: 10/10.**

`attemptReopen` runs the execution gate, checks request authority under `lock`, releases the lock,
and only then synchronously constructs `ViewerStoreCoordinator`
(`ViewerStoreCoordinator.swift:1814-1826`). Construction opens the writer, accepts/migrates and
probes the schema, opens the query and export readers, reconciles orphan rows synchronously, and
triggers startup maintenance (`ViewerStoreCoordinator.swift:180-238`; `ViewerSQLite.swift:521-556`).

There is no ownership reservation or quiescence handshake covering the interval after
`canConstruct` becomes true and before the second request check. During that interval:

- a matching `runtimeEnded` invalidates the request, clears the current context, finds no published
  coordinator to await, and can return immediately (`ViewerStoreCoordinator.swift:1757-1795`); or
- terminal `closeStorage` invalidates the request, observes no published coordinator, and returns
  without synchronizing with `reopenQueue` (`ViewerStoreCoordinator.swift:1442-1455`).

The constructor may therefore open three SQLite owners, perform orphan reconciliation, and start
maintenance after the corresponding shutdown call has completed. When construction finishes, the
second generation check correctly fails and `replacement.closeStorage()` eventually closes the
maintenance owner and pool (`ViewerStoreCoordinator.swift:1839-1843`). This prevents publication,
recording recovery, and an unbounded leak, but it does not make shutdown completion own the late
work. It contradicts the active requirement that shutdown establish quiescence, release all store
resources before cleanup completes, and permit no maintenance work after the terminal flush.

The risk is Low because the reopen queue remains serial and one-shot, the replacement is never
published, no new runtime recording is materialized, and the late ownership is bounded and
eventually closed. It is still actionable: callers may treat completed runtime cleanup or terminal
close as the point at which SQLite files and maintenance ownership are safe to inspect, repair,
move, or discard, while the stale turn can still reopen or mutate the store.

The new tests do not cover this ordering. `ArmableViewerExecutionGate` blocks at the first line of
`attemptReopen`, before `canConstruct` is checked (`ViewerStoreTests.swift:1594-1813`,
`5395-5448`; `ViewerStoreTests.swift:6109-6148`). They therefore always invalidate authority
before construction is admitted. Waiting on `afterCurrentReopenPrefix` after releasing that gate
proves eventual queue completion in the test, but neither production `runtimeEnded` nor
`closeStorage` performs that wait before reporting its own completion.

Required resolution:

1. Bind shutdown completion to any reopen construction turn that already passed authorization.
   A matching runtime end and terminal close must not complete until that stale turn has either
   failed construction or closed its replacement. Preserve the valid newer-runtime overlap path;
   do not globally cancel or wait on unrelated successor ownership.
2. Keep constructor, SQLite, maintenance, and close work outside the runtime lock. Use a bounded
   generation-specific in-flight reservation/quiescence handshake or equivalent serial-prefix
   ownership rather than holding `NSLock` across filesystem/SQLite work. Add no polling, timer,
   recursive retry, or unbounded wait.
3. Add a deterministic seam immediately after the first authority check and before/during
   coordinator construction. For both matching runtime end and terminal close, pause there, begin
   shutdown on another task, prove shutdown does not complete early, release construction, and
   prove the stale replacement closes before shutdown completes. Assert construction/close counts,
   unavailable status, no new recording, no post-completion maintenance/SQLite owner, and the
   ordinary later-runtime one-attempt/one-gap behavior.
4. Rerun the four current cancellation regressions, the new post-check race matrix under repeated
   iterations, adjacent sequential/replacement/recovery/shutdown tests, the complete Store and
   unsigned Viewer suites, and save fresh exact evidence.

## State-Machine, Lock, and Generation Audit

- Initial constructor/bootstrap failure remains explicit-retry-only. Intentional detach is the only
  source of the automatic reopen-on-next-runtime reason. A failed automatic construction does not
  poll and leaves the exact runtime marker recoverable by explicit retry.
- Same-logical-ID `runtimeStarted` returns before invalidating any reopen or recovery generation,
  changing timestamps, clearing sessions, or adding another marker.
- Automatic requests require their exact current runtime. Explicit requests require their captured
  runtime or the deliberate nil-runtime state. A runtime appearing during an explicit nil-runtime
  request invalidates it and can receive a correctly typed automatic request when the retained
  reopen reason applies.
- Old constructor failure and old post-construction cancellation clear no newer request because
  both mutations are guarded by request value and generation. Generation increment and invalidation
  are lock-confined. The wrap-to-one branch is internally consistent; collision would require an
  infeasible full `UInt64` cycle while an old request remained live.
- Recovery publication still requires the matching recovery generation, coordinator object,
  runtime context, and coordinator runtime ID. Failed claims saturating-merge their exact missed
  count; obsolete completions cannot publish into a replacement runtime.
- No reviewed path holds the runtime lock while waiting at the execution gate, constructing or
  closing SQLite, running preparation, or awaiting runtime shutdown. The unresolved issue is the
  missing completion handshake across that intentionally unlocked construction interval.

## Determinism and Evidence Accuracy

- Moving `reopenGate.waitUntilBlocked()` into `Task.detached` in the application regression is a
  valid test-only correction. The test remains `@MainActor`, but the blocking semaphore wait no
  longer occupies that actor, so `ViewerApplicationModel.retry()` can finish old cleanup and create
  the second manager. The first failed application result and the corrected direct pass are both
  disclosed in `implementation-validation-round14.md`; neither is misrepresented.
- The other three cancellation tests use a lock-protected one-shot gate, wait for exact entry,
  perform the intended lifecycle mutation, release the queue, and assert identity-specific
  recording/gap state. Current real wall time avoids unrelated seven-day retention reclamation.
- The saved Round 14 result accounting is consistent with the current suite: four new tests, 87
  Store tests with one explicit live-resource-audit skip, and 168 unsigned Viewer tests with one
  skip while the two configured-signing probes are excluded. The Swift package result is explicitly
  identified as a reused unchanged Core/SDK build, and the CocoaPods result is explicitly historical
  unchanged-input evidence rather than a fresh pass.
- The focused regression, stress, complete Store, complete unsigned Viewer, OpenSpec, hygiene,
  packaging, SQLite linkage, and privacy-manifest results are kept distinct. The configured-signing
  exclusions and live-resource skip are not counted as passes.

## Requirements-to-Tests Coverage

Round 14 adds direct evidence for typed automatic-request cancellation before construction,
same-process later-runtime recovery, newer-runtime supersession, and real application rapid stop.
Existing adjacent tests continue to cover same-ID idempotence, sequential success, automatic
failure followed by explicit retry, replacement-runtime cleanup isolation, recovery claim
restore/consume, maintenance quiescence before the coordinator's terminal flush, failed-flush
reconciliation, and complete Store behavior.

Coverage remains insufficient for the requirement that shutdown completion itself owns all reopen
construction and maintenance resources. No test can pause after the first authority check, observe
construction/close ownership through `ViewerStoreRuntime`, or assert that matching runtime end and
terminal close wait for that admitted stale turn. Passing pre-check cancellation and coordinator-
local maintenance-quiescence tests do not imply this missing runtime-level ordering.

## Fresh Validation

This review reused the current Round 14 compiled products and ran read-only
`test-without-building`; the reviewed production and test sources were unchanged from the saved
Round 14 build.

### Four Round 14 cancellation regressions

```text
ViewerStoreTests: 4 tests, 0 failures
0.068 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-06-01-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Complete Store regression

```text
ViewerStoreTests: 87 tests, 1 explicit live-resource-audit skip, 0 failures
4.116 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-07-25-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Specification, structure, and hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches
```

These passing results validate the current covered paths but do not exercise or disprove
`NW-LSS-IMPL-R14-CT-001`.

## Completion Gate

Round 14 correctness/testing approval is withheld with exactly **one** unresolved actionable
finding: **0 High, 0 Medium, 1 Low**. Approval requires shutdown-owned quiescence for an authorized
in-flight reopen construction, deterministic post-check runtime-end and terminal-close regressions,
fresh affected and complete validation, and a new independent correctness/testing review with zero
unresolved findings.
