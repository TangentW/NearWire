# Implementation Review Round 9 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 3 — 0 High, 3 Medium, 0 Low.**

Round 8 remediation resolves the reported failure-publication, relay-ordering, recovery-permit, and reflection-root defects. Direct writer failures now advance the authoritative generation before the serialized writer turn is released; relay mutation and observer publication are ordered; approved recovery actions retain the generation they were prepared for; and the admission/session/store ownership roots expose closed mirrors. Three architecture gaps remain in the complete change. Runtime-end invalidation still does not prevent already queued maintenance from performing writer turns after the terminal flush has begun or completed, schema migration opens both read connections before migration and schema acceptance, and runtime recovery treats queue admission as successful durable recovery and can discard the only missed-observation aggregate before materialization succeeds.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to goal-level `release-hardening`. That deferral is neither a finding nor passing evidence in this review.

## Scope and Evidence Basis

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and task plan; the current production, integration, test, packaging, and operator-documentation change; all three Round 8 implementation-review reports; `implementation-remediation-round8.md`; and `implementation-validation-round9.md`. It independently retraced the complete writer/recovery/lifecycle ownership graph and rechecked protocol/store authority separation, generation-bound automatic and nonrecovering mutations, runtime replacement, SQLite connection ownership, migration order, reflection roots, scope exclusions, and Core/SDK/Viewer dependency boundaries.

Fresh current-tree validation performed by this review:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
# exit 1; no matches
```

The complete current `ViewerStoreTests` suite also passed independently:

```text
xcodebuild ... test -only-testing:NearWireViewerTests/ViewerStoreTests
Executed 73 tests, with 1 test skipped and 0 failures
** TEST SUCCEEDED **
/tmp/NearWireViewerRound9ArchitectureReviewDerived/Logs/Test/Test-NearWireViewer-2026.07.13_11-56-55-+0800.xcresult
```

The one skip is the explicit opt-in live Application Support audit. A separate `xcresulttool` summary attempt encountered the same sandbox-denied internal `TestReport` cache write recorded in Round 9 validation, so no auxiliary parser result is claimed. The successful `xcodebuild` execution above is the fresh behavioral result.

## Round 8 Finding Disposition

- **Failure publication before writer release:** resolved. `ViewerSQLiteConnection.run` invokes its failure handler inside the serial queue turn, and `ViewerEventStore.writeTransaction` classifies and publishes failure from that edge before another writer can validate an old ticket. The deterministic queued direct-writer regression passed.
- **Ordered relay callbacks:** resolved. Relay state mutation and both observer callbacks are serialized by `publicationLock`, transitions carry a monotonic sequence, and Event-store/ingress observers reject stale transitions. The reversed-notification regression passed.
- **Lifecycle-owned scheduled maintenance:** partially resolved. Recovery publication is lifecycle-checked before and after the injected publication seam, dirty recovery successors retain their original permit, and scheduled storage failures publish authoritatively. Finding 1 remains because lifecycle invalidation is checked only after the entire maintenance campaign has already executed.
- **Generation-bound recovery/nonrecovering mutations:** resolved in the reported paths. Unpin, manual deletion, settings recovery, explicit retry, and capacity recovery carry original-generation permits; ordinary metadata and cleanup use nonrecovering authorization and do not reopen automatic ingress.
- **Reflection roots:** resolved. `WireHello`, admission context/core/handle/manager, active session/manager, store coordinator/runtime, and their retained operational owners expose content-free descriptions and mirrors, with focused secret-marker coverage.

## Findings

### NW-LSS-IMPL-R9-ARCH-001 — Medium — Runtime-end invalidation does not stop queued maintenance writer turns before the terminal flush

`ViewerStoreMaintenanceOwner.trigger` captures a lifecycle generation and queues `run` (`ViewerStoreMaintenance.swift:1192-1219`). However, `run` calls the complete `maintenance.run` campaign before it takes the owner lock or validates `stopped`, `ending`, or the captured lifecycle generation (`ViewerStoreMaintenance.swift:1305-1328`). A dirty successor is likewise queued with the old generation and performs the campaign before checking it (`ViewerStoreMaintenance.swift:1343-1355`). `runtimeEnded()` invalidates flags and permits but does not cancel or join the maintenance queue (`ViewerStoreMaintenance.swift:1248-1258`). The coordinator then starts preparation shutdown and awaits `ingress.flush`; only after that flush returns does it call `maintenanceOwner.close()`, whose `queue.sync` finally waits for maintenance ownership (`ViewerStoreCoordinator.swift:653-715`).

Consequently, a maintenance task that was queued but had not entered `run`, or a multi-turn campaign already between writer calls, can acquire the SQLite writer after runtime-end invalidation. It can mutate, checkpoint, reclaim, or publish a failure after the terminal ingress flush has started and can perform a writer turn after that flush has already resolved. Recovery publication is now suppressed, but writer ownership itself is not lifecycle-owned. This violates the required single finite terminal prefix and the rule that shutdown cannot schedule or execute store work after its flush outcome is known.

`testRuntimeEndInvalidatesInFlightMaintenanceRecoveryBeforePublication` blocks only the post-campaign recovery-publication seam and uses the owner directly; it does not place a queued or multi-turn writer across a coordinator terminal flush (`ViewerStoreTests.swift:3987-4028`). The shutdown regressions do not run an in-flight scheduled maintenance campaign (`ViewerStoreTests.swift:4351-4485`).

Required resolution:

- Validate lifecycle ownership before entering `maintenance.run` and before every serialized writer turn, or quiesce the bounded maintenance queue before terminal ingress flush begins.
- Ensure a dirty successor invalidated by `runtimeEnded()` performs zero maintenance planning, disk admission, SQLite mutation, checkpoint, or failure publication.
- Add a deterministic coordinator-level regression that holds a queued or first-turn maintenance campaign, begins runtime shutdown, releases it across the terminal flush, and proves exactly one terminal flush attempt, zero post-flush writer turns/publications, bounded completion, and pool close only after all prior writer ownership is gone.

### NW-LSS-IMPL-R9-ARCH-002 — Medium — Query and export connections open before schema migration and acceptance

`ViewerSQLitePool.init(paths:)` opens the writer, then immediately opens the query and export readers and probes all three connections (`ViewerSQLite.swift:514-539`). Only after that initializer returns does `ViewerSQLitePool.init(migrating:)` invoke `ViewerStoreSchema.migrate(writer)` (`ViewerStoreSchema.swift:373-381`). A first-create migration, unknown-version rejection, incomplete-schema rejection, and every future migration therefore happen after both read connections have already opened the database.

This contradicts the design and capability boundary that schema creation/migration must complete on the sole writer before read connections open. The current order also makes future migration correctness depend on two idle but live connections and allows unsupported or corrupt schema files to be opened by read owners before writer validation fails closed. Existing tests assert the final three roles and schema version, and that unknown schemas are eventually rejected, but do not assert connection-open ordering (`ViewerStoreTests.swift:110-138,163-172`).

Required resolution:

- Split pool construction so the writer opens, migrates, probes, and accepts the schema before either read connection is created.
- Preserve exact cleanup if migration or either later reader open fails, without exposing a partially initialized pool.
- Add a deterministic connection-open/migration observer test proving no query/export connection exists during first creation, reopen validation, unknown-schema rejection, or migration failure.

### NW-LSS-IMPL-R9-ARCH-003 — Medium — Runtime recovery acknowledges queue admission as durable recovery and can lose the outage aggregate

`ViewerStoreCoordinator.recoverRuntime` and `recoverSession` return only the Boolean result of `preparationQueue.offer`; their queued closures perform durable materialization later and catch failures without reporting an operation result to `ViewerStoreRuntime` (`ViewerStoreCoordinator.swift:277-324`). In same-coordinator recovery, the runtime treats those offer results as success, clears `coordinatorNeedsRecovery`, and resets `missedObservationCount` before any queued materialization has completed (`ViewerStoreCoordinator.swift:1566-1620`). Fresh reopen does the same while installing the replacement coordinator (`ViewerStoreCoordinator.swift:1669-1714`).

If recording materialization fails after the queue accepted the recovery operation, the relay eventually closes automatic writing, but the runtime has already discarded the sole aggregate covering observations missed while it had no usable coordinator. The coordinator closure catches the failed `ensureRecording` without retaining that count. A later retry can recover still-live nondurable sessions and subsequent gaps, but it cannot reconstruct the discarded pre-recovery aggregate. Fresh reopen can also publish an available outward state before the replacement recording and sessions are durably recovered.

`testUnavailableRuntimeReopensAfterExplicitRetry` covers only a successful post-repair materialization and eventually observes its gap (`ViewerStoreTests.swift:1002-1056`). It does not inject a failure after pool reopen/queue admission but before recording materialization, and therefore does not prove the aggregate survives a failed recovery attempt.

Required resolution:

- Give runtime recovery a completion result tied to the exact coordinator/runtime generation; queue admission alone must not mean recovered.
- Clear `coordinatorNeedsRecovery` and the missed-observation aggregate only after recording plus required live-session materialization and gap ownership succeed. On failure, retain the aggregate for the next explicit recovery and keep outward status nondurable/unavailable.
- Add deterministic same-coordinator and fresh-reopen tests that fail after recovery work is admitted but before recording materialization commits, then retry successfully and prove exact gap count, causal parent/device order, no premature available state, and no duplicate rows.

## Architecture and Boundary Recheck

- Event-store automatic tickets and all recovery permits are revalidated on the serial writer before planning, disk admission, `BEGIN`, or mutation. Failure publication now closes the old generation before releasing that writer turn.
- Relay observer publication is ordered, and Event-store presentation plus ingress scheduling converge on the latest transition. Stale notification application cannot reopen admission or overwrite public state.
- The session manager remains the sole authority for protocol sequence, queue, token, mailbox, timeout, and terminal decisions. Journal callbacks remain immutable, nonthrowing, and bounded from the protocol executor's perspective.
- Reflection is closed across Event/wire values, transport and admission ownership, active sessions and queues, SQLite/store services, coordinator/runtime roots, and recovery authorizations. No current root traversal exposes Event content, raw Hello/frame bytes, queue keys, session epochs, endpoints, peer identity text, SQL, or paths.
- SQLite implementation and linkage remain Viewer-only. No SQLite or third-party runtime dependency entered Core or SDK, no nested manifest or podspec was added, and no supported SDK persistence/search API was created. Core changes are limited to shared platform-neutral journal/reflection carriers.
- The Viewer project remains Swift 5 language mode and macOS 13 compatible. The current UI remains limited to storage status/settings/cleanup/retry; timeline/history browsing, search UI, detail rendering, export selection, control composition, charts, server/cloud, and import remain absent.

## Approval Gate

Approval requires resolving all three findings, saving focused and complete validation, and obtaining a fresh independent architecture/API review with **zero unresolved actionable findings**. Configured signing, entitlement assertions, and stable-signer validation remain deferred exclusively to `release-hardening` and are outside this finding count.
