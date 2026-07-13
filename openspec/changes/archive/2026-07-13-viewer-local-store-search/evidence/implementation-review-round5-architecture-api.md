# Implementation Review Round 5 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 3 — 0 High, 3 Medium, 0 Low.**

Round 4 remediation resolves the duplicate same-coordinator device materialization, stale reader-side metadata quota preflight, validation-after-cleanup, impossible Event-type prefix, direct-carrier reflection, and missing live-filesystem evidence findings in their reported forms. The Viewer-only dependency boundary, runtime-generation isolation, protocol/store authority separation, bounded queue ownership, and deferred-UI scope also remain sound.

Three architecture/API issues remain: production maintenance still cannot reach a cheaper physical-recovery action when an earlier expensive action cannot satisfy its disk plan; shutdown now owns an implicit second flush attempt contrary to the active explicit-retry/one-attempt contract; and maintenance metadata writes do not report non-capacity storage failures through the authoritative `writeFailed` state.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to goal-level `release-hardening`. That deferral is not a finding and is not represented as passing evidence here.

## Scope and Evidence Basis

This fresh review re-read `AGENTS.md`; the active proposal, design, both capability specifications, and task plan; all current production, integration, test, operator-documentation, and evidence files; all three Round 4 implementation reports; `implementation-remediation-round4.md`; `implementation-validation-round5.md`; `resource-filesystem-audit-round5.md`; and the complete current working-tree diff.

The review specifically retraced stable runtime/device ownership, same-coordinator and replacement-coordinator recovery, writer-executor quota admission, action-specific maintenance planning, ingress failure/retry/shutdown ownership, reflection surfaces, SQLite executor isolation, Sendable/lock boundaries, packaging boundaries, and deferred UI/API scope.

Fresh local gates on the reviewed tree:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output
```

The saved Round 5 regression reports 126 unsigned Viewer tests with one explicit opt-in live-container skip and zero failures, 49 focused store tests with the same opt-in skip and zero failures, and 531 root package tests with seven existing skips and zero failures. The two configured-signing tests were excluded from the unsigned command rather than counted as passes or skips.

## Round 4 Disposition

- **Same-coordinator recovery:** resolved in its reported duplicate-row form. `recoverSession` and `materializeSession` reuse an existing `DeviceContext`; recovery materializes only tracked nondurable connections. `testSameCoordinatorRecoveryDoesNotDuplicateDurableLiveDevices` covers repeated recovery and verifies two exact latest-closed device rows.
- **Writer-authoritative metadata capacity admission:** the reported reader/writer race is resolved. `capacityCheckedWrite` performs projection, disk admission, transaction, one bounded cleanup recovery, and retry in writer order. Finding 3 below concerns its non-capacity failure-state API, not the original ordering race.
- **Validation before structural cleanup:** resolved. `validateStructuralObservation` runs before planning or recovery and covers policy, drop, gap, range, direction, count, and checked-integer bounds. The named regression proves invalid observations cannot tombstone history.
- **Maximum trailing-dot Event prefix:** resolved. A trailing-dot prefix must leave capacity for a valid final segment, and the new boundary test covers 126/127/128-byte cases.
- **Direct carrier reflection:** resolved. `WireReceivedEvent`, `ViewerDownlinkJournalEvent`, and `ViewerStructuralObservation` expose closed redacted descriptions and mirrors, with table-driven secret-marker coverage.
- **Live Application Support and incremental-vacuum evidence:** resolved as an evidence finding. The reversible live-container audit and measured SQLite page reclamation are current and explicitly avoid claiming immediate APFS allocated-byte shrinkage.
- **Action-specific maintenance reserve:** partially resolved. Each mutation now computes its own plan, but the production campaign cannot bypass a blocked expensive action to execute a safe lower-cost physical recovery. This remains actionable as finding 1.

## Findings

### NW-LSS-IMPL-R5-ARCH-001 — Medium — A blocked expensive maintenance action still prevents cheaper physical recovery

`ViewerStoreMaintenance.run` calls `selectTombstones`, `reclaimOneBatch`, `checkpointOneStep`, and `reclaimFreePagesOneStep` in fixed order and aborts the whole campaign on the first thrown error (`ViewerStoreMaintenance.swift:202-240`). The individual mutation paths now calculate action-specific reserves, which removes the former unconditional 41-MiB check. However, `reclaimOneBatch` throws `.capacityExceeded` when its selected Event/non-Event batch cannot preserve `64 MiB + selected plan` (`ViewerStoreMaintenance.swift:512-583,605-659`). That error leaves `run` before it can reach the floor-only checkpoint or incremental-vacuum paths (`ViewerStoreMaintenance.swift:738-768`). The same blockage can occur when a newly selected tombstone's small mutation plan cannot fit while an already existing WAL/freelist cleanup could run at the floor.

This retains the liveness defect identified by `NW-ISPD4-001`: at low available capacity, a high-cost reclaim correctly fails closed, but the production maintenance trigger cannot perform a cheaper bounded action that may create the space needed for the next campaign. The new regression calls `reclaimFreePagesOneStep` and `checkpointOneStep` directly (`ViewerStoreTests.swift:2873-2874`); it does not drive `run`, place a blocked expensive action ahead of free pages/WAL, or prove campaign-level progress. The operator statement that each turn determines its next bounded action is true for reserve sizing but incomplete for recovery selection.

Required resolution:

- Represent the next maintenance operation as an explicit bounded action/plan before mutation.
- If an Event/non-Event reclaim cannot satisfy its own physical reserve, allow at most one eligible floor-only checkpoint or free-page action without mutating or skipping logical selection state; otherwise fail closed.
- Preserve the eight-turn, one-active-task/one-dirty-successor limits and retention-before-capacity logical-selection order.
- Add a production-`run` regression with an oversized reclaim head, available capacity above the 64-MiB floor but below the reclaim plan, and reclaimable WAL/free pages. Prove the cheap action progresses, the expensive row remains intact, and no extra recording is tombstoned.

### NW-LSS-IMPL-R5-ARCH-002 — Medium — Shutdown implicitly retries a failed prefix despite the one-attempt and explicit-retry contract

After offering device/recording closes, `ViewerStoreCoordinator.runtimeEnded` calls `ingress.flush`. When that returns `writeFailed`, shutdown calls `eventStore.retry`, clears the ingress failure state, and calls `flush` again (`ViewerStoreCoordinator.swift:604-689`, especially `:663-668`). `ingress.retry()` is invoked even if the preceding `try? eventStore.retry()` failed. A first shutdown write failure can therefore receive a second write attempt; a capacity failure in that second attempt may also enter `ViewerEventStore`'s bounded maintenance recovery.

The active design assigns failed prefixes to one **explicit** retry boundary, says shutdown performs no cleanup scan after terminal failure, and says a failed flush releases resources for next-open reconciliation (`design.md:100,176-180`). The normative shutdown scenario requires the exact finite prefix to receive one flush attempt (`specs/viewer-local-store-search/spec.md:274-282`). A single automatic retry is finite and does not create an unbounded loop, but it is still a second implicit attempt and broadens shutdown ownership beyond the approved contract. Unconditionally clearing ingress after a failed retry probe also violates the invariant that ingress resumes only after a successful recovery decision.

Required resolution:

- Keep shutdown to the one specified flush attempt and rely on next-open reconciliation after failure; or change the OpenSpec contract before implementation if one automatic retry is an intentional product decision.
- Never call `ingress.retry()` unless the corresponding store recovery probe succeeded.
- Add deterministic shutdown tests for a pre-existing failed prefix, a failure during the shutdown attempt, a failed recovery probe, and a capacity failure. Prove exact attempt count, no maintenance scan after terminal failure, finite completion, resource release, and correct next-open orphan repair.

### NW-LSS-IMPL-R5-ARCH-003 — Medium — Maintenance metadata writes omit authoritative `writeFailed` reporting

`ViewerStoreMaintenance.capacityCheckedWrite` correctly reports `.available` after success and `.capacityPaused` after unrecoverable capacity admission. Its catch clauses handle only `.capacityExceeded` (`ViewerStoreMaintenance.swift:841-894`). A non-capacity SQLite/storage failure from projection, disk access, `BEGIN`, `addQuota`, insert, or `COMMIT` escapes without reporting `.writeFailed` through `storeStateReporter`. In the live composition that reporter is the authoritative `ViewerEventStore.noteMaintenanceWriteState` seam (`ViewerStoreCoordinator.swift:191-200`; `ViewerEventStore.swift:1435-1445`).

Therefore an annotation or recording-metadata mutation can roll back because of an I/O/unavailable/corrupt-store failure while the durable writer remains presented as available and later ingress continues automatically. That differs from `ViewerEventStore.writeTransaction`, which maps non-capacity write failures to `.writeFailed` and stops automatic ingress drain (`ViewerEventStore.swift:1360-1415`). Ordinary stale-revision `.busy` and caller `.invalidValue` outcomes should remain operation-local, but storage-integrity and I/O categories need the same authoritative failure boundary.

Required resolution:

- Centralize writer failure classification shared by Event and maintenance mutation APIs: capacity exhaustion becomes `.capacityPaused`; storage/I/O/corruption failures become `.writeFailed`; stale revision, lease contention, cancellation, and invalid caller values remain operation-local where specified.
- Publish the state transition through the existing latest-only status signal and prevent automatic ingress retry until a successful explicit recovery/configuration/data trigger.
- Add deterministic injected failures before `BEGIN`, during annotation/metadata insert, and at commit, plus stale-revision controls. Assert rollback, exact safe state, notification behavior, and retry ownership.

## Architecture and Boundary Recheck

- SQLite remains macOS Viewer-only with one writer, one query reader, and one export reader. No database abstraction or third-party runtime dependency entered Core or SDK.
- The Core adjustment remains limited to internal transport SPI accounting/reflection and does not add a supported public SDK API.
- Runtime generations still isolate late callbacks and replacement coordinators. The session manager remains the only protocol/queue/token/mailbox owner; storage callbacks cannot mutate protocol state.
- Shared pipeline accounting remains bounded across preparation and ingress, with a reserved lifecycle partition and no new unbounded task or payload owner.
- The new reflection implementations contain no Event/query/policy/gap content. Safe status and application presentation remain content-free.
- Store/UI functionality remains within this change: no timeline, history browser, payload renderer, search controls, export selection, control composer, performance chart, server, cloud service, or SDK persistence API was added.
- The manually maintained Xcode project, macOS 13 deployment target, Swift 5 language mode, root-manifest-only structure, and system-SQLite linkage remain intact.

## Approval Gate

Approval requires resolving all three findings, rerunning the affected focused and complete gates, and obtaining a fresh independent architecture/API review with **zero unresolved findings**. The configured-signing gates remain deferred exclusively to `release-hardening` and are not part of this finding count.
