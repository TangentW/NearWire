# Implementation Review Round 13 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 0 Medium, 1 Low.**

Both Round 12 findings are resolved on their reported paths. Intentional coordinator detachment now preserves one bounded reopen-on-next-runtime reason, the next runtime makes one automatic attempt, failed materialization restores the exact generation-bound claim, and real Viewer application Retry and TLS identity reset reuse the shared runtime correctly. Repeated same-logical-ID start is now a true no-op that preserves the original timestamps and cannot clear recovery authority or duplicate marker ownership.

One adjacent shutdown race remains. A queued automatic reopen is not tied to the continued existence of a runtime context. If that runtime ends before the queued work installs its replacement, shutdown completes but the stale work can subsequently install an idle coordinator and restart SQLite/maintenance ownership after the runtime has closed.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. This review records neither a finding nor a pass for that deferred work.

## Scope and Fresh Evidence

This independent review read the Round 12 architecture/API report, `implementation-remediation-round12.md`, `implementation-validation-round13.md`, the current runtime/coordinator, session-manager, application-composition, storage, test, specification, and design paths relevant to the two findings, and the whole-change module/API boundaries. It traced startup, intentional detach, replacement overlap, automatic reopen success and failure, exact claim restore/consume, duplicate start, runtime end, terminal close, and late reopen completion.

Fresh current-tree validation performed by this review:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output

find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print
# exit 0; no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
# exit 1; no matches
```

The four direct Round 12 remediation regressions passed independently against the existing current-tree DerivedData, avoiding another large `/tmp` build tree:

```text
ViewerStoreTests: 4 tests, 0 failures
0.083 seconds test execution
/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-42-35-+0800.xcresult
** TEST SUCCEEDED **
```

The saved Round 13 current-tree evidence also reports 80 repeated direct-regression iterations, 83 complete Store tests with one explicit live-resource-audit skip, 164 unsigned Viewer tests with one such skip and the two deferred signing tests excluded, and 536 Swift package tests with seven environment-dependent skips, all with zero failures. This review treats those skips and exclusions exactly as documented, not as passes.

The isolated package dump exited zero and still reports no external dependency, iOS 16, macOS 13, Swift language version 5, and the existing four products. User-level SwiftPM cache warnings were nonblocking because the command used isolated module and scratch paths. `swift-format lint` exited zero with the same seven `OnlyOneTrailingClosureArgument` suggestions and one test-only `ReplaceForEachWithForLoop` suggestion already recorded in validation evidence.

## Round 12 Finding Disposition

### `NW-LSS-IMPL-R12-ARCH-001` — Resolved

- When the owned coordinator is detached, `detachRuntime` clears the finished context, removes the coordinator, and retains `needsRuntimeReopen = true` without immediately reopening an idle store (`ViewerStoreCoordinator.swift:1756-1778`). Initial constructor/bootstrap failure still leaves that flag false, so its active runtime remains explicit-retry-only.
- The next distinct runtime adds its single runtime-level unavailable marker and automatically enters `retryStorage` only when the coordinator is absent and the retained intentional-detach reason exists (`ViewerStoreCoordinator.swift:1446-1481`). `reopenScheduled` admits only one queued attempt and creates no polling or recurring retry (`ViewerStoreCoordinator.swift:1734-1740`).
- A successful replacement snapshots the matching runtime and sessions, begins one exact claim, and materializes them in causal order. Failure restores the claimed count with saturating arithmetic; success clears authority only under the matching claim generation, coordinator identity, and runtime identity (`ViewerStoreCoordinator.swift:1801-1842`, `1851-1889`).
- `testSequentialRuntimeAutomaticallyReopensAfterCompletedShutdown` proves runtime A fully closes before runtime B starts and B automatically receives a distinct active recording. `testFailedAutomaticSequentialReopenRetainsMarkerForExplicitRetry` proves one failed automatic materialization leaves no false B row and one later explicit retry produces one recording-level unavailable gap with no invented device (`ViewerStoreTests.swift:1465-1592`).
- `testApplicationRetryAndIdentityResetReuseOneStoreRuntimeAutomatically` composes `ViewerApplicationModel`, the real `ViewerMultiDeviceSessionManager`, and one shared `ViewerStoreRuntime`. Application Retry and TLS identity reset create three sequential generations, close each predecessor, and start each successor without a storage-retry call (`ViewerStoreTests.swift:5115-5171`; `ViewerApplicationModel.swift:190-198`, `225-260`, `326-349`; `ViewerRuntimeDependencies.swift:20-50`).

### `NW-LSS-IMPL-R12-ARCH-002` — Resolved

- `runtimeStarted` now compares the retained logical ID while holding the runtime lock and returns before invalidating a claim, replacing `RuntimeContext`, clearing sessions/counts, forwarding coordinator work, or changing either recovery flag (`ViewerStoreCoordinator.swift:1446-1457`). The first wall and monotonic timestamps therefore remain authoritative.
- Recovery authority is still changed only by a new-generation start or a generation/coordinator/runtime-matching recovery completion. A repeated same-ID callback before reopen, while the execution gate is paused, or after a failed claim cannot reach queue admission or create coordinator-local/runtime-level overlap (`ViewerStoreCoordinator.swift:1863-1889`).
- `testRepeatedRuntimeStartPreservesOriginalContextAndRecoveryOwnership` exercises all three duplicate timings, proves the original `1_000`/`2_000` timestamps and `midRuntimeRetry` reason, exactly one recording-level unavailable gap, no device, and no duplication after another retry (`ViewerStoreTests.swift:1149-1227`).

## Finding

### `NW-LSS-IMPL-R13-ARCH-001` — Low — A stale queued reopen can install an idle coordinator after runtime shutdown completes

**Confidence: 10/10.**

The automatic sequential reopen is queued by setting `reopenScheduled = true` and dispatching `attemptReopen` without capturing a runtime identity or shutdown generation (`ViewerStoreCoordinator.swift:1734-1740`). If the execution is delayed and that runtime ends first, `runtimeEnded` calls `detachRuntime`; the latter clears the matching `runtimeContext`, observations, and recovery claim, but exits early because no coordinator has yet been installed (`ViewerStoreCoordinator.swift:1743-1769`). It does not invalidate the queued reopen or clear its admission. `runtimeEnded` therefore returns and the application cleanup receipt can complete.

When the stale work resumes, `attemptReopen` constructs a fresh coordinator and checks only that `coordinator == nil`. It then installs the replacement even though `runtimeContext` is nil, clears `needsRuntimeReopen`, and leaves no claim to materialize (`ViewerStoreCoordinator.swift:1781-1819`). The replacement's constructor already opens the pool and triggers startup maintenance (`ViewerStoreCoordinator.swift:222-238`). `status()` can consequently report that idle store as available after the only runtime has ended (`ViewerStoreCoordinator.swift:1377-1405`). The same problem exists for the internal terminal `closeStorage` path: it resets context and flags but does not invalidate an admitted reopen, so queued work may install a new coordinator after the close call returns (`ViewerStoreCoordinator.swift:1431-1443`).

This does not corrupt a recording, and a later runtime can attach to the idle coordinator, so the finding is Low. It is still actionable because shutdown is required to own the final bounded flush and release SQLite/maintenance ownership; work from the closed generation must not recreate that ownership after cleanup reports completion (`design.md:174-180`). The new Round 12 regressions keep runtime B live until automatic reopen finishes and therefore do not cover this close-before-install ordering.

Required resolution:

1. Before installing a replacement, require a current runtime context that is still eligible for that reopen, or cancel the stale attempt without consuming `needsRuntimeReopen`. A no-runtime cancellation must leave the next real runtime eligible for its one bounded automatic attempt.
2. Generation-bind or invalidate queued reopen work so terminal `closeStorage` cannot install a replacement after returning. Preserve the existing replacement-runtime behavior when a newer context legitimately exists before old cleanup completes.
3. Add deterministic gate-controlled tests that end the triggering runtime, and separately call terminal close, while automatic reopen is paused. After release, prove no idle coordinator/status/maintenance ownership appears. Then start a later runtime and prove it receives exactly one automatic attempt, one recording, and no duplicated unavailable marker. Include the variant where a newer context exists before the older queued attempt resumes so valid replacement recovery remains intact.

## State Matrix and API Boundary Audit

- Initial bootstrap/path/schema failure remains unavailable and explicit-retry-only. Intentional detach retains one next-runtime automatic opportunity. Automatic construction/materialization failure retains the exact marker for explicit recovery. Same-ID start is idempotent, and a newer distinct context present during predecessor cleanup remains recoverable under identity guards.
- The unresolved matrix cell is only `automatic reopen admitted -> triggering runtime ends or terminal close completes -> queued work resumes with no context`. Current code installs an ownerless replacement instead of cancelling it.
- `reopenExecutionGate`, reopen flags, runtime context, recovery claim, coordinator, query, export, SQLite, and all relevant test seams remain Viewer-internal. Repository search finds no exposure from Core or SDK and no public Viewer declaration for these types or controls.
- Persistence remains an observer of validated protocol outcomes. No storage path owns transport sequence, mailbox, queue, token, admission, or terminal decisions. The root package remains dependency-free, no nested manifest/podspec exists, and the manually maintained Viewer project remains the only SQLite consumer.

## Approval Gate

Architecture/API approval requires resolving `NW-LSS-IMPL-R13-ARCH-001`, adding the paused-reopen shutdown/terminal-close matrix regressions, saving fresh affected and complete validation, and obtaining a fresh independent architecture/API review with **zero unresolved actionable findings**. Configured signing, entitlement assertions, and stable-signer validation remain deferred exclusively to `release-hardening` and are outside this finding count.
