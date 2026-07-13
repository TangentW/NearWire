# Implementation Review Round 12 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 2 — 0 High, 1 Medium, 1 Low.**

The Round 11 initial-outage marker is correct for the two new single-start regressions: bootstrap failure and prior-runtime ownership each retain one generation-bound missed observation, failed recovery restores the exact claim, successful recovery creates one recording-level `storageUnavailable` gap, and a later retry does not duplicate it. The new reopen execution gate is Viewer-internal and does not change production composition. Two lifecycle-state gaps remain. A later logical runtime that starts after its predecessor has fully detached cannot automatically recreate the coordinator, and a repeated start callback for one logical generation can overwrite its original time and clear recovery authority without consuming the retained aggregate.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. This review records neither a finding nor a pass for that deferred work.

## Scope and Fresh Evidence

This independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and tasks; current Viewer storage/runtime/session/application implementation and operator documentation; the Round 11 architecture/API report; `implementation-remediation-round11.md`; and `implementation-validation-round12.md`. It traced the initial marker through runtime/coordinator ownership, recovery claim/restore/consume, prior-generation shutdown, later-runtime construction, preparation admission, and the production application restart paths. It also rechecked SQLite ownership, shutdown/maintenance ordering, internal/public API exposure, packaging, and Core/SDK/Viewer boundaries.

Fresh current-tree validation performed by this review:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
# exit 1; no matches

env CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound12ArchitectureModuleCache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMRound12ArchitectureModuleCache \
  swift package --disable-sandbox \
  --scratch-path /tmp/NearWirePackageDumpRound12Architecture dump-package
# exit 0; no external dependencies; iOS 16, macOS 13, Swift language version 5
```

The two direct Round 11 regressions passed independently:

```text
Executed 2 tests, with 0 failures
** TEST SUCCEEDED **
/tmp/NearWireViewerRound12ArchitectureFocused/Logs/Test/Test-NearWireViewer-2026.07.13_13-15-46-+0800.xcresult
```

The complete current Store suite then passed using the same freshly compiled tree:

```text
Executed 79 tests, with 1 test skipped and 0 failures
** TEST SUCCEEDED **
/tmp/NearWireViewerRound12ArchitectureFocused/Logs/Test/Test-NearWireViewer-2026.07.13_13-17-12-+0800.xcresult
```

The one skip is the explicit opt-in live Application Support audit and is not represented as a pass. An earlier attempt to create a second independent DerivedData tree stopped before tests because `/tmp` reached `No space left on device`; the failed tree created by this review was removed, and the unchanged command was rerun against the already-fresh focused build tree to the successful result above. `swift-format lint` exited zero with the eight already-recorded nonblocking style suggestions.

## Round 11 Finding Disposition

`NW-LSS-IMPL-R11-ARCH-001` is resolved for the reported single-start bootstrap and replacement paths:

- A new logical generation adds one saturating runtime-level observation only when no coordinator can attach (`ViewerStoreCoordinator.swift:1451-1471`). An attachable coordinator receives no runtime marker, so its accepted asynchronous start failure remains solely in the coordinator-local aggregate (`ViewerStoreCoordinator.swift:240-257`, `860-890`, `948-973`).
- Reopen moves the exact runtime aggregate into one recovery claim, clears the live counter while work is in flight, restores the claim with saturating arithmetic on failure, and consumes it only after the matching coordinator/runtime/generation reports success (`ViewerStoreCoordinator.swift:1810-1841`, `1850-1886`). In the single-start path, coordinator-local and runtime-level ownership do not overlap.
- `testUnavailableRuntimeReopensAfterExplicitRetry` and `testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime` now cover zero later observations, one failed materialization attempt, exact one-gap recovery, no invented device, and no duplicate on a later retry (`ViewerStoreTests.swift:1065-1146`, `1278-1374`). The first test covers a nil bootstrap coordinator; the second covers prior-runtime coordinator ownership.

The finding below does not dispute those direct results. It covers later runtime construction after completed detachment. The Low finding covers the remediation's separate repeated-callback claim.

## Findings

### NW-LSS-IMPL-R12-ARCH-001 — Medium — A later runtime after completed shutdown does not automatically recreate the store coordinator

**Confidence: 10/10.**

When the currently owned logical runtime ends with no successor already installed, `detachRuntime` clears `runtimeContext`, detaches the coordinator, computes `shouldReopen` as false, and assigns that false value to `needsRuntimeReopen` (`ViewerStoreCoordinator.swift:1752-1777`). The coordinator then closes. When a later `ViewerMultiDeviceSessionManager` is created on the same process-wide `ViewerStoreRuntime`, its initializer invokes `runtimeStarted` with a fresh logical ID (`ViewerMultiDeviceSessionManager.swift:47-65`). The runtime correctly adds the new initial-outage marker because `coordinator` is nil, but `shouldReopen` remains false because `needsRuntimeReopen` was cleared; startup publishes unavailable state and returns without attempting a fresh coordinator (`ViewerStoreCoordinator.swift:1451-1480`). Only a manual Retry Storage action can then materialize that runtime.

This is reachable in production without concurrent windows. `ViewerApplicationModel.retry` and identity-reset flows wait for the prior cleanup and then create a new handoff owner through the same `ViewerRuntimeDependencies.live` capture (`ViewerApplicationModel.swift:190-198`, `225-260`; `ViewerRuntimeDependencies.swift:18-50`). If prior cleanup finishes before the replacement manager is constructed, the next listener runtime remains nondurable even though the database is healthy. This violates automatic per-runtime journaling and the later-runtime/new-context requirement (`specs/viewer-local-store-search/spec.md:29-46`). The current replacement test covers only the opposite ordering, where the successor context already exists when the predecessor detaches and therefore sets `shouldReopen` true.

Required resolution:

1. Preserve a bounded reopen-on-next-runtime reason when a coordinator is intentionally detached after runtime shutdown. Keep it distinct from initial path/schema/bootstrap failure, which remains explicit-retry-only.
2. On the next logical runtime, perform at most one fresh coordinator/reconciliation attempt without polling or a recurring retry loop. If that attempt fails, retain the new generation's marker and remain unavailable until explicit retry; if it succeeds, materialize only that new runtime context under the existing generation-bound claim rules.
3. Add a deterministic same-`ViewerStoreRuntime` regression that fully starts and ends runtime A, then starts runtime B after A cleanup has completed without calling `retryStorage`. Prove B automatically receives a distinct recording, A remains closed, and failure of the one automatic reopen retains B's exact marker for one later explicit retry. Add proportional application restart/reset composition coverage using the shared live runtime boundary.

### NW-LSS-IMPL-R12-ARCH-002 — Low — Repeated same-generation start can overwrite identity and strand the retained recovery claim

**Confidence: 9/10.**

The remediation distinguishes a new generation, but `runtimeStarted` still replaces `runtimeContext` on every callback, including the same logical ID (`ViewerStoreCoordinator.swift:1451-1463`). A repeated callback can therefore replace the original wall/monotonic start time before recovery, contrary to the requirement to materialize the original identity/time. More importantly, when a failed recovery has restored `missedObservationCount` and left `coordinatorNeedsRecovery` true, a repeated same-ID callback treats the coordinator as attachable, offers another coordinator start, and immediately sets `coordinatorNeedsRecovery = false` from queue admission alone (`ViewerStoreCoordinator.swift:1464-1501`). The coordinator may already own the same runtime ID, so that accepted operation becomes an internal no-op (`ViewerStoreCoordinator.swift:240-257`). The next retry then sees no runtime recovery requirement, does not begin a claim, and can create the partial recording through `coordinator.retryStorage` without consuming the retained runtime marker (`ViewerStoreCoordinator.swift:1673-1708`). A repeated callback racing fresh reopen can also let coordinator-local and runtime-level startup markers overlap, defeating the intended single-owner rule.

The current production manager calls `runtimeStarted` once per manager, so this is Low rather than Medium. It is still actionable because the remediation explicitly claims repeated same-generation callbacks preserve the aggregate, and the current state machine preserves the number while disconnecting it from recovery authority. No current test repeats the same logical ID before retry, after failed recovery, or while reopen is in flight.

Required resolution:

1. Make same-logical-ID `runtimeStarted` idempotent: preserve the first `RuntimeContext` and its timestamps, do not forward a second coordinator start for an already-known generation, and do not clear `coordinatorNeedsRecovery` or alter an in-flight claim.
2. Clear recovery authority only from a generation/coordinator-matching successful materialization completion, never from preparation-queue admission.
3. Add deterministic repeated-start tests before the first reopen, after a failed recovery claim is restored, and while reopen is paused. Assert the original start time, exactly one recording-level unavailable gap, no coordinator-local/runtime-level duplicate, and no later-retry duplication.

## Reopen Gate and Whole-Change Architecture Audit

- `reopenExecutionGate` is a private stored closure on the Viewer-internal `ViewerStoreRuntime`; its initializer and type are absent from public SDK products, Core, CocoaPods, and `ViewerSessionJournaling`. Repository search finds one production construction using the no-op default and one test injection (`ViewerStoreCoordinator.swift:1301-1335`, `1780-1788`; `ViewerRuntimeDependencies.swift:18-50`; `ViewerStoreTests.swift:1278-1287`).
- The gate runs on the dedicated reopen serial queue before pool construction and outside the runtime lock. The test-only semaphore therefore cannot invert the runtime lock, preparation executor, writer executor, or maintenance executor. Production execution adds one no-op call and no callback retention, task, reservation, or public API.
- Writer-first migration/schema acceptance still precedes both read connections. Runtime shutdown still invalidates and quiesces maintenance before its one terminal preparation/ingress flush, and generation/coordinator identity guards reject late recovery completion.
- Persistence remains an observer of protocol outcomes. The journal protocol exposes no network owner, sequence mutator, queue, token bucket, mailbox mutation, or terminal gate. Storage failure cannot change session ownership or network terminal decisions.
- SQLite, coordinator, query, export, maintenance, and their test seams remain Viewer-only and module-internal. The root package has no external dependency, no nested manifest or podspec exists, Core remains platform-neutral, SDK persistence APIs remain absent, and the manually maintained Viewer project still links system SQLite plus the root local package under Swift 5 and macOS 13 settings.

## Approval Gate

Architecture/API approval requires resolving `NW-LSS-IMPL-R12-ARCH-001` and `NW-LSS-IMPL-R12-ARCH-002`, adding the sequential-runtime and repeated-start regressions, saving fresh affected and complete validation, and obtaining a fresh independent architecture/API review with **zero unresolved actionable findings**. Configured signing, entitlement assertions, and stable-signer validation remain deferred exclusively to `release-hardening` and are outside this finding count.
