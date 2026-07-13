# Independent Implementation Review — Round 12 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

The Round 11 zero-observation startup finding is resolved for both unavailable bootstrap and replacement-runtime handoff. Each new logical runtime generation that has no attachable coordinator receives exactly one bounded runtime-level unavailable marker. An injected failed retry retains that marker; the first successful retry creates the original logical recording as a partial `midRuntimeRetry` recording, owns exactly one recording-level `storageUnavailable` gap, and creates no device row; a later retry does not duplicate the gap. The existing accepted-coordinator start-failure path continues to use its separate coordinator-local marker, so the two ownership paths do not double-count the same interval.

No new correctness, testing, determinism, or evidence-accuracy issue was found across the active change. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. They are neither findings nor represented as passing evidence here.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and task plan; the relevant current production, test, packaging, operator-documentation, and evidence tree; all three Round 11 implementation-review reports; `implementation-remediation-round11.md`; and `implementation-validation-round12.md`.

The review retraced `NW-LSS-IMPL-R11-ARCH-001`, the Round 10 initial-admission and lifecycle-prefix findings, and the earlier recovery, queue, writer-ordering, schema, shutdown, settings-supersession, and diagnostic findings. It re-audited generation identity, marker creation and saturation, recovery claim/restore/consume transitions, replacement handoff, late callbacks, recording/device materialization, idempotence, test synchronization, exact database assertions, skip accounting, and broader requirements-to-evidence coverage.

## Round 11 Finding Disposition

### `NW-LSS-IMPL-R11-ARCH-001` — resolved

`ViewerStoreRuntime.runtimeStarted` now distinguishes a new logical runtime generation from a repeated callback. It adds one missed observation only when the generation is new and the current coordinator is absent or belongs to another runtime. An attachable coordinator receives no runtime-level marker; if its accepted asynchronous start later fails, the coordinator-local marker from Round 10 remains the sole owner. This prevents both the previously missing zero-observation gap and a duplicate marker on the accepted-start path.

`beginRecoveryAttemptLocked` moves the exact aggregate into a generation-bound in-flight claim and clears the live counter. `completeRecoveryAttempt` clears the claim after success, or saturating-merges it with observations received during the attempt after failure. Its identity guards require the same recovery generation, coordinator object, runtime logical ID, and coordinator runtime ID. Obsolete completion therefore cannot publish into a replacement generation.

Fresh-coordinator recovery passes the original runtime logical ID, start wall time, and start monotonic time directly from the retained `RuntimeContext` into `recoverRuntimeAndSessions`. That operation first creates the partial recording, then any still-live devices, then the recording-level unavailable gap, and reports success only after all required ownership exists. With no device observation, the sessions snapshot is empty and no device is fabricated.

## Zero-Observation Path Verification

### Unavailable bootstrap

The bootstrap regression begins against a rejected schema, so no coordinator is attachable. It emits no device, Event, policy, drop, or lifecycle callback. The new generation contributes exactly one marker. After schema repair, the injected first retry fails before any recording exists; unavailable status and a zero recording count prove that failure was not published as recovery. The later retry creates exactly one logical recording with `durableStartReason = midRuntimeRetry`, one recording-level gap whose aggregate count is one, and zero device rows. A later explicit retry crosses the preparation prefix and leaves the logical recording's gap aggregate at one.

### Replacement-runtime handoff

The replacement regression starts a new runtime while the coordinator still belongs to its predecessor. The new generation is therefore nondurable and receives exactly one marker without any replacement journal callback. The module-internal reopen execution gate pauses after old-runtime cleanup and before replacement construction, allowing the test to arm the exact next write failure without a timing race. The failed attempt leaves the replacement with zero active recording rows and unavailable status. The next retry creates one active replacement recording, one recording-level gap with aggregate one, and zero devices. A later retry leaves the gap unchanged, and repeated cleanup for the old logical ID neither closes nor attaches the replacement recording.

### Exact aggregate of three

`testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes` now has three causally distinct observations:

```text
1 new-generation initial outage marker
+ 1 policy callback before the failed retry
+ 1 policy callback after the failed retry
= 3 recording-level unavailable observations
```

The failed retry does not consume the first two observations. The policy callback received after failure joins the restored aggregate, and the first successful materialization records an exact recording-level sum of three. The updated expectation is semantically required rather than a relaxed assertion.

## Determinism and Assertion Audit

- `OneShotViewerStoreFault` is lock-protected and consumes exactly the next armed write-gate check. Both zero-observation tests wait for its exact failure count and for recovery to leave the in-flight state before inspecting the database.
- `ArmableViewerExecutionGate` is no-op by default. In the replacement regression it blocks exactly the first armed reopen execution, signals entry, and resumes only after the fault is armed. The failure cannot race ahead of the test setup.
- The bootstrap and replacement tests query the gap through the exact logical recording ID and restrict it to recording-level `storageUnavailable` rows. Because gap counts are positive, aggregate one also proves exactly one owned observation rather than two partial rows.
- Both paths assert zero durable devices. Bootstrap additionally asserts exactly one `midRuntimeRetry` recording; replacement asserts exactly one active recording for the replacement logical ID and later proves stale old-runtime cleanup leaves it active.
- The later-retry assertions wait behind the current preparation prefix before checking the unchanged gap. They do not infer completion from queue admission alone.
- The two direct regressions passed 100 iterations each in the saved Round 12 validation and again in this independent 200-test stress run. No timeout was widened and no retry loop, sleep, or scheduling assumption masks the intended edges.

## Prior Findings and Broader Correctness Recheck

- The accepted-coordinator initial failure still records exactly one coordinator-local marker. Its failed retry retains the marker; its first success owns one partial recording and recording-level gap; it creates no device.
- The saturated same-coordinator regression still establishes its exact accepted lifecycle prefix before arming the retry failure. Its final recording-level sum remains six: one coordinator-local initial marker plus five rejected lifecycle observations, with exactly one durable device and no duplication.
- Fresh recovery claims remain generation-bound and preserve observations that arrive during a failed or successful attempt. The corrected aggregate-three regression covers restoration plus a new observation after failure.
- Writer-first migration and schema acceptance still precede both readers. Rejected or incomplete schemas never expose a reader and are not recreated destructively.
- Runtime shutdown still invalidates maintenance recovery, reaches maintenance quiescence, and performs one finite terminal flush before closing the pool. Late work cannot commit after the terminal boundary.
- Newer storage-setting revisions still revoke queued and running recovery publication. Writer generations continue to reject preselected or stale automatic work after failure.
- The preparation-prefix seam remains internal, reservation-free, and conservative. It proves completion of the already accepted lifecycle prefix without claiming a whole-pipeline suffix boundary.
- Change-snapshot diagnostics remain content-free while retaining trusted callback values. Query/export leases, frozen keysets, cancellation, retention, quota/reclaim, revision-safe deletion, path ownership, rollback, and SQLite failure classification showed no regression in source inspection or complete tests.
- No persistence callback gained protocol authority over sequence, queues, tokens, mailbox admission, timeouts, or terminal state. The remediation remains Viewer-only and adds no Core/SDK persistence dependency or public API.

## Evidence Accuracy

`implementation-validation-round11.md` now marks its results as superseded by Round 12 because the later architecture review found the zero-observation runtime-level gap. `implementation-remediation-round11.md` and `implementation-validation-round12.md` accurately describe the new generation marker, both deterministic regressions, the 200-test stress run, and the changed aggregate expectation of three.

The Round 12 validation explicitly records the earlier focused failure caused by the obsolete expected aggregate of two and does not present it as passing. It separately identifies the one live-resource-audit skip, seven environment-dependent SwiftPM skips, two excluded configured-signing tests, and unchanged-input CocoaPods applicability. No historical failure, excluded probe, or environment limitation is represented as a fresh pass.

## Fresh Validation

### Independent 200-test stress run

The two zero-observation regressions ran 100 iterations each using a separate derived-data directory:

```text
ViewerStoreTests: 200 tests, 0 failures
3.195 seconds test execution
/tmp/NearWireViewerRound12CorrectnessStress/Logs/Test/Test-NearWireViewer-2026.07.13_13-11-25-+0800.xcresult
** TEST SUCCEEDED **
```

### Focused recovery and prior-finding combination

The independent focused command selected both Round 11 regressions and the eight applicable Round 9/10 recovery and queue regressions:

```text
ViewerStoreTests: 10 tests, 0 failures
0.226 seconds test execution
/tmp/NearWireViewerRound12CorrectnessStress/Logs/Test/Test-NearWireViewer-2026.07.13_13-12-02-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Complete unsigned Viewer regression

```text
ViewerStoreTests: 79 tests, 1 explicit live-resource-audit skip, 0 failures
NearWireViewerTests.xctest: 160 tests, 1 explicit live-resource-audit skip, 0 failures
6.688 seconds test execution
/tmp/NearWireViewerRound12CorrectnessStress/Logs/Test/Test-NearWireViewer-2026.07.13_13-12-11-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

The configured-signing and stable-signer probes were explicitly excluded. They are not counted as passing or skipped. The one live-resource-audit skip is not represented as a pass.

### Complete Swift package regression

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound12ModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMRound12ModuleCache swift test --disable-sandbox --skip-build --scratch-path /tmp/NearWireSwiftPMRound12FullBuild
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
1.950 seconds test execution
exit 0
```

The seven environment-dependent skips are not represented as passes.

### Specification, structure, and hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches

find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print
exit 0, no output
```

## Completion Gate

Round 12 correctness/testing review is approved with exactly zero unresolved actionable findings. This report satisfies the correctness/testing dimension of the fresh implementation-review round; architecture/API and security/performance/documentation remain independently owned review dimensions.
