# Independent Implementation Review — Round 8 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, 0 Low.**

Round 7's queued automatic-writer gate, direct/retry materialization handling, drop monotonicity, manual-delete rollback matrix, and unidentified SwiftPM failure evidence are materially resolved. One recovery-generation race remains: successful unpin, manual-delete, and settings-maintenance operations report recovery only after their serialized work has released the writer, and the callback then creates a permit for whatever generation is current at callback time. An intervening, newer storage failure can therefore be reopened by an older successful recovery action.

Configured-signing and entitlement probes remain explicitly deferred by user direction to the goal-level `release-hardening` change. They are not counted as findings and are not represented as passing or skipped in this review.

## Scope

This independent review read `AGENTS.md`; the active proposal, design, capability specifications, tasks, production/test/documentation/evidence diff; all three Round 7 implementation-review reports; `implementation-remediation-round7.md`; and `implementation-validation-round8.md`. It retraced writer-ticket and generation interleavings, direct and retry materialization failures, the recovery transition matrix, manual-delete before-begin/body/commit rollback, validation-before-cleanup for drop samples, equal/lower/`Int64` saturation semantics, rejected-sample gap behavior, stale ingress-head removal, and the saved repeated SwiftPM evidence.

## Round 7 Finding Disposition

### Shared writer gate and direct/retry materialization — resolved in the reported paths

Automatic writes now obtain a generation ticket before queuing and validate it inside `pool.writer.run` before the write gate, planning, capacity/disk admission, or `BEGIN`. A maintenance failure advances the authoritative generation, so a preselected ingress prefix waiting behind that failure is rejected without committing and remains owned by ingress. Direct recording/device materialization uses the same transaction gate, while explicit retry prepares one generation-bound permit, probes the store, materializes recording/device state with that permit, and completes only that same permit. Failed materialization advances the generation and prevents the stale retry from reopening ingress.

The deterministic queued-prefix regression covers the old check-then-act race, and the direct/repeated retry regression covers failure and later successful recovery. The remaining finding is narrower: the other three approved recovery actions do not carry a permit from the action through completion.

Evidence: `ViewerEventStore.swift:1476-1515,2018-2067`; `ViewerStoreCoordinator.swift:607-623`; `ViewerStoreTests.swift:3439-3600`.

### Manual-delete rollback and state classification — resolved

The current matrix injects unavailable, corruption, and capacity failures at before-begin, body, and before-commit phases. The implementation rolls back the transaction body and the tests assert exact authoritative state, no tombstone, and unchanged quota for all nine combinations. This resolves the Round 7 rollback-coverage requirement.

Evidence: `ViewerStoreMaintenance.swift:404-482`; `ViewerStoreTests.swift:3744-3845`.

### Strict cumulative-drop persistence — resolved

The writer-side planning phase now compares the incoming count with the latest persisted count before capacity recovery: a lower value throws `.staleObservation`, an equal projected value reserves zero and writes no row, and only a greater value reserves quota. The transaction body repeats the same comparison. The coordinator saturates `UInt64` values at `Int64.max`, suppresses equal projected values, and emits a `dropJournalNonIncreasing` gap for a genuine decrease. Ingress removes a structurally stale head, reports it through the rejected-structural callback, and continues with later work instead of permanently blocking the queue.

The quota-pressure regression proves equal/lower samples cause no cleanup, tombstone, quota change, row, or global failure. The coordinator regression covers `Int64.max`, `Int64.max + 1`, `UInt64.max`, and a later real decrease. The existing outage regression separately covers a rejected sample becoming a gap before a later valid sample.

Evidence: `ViewerEventStore.swift:654-695,790-815`; `ViewerStoreCoordinator.swift:544-604`; `ViewerStoreTests.swift:445-640`.

### Previously unidentified SwiftPM failures — resolved with auditable repetition

The preserved failing logs identify both failures exactly: the performance state-stream termination timeout in `/tmp/NearWireSwiftPMRound8-full.log`, and the outbound transport admission observation race in `/tmp/NearWireSwiftPMRound8-repeat-2.log`. The corresponding test-only changes remove the cancellation-bypassing stream exit and wait for the progress-driven outbound turn to reach its stable blocked state before establishing the baseline.

Direct inspection found exactly 100 performance logs, 100 transport logs, and 20 complete-suite stability logs. Scanning each set found zero failed test case, failed suite, or `error:` line. The first and hundredth targeted logs each report one selected test and zero failures; the first and twentieth complete logs each report 535 tests and zero failures. This resolves the Round 7 evidence finding.

## Finding

### NW-LSS-IMPL-R8-CT-001 — Medium — Recovery callbacks can bind an old successful action to a newer failure generation

The relay's `RecoveryPermit` mechanism is generation-aware, but `recover(_:)` defeats that protection for unpin, manual delete, and settings maintenance by creating the permit inside the completion callback. A successful unpin commits and returns from its writer operation before calling `recoveryReporter(.unpin)`. Manual deletion likewise commits and releases the writer before calling `recoveryReporter(.manualDelete)`. The maintenance owner waits for the campaign to return before publishing `.settingsChanged`. Production wires all three callbacks to `storeStateRelay.recover`, which calls `prepareRecovery` and `completeRecovery` back-to-back using the generation current at callback time.

This admits the following interleaving:

1. generation A is failed, and an authorized unpin, manual-delete, or settings action starts to repair it;
2. that action succeeds and releases the serialized writer, but its recovery callback has not run yet;
3. another maintenance writer fails, calls `reportFailure`, and advances the relay to failed generation B;
4. the older action's callback runs, creates a fresh permit for generation B, and immediately marks B `available` even though the successful action preceded and did not repair that failure.

The race window exists between return from `pool.writer.run`/maintenance and the next callback statement; no lock or serialized executor binds those operations together. The action enum limits which call sites may request recovery, but its value is not an authorization tied to the failure being repaired. `testRecoveryMatrixAllowsOnlyApprovedSuccessfulActions` exercises the actions sequentially and therefore cannot expose an intervening generation change.

Required remediation:

1. Prepare a recovery permit against the failed generation before each approved recovery action, carry that exact permit through the action, and validate it on the serialized writer turn before planning or mutation.
2. Complete only that same permit after the successful commit/campaign. Remove the callback path that creates a new permit after success. If any intervening failure advances the generation, completion of the stale action must be rejected and the newer failed state must remain authoritative.
3. Add deterministic interleaving coverage with a latch after a successful recovery commit/campaign but before completion, inject a second maintenance failure, then release the old completion. Assert the newer state remains failed, ingress remains stopped, no automatic successor crosses the gate, and a later recovery explicitly bound to the new generation can recover. Cover unpin, manual delete, and settings maintenance, or prove they share one tested generation-bound primitive.

Evidence: `ViewerEventStore.swift:2025-2071,2074-2083`; `ViewerStoreMaintenance.swift:328-334,470-481,1200-1213`; `ViewerStoreCoordinator.swift:194-215`; `ViewerStoreTests.swift:3603-3694`.

## Fresh Validation Performed

### OpenSpec and hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches
```

### Fresh ViewerStore regression

The repository's arm64/module-cache command shape executed all 66 `ViewerStoreTests`: 65 passed, the explicit opt-in live Application Support audit was skipped, and zero failed. The result bundle reports `testsCount: 66`, `testsSkippedCount: 1`, and `status: succeeded`:

```text
/tmp/NearWireViewerRound8CorrectnessReviewArm64/Logs/Test/Test-NearWireViewer-2026.07.13_11-07-56-+0800.xcresult
```

Three preceding ad hoc commands omitted the required arm64/module-cache shape. The first stopped at the expected unsigned signing requirement; the next two dual-architecture attempts failed explicit-module resolution with incompatible target modules. They did not execute tests and are not counted as behavioral results. The corrected repository command above is the fresh review result.

### Fresh root Swift package regression

The current Round 8 `--disable-sandbox --skip-build` command completed independently during this review:

```text
NearWirePackageTests.xctest: 535 tests, 7 skipped, 0 failures
All tests: 535 tests, 7 skipped, 0 failures
exit 0
```

The seven environment-dependent skips are not represented as passes. Separately, the saved 100 + 100 targeted and 20 complete stability processes were counted and failure-scanned as described above.

## Completion Gate

Round 8 correctness/testing approval requires remediation of `NW-LSS-IMPL-R8-CT-001`, fresh affected and complete validation evidence, and a new independent correctness/testing review reporting exactly zero unresolved actionable findings.
