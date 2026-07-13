# Implementation Review Round 7 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 2 — 0 High, 2 Medium, 0 Low.**

Round 6 remediation correctly serializes checkpoint reserve admission and introduces a relay that closes ingress after a maintenance failure. The relay does not yet form one authoritative writer state machine: direct `ViewerEventStore` writes and a drain that already crossed the ingress lock can bypass it. Recovery authorization is also represented only as a raw `available` state, allowing unrelated metadata writes to reopen ingress while a successful settings-change campaign cannot do so.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to goal-level `release-hardening`. That deferral is neither a finding nor passing evidence in this review.

## Scope and Evidence Basis

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and task plan; the complete current production, integration, test, packaging, operator-documentation, and working-tree change; all three Round 6 implementation-review reports; `implementation-remediation-round6.md`; `implementation-validation-round7.md`; and the relevant prior remediation, validation, and live-resource evidence.

The review retraced the two Round 6 architecture findings and rechecked shared store/ingress state ownership, recovery authorization, serialized physical-capacity admission, SQLite error origin, manual-delete state reporting, bounded maintenance fallback, runtime-generation and shutdown ownership, protocol/store authority separation, Sendable/lock discipline, active Event reflection, cumulative drop semantics, Core/SDK/Viewer boundaries, package structure, and scope exclusions.

Fresh local gates on the reviewed tree:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output
```

The saved Round 7 validation reports 140 unsigned Viewer tests with one explicit opt-in live-resource skip and zero failures, 534 root package tests with zero failures, and focused passes for the new write-gate, SQLite-lock, manual-delete, checkpoint, cumulative-drop, and reflection regressions. The two configured-signing tests were excluded from the unsigned command and are not counted as passing or skipped.

## Round 6 Finding Disposition

- **Maintenance failure immediately stops later ingress offers:** partially resolved. `ViewerStoreStateRelay` now sends maintenance states to both `ViewerEventStore` status and `ViewerStoreIngress`, and the new regression proves that offers made after a maintenance failure are stopped until explicit retry. Finding 1 remains because direct Event-store writes and a drain already selected before the relay transition are outside that ownership boundary.
- **Checkpoint reserve admission:** resolved. WAL action validation and the floor-only reserve check now occur inside `pool.writer.run` immediately before `sqlite3_wal_checkpoint_v2`. `testCheckpointReserveSharesWriterOrderingWithEventWrite` covers the serialized production path.

The Round 6 correctness and security findings are resolved in their reported forms: actual SQLite `BUSY/LOCKED` has a distinct `sqliteBusy` origin; manual deletion reports authoritative storage/capacity failure; local and remote drop samples are saturating cumulative values guarded against decrease; and active drafts, queue owners/results, policy keys, batches, frames, messages, and Viewer downlink policies now expose closed content-free reflection.

## Findings

### NW-LSS-IMPL-R7-ARCH-001 — Medium — The relay is not an authoritative writer gate and can be bypassed by direct or already-selected writes

`ViewerStoreStateRelay` is constructed beside `ViewerEventStore`, is supplied only to `ViewerStoreMaintenance`, and forwards maintenance status to ingress and Event-store presentation state (`ViewerStoreCoordinator.swift:182-215`; `ViewerEventStore.swift:1890-1911`). `ViewerEventStore.writeTransaction` does not consult the relay or the current store state after it acquires the writer. Its only gate is the independently injected `writeGate`, and every successful transaction unconditionally sets presentation back to `available` (`ViewerEventStore.swift:1438-1475`).

This leaves two concrete bypasses:

1. Recording/device materialization calls `eventStore.beginRecording` and `beginDeviceSession` directly (`ViewerStoreCoordinator.swift:749-802`). A failure sets only Event-store status. It does not close ingress through the relay, so durable devices that already exist can keep admitting and automatically draining Events after the store has entered `writeFailed`.
2. `ViewerStoreIngress.drain` checks its private gate, selects a structural item or Event prefix, releases the ingress lock, and only then calls the Event store (`ViewerEventStore.swift:1794-1845`). If a maintenance failure reports `writeFailed` while that selected drain is queued behind the maintenance writer turn, the relay closes ingress, but the already-selected call subsequently acquires the writer without rechecking shared authorization. A successful commit resets Event-store status to `available` while ingress remains stopped, splitting the two state owners.

The explicit retry path exposes the same separation in the other direction: it calls `eventStore.retry()`, then `ingress.retry()`, and only afterward attempts recording/device materialization (`ViewerStoreCoordinator.swift:591-603`). If that direct materialization fails, Event-store status returns to `writeFailed` while ingress remains reopened.

`testMaintenanceWriteFailureStopsIngressUntilExplicitRecovery` injects failure before any ingress offer, asserts later offers are stopped, and then invokes store/ingress retry separately (`ViewerStoreTests.swift:3219-3295`). It does not hold a preselected drain behind the writer, inject a direct recording/device failure, or assert that status and admission cannot diverge.

Required resolution:

- Replace the presentation relay plus private ingress Boolean with one authoritative failure generation/state owner shared by maintenance, direct Event-store operations, and ingress.
- Recheck that generation/state on the serialized writer turn immediately before every transaction or checkpoint mutation. An ingress item selected before a failure transition must not begin SQLite work afterward.
- Make failure publication and successful recovery transition update presentation and admission from the same owner; no path may set one available while the other remains stopped or vice versa.
- Add deterministic regressions for a preselected drain queued behind a failing maintenance write, direct recording/device materialization failure with another durable device still live, and retry-probe success followed by materialization failure. Assert zero unauthorized SQLite attempts, bounded retained/gap ownership, and identical status/admission state.

### NW-LSS-IMPL-R7-ARCH-002 — Medium — Recovery authorization is untyped, both reopening on unrelated writes and missing the settings-change recovery path

The maintenance callback accepts only `ViewerStoreStatus.State`; it carries no recovery reason, prior failure generation, or proof that the triggering action can make the blocked write safe. Every successful `capacityCheckedWrite` calls `storeStateReporter(.available)` (`ViewerStoreMaintenance.swift:930-968`). That includes rename, note, annotation, and pin operations as well as unpin. Consequently, any successful unrelated metadata mutation after a transient failure reopens ingress and schedules its queued prefix through `noteExternalStoreState(.available)` (`ViewerEventStore.swift:1753-1763`). The active design authorizes a new attempt after explicit retry/reopen or a relevant configuration/data action that can make writing safe—specifically storage-setting change, unpin, or confirmed manual deletion—not after arbitrary annotation, rename, or pin success (`design.md:100,125-127`).

The inverse path is also missing. `ViewerStoreRuntime.saveConfiguration` persists the value and requests `.settingsChanged` maintenance (`ViewerStoreCoordinator.swift:1212-1218`), but `ViewerStoreMaintenance.run` publishes only cleanup metadata and never reports an authorized `available` transition or schedules one finite ingress successor (`ViewerStoreMaintenance.swift:211-261`). If ingress is already stopped by `capacityPaused`, increasing capacity and completing a successful campaign leaves it stopped until the user separately invokes Retry Storage, contrary to the specified settings-change recovery trigger.

Current coverage verifies ordinary settings persistence/presentation and explicit retry, but it does not begin from stopped ingress and distinguish capacity increase, unpin, manual deletion, rename, annotation, or pin as recovery authorities. The maintenance write-gate regression uses only explicit store/ingress retry.

Required resolution:

- Model recovery as a typed transition such as explicit retry, successful reopen, capacity/retention change, unpin, confirmed deletion, or other specifically approved trigger, bound to the current failure generation.
- Keep rename, annotation, pinning, and unrelated successful writes from clearing `writeFailed`/`capacityPaused` or scheduling ingress.
- After a settings change or other authorized trigger, first prove the recovery action/campaign succeeds, then authorize exactly one finite pending-prefix attempt; retain the stopped state if the action fails or cannot make the plan safe.
- Add a transition-matrix regression covering every allowed and disallowed action from both `writeFailed` and `capacityPaused`, including increased capacity that resumes without an extra Retry button and a decreased/irrelevant setting that does not.

## Architecture and Boundary Recheck

- Checkpoint and incremental-vacuum action checks now share writer ordering with all other mutations. Manual deletion and orphan reconciliation retain their exact writer-serialized physical plans.
- SQLite remains macOS Viewer-only with exactly one writer, one interactive reader, and one export reader. Query/export pointers remain confined to their own serial executors.
- Runtime generations continue to reject late callbacks and prevent a prior cleanup receipt from attaching to or closing a replacement recording. Shutdown owns one finite ingress flush and no automatic retry or maintenance scan after terminal failure.
- The session manager remains the only protocol, sequence, rate, mailbox, queue, and terminal authority. Journal failures affect only bounded gap/status ownership.
- The cumulative drop implementation remains bounded per reason and saturating. The Core/Viewer reflection additions expose only counts, byte counts, or closed policy categories and add no persistence API.
- No SQLite or third-party runtime dependency entered Core or SDK. No nested package manifest or podspec was added, and the manually maintained Viewer project remains at macOS 13 with Swift 5 language mode.
- No timeline/history browser, search/filter UI, payload renderer, export selection UI, control composer, performance chart, server, cloud service, or SDK persistence/search API was introduced.

## Approval Gate

Approval requires resolving both findings, saving proportionate focused and complete validation, and obtaining a fresh independent architecture/API review with **zero unresolved findings**. Configured signing and signer-bound entitlement probes remain deferred exclusively to `release-hardening` and are not part of this finding count.
