# Independent Implementation Review — Round 13 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

Both Round 12 architecture findings are resolved. A coordinator detached after a completed runtime now leaves one bounded reopen-on-next-runtime reason; the next distinct runtime schedules at most one automatic reopen, while initial bootstrap/path/schema failure remains explicit-retry-only. A failed automatic reopen retains the new runtime's exact marker for a later explicit retry. Repeated same-logical-ID start callbacks now return before changing the original context, recovery authority, in-flight claim, sessions, or coordinator ownership.

The four new regressions have strong state, identity, time, gap, and composition assertions and deterministic execution gates. The initially failed four-test run is accurately explained by two test-only assumptions and is not represented as passing evidence. No new correctness, testing, determinism, or evidence-accuracy issue was found across the active change.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. They are neither findings nor represented as passing evidence here.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, capability specifications, and tasks; the relevant current production, test, application-composition, documentation, and evidence tree; the Round 12 architecture/API report; `implementation-remediation-round12.md`; and `implementation-validation-round13.md`.

The review retraced `NW-LSS-IMPL-R12-ARCH-001` and `NW-LSS-IMPL-R12-ARCH-002`, then re-audited sequential runtime shutdown/start, automatic reopen success and failure, explicit recovery, same-generation start idempotence at all three required timing points, Viewer application Retry, TLS identity reset, generation claims, original recording identity/time, exact gap ownership, device non-invention, later-retry idempotence, deterministic gates, and all prior recovery and queue invariants.

## Round 12 Finding Disposition

### `NW-LSS-IMPL-R12-ARCH-001` — resolved

When a runtime-owned coordinator detaches, `detachRuntime` now sets `needsRuntimeReopen = true` whether or not a successor context already exists. It does not reopen an idle store: `runtimeEnded` immediately calls `retryStorage` only when a successor context is already present. If there is no successor, the reason remains bounded as one Boolean until the next distinct runtime begins.

The next distinct runtime creates its one generation-level unavailable marker and observes both `coordinator == nil` and the retained reopen reason. It therefore schedules one attempt through the existing `reopenScheduled` gate. The attempt is asynchronous on the single reopen queue and introduces no polling, timer, recursive retry, or unbounded work. Initial bootstrap/path/schema failure does not set this reason, so its explicit-retry boundary is unchanged.

Successful replacement construction installs the coordinator for the current logical runtime, moves the exact marker into a generation-bound claim, materializes the partial recording and recording-level gap, then publishes availability only through the matching completion. Construction or recovery failure either leaves the marker live or restores the claimed value. A later explicit retry can consume it only after durable ownership succeeds.

The direct success regression fully closes runtime A before starting runtime B on the same `ViewerStoreRuntime`. Without a storage retry call, A remains closed and B becomes one distinct active recording with one recording-level unavailable observation. The failure regression pauses the automatic B reopen before construction, injects the exact next write failure, proves B has no active recording and storage remains unavailable, then proves one explicit retry creates B with gap aggregate one and zero devices while A remains closed.

The application composition regression exercises the production ordering rather than calling the store runtime directly. One shared `ViewerStoreRuntime` is captured by three real `ViewerMultiDeviceSessionManager` generations. Viewer application Retry waits for the first cleanup before creating the second manager, and TLS identity reset waits for the second cleanup before creating the third. The assertions progress from one active recording, to one closed plus one active, to two closed plus one active, and finally three closed after termination. Identity load and TLS reset counters prove the intended application branches executed.

### `NW-LSS-IMPL-R12-ARCH-002` — resolved

`ViewerStoreRuntime.runtimeStarted` now compares the incoming logical ID while holding the runtime lock and immediately returns when it matches the retained context. The duplicate path executes before recovery invalidation, context assignment, session clearing, missed-count reset, coordinator selection, automatic reopen, coordinator forwarding, or status publication. It therefore preserves the first wall and monotonic timestamps and cannot clear `coordinatorNeedsRecovery`, alter an in-flight claim, or overlap runtime-level and coordinator-local markers.

The regression sends the same logical ID at all three required edges:

1. before the first reopen, with replacement timestamps;
2. while the reopen execution gate is paused, with another timestamp pair;
3. after the injected failed attempt has restored recovery ownership, with a third timestamp pair.

The later success persists the first values exactly: wall time `1_000`, monotonic time `2_000`, and `durableStartReason = midRuntimeRetry`. It also proves one logical recording-level gap with aggregate one, zero devices, and an unchanged gap after another retry. These assertions close both the timestamp-overwrite and stranded-marker forms of the finding.

## Determinism and Assertion Audit

- `ArmableViewerExecutionGate` is no-op by default and blocks exactly the first armed reopen turn. Both the repeated-start and failed-sequential tests wait for gate entry before arming the one-shot write fault, so the injected failure cannot be consumed by earlier work.
- `OneShotViewerStoreFault` is lock-protected, consumes one armed check, and exposes an exact failure count. Tests wait for that count and for recovery to leave the in-flight state before querying storage.
- The repeated-start test asserts the original logical ID through `recordingStart`, exact first wall/monotonic time, partial retry reason, recording-level gap aggregate one, zero device rows, and later-retry nonduplication.
- Sequential tests address recordings by distinct logical IDs and assert exact latest states. The automatic-success path proves A closed, B active, and B gap aggregate one. The failure path proves no B active row after failure, then B active with gap aggregate one after explicit retry, A still closed, and zero devices.
- Gap helpers join through the exact logical recording ID and restrict results to recording-level `storageUnavailable` rows. Positive gap counts make aggregate one an exact ownership assertion rather than a loose existence check.
- The application test uses an awaited Combine status observation on the MainActor, then polls only background storage state. It does not block the actor whose state transition it awaits.
- All four regressions passed 20 iterations each in the saved Round 13 validation and again in this independent 80-test run. The deterministic gates and assertions required no timeout increase, sleep, or generic status-only inference.

## Initial Failed Four-Test Attempt Audit

The saved explanation is consistent with the implementation and current evidence:

- The original sequential fixture used ancient synthetic wall times. Startup maintenance correctly applied the default seven-day retention policy and could reclaim closed runtime A before the assertion. Current tests use a real current wall time for retention-sensitive sequential recordings; this changes the fixture, not production retention or reopen behavior.
- The original application fixture synchronously polled while isolated to the MainActor. That prevented the application status transition it was waiting for. The current `waitForApplicationStatus` subscribes to the published status and awaits XCTest fulfillment, allowing MainActor work to progress.

Production source predates the failed run and was not changed by these fixture corrections; the test source and rebuilt test bundle are later. The corrected four-test run, 80-test stress run, focused 14-test combination, complete Store suite, and complete unsigned Viewer suite all use the corrected current tests. The failed result remains named in `implementation-validation-round13.md` and is not presented as passing.

## Prior Recovery and Whole-Change Recheck

- Zero-observation bootstrap and prior-runtime handoff still create exactly one generation marker, retain it through failed recovery, and consume it only after one partial recording and recording-level gap exist without an invented device.
- The accepted-coordinator asynchronous start-failure path still owns one separate coordinator-local marker. Runtime-level and coordinator-local ownership remain mutually exclusive.
- The saturated same-coordinator regression still establishes its accepted lifecycle prefix before the retry writer edge and ends with recording-level aggregate six plus exactly one durable device.
- The fresh-reopen aggregate remains exactly three: one initial generation marker and two deliberate policy observations across the failed attempt.
- Recovery completion still requires the same recovery generation, coordinator object, runtime logical ID, and coordinator runtime ID. Failed claims saturating-merge with later observations; obsolete callbacks cannot publish into replacement runtimes.
- Writer-first schema acceptance still precedes both readers. Shutdown still invalidates maintenance, reaches quiescence, and performs one finite terminal flush before pool close.
- Settings revisions still revoke queued and running stale recovery publication. Preparation-prefix ordering, writer authorization, change-snapshot redaction, query/export bounds, retention, quota/reclaim, cancellation, rollback, and filesystem ownership showed no regression.
- Storage remains an observer of protocol outcomes and cannot mutate sequence, queues, tokens, mailbox admission, timeouts, or terminal decisions. The remediation is Viewer-only and adds no public SDK/Core persistence surface.

## Evidence Accuracy

`implementation-validation-round12.md` now marks its results as superseded because the later Round 12 architecture review found the two adjacent lifecycle issues. `implementation-remediation-round12.md` and `implementation-validation-round13.md` accurately describe both fixes, all four regressions, the 80-test stress run, and the first failed attempt.

The Round 13 validation separately identifies the one explicit live-resource-audit skip, seven environment-dependent SwiftPM skips, two excluded configured-signing tests, and unchanged-input CocoaPods applicability. It does not represent the failed initial run, skipped audit, excluded signing probes, or historical package result as a fresh pass.

## Fresh Validation

To avoid unnecessary disk growth while `/tmp` remained constrained, this review reused the current Round 13 compiled Viewer/test products and ran `test-without-building`. The production binary is newer than the current production source, and the test bundle is newer than the current test source.

### Independent four-regression stress run

Each new regression ran 20 iterations:

```text
ViewerStoreTests: 80 tests, 0 failures
1.909 seconds test execution
/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-40-15-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Focused lifecycle and prior-recovery combination

The four Round 12 remediation regressions and all ten applicable Round 9 through Round 11 recovery/queue regressions ran together:

```text
ViewerStoreTests: 14 tests, 0 failures
0.304 seconds test execution
/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-40-36-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Saved complete current-tree Viewer evidence

The current compiled products used above came from the complete validation recorded in `implementation-validation-round13.md`:

```text
ViewerStoreTests: 83 tests, 1 explicit live-resource-audit skip, 0 failures
NearWireViewerTests.xctest: 164 tests, 1 explicit live-resource-audit skip, 0 failures
6.849 seconds complete Viewer test execution
** TEST SUCCEEDED **
```

The two configured-signing tests were excluded and are not counted as passing or skipped. The one live-resource-audit skip is not represented as a pass.

### Complete Swift package regression

```text
env CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound13ModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/NearWireSwiftPMRound13ModuleCache swift test --disable-sandbox --skip-build --scratch-path /private/tmp/NearWireSwiftPMRound13FullBuild
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
2.458 seconds test execution
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

Round 13 correctness/testing review is approved with exactly zero unresolved actionable findings. This report satisfies the correctness/testing dimension of the fresh implementation-review round; architecture/API and security/performance/documentation remain independently owned review dimensions.
