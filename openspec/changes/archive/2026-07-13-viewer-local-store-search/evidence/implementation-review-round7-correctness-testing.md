# Independent Implementation Review — Round 7 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 3 — 0 High, 3 Medium, 0 Low.**

The two Round 6 correctness findings are materially improved: SQLite lock origin is now distinct from caller contention, manual-delete failures publish authoritative state, and production local/remote drop emitters publish cumulative saturating values. The Round 6 architecture checkpoint-serialization and active queue-reflection findings are also resolved in their reported forms.

Three issues remain. The shared maintenance/ingress failure relay is not enforced on the serialized writer turn and has overbroad/undercomplete recovery authorization; relational drop monotonicity is validated only after capacity recovery may already mutate history and equal projected counts remain writable; and the completion evidence acknowledges an unidentified current-tree test failure that has not been captured or root-caused.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred by user direction to the goal-level `release-hardening` change. They are neither findings nor represented as passing here.

## Scope

This independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and tasks; the complete current production, test, packaging, documentation, and evidence diff; all three Round 6 implementation-review reports; `implementation-remediation-round6.md`; the current `implementation-validation-round7.md`; `resource-filesystem-audit-round6.md`; and the relevant prior implementation/remediation evidence.

The review retraced SQLite error origin, transaction rollback, manual-delete state, maintenance/ingress gate ordering and recovery, checkpoint serialization, cumulative drop projection and persistence, rejected-observation gaps, runtime/shutdown ownership, bounded queues/tasks, retention/reclaim, query/export snapshot behavior, reflection changes, and saved test-result accuracy.

## Round 6 Finding Disposition

### SQLite error origin and manual-delete state — resolved in the reported direct cases

`ViewerStoreError.sqliteBusy` now represents actual SQLite `BUSY`/`LOCKED`, while `.busy` remains the operation-local revision/active/lease conflict. The classifier maps `sqliteBusy` to `writeFailed`. The external-writer regression obtains a real `BEGIN IMMEDIATE` lock and proves the distinction from a stale revision.

Manual deletion now performs its fault phases and disk admission on the writer executor, rolls back its transaction body, and reports capacity versus storage failure through the authoritative state callback. The focused regression proves pre-BEGIN capacity, unavailable, and corruption classifications leave no tombstone. Finding 1 below concerns the shared cross-owner gate and recovery authorization; it does not repeat the fixed error-origin distinction. The manual-delete test should nevertheless be extended through post-mutation/pre-COMMIT rollback as part of that remediation because its current injected failures all occur before `BEGIN`.

Evidence: `ViewerSQLite.swift:5-44,354-369`; `ViewerStoreMaintenance.swift:404-472,1012-1031`; `ViewerStoreTests.swift:3285-3403`.

### Cumulative and saturating production drop projection — resolved at the session emitter

The session now retains bounded cumulative counters per local and remote reason, performs saturating addition, emits only reasons whose in-memory value changed, and uses the post-merge count. The flow-control regression covers repeated local/remote updates, a zero remote summary, and saturation to `UInt64.max`.

Finding 2 is a remaining store-boundary/order issue: it does not dispute the corrected session-side projection.

Evidence: `ViewerMultiDeviceSession.swift:179-199,570-589,1154-1174`; `ViewerFlowControlTests.swift:679-750`.

### Writer-serialized checkpoint admission — resolved

`checkpointOneStep` rechecks actionable WAL size and the floor-only reserve inside `pool.writer.run` immediately before `sqlite3_wal_checkpoint_v2`. Its interleaving regression proves checkpoint and another writer cannot concurrently spend one apparent reserve.

Evidence: `ViewerStoreMaintenance.swift:819-840`; `ViewerStoreTests.swift:3446-3488`.

### Closed reflection for active queue ownership — resolved in the reported carriers

`EventDraft`, queue keys/policies, pending Events, bounded queue owners, snapshots, scheduling/enqueue/dequeue/offer/clear results, batches, batch attempts, and Viewer downlink policy now expose content-free descriptions and mirrors. The table-driven Core regression exercises populated ownership/result shapes and the Viewer policy regression covers the independent keep-latest representation.

Evidence: `EventDraft.swift:80-89`; `EventQueueConfiguration.swift:36-67,164-180`; `BoundedEventQueue.swift:33-201,1155-1171`; `EventBatchScheduler.swift:85-120`; `BoundedEventQueueTests.swift:7-85`; `ViewerFlowControlTests.swift:9-22`.

## Findings

### NW-LSS-IMPL-R7-CT-001 — Medium — The shared failure gate can be crossed by an already-queued writer and recovery authorization is not action-specific

`ViewerStoreStateRelay.report` updates `ViewerStoreIngress.writeFailed` under the ingress lock and then updates presentation state. `ViewerStoreIngress.drain` checks that flag before selecting a prefix, releases the ingress lock, and then calls `ViewerEventStore.appendEvents`/`appendStructural`. `ViewerEventStore.writeTransaction` enters the serial writer later but does not consult the relay/gate on that writer turn.

This leaves a deterministic check-then-act race:

1. an ingress drain selects a bounded prefix and queues its `pool.writer.run` behind an interactive maintenance mutation;
2. the maintenance mutation fails while owning the writer and reports `writeFailed`, which stops future ingress selection;
3. the already-queued Event writer obtains the next writer turn, sees no shared gate check, commits automatically, and calls `setState(.available)`;
4. the drain removes the committed prefix even though no explicit/relevant recovery action authorized that attempt.

Publishing the maintenance classification while the writer is owned therefore does not, by itself, prevent another writer already waiting on that same serial executor from crossing the boundary. It can also leave public Event-store status `available` while the ingress-local flag remains stopped.

Recovery publication is also too broad and incomplete. Every successful `capacityCheckedWrite`, including a rename or annotation append, calls `storeStateReporter(.available)`, which clears the ingress gate and schedules retained work even though those operations are not an approved repair/capacity action. Conversely, `ViewerStoreRuntime.saveConfiguration` saves the value and requests maintenance but does not publish a successful authorized reopen, so a capacity increase can leave ingress stopped despite storage-setting change being an approved recovery trigger.

`testMaintenanceWriteFailureStopsIngressUntilExplicitRecovery` performs the failure first and only then offers new observations. It never queues an ingress writer behind the failing maintenance turn. It also recovers by directly calling `store.retry()` and `ingress.retry()` rather than exercising the live relay, does not test rename/annotation versus unpin/delete/settings authorization, and does not assert the gap claimed by `implementation-remediation-round6.md`.

Required remediation:

1. Put a generation/state gate on the serialized writer boundary itself. A prefix selected under generation N must revalidate N immediately before planning/`BEGIN`; a maintenance failure that advances the generation must make an already-queued automatic write stop without mutation.
2. Keep public state and ingress ownership under one authoritative transition so they cannot diverge after a stale queued completion.
3. Make recovery action-specific: explicit retry/reopen, successful settings change, unpin, and manual deletion may authorize one finite successor; rename and annotation must not.
4. Add deterministic interleaving coverage for an ingress append queued behind a failing metadata/manual-delete turn, plus table-driven recovery-action tests and production-coordinator gap persistence. Assert exact SQLite attempt count, no stale-prefix commit, consistent state, bounded retained ownership, and one authorized successor only.
5. Extend manual-delete failure injection through `beforeBody` and `beforeCommit` to prove actual rollback and quota/tombstone restoration rather than only pre-BEGIN nonmutation.

Evidence: `ViewerEventStore.swift:1438-1504,1746-1815,1890-1911`; `ViewerStoreMaintenance.swift:940-968`; `ViewerStoreCoordinator.swift:189-220,1212-1218`; `ViewerStoreTests.swift:3214-3283`; `design.md:98-100`; `specs/viewer-local-store-search/spec.md:99-111,135-148`; `implementation-remediation-round6.md:7-14`.

### NW-LSS-IMPL-R7-CT-002 — Medium — Drop monotonicity is checked after cleanup admission and equal persisted values are accepted

Session-side cumulative projection is fixed, but the durable boundary does not enforce the complete contract before side effects. For a new drop sequence, `plannedStructuralReservation` returns one structural reservation after checking only whether that exact sequence already exists. It does not compare the incoming count with the latest count for the same device/reason. `writeTransaction` may therefore run and commit one capacity-recovery cleanup campaign before the transaction body finally queries the latest drop count and rejects a decrease.

An invalid decreasing observation can thus tombstone otherwise eligible history before it is rejected, recreating the validation-before-cleanup defect previously fixed for structural carriers. The resulting `.invalidValue` is also classified as an Event-ingress write failure, poisoning the store after the unrelated cleanup has already committed.

The body check itself uses `latestCount > incomingCount`, so a different sequence with an equal count is accepted and charged. That contradicts the design that drop samples are emitted only when their persisted cumulative value changes. It also matters at the `UInt64`/SQLite boundary: the coordinator projects any value above `Int64.max` to `Int64.max`, so repeated higher in-memory counts can become equal durable counts unless the projection/store treats equality as a no-op or rejection.

The named `testRejectedCumulativeDropSampleCreatesGapBeforeLaterSample` does not exercise monotonic rejection. It injects a generic writer failure for the first valid count, rejects a second valid higher sample because ingress is stopped, then persists a third higher sample after retry. No test submits a lower/equal count against existing history, places the store at a cleanup boundary, or checks the `Int64.max` projection.

Required remediation:

1. Move the latest-per-reason cumulative comparison into the writer-side planning phase before quota projection, disk admission, or capacity recovery; repeat it in the body for defense in depth.
2. Define and enforce strict persisted change semantics: lower counts reject without cleanup/state poisoning, equal projected counts are idempotent no-ops or rejected without a row, and only a greater persisted count reserves quota.
3. Define the `UInt64` to SQLite `Int64` saturation boundary so values at/above `Int64.max` do not create repeated equal rows.
4. Add tests with eligible history and quota pressure proving lower/equal invalid samples create no tombstone, quota change, row, or global failure. Add exact `Int64.max`, `Int64.max + 1`, and `UInt64.max` production-coordinator cases, plus a real rejected-sample gap/recovery case distinct from an injected writer outage.

Evidence: `ViewerEventStore.swift:643-682,777-788,1438-1499`; `ViewerStoreCoordinator.swift:538-585`; `ViewerStoreTests.swift:441-503`; `design.md:62-67,80-86`; `implementation-remediation-round6.md:34-42`.

### NW-LSS-IMPL-R7-CT-003 — Medium — Completion evidence retains an unidentified current-tree test failure

`implementation-validation-round7.md` explicitly records that an earlier direct run on the current tree produced one timing-sensitive failure, but the failing test name and assertion were lost to output truncation. One preserved full rerun and two additional `--skip-build` repetitions then passed all 534 tests, and their retained logs support those three green snapshots. A fresh managed-sandbox review run also completed 534 tests with zero failures (seven environment-dependent skips).

Those later passes do not identify or explain the original failure. Because the failure was observed on the same current tree and was described as timing-sensitive rather than an environment/build denial, it remains a possible concurrency/test-isolation defect. Without the failing identity, the review cannot show that the affected requirement was exercised repeatedly, that the failure is unrelated to this change, or that a known fix removed it. Three green points are useful but do not convert an uncaptured red point into zero unresolved evidence.

Required remediation:

1. Run the complete package suite repeatedly with untruncated per-run logs and result preservation until the failure is reproduced or a statistically meaningful clean run count is achieved under the same command/environment.
2. On reproduction, capture the exact test, assertion, ordering, seed/environment, and preceding suite context; isolate and root-cause it rather than increasing a timeout or dropping the test.
3. Update validation evidence with the red run if recovered and the exact remediation/repetition results. Completion evidence should not characterize the change as stable while an unidentified current-tree failure remains unaudited.

Evidence: `implementation-validation-round7.md:71-87`; `/tmp/NearWireSwiftPMRound7-full.log`; `/tmp/NearWireSwiftPMRound7-repeat1.log`; `/tmp/NearWireSwiftPMRound7-repeat2.log`.

## Fresh Validation Performed

### OpenSpec and hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches
```

### Fresh ViewerStore regression

The focused `ViewerStoreTests` command explicitly excluded the opt-in live Application Support audit and executed all remaining 60 tests. Its result bundle reports `testsCount: 60`, `status: succeeded`, and no failure.

```text
/tmp/NearWireViewerRound7ReviewDerived/Logs/Test/Test-NearWireViewer-2026.07.13_10-11-59-+0800.xcresult
```

### Fresh flow-control remediation regressions

The cumulative-drop and Viewer downlink-policy reflection tests passed together with zero failures.

### Saved complete Viewer evidence

Direct inspection of the recorded complete result bundle confirmed:

```text
/tmp/NearWireViewerRound7Derived/Logs/Test/Test-NearWireViewer-2026.07.13_10-00-31-+0800.xcresult
testsCount: 140
testsSkippedCount: 1
status: succeeded
```

The single skip is the explicit live-container audit marker. The two configured-signing probes were excluded from this unsigned command and are not included in those counts.

### Root Swift package evidence

The three preserved Round 7 logs each report 534 tests and zero failures. A fresh review execution using `/tmp` caches and `--disable-sandbox` also completed:

```text
NearWirePackageTests.xctest: 534 tests, 7 skipped, 0 failures
All tests: 534 tests, 7 skipped, 0 failures
exit 0
```

The seven skips reflect the managed review environment and are not represented as passes. They do not resolve finding `NW-LSS-IMPL-R7-CT-003` because that finding concerns the separately acknowledged, unidentified failing run.

## Completion Gate

Round 7 correctness/testing approval requires all three findings to be remediated, fresh affected and complete validation to be saved, and a new independent correctness/testing review to report exactly zero unresolved actionable findings.
