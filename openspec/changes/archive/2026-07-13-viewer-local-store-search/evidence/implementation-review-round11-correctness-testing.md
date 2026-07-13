# Independent Implementation Review — Round 11 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

The Round 10 initial-outage finding is resolved. An asynchronously failed initial recording admission now establishes one bounded coordinator-owned unavailable marker. A failed explicit retry retains that marker, and the first successful retry creates the original partial recording plus exactly one recording-level `storageUnavailable` gap without inventing a device. The saturated same-coordinator recovery regression now also proves the exact preparation-queue prefix before it observes retry admission and in-flight execution. Its final count is exactly six: one failed-start marker plus five rejected session observations, with exactly one durable device row.

All earlier Round 9 findings remain resolved. No new correctness, testing, or evidence-accuracy issue was found across the complete active change. Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. They are neither findings nor represented as passing evidence here.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, capability specifications, and task plan; the current production, test, packaging, operator-documentation, and evidence tree; all three Round 10 implementation-review reports; `implementation-remediation-round10.md`; `implementation-validation-round11.md`; and the synchronized historical evidence notes.

The review retraced both Round 10 findings and all Round 9 findings, then re-audited the complete requirement-to-test surface: initial and mid-runtime recovery, preparation and ingress admission, failure publication, exact missed-observation ownership, recording/device materialization, settings supersession, shutdown ordering, schema acceptance, change-snapshot diagnostics, query/export behavior, retention/capacity boundaries, cancellation, skip accounting, and evidence accuracy.

## Round 10 Finding Disposition

- **`NW-LSS-IMPL-R10-CT-001` — resolved.** The accepted runtime-start closure catches an initial `ensureRecording` failure and records one coordinator-local nondurable observation at the original runtime-start time. Failed retries return before clearing that aggregate. The first successful retry creates the original logical recording with `partial = true`, writes exactly one recording-level `storageUnavailable` gap, and then clears the aggregate. The standalone regression proves failure, failed retry, and success in sequence; the final database has one partial `midRuntimeRetry` recording, gap sum one, and zero device rows.
- **`NW-ISPD10-001` — resolved.** `afterCurrentPrefix` places a callback on the same serial preparation queue behind the already accepted lifecycle prefix without reserving pipeline capacity. The saturated regression enqueues the barrier only after all 40 lifecycle offers have returned, releases the blocked initial writer, waits for that prefix barrier, and only then arms and admits a second blocking writer failure. Entry into that second fault proves the retry writer turn was admitted; `isRecoveryInFlight == true` proves the recovery generation owns it. Releasing the second failure proves failed completion, retained ownership, and a later successful retry.

## Exact Failure and Recovery Accounting

### Zero-observation initial outage

The standalone path contains no device, Event, policy, drop, or lifecycle observation between initial start and recovery:

1. Runtime-start preparation is accepted, but its recording write fails asynchronously.
2. The coordinator retains one bounded unavailable marker and the store relay remains unavailable.
3. The first explicit retry also fails. No recording is materialized and the marker remains one.
4. The next retry succeeds. It creates one partial `midRuntimeRetry` recording and one recording-level gap whose aggregate count is exactly one.
5. No device row is created because no device observation exists.

The source path is idempotent after materialization: `ensureRecording` returns the existing recording, the unavailable aggregate has already been cleared only after its gap commit, and an already-available relay does not publish another recovery transition. The regression's exact final count also proves that the failed retry neither dropped nor duplicated the marker.

### Saturated same-coordinator outage

The shared structural budget is 36. The accepted runtime-start turn owns one reservation, leaving 35 accepted session lifecycle observations from the 40 offered and five rejected observations. The exact durable accounting after recovery is therefore:

```text
1 failed initial recording admission marker
+ 5 rejected session observations
= 6 recording-level unavailable observations
```

The one logical live device was already represented by the accepted lifecycle prefix. Recovery reuses that durable device instead of inventing or duplicating one, so the final database contains exactly one `DeviceSessions` row. The test separately proves zero recordings after the blocked failed retry, retained armed recovery, successful later recovery, recording-level gap sum six, and device-row count one.

The prefix barrier is conservative: it cannot run before the serial drain that owns the prefix, although it may wait behind later work. It does not consume one of the 36 structural reservations and has no production caller; it is an internal deterministic observation seam for the regression, not a second admission path.

## Prior Finding and Whole-Change Recheck

- Runtime shutdown still invalidates recovery, crosses maintenance-queue quiescence, and performs one finite terminal ingress flush before closing the pool. No post-flush maintenance writer can be published.
- Store construction still opens the writer, completes migration and schema probes, and publishes schema acceptance before opening either reader. Unknown, incomplete, and rejected schemas never open a reader.
- Fresh- and same-coordinator recovery claims remain generation-bound. Failed materialization restores claims using checked saturation; success publishes availability only after required recording, device, and gap ownership is durable.
- Newer settings revisions still revoke queued and running recovery publication. Both pre- and post-publication revision checks preserve the current failed state until a current explicit recovery succeeds.
- `ViewerStoreChangeSnapshot` retains the trusted recording and upper-row values required by consumers while description, debug description, reflection, and interpolation expose no IDs or Event content.
- Writer-generation checks still prevent preselected ingress and automatic work from committing after a writer failure. Direct mutations, maintenance, capacity recovery, stale permits, and rollback behavior remain covered.
- Query and export leases, frozen keysets, bounds, cancellation, atomic export replacement, retention, quota, reclaim, revision-safe deletion, path ownership, and SQLite failure classifications showed no regression in source inspection or the complete suites.
- The active proposal, design, specifications, tasks, operator documentation, and current implementation agree on partial retry, one coalesced recording-level outage gap, bounded ownership, and no fabricated device. No requirement or scenario lacks proportionate evidence within the current change.

## Evidence Accuracy

`implementation-remediation-round9.md` now labels its earlier semaphore-only synchronization account as superseded. `implementation-validation-round10.md` withdraws that earlier completion claim and points to the Round 11 replacement. `implementation-validation-round11.md` accurately records that the first two-test attempt used the obsolete expected count of five and failed, while the corrected exact count of six passed. None of those historical failures is represented as passing evidence.

The Round 11 validation also distinguishes the one explicit live-resource-audit skip, the seven environment-dependent SwiftPM skips, and the two excluded configured-signing tests. The unchanged-input CocoaPods result is described as applicable rather than as a fresh pass. No discrepancy was found between the recorded commands, stated limitations, and the current tree.

## Fresh Validation

### Focused remediation and prior-finding regressions

The independent command selected the two Round 10 regressions and all six applicable Round 9 remediation regressions in one run using a separate derived-data directory:

```text
ViewerStoreTests: 8 tests, 0 failures
0.186 seconds test execution
/tmp/NearWireViewerRound11CorrectnessReview/Logs/Test/Test-NearWireViewer-2026.07.13_12-50-42-+0800.xcresult
** TEST SUCCEEDED **
```

### Complete Store regression

```text
ViewerStoreTests: 79 tests, 1 explicit live-resource-audit skip, 0 failures
3.978 seconds test execution
/tmp/NearWireViewerRound11CorrectnessReview/Logs/Test/Test-NearWireViewer-2026.07.13_12-51-07-+0800.xcresult
** TEST SUCCEEDED **
```

### Complete unsigned Viewer regression

The configured-signing and stable-signer probes were explicitly excluded, as required by the deferred goal boundary:

```text
NearWireViewerTests.xctest: 160 tests, 1 explicit live-resource-audit skip, 0 failures
6.290 seconds test execution
/tmp/NearWireViewerRound11CorrectnessReview/Logs/Test/Test-NearWireViewer-2026.07.13_12-52-52-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

The one skip is not represented as a pass. The two excluded signing tests are not counted as passed or skipped.

### Complete Swift package regression

```text
env CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/NearWireSwiftPMModuleCache swift test --disable-sandbox --skip-build --scratch-path /tmp/NearWireSwiftPMRound11FullBuild
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
2.158 seconds test execution
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

find . -name Package.swift -o -name '*.podspec'
./NearWire.podspec
./Package.swift
```

## Completion Gate

Round 11 correctness/testing review is approved with exactly zero unresolved actionable findings. This report satisfies the correctness/testing dimension of the fresh implementation-review round; architecture/API and security/performance/documentation remain independently owned review dimensions.
