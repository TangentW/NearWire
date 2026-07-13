# Independent Implementation Review — Round 6 — Correctness and Testing

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 2 — 0 High, 2 Medium, 0 Low.**

The Round 5 shutdown and late-runtime findings are resolved. The saved 100-iteration result was inspected at the individual test-status level, and a fresh independent 100-iteration execution also passed. The one-attempt shutdown, writer-serialized physical plans, bounded maintenance fallback, reflection correction, and recorded complete validation are otherwise supported by the current implementation and tests.

Two correctness gaps remain outside those repaired cases: the shared write-failure classifier cannot distinguish SQLite lock failure from an ordinary revision/lease conflict and is bypassed by manual deletion, and production drop journaling emits per-callback deltas despite the accepted cumulative-sample design.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred by user direction to the goal-level `release-hardening` change. They are neither findings nor represented as passing in this report.

## Scope

This review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and tasks; the complete current production, test, packaging, and operator-documentation diff; all three Round 5 implementation reports; `implementation-remediation-round5.md`; `implementation-validation-round6.md`; and `resource-filesystem-audit-round6.md`.

The review retraced runtime-generation ownership, shutdown work and retry boundaries, SQLite transaction rollback and failure classification, manual-delete and orphan-reconciliation disk admission, maintenance action planning and fallback, direct-carrier reflection, drop/policy observation semantics, current regression coverage, saved result bundles, and complete package validation.

## Round 5 Remediation Disposition

### Late-runtime replacement regression — resolved

The prior intermittent assertion was caused by an invalid test timestamp: the fixture used wall times near the Unix epoch while startup/dirty maintenance used the real current date, allowing valid seven-day retention cleanup to remove the newly closed recording before the assertion. The fixture now derives lifecycle values from the current wall clock without increasing its wait timeout.

The saved result bundle at `/tmp/NearWireViewerRound5FixDerived/Logs/Test/Test-NearWireViewer-2026.07.13_09-20-58-+0800.xcresult` was inspected through its legacy test-summary object. It contains exactly 100 `testStatus` entries for `testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime`, all 100 are `Success`, and none is `Failure`. A fresh independent `-test-iterations 100` execution also exited 0.

Evidence: `ViewerStoreTests.swift:740-822`; `implementation-remediation-round5.md:32-41`.

### One-attempt shutdown — resolved

`ViewerStoreCoordinator.runtimeEnded` now invokes `ingress.flush()` exactly once. It no longer calls `eventStore.retry()`, `ingress.retry()`, or a second flush after terminal failure. It closes maintenance ownership and the SQLite pool after the finite result. The three new regressions cover a failure created by the shutdown prefix, a prefix already in `writeFailed`, and capacity failure followed by next-open orphan reconciliation.

Evidence: `ViewerStoreCoordinator.swift:615-696`; `ViewerStoreTests.swift:3222-3358`.

### Writer-serialized physical plans — resolved in the reported paths

Manual deletion now performs its structural disk-reserve check inside the writer executor immediately before `BEGIN IMMEDIATE`. Orphan reconciliation selects the bounded child group, calculates the exact child-plus-parent quota plan, checks logical and physical admission, and begins its transaction on the same writer turn. The interleaving and exact-plan tests exercise these production paths.

Evidence: `ViewerStoreMaintenance.swift:404-457`; `ViewerStoreCoordinator.swift:950-1038`; `ViewerStoreTests.swift:3135-3220`.

### Maintenance fallback below a blocked expensive plan — resolved

The production `run` campaign catches capacity admission at tombstone-selection and physical-reclaim boundaries and permits one eligible floor-only action for that turn: passive checkpoint first, then incremental vacuum. The eight-turn campaign remains bounded and the fallback performs no logical selection. Its regression drives the production `run` path and proves that free-page work progresses while the blocked Event and tombstone remain intact.

Evidence: `ViewerStoreMaintenance.swift:212-276`; `ViewerStoreTests.swift:2959-3054`.

### Direct-carrier reflection and decoder test correction — resolved

The active Event envelope, context, record, single/batch payload, frame, decoded/admitted message, and frame-decoder carriers now expose bounded content-free descriptions and mirrors. The Core secret-marker regressions cover the direct carriers. The lane-preflight regression uses the supported `retainedByteCount` accounting seam and correctly expects only the four-byte parsed length prefix after failure rather than depending on private `Mirror` layout.

Evidence: `EventEnvelope.swift:138-183`; `WireEventPayloads.swift:341-555`; `WireFrame.swift:11-19,102-111,485-494`; `WireMessage.swift:92-99,533-542`; `EventEnvelopeTests.swift:7-28`; `WireEventTests.swift:8-41`; `WireFrameTests.swift:319-342`.

## Findings

### NW-LSS-IMPL-R6-CT-001 — Medium — Write-failure classification loses error origin and manual deletion bypasses it

`ViewerStoreWriteFailureDisposition` classifies `.busy` as operation-local for an interactive mutation. That is correct for a stale recording revision, an active/read lease, or another expected user-operation conflict. However, `ViewerSQLiteConnection.map` maps real `SQLITE_BUSY` and `SQLITE_LOCKED` results to the same `.busy` value. A lock failure from `BEGIN IMMEDIATE`, a statement, or `COMMIT` therefore reaches `capacityCheckedWrite` as indistinguishable from a stale revision and leaves the authoritative store state unchanged.

This contradicts both the design's bounded SQLite-busy failure boundary and the Round 5 remediation claim that storage/I/O failures become `writeFailed` while only stale revision and lease contention remain local. A real busy/locked writer may consequently remain presented as available and later ingress may continue automatically instead of waiting for a successful explicit recovery boundary.

The supposedly shared classifier also does not cover `requestDelete`. Manual deletion performs its writer-serialized reserve and rolls back its transaction, but any capacity, corruption, busy/locked, or unavailable-store error simply escapes. It does not report `capacityPaused` or `writeFailed` through `storeStateReporter`. The current mutation-failure regression exercises only `capacityCheckedWrite` through `updateRecording`, injecting `.unavailable` before begin/body/commit and one stale-revision control; it cannot reveal either gap.

Required remediation:

1. Preserve failure origin in the error model. For example, distinguish SQLite `BUSY/LOCKED` from operation conflicts instead of using one `.busy` case for both.
2. Classify SQLite lock/storage/corruption/unavailable failures as `writeFailed`; keep stale revision, active/lease contention, cancellation, work limits, and invalid caller input operation-local as specified.
3. Route manual-delete mutation failure through the same authoritative classification and safe status signal while preserving its single-use confirmation and rollback semantics.
4. Add deterministic tests for an actual SQLite writer lock at `BEGIN` or statement/commit time and injected capacity/corruption/unavailable failures in `requestDelete`. Assert rollback, exact safe state, no automatic ingress retry, and unchanged stale-revision/lease behavior.

Evidence: `ViewerSQLite.swift:5-43,354-369`; `ViewerStoreMaintenance.swift:404-457,910-982`; `ViewerStoreTests.swift:3056-3133`; `implementation-remediation-round5.md:23-30`; `design.md:100`.

### NW-LSS-IMPL-R6-CT-002 — Medium — Live drop journaling stores deltas instead of cumulative samples

The accepted schema/design defines drop samples as **monotonic cumulative** queue/drop observations emitted only when their persisted value changes. Production emits the amount added by each callback instead:

- local loss first merges `added` into the cumulative `localDrops`, but builds every `ViewerDropJournalSample` from `added` rather than the updated cumulative fields;
- remote summaries increment only one aggregate `remoteDroppedEvents` counter, while the per-reason journal samples carry each incoming summary's delta and no cumulative per-reason state is retained.

For example, two local overflow callbacks adding 2 and 3 persist samples `2, 3`, not the required monotonic cumulative series `2, 5`. Repeated remote summary values can likewise produce a nonmonotonic or repeated per-reason series. This weakens the durable analysis foundation and makes a row ambiguous as a point-in-time counter versus a delta, especially across a missed sample/gap.

Current tests do not exercise the production session-to-store drop path. The store-level idempotence test manually inserts one arbitrary drop count, and `FlowJournalBox.dropsChanged` is an empty method, so neither local nor remote repeated changes assert cumulative, saturating, per-reason behavior.

Required remediation:

1. Emit the post-merge saturating cumulative count for each local reason.
2. Retain bounded saturating cumulative remote counters per persisted reason and emit their updated values.
3. Add session/journal integration tests with repeated local and remote drops, zero/no-change callbacks, saturation boundaries, and one rejected journal observation followed by a later sample. Assert a monotonic cumulative series and the appropriate gap without changing protocol counters or ownership.

Evidence: `ViewerMultiDeviceSession.swift:527-546,1095-1121`; `design.md:62-67,80-86`; `ViewerStoreTests.swift:246-356`; `ViewerFlowControlTests.swift:1437-1442`.

## Fresh Validation

### OpenSpec and diff hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output
```

### Fresh 100-iteration late-runtime regression

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj \
  -scheme NearWireViewer \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerRound6ReviewDerived \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache \
  test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime \
  -test-iterations 100 \
  -quiet
```

Result:

```text
Running tests repeatedly 100 times.
exit 0
```

### Fresh focused ViewerStore regression

A fresh focused command explicitly excluded the opt-in live Application Support audit and executed the remaining 55 `ViewerStoreTests`. It exited 0 with no failure. The separate live-path audit remains documented in `resource-filesystem-audit-round6.md`.

### Saved complete unsigned Viewer regression

The saved Round 6 result bundle was inspected directly:

```text
/tmp/NearWireViewerRound6Derived/Logs/Test/Test-NearWireViewer-2026.07.13_09-23-02-+0800.xcresult
testsCount: 133
status: succeeded
```

This command excluded the two configured-signing probes rather than counting them as passing or skipped.

### Fresh complete root Swift package regression

```text
NearWirePackageTests.xctest: 533 tests, 7 skipped, 0 failures
All tests: 533 tests, 7 skipped, 0 failures
exit 0
```

The sandbox cache warnings were non-gating and all build/scratch output remained under `/tmp`.

## Completion Gate

Round 6 correctness/testing approval requires both findings to be remediated, affected and complete validation to be refreshed, and a new independent review round to report exactly zero unresolved actionable findings.
