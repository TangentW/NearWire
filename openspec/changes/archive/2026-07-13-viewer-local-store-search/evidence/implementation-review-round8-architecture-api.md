# Implementation Review Round 8 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 3 — 0 High, 3 Medium, 0 Low.**

Round 7 remediation materially improves the architecture: automatic writes carry UUID generation tickets, stale queued prefixes revalidate on the SQLite writer, direct and recovery materialization use the same authorization owner, explicit retry remains closed until all materialization succeeds, and recovery call sites are typed. Three concurrency boundaries remain. Direct Event-store failures advance the generation only after releasing the writer; relay observer notifications can be delivered out of authoritative transition order; and maintenance outcome publication is not lifecycle-generation checked, so campaign failures are swallowed and a recovery can be published after shutdown has stopped the owner.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to goal-level `release-hardening`. That deferral is neither a finding nor passing evidence in this review.

## Scope and Evidence Basis

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and task plan; the complete current production, integration, test, packaging, operator-documentation, and evidence change; all three Round 7 implementation-review reports; `implementation-remediation-round7.md`; `implementation-validation-round8.md`; and relevant prior remediation, validation, and live-resource evidence.

The review retraced both Round 7 architecture findings and rechecked UUID generation ownership, stale-prefix handling, direct recording/device materialization, two-phase explicit recovery, typed recovery call sites, maintenance dirty-successor ownership, presentation/admission consistency, bounded tasks and queues, runtime/shutdown ordering, protocol/store authority separation, Sendable/lock discipline, Core/SDK/Viewer boundaries, package structure, and scope exclusions. The obsolete `successfulReopen` recovery case has been removed; successful reopen correctly creates a fresh validated coordinator and state owner.

Fresh local gates on the reviewed tree:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output
```

Evidence was inspected rather than accepted only from prose:

- `xcresulttool get test-results summary` on the recorded complete Viewer bundle confirms 146 total, 145 passed, one explicit live-resource skip, and zero failures.
- All 20 recorded SwiftPM stability logs exist; every log contains the 535-test/zero-failure completion and none contains a failed test, failed suite, or error line.
- Both sets of 100 targeted SwiftPM repetition logs exist and contain zero-failure results for the two previously unidentified test-observation races.

The two configured-signing tests were excluded from the unsigned Viewer command and are not counted as passing or skipped.

## Round 7 Finding Disposition

- **Generation-checked shared writer state:** partially resolved. Automatic writes now issue one opaque ticket and validate its exact UUID generation on the serial writer before the injected gate, planning, reserve admission, and `BEGIN`. The deterministic maintenance-failure regression proves that a prefix queued behind a maintenance failure cannot commit. Finding 1 remains because direct `ViewerEventStore.writeTransaction` failure publication occurs after its writer turn returns.
- **Typed recovery authorization:** resolved at the reviewed call sites. Capacity increase or retention decrease carries `.settingsChanged`; actual pinned-to-unpinned transition carries `.unpin`; confirmed deletion carries `.manualDelete`; rename, annotation, pinning, longer retention, lower capacity, and ordinary cleanup do not recover. Explicit retry probes and materializes under one permit and publishes available only after the complete sequence succeeds.

The other Round 7 findings are resolved in their reported forms: cumulative drop comparison now occurs during planning before cleanup, equal projections are idempotent, saturation is bounded at `Int64.max`, active handoff/secure-transport reflection is closed, and both previously unexplained SwiftPM failures were reproduced, root-caused as test-observation races, corrected without timeout increases, and repeatedly verified.

## Findings

### NW-LSS-IMPL-R8-ARCH-001 — Medium — Direct Event-store failure advances the generation after releasing the writer

`ViewerEventStore.writeTransaction` validates its authorization inside `pool.writer.run`, then performs the injected gate, plan, reserve check, `BEGIN`, mutation, and `COMMIT` (`ViewerEventStore.swift:1476-1519`). However, error classification and `writeStateRelay.reportFailure` occur only in catch clauses outside `pool.writer.run` (`ViewerEventStore.swift:1522-1551`). `ViewerSQLiteConnection.run` is a synchronous serial-queue turn; once its body throws, the queue turn ends before the caller's outer catch executes (`ViewerSQLite.swift:279-320`).

A direct recording/device or ingress write can therefore fail with I/O, SQLite lock, corruption, unavailable storage, or commit failure, release the writer while the relay still reports the old generation as available, and allow a second already-ticketed writer to acquire the next writer turn and validate successfully. Only afterward does the first caller advance the generation and close the state. The second transaction is an unauthorized automatic write under the approved failure boundary even though final presentation may eventually show `writeFailed`.

`testWriterGenerationRejectsAPreselectedIngressPrefixAfterMaintenanceFailure` does not cover this window. Its maintenance path invokes `reportInteractiveWriteFailure` from inside the maintenance writer closure before that turn exits (`ViewerStoreTests.swift:3439-3528`; `ViewerStoreMaintenance.swift:946-977`). `testDirectMaterializationFailureAndFailedRetryCannotReopenIngress` observes a direct failure sequentially and offers work only after failure publication; it does not queue another ticket behind the failing Event-store writer (`ViewerStoreTests.swift:3530-3601`).

Required resolution:

- Classify every direct Event-store storage failure and advance the authoritative generation before the failing writer closure returns. Operation-local `writeNotAuthorized` and `staleObservation` must remain nonpoisoning.
- Preserve the one eligible capacity-recovery campaign without exposing an old-generation writer window; any terminal recovery failure must close the generation before another automatic transaction can validate.
- Add a deterministic direct-write interleaving test that blocks a recording/device or Event transaction inside the writer, queues a second automatic ticket, injects failure, and proves the second writer performs zero planning/mutation until one approved recovery creates a new generation.

### NW-LSS-IMPL-R8-ARCH-002 — Medium — Relay observer notifications can overwrite a newer authoritative transition

`ViewerStoreStateRelay.completeRecovery` and `reportFailure` update state/generation under the relay lock, capture weak observers, unlock, and then separately notify Event-store presentation and ingress (`ViewerEventStore.swift:2050-2083`). Those callbacks carry only a raw state and no transition generation. Concurrent transitions can therefore be committed in authoritative order but delivered in the opposite observer order.

For example, recovery can commit `available` and unlock; a failure can then commit a new UUID generation and notify both observers as failed; the delayed recovery callbacks can finally set Event-store presentation back to `available` and ask ingress to schedule a drain. Ingress rechecks the relay before admission/writing, so the generation gate still prevents SQLite mutation, but public status can remain falsely available and the two observer surfaces no longer represent the relay's current state. The reverse interleaving can likewise leave stale failure presentation after a later valid recovery.

Current tests exercise transition sequences serially. The recovery matrix and stale-prefix tests do not suspend observer delivery or race `completeRecovery` against `reportFailure`.

Required resolution:

- Give every transition a monotonic/opaque notification generation and require observers to apply only the relay's current transition, or serialize state mutation and observer publication through one ordered transition executor.
- Make Event-store status and ingress scheduling derive from the same current snapshot rather than trusting a stale raw-state callback.
- Add deterministic reordered-notification tests for recovery-versus-failure and failure-versus-recovery. Assert relay state, public status, admission, flush, and scheduled-drain ownership all converge on the newest transition.

### NW-LSS-IMPL-R8-ARCH-003 — Medium — Maintenance outcome publication is not lifecycle-owned and can recover after terminal flush

`ViewerStoreMaintenanceOwner.run` catches every campaign error and converts it only to `succeeded = false`; it does not classify capacity versus storage failure through the authoritative relay (`ViewerStoreMaintenance.swift:1200-1212`). A scheduled startup, settings, session-close, threshold, periodic, or explicit cleanup mutation can therefore roll back because of capacity, corruption, I/O, or unavailable storage while the relay remains `available` and automatic ingress continues. `ViewerStoreMaintenance.run` publishes only cleanup category `.failed` before rethrowing (`ViewerStoreMaintenance.swift:214-264`).

The success side has the opposite lifecycle race. `close()` marks the owner stopped and clears dirty/pending recovery under its lock, but an already-running `run` calls `recoveryReporter(recoveryAction)` before it checks `stopped` (`ViewerStoreMaintenance.swift:1158-1168,1200-1218`). `runtimeEnded` only cancels the periodic wake before starting the terminal ingress flush, and calls `maintenanceOwner.close()` after that flush resolves (`ViewerStoreCoordinator.swift:643-715`). Thus a settings-recovery campaign already in flight can complete after a terminal flush returned `writeFailed`, publish `available`, and schedule the retained ingress prefix before noticing that the owner was stopped. Shutdown then closes the SQLite pool while that post-flush drain is queued or running. This recreates an implicit attempt after the specified single terminal flush and weakens resource ownership.

The owner preserves at most one scheduled campaign plus one dirty successor during ordinary operation, but no current regression blocks a recovery-bearing campaign across `runtimeEnded`/`close`, and no scheduled-campaign failure test asserts authoritative state classification.

Required resolution:

- Give maintenance-owner work a lifecycle generation. Check that the exact run is still active before publishing either recovery or failure, and invalidate all recovery authority before terminal flush ownership begins.
- Route genuine scheduled-campaign capacity/storage failure through the shared classifier and authoritative state owner; keep operation-local/no-work outcomes nonpoisoning.
- Ensure shutdown first quiesces or invalidates recovery-bearing maintenance work, then performs its one finite ingress flush, and cannot schedule a writer after the flush outcome is known.
- Add deterministic tests for a scheduled cleanup storage failure from `available`, a dirty settings-recovery successor, and an in-flight recovery campaign released after runtime shutdown starts. Assert exact state, one flush attempt, zero post-flush writer authorization, bounded completion, and pool closure after all writer ownership is gone.

## Architecture and Boundary Recheck

- UUID tickets are checked on the serial SQLite writer before automatic planning, reserve admission, and mutation. Recovery permits remain generation-bound through recording and all live-device materialization, and incomplete recovery retains failed state.
- Typed recovery call sites match the approved matrix. A fresh coordinator represents successful reopen without carrying stale permits or generations.
- Checkpoint, free-page work, manual deletion, metadata writes, Event ingress, and orphan reconciliation retain serialized physical-capacity admission. Drop monotonicity validation now precedes cleanup side effects.
- Preparation, ingress, queue, and handoff ownership remain bounded; no task-per-Event or unbounded retry loop was introduced. The session manager remains the sole protocol, sequence, rate, mailbox, queue, and terminal authority.
- Active Event, queue, handoff, channel, listener, and store-owner reflection exposes only closed categories/counts and no Event content, IDs, queue keys, endpoints, certificate state, or raw bytes.
- SQLite remains macOS Viewer-only with one writer, one query reader, and one export reader. No SQLite or third-party runtime dependency entered Core or SDK, no nested manifest/podspec was added, and no supported SDK persistence API was created.
- The manually maintained Viewer project remains compatible with macOS 13 and Swift 5 language mode. No timeline/history browser, search UI, payload renderer, export-selection UI, control composer, performance chart, server, cloud component, or import path entered this change.

## Approval Gate

Approval requires resolving all three findings, saving proportionate focused and complete validation, and obtaining a fresh independent architecture/API review with **zero unresolved findings**. Configured signing and signer-bound entitlement probes remain deferred exclusively to `release-hardening` and are not part of this finding count.
