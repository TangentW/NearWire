# Implementation Review Round 11 — Security, Performance, and Documentation

Date: 2026-07-13

## Scope

This fresh independent review examined `AGENTS.md`; the complete current
`viewer-local-store-search` proposal, design, capability specifications, and task plan; the
current production, test, packaging, privacy-resource, operator-documentation, and evidence
tree; all three Round 10 implementation-review reports;
`implementation-remediation-round10.md`; `implementation-validation-round11.md`; and the
applicable live resource/filesystem audit. It retraced every Round 10 finding and re-audited
the current-prefix barrier, its only call site, the blocking admission/fault proof, the
initial-start outage marker, recovery ownership, shutdown and replacement safety, bounded
queue/task/work/memory behavior, reflection and diagnostics, SQLite and export filesystem
identity, privacy declarations, package boundaries, and documentation/evidence accuracy.

Production, test, specification, task, packaging, and operator-documentation files were not
modified. This report is the only file added by this review. Configured signing, entitlement
assertions, and the stable-signer update-boundary probe remain explicitly deferred by user
direction to goal-level `release-hardening`; they are neither findings nor passing results in
this report.

## Verdict

**Approved. No unresolved findings remain: zero high, zero medium, and zero low.**

## Round 10 Finding Disposition

- `NW-LSS-IMPL-R10-ARCH-001`: no finding was reported, and the current architecture/API
  review remains applicable. The Round 10-to-11 remediation does not add a public API,
  transport authority, SDK persistence surface, or new module boundary.
- `NW-LSS-IMPL-R10-CT-001`: resolved. A failed initial recording materialization now records
  one coordinator-local bounded unavailable marker. A failed retry cannot clear it; the first
  successful retry materializes the original logical recording and transfers that marker into
  one `storageUnavailable` gap without inventing an ended or absent device.
- `NW-ISPD10-001`: resolved. The same-coordinator regression no longer infers lifecycle-queue
  quiescence from store status. It installs a current-prefix barrier after the finite saturated
  offer prefix, waits for that prefix after releasing the initial write fault, and then uses a
  second blocking write fault to prove both recovery admission and in-flight claim ownership
  before allowing the intended failure. The exact focused command passed freshly, and the
  formerly failing test also passed five consecutive iterations in this review.

## Current-Prefix Barrier Audit

`ViewerJournalPreparationQueue.afterCurrentPrefix` asynchronously places a callback on the
same private serial dispatch queue that executes preparation work. The current implementation
has the following properties:

- It is internal to the Viewer implementation. Repository search found one caller only:
  `ViewerStoreTests.testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork`. There is
  no production call and no Core or SDK surface.
- It does not reserve pipeline count or bytes, insert a journal item, create a task per Event,
  or change the fixed 36-entry structural allowance. The call returns after one constant-time
  dispatch operation and does not block the caller.
- The mechanism carries only an escaping `@Sendable () -> Void`. Its sole current callback
  captures one XCTest expectation and no Event, frame, SQL value, path, peer identity, queue
  key, recovery claim, or coordinator/runtime state.
- The proof is bounded at its sole call site: the test makes a finite prefix of 40 same-session
  offers, installs the callback, performs no later offers before awaiting it, and explicitly
  releases the blocked initial writer. The callback therefore runs only after every operation
  accepted from that finite prefix has completed and released its shared ownership.
- A late callback cannot reopen, attach, close, or publish into a replacement runtime. The
  queued closure has no such reference or capability. If no coordinator exists,
  `ViewerStoreRuntime.afterCurrentJournalPrefix` invokes the content-free callback directly.
  Normal production close/replacement paths do not call the seam.

The seam is consequently sufficient for the deterministic regression proof without widening
the production queue, retaining content, or changing close/replacement ownership.

## Recovery and Initial-Outage Marker Audit

The runtime-start failure path now calls `recordNondurableUnavailable(count: 1, ...)` after the
logical recording identity and original start times are established. Before a recording exists,
the coordinator retains only three scalar fields: a saturating count and bounded first/last wall
times. It retains no Event, device context, frame, query, SQL, path, or arbitrary metadata.

`ensureRecording` transfers a nonzero marker into one coalesced recording-level
`storageUnavailable` gap only after `beginRecording` succeeds. It resets the three fields only
after bounded gap ownership has been established. A failed initial attempt or failed retry
therefore leaves the marker available to a later explicit retry, while coordinator close or
replacement discards only the obsolete coordinator-local state and cannot publish into a new
runtime.

The two direct regressions establish distinct edges:

- `testDirectMaterializationFailureAndFailedRetryCannotReopenIngress` proves a direct writer
  failure closes ingress, a failed initial recording materialization creates no durable
  recording, a further failed retry still creates none, and the first successful retry creates
  exactly one `midRuntimeRetry` recording, one recording-level unavailable gap with count one,
  and no false device row.
- `testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork` first proves the initial
  write reached the blocking gate, then drains the finite accepted lifecycle prefix through the
  barrier. Its second blocking gate proves the retry reached writer work; the contemporaneous
  `isRecoveryInFlight` assertion proves the claim remains owned before failure. The failed retry
  publishes neither availability nor a recording. The following successful retry owns the exact
  aggregate of six: one initial-start marker plus five rejected session observations, with one
  live device row.

This eliminates the Round 10 ambiguity in which retry work could be rejected before consuming
the intended injected fault.

## Security, Resource, Privacy, and Documentation Recheck

- The complete Event/wire/admission/session/store/SQLite/query/export/status ownership chain
  retains closed descriptions and bounded content-free mirrors. The new scalar outage marker and
  test-only barrier add no reflection root or generic diagnostic disclosure.
- Event preparation, shared pipeline ownership, ingress, structural lanes, maintenance
  campaigns, query/export pages, status delivery, recovery claims, and shutdown remain bounded
  by the existing count, byte, transaction, generation, time, and task limits. No automatic retry
  loop, unbounded result materialization, task-per-Event path, or alias-map accumulation was
  introduced.
- SQLite values remain checked and parameter-bound. Writer-first schema acceptance, defensive
  connection settings, progress/cancellation generations, owner-only nonsymlink artifacts, and
  fail-closed unknown/corrupt-schema behavior are unchanged.
- Export still retains the opened parent and temporary descriptors, verifies leaf/parent
  identity and owner-only mode, commits through descriptor-relative `renameat`, and preserves the
  previous destination for every reported pre-commit failure. It remains a bounded streaming
  operation outside Viewer quota and retention.
- The applicable live filesystem audit observed `0700` Application Support ownership and `0600`
  main/WAL/SHM artifacts, restored the exact prior store identity, removed the temporary audit
  store and marker, and left no named residual copy. Round 10-to-11 changes do not alter those
  paths or lifecycle rules.
- Documentation accurately states that the local SQLite database and JSON exports receive no
  NearWire application-layer at-rest encryption; FileVault is outside NearWire's guarantee;
  `secure_delete` is defense in depth rather than guaranteed erasure; export aliases are
  pseudonyms rather than redaction; and selected destinations may synchronize or back up Event
  content.
- The fresh built and checked-in privacy manifests are byte-identical. The manifest continues to
  declare the existing UserDefaults accessed-API reason and linked, nontracking device identifier
  used for app functionality. Local filesystem-capacity inspection does not transmit data.
- Fresh binary inspection links the Viewer to the system `/usr/lib/libsqlite3.dylib`. Repository
  discovery found only the root `Package.swift` and root `NearWire.podspec`; their unchanged
  hashes match the saved Round 11 validation. No third-party Core/SDK runtime dependency, nested
  manifest, nested podspec, or project-generation tool was introduced.
- `implementation-remediation-round9.md` and `implementation-validation-round10.md` now mark the
  superseded semaphore/quiescence evidence accurately. Round 10 remediation and Round 11
  validation disclose the changed six-count semantic, the failed pre-correction attempt, all
  environment-dependent skips, unchanged-input CocoaPods basis, and signing deferral without
  representing any of them as a fresh pass.

## Fresh Focused Validation

This review reran the exact eight-test focused command recorded in
`implementation-validation-round11.md`:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS' -derivedDataPath /tmp/NearWireViewerRound11SPD ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=/tmp/NearWireModuleCache SWIFT_MODULECACHE_PATH=/tmp/NearWireModuleCache test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testQueuedSettingsRecoveryIsRevokedByANewerNonrecoveringRevision \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRunningSettingsRecoveryIsRevokedBeforePublicationByNewerRevision \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRuntimeShutdownQuiescesMaintenanceBeforeOneTerminalFlush \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLatestOnlyChangeSignalCarriesSafeRecordingAndUpperRowSnapshot \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testDirectMaterializationFailureAndFailedRetryCannotReopenIngress

ViewerStoreTests: 8 tests, 0 failures
0.162 seconds test execution
/tmp/NearWireViewerRound11SPD/Logs/Test/Test-NearWireViewer-2026.07.13_12-49-47-+0800.xcresult
** TEST SUCCEEDED **
```

The previously failing same-coordinator regression was then repeated five times in one test
invocation:

```text
xcodebuild ... test -test-iterations 5 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork

Executed 5 tests, 0 failures
0.059 seconds test execution
/tmp/NearWireViewerRound11SPDRepeat/Logs/Test/Test-NearWireViewer-2026.07.13_12-51-19-+0800.xcresult
** TEST SUCCEEDED **
```

Fresh static and packaging/resource checks on the reviewed tree also produced:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

find . -name Package.swift -o -name '*.podspec'
./NearWire.podspec
./Package.swift

Package.swift
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1

NearWire.podspec
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33

checked-in and fresh built PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9

fresh Viewer code dylib
/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)
```

The saved complete Store suite, complete unsigned Viewer suite, complete Swift-package suite,
and unchanged-input CocoaPods evidence remain applicable as recorded in
`implementation-validation-round11.md`. Their explicit live-resource skip, environment-dependent
Swift-package skips, and configured-signing exclusions are not represented here as passes.

## Unresolved Count

**No actionable findings remain unresolved: zero high, zero medium, and zero low. Approved.**
