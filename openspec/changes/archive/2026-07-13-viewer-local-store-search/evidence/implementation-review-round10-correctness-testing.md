# Independent Implementation Review — Round 10 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, 0 Low.**

All five Round 9 findings are resolved in their reported paths. Writer migration and schema acceptance now precede reader construction; maintenance reaches queue quiescence before the terminal flush; recovery keeps a generation-bound missed-observation claim until materialization completion; a newer settings revision revokes queued and running recovery publication; and the latest-only change snapshot retains its trusted refresh values while exposing content-free diagnostics. The validation-discovered synchronization correction is also sound: the affected regression now waits for the exact injected failure before waiting for recovery completion, and it passed both the seven-test combination and the complete Store suite.

One adjacent lifecycle-recovery defect remains. An asynchronously failed initial recording admission is still acknowledged only at the preparation-queue boundary and does not establish any bounded outage/gap ownership. A successful retry with no intervening device or Event observation therefore creates a partial recording with no `storageUnavailable` gap, contrary to the synchronized capability, design, and operator documentation.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. They are neither findings nor represented as passing evidence here.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and task plan; the current production, test, packaging, operator-documentation, and evidence tree; all three Round 9 implementation-review reports; `implementation-remediation-round9.md`; `implementation-validation-round10.md`; and the latest synchronized design/spec text.

The review retraced every Round 9 finding and re-audited requirements-to-tests, lifecycle and writer ordering, initial and mid-runtime recovery, queue admission versus operation completion, missed-observation ownership, settings supersession, shutdown, schema rejection, callback diagnostics, concurrency/failure paths, skip accounting, and evidence accuracy across the complete change.

## Round 9 Finding Disposition

- **`NW-LSS-IMPL-R9-ARCH-001` — resolved.** `runtimeEnded()` invalidates pending recovery and dirty successors, `waitForQuiescence()` establishes a serial maintenance-queue barrier, and the coordinator crosses that barrier before its one terminal ingress flush. The coordinator-level regression blocks a campaign before execution, starts shutdown, proves zero terminal writer turns while maintenance owns the queue, then proves one terminal flush and no dirty-successor execution.
- **`NW-LSS-IMPL-R9-ARCH-002` — resolved.** `ViewerSQLitePool` opens only the writer, migrates and probes the schema, publishes `schemaAccepted`, and only then opens the query and export readers. The construction-order regression covers first creation, reopen, unknown-newer schema, and invalid version-zero migration; both rejection paths stop after `writerOpened`.
- **`NW-LSS-IMPL-R9-ARCH-003` — resolved for the reported retry paths.** `ViewerStoreRuntime` moves the missed count into a generation-bound claim, and `recoverRuntimeAndSessions` completes only after the recording, required live devices, and bounded gap ownership are established. Admission/materialization failure merges the claim back with observations received during the attempt using checked saturation. Fresh-coordinator and same-coordinator tests prove no premature available state, exact retained counts, causal device materialization, and no duplicate live device row. The finding below concerns the earlier initial-start operation, which still has no completion result.
- **`NW-LSS-IMPL-R9-CT-001` — resolved.** Settings triggers carry the runtime revision; a newer settings edit replaces a pending recovery even when it has no permit; and a running campaign checks the revision before and after the publication seam. Both queued and running supersession regressions preserve the failed relay/status and automatic-ticket rejection, then prove a later current revision can recover.
- **`NW-ISPD9-001` — resolved.** `ViewerStoreChangeSnapshot` has closed description/debug/reflection. Its focused regression proves the callback consumer still receives the exact internal row IDs while description, reflection, interpolation, and mirror children reveal neither IDs nor Event content.
- **Validation-discovered test synchronization defect — resolved.** `OneShotViewerStoreFault` signals when the intended failure is consumed, and `testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork` waits for that signal and then for `isRecoveryInFlight == false`. It no longer assumes a saturated preparation prefix drains within a generic status poll. The test passed independently, in the seven-test combination, and in the complete Store suite.

## Finding

### NW-LSS-IMPL-R10-CT-001 — Medium — Failed initial recording admission can leave a known unavailable interval without its required gap

`ViewerStoreCoordinator.runtimeStarted` returns the Boolean result of `preparationQueue.offer`, not the result of the queued recording admission. Inside the accepted closure it sets the logical runtime identity, calls `ensureRecording(partial: false)` through `try?`, and discards any materialization failure (`ViewerStoreCoordinator.swift:240-253`). `ViewerStoreRuntime.runtimeStarted` consequently clears its missed count and sets `coordinatorNeedsRecovery = false` as soon as that queue offer succeeds (`ViewerStoreCoordinator.swift:1423-1474`). A writer failure still closes the authoritative store relay, so networking remains safe, but neither the runtime recovery claim nor the coordinator's unavailable-observation aggregate owns the known initial outage.

On a later explicit retry, the coordinator can successfully call `ensureRecording(partial: true)` and reopen the store. That function creates a `storageUnavailable` gap only when `nondurableUnavailableCount > 0` (`ViewerStoreCoordinator.swift:852-883`). The failed initial admission never increments that count. Therefore, when no device/session/Event callback occurs between the failed start and the successful retry, the database contains the original partial recording but zero `storageUnavailable` gap rows. The active requirement says a successful same-runtime retry materializes the original identity/time **and one coalesced unavailable gap** (`specs/viewer-local-store-search/spec.md:29-33`); the design and operator guide make the same unconditional claim (`design.md:48-52`; `Documentation/Viewer-Local-Store.md:25-27`).

This path is not covered by the current tests. `testUnavailableRuntimeReopensAfterExplicitRetry` and `testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes` deliberately add a policy observation before retry, so their claimed count is nonzero. `testDirectMaterializationFailureAndFailedRetryCannotReopenIngress` proves state and recording recovery but does not assert an unavailable gap. The same-coordinator failed-recovery regression adds repeated session observations. None injects an asynchronously failed initial `ensureRecording`, performs no intervening journal callback, retries successfully, and asserts exactly one bounded gap.

Required resolution:

1. Give the accepted initial runtime-start work a completion/ownership result, or retain a bounded coordinator-local outage marker when its recording admission fails. Queue admission must not erase the known unavailable interval.
2. On successful same-runtime retry, materialize the original recording and exactly one coalesced `storageUnavailable` gap even when the missed-Event count is zero, without inventing a device row or unbounded per-callback state.
3. Add a deterministic regression for: initial start offer accepted; recording write fails asynchronously; no device/Event callback occurs; outward storage remains unavailable; retry succeeds; the original logical recording is partial and exactly one bounded unavailable gap exists. Also prove a failed retry retains that marker and a second successful retry does not duplicate it.

## Rechecked Correctness and Test Boundaries

- Maintenance invalidation, serial-queue quiescence, preparation finish, finite ingress flush, pool close, and next-open orphan reconciliation preserve the required device-before-recording and no-post-flush ordering in the covered runtime path.
- Writer failure classification still advances the relay generation before releasing the serial writer turn. Preselected ingress, direct mutation, maintenance, capacity, and stale-permit tests preserve rollback and authorization boundaries.
- Recovery callbacks are tied to runtime/coordinator generations. Failed completion restores the claimed aggregate with saturating arithmetic; observations arriving during successful recovery keep the runtime unavailable for a later explicit retry.
- Settings comparison, persistence, revision capture, owner-side pending replacement, and pre/post-publication revision checks form one bounded supersession protocol. Nonrecovering settings edits cannot complete an older recovery permit in the tested queued or running paths.
- Unknown, incomplete, and migration-rejected schemas never open a reader. Successful construction owns exactly three serial connections after acceptance and unwinds local connection ownership on construction failure.
- Callback diagnostics are closed while trusted values remain intact. No regression was found in query/export keysets, leases, quota/reclaim, ingress retention, transition/drop gaps, cancellation, export atomicity, SQLite path security, or protocol/store authority separation.
- The Round 10 validation report accurately distinguishes the failed pre-correction focused attempt, the earlier wrong signing-test exclusions, the final passing unsigned suite, environment-dependent skips, and the unavailable current CocoaPods rerun. It does not represent those failures, exclusions, or deferred signing probes as passes.

## Fresh Validation

### Focused Round 9 remediation regressions

Fresh command selected the same seven remediation tests from `implementation-validation-round10.md` using an independent derived-data directory:

```text
ViewerStoreTests: 7 tests, 0 failures
0.140 seconds test execution
/tmp/NearWireViewerRound10CorrectnessReview/Logs/Test/Test-NearWireViewer-2026.07.13_12-35-14-+0800.xcresult
** TEST SUCCEEDED **
```

### Complete Store regression

```text
xcodebuild ... test -only-testing:NearWireViewerTests/ViewerStoreTests
ViewerStoreTests: 79 tests, 1 explicit live-resource-audit skip, 0 failures
4.160 seconds test execution
/tmp/NearWireViewerRound10CorrectnessReview/Logs/Test/Test-NearWireViewer-2026.07.13_12-35-46-+0800.xcresult
** TEST SUCCEEDED **
```

The skip is the explicit machine-local Application Support audit marker and is not represented as a pass.

### Complete Swift package regression

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMModuleCache swift test --disable-sandbox --skip-build --scratch-path /tmp/NearWireSwiftPMRound10FullBuild
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
1.947 seconds test execution
exit 0
```

The seven environment-dependent skips are not represented as passes.

### Specification and hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches
```

## Completion Gate

Round 10 correctness/testing approval requires remediation of `NW-LSS-IMPL-R10-CT-001`, focused coverage of the zero-observation initial-outage path, fresh affected and complete validation, and a new independent correctness/testing review reporting exactly zero unresolved actionable findings.
