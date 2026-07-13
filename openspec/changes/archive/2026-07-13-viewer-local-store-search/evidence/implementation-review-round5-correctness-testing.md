# Independent Implementation Review — Round 5 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

Reviewer scope: correctness and testing review of the current `viewer-local-store-search` implementation after Round 4 remediation. This review read the active proposal, design, capability specifications, tasks, current implementation, tests, operator documentation, all Round 4 review reports, the Round 4 remediation record, the Round 5 validation record, and the Round 5 resource/filesystem audit. Configured signing and signer-bound entitlement validation remain outside this review by the recorded user direction.

## Verdict

**Not approved.** There are **2 unresolved findings: 1 High and 1 Medium**.

The four correctness findings from Round 4 are remediated in the current tree and are not repeated. The remaining blocker is in the newly added shutdown behavior: it silently retries a terminal write failure even though the accepted specification permits only one flush attempt and requires a new explicit retry boundary. The related generation-isolation regression is also still observably flaky and the saved evidence overstates its stability.

## Round 4 Finding Disposition

### Same-coordinator recovery idempotence — resolved

`ViewerStoreCoordinator.recoverSession` now recognizes an already materialized `connectionID`, clears only stale nondurable state, and returns without creating another durable device session. `materializeSession` independently returns the existing device context for the same connection. `testSameCoordinatorRecoveryDoesNotDuplicateDurableLiveDevices` exercises a mixed durable/nondurable coordinator, repeated recovery, and shutdown, then verifies exactly one latest closed row for each logical device.

Evidence: `ViewerStoreCoordinator.swift:289-299,773-785`; `ViewerStoreTests.swift:889-950`.

### Metadata, annotation, and Event quota admission serialization — resolved

`ViewerStoreMaintenance.capacityCheckedWrite` performs quota projection, filesystem guard, transaction begin, mutation, and the one eligible cleanup retry on the writer executor. Recording metadata and annotation mutations use this shared path, so their admission is serialized with Event writes instead of racing on a stale quota snapshot. `testConcurrentMetadataAndEventCapacityAdmissionUsesWriterOrdering` covers annotation/annotation, annotation/Event, metadata/Event, eligible cleanup, and protected-capacity pause cases.

Evidence: `ViewerStoreMaintenance.swift:253-312,841-918`; `ViewerStoreTests.swift:1756-1907`.

### Validation before cleanup for every structural carrier — resolved

`ViewerEventStore.appendStructural` calls `validateStructuralObservation` before capacity projection or cleanup. Validation covers checked sequence arithmetic and monotonicity, bounded policy values, positive bounded drop data, and gap count/reason/time/direction/wire-sequence invariants. `testInvalidStructuralObservationsCannotTriggerCapacityCleanup` proves rejected carriers neither create tombstones nor change quota accounting.

Evidence: `ViewerEventStore.swift:486-494,772-860`; `ViewerStoreTests.swift:2254-2375`.

### 128-byte Event-prefix boundary — resolved

The query compiler permits a trailing dot only when the complete prefix is strictly shorter than 128 UTF-8 bytes. Boundary coverage accepts a 126-byte segment plus dot, rejects a 127-byte segment plus dot, and accepts valid 127-byte and 128-byte partial-segment prefixes.

Evidence: `ViewerStoreQuery.swift:293-306`; `ViewerStoreTests.swift:541-594`.

## Findings

### NW-LSS-IMPL-R5-CT-001 — High — Shutdown performs an unauthorized second write attempt after terminal failure

`ViewerStoreCoordinator.runtimeEnded` first awaits `ingress.flush()`. If that returns `.writeFailed`, it then ignores the result of `eventStore.retry()`, unconditionally resets the ingress with `ingress.retry()`, and calls `ingress.flush()` a second time:

```swift
var flushOutcome = await self.ingress.flush()
if flushOutcome == .writeFailed {
  try? self.eventStore.retry()
  self.ingress.retry()
  flushOutcome = await self.ingress.flush()
}
```

This is finite, but finiteness is not the complete contract. The design states that a failed prefix is retained for **one explicit retry boundary**, that automatic retry polling stops, and that only a user retry or a listed relevant data/configuration action may trigger a new attempt. The capability specification is even more direct: during shutdown, the exact finite prefix receives **one flush attempt**; failure releases resources and next-open reconciliation closes the orphan. Runtime shutdown is not itself an explicit retry action after that attempt has failed.

The ignored `eventStore.retry()` result makes the behavior less defensible: ingress is reset and another drain is attempted even when the store probe did not successfully re-establish writability. This can replay a failed prefix without an authorized recovery boundary and masks the underlying late-runtime race instead of preserving the specified failure outcome.

Required remediation:

1. Remove the implicit `eventStore.retry()` / `ingress.retry()` / second-flush sequence from terminal shutdown.
2. After the single shutdown flush reports failure, release all store resources without claiming unwritten closes; rely on next-open orphan reconciliation as specified.
3. Fix the late-generation lifetime/synchronization defect at its source rather than using a second persistence attempt as compensation.
4. Add a deterministic injected shutdown-failure test that proves exactly one writer attempt, no store or ingress retry, finite resource closure, no falsely persisted terminal row, and successful orphan reconciliation on the next open.

Evidence: `ViewerStoreCoordinator.swift:604-690`, especially `663-668`; `design.md:98-100`; `specs/viewer-local-store-search/spec.md:99-111,274-282`.

### NW-LSS-IMPL-R5-CT-002 — Medium — Late-generation shutdown regression remains flaky and its stability claim is unsupported

The current remediation record says the late-runtime regression “passed five consecutive iterations.” It does not preserve the command, result bundle, per-iteration results, or any other evidence for those five runs. More importantly, fresh independent execution does not reproduce that stability:

- A fresh focused 49-test `ViewerStoreTests` run failed `testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime`. Its wait expired and line 801 observed zero latest `closed` rows for the replacement logical recording instead of one.
- An immediate isolated rerun passed, demonstrating timing sensitivity rather than a stable deterministic failure.
- A subsequent isolated `-test-iterations 10` run failed the same test twice and exited 65.
- An independent `-test-iterations 20` reproduction failed iterations 12 and 13, producing four assertion failures in total: the bounded wait at helper line 3016 expired and line 801 observed zero closed rows instead of one in each failing iteration.
- A later focused suite invocation passed, confirming that the result is nondeterministic rather than repaired.

The assertion is checking durable lifecycle correctness, not incidental timing: the replacement runtime sometimes fails to reach the required closed recording state. A single green suite snapshot in `implementation-validation-round5.md` is valid as a point-in-time result, but it is not sufficient completion evidence for this known intermittent defect. The unsupported “five consecutive iterations” statement must not be used to claim remediation.

Required remediation:

1. Root-cause the generation/lifetime race and make the close contract deterministic; do not extend the polling timeout as a substitute.
2. Introduce deterministic synchronization or fault hooks that exercise old-runtime cleanup overlapping replacement-runtime start/end without scheduler luck.
3. Run the test both repeatedly and inside the complete Viewer suite, save the exact commands and result bundles, and update remediation/validation evidence to distinguish historical snapshots from current repeatability.

Evidence: `ViewerStoreTests.swift:726-805`, especially `789-803`; `implementation-remediation-round4.md:54-56`; `implementation-validation-round5.md:17-52`.

## Fresh Validation Performed

### OpenSpec and diff hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output
```

### Focused ViewerStore suite

The first fresh focused run executed the 49-test `ViewerStoreTests` target with the live Application Support audit skipped. It failed at `testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime`, with the replacement recording still not durably closed after the bounded wait. An immediate isolated rerun passed. A later focused suite invocation also passed, which confirms the intermittent nature of the defect but does not clear it.

### Repeated late-runtime regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerDerived \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache \
  test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime \
  -test-iterations 10 \
  -quiet
```

Result:

```text
Running tests repeatedly 10 times.
Failing tests:
  ViewerStoreTests.testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime()
  ViewerStoreTests.testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime()
** TEST FAILED **
exit 65
```

An independent 20-iteration reproduction produced the same defect with more precise iteration evidence:

```text
iterations 12 and 13 failed
4 assertion failures total
ViewerStoreTests.swift:3016: waitUntil timed out
ViewerStoreTests.swift:801: expected latest closed recording count 1, observed 0
```

### Signing exclusions

No finding is raised for configured signing or signer-bound entitlement validation. Those gates are explicitly deferred to the goal-level `release-hardening` change, and the unsigned commands used here do not claim to satisfy them.

## Completion Gate

Round 5 correctness/testing approval requires both findings above to be remediated, fresh deterministic regression evidence to be saved, and a new independent review round to report no unresolved finding.
