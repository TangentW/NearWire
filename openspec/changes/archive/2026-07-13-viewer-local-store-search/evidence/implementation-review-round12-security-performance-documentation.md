# Implementation Review Round 12 — Security, Performance, and Documentation

Date: 2026-07-13 (Asia/Shanghai)

## Scope

This fresh independent review examined `AGENTS.md`; the complete current
`viewer-local-store-search` proposal, design, capability specifications, and task plan; the
relevant current production, test, packaging, privacy-resource, operator-documentation, and
evidence tree; all three Round 11 implementation-review reports;
`implementation-remediation-round11.md`; `implementation-validation-round12.md`; and the
applicable prior resource/filesystem audit. It retraced the Round 11 architecture finding and
all prior security/performance/documentation findings, then re-audited generation-bound outage
ownership and saturation, runtime lock/executor order, denial-of-service and retention bounds,
the `reopenExecutionGate` seam, recovery failure integrity, gap metadata and privacy, test and
evidence accuracy, filesystem/export boundaries, package placement, and operator disclosure.

Production, test, specification, task, packaging, and operator-documentation files were not
modified. This report is the only file added by this review. Configured signing, entitlement
assertions, and the stable-signer update-boundary probe remain explicitly deferred by user
direction to goal-level `release-hardening`; they are neither findings nor passing results in
this report.

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

## Round 11 Finding Disposition

### `NW-LSS-IMPL-R11-ARCH-001` — Resolved

`ViewerStoreRuntime.runtimeStarted` now distinguishes a new logical runtime generation from a
repeated callback for the same logical ID. A new generation receives one runtime-level missed
observation when there is no attachable coordinator, covering both failed bootstrap/schema
construction and a replacement runtime waiting for its predecessor's coordinator to close. An
attachable coordinator receives no runtime-level marker, so an accepted start that later fails
continues to use the separate coordinator-local marker from Round 10 without double counting.

The runtime marker follows the same recovery ownership as later nondurable observations. A
reopen moves the exact saturating aggregate into one generation-bound in-flight claim. Failed
construction does not touch the aggregate; rejected recovery admission or failed materialization
merges the claim back with observations accumulated during the attempt; success clears the claim
only after the replacement coordinator owns the original partial recording and the bounded
recording-level `storageUnavailable` gap. The exact coordinator identity, runtime logical ID,
and recovery generation guards reject late completion from a predecessor or invalidated
attempt.

The two zero-observation regressions now cover both missing paths. Each proves one failed retry,
no false recording/device publication, one later successful partial recording, exactly one
recording-level unavailable gap, and no duplication on another retry. The replacement test also
proves that late predecessor cleanup cannot close or attach the new runtime.

## Generation Marker, Locking, and Resource Audit

- `missedObservationCount` and `recoveryClaimedMissedCount` are two `Int64` scalars protected by
  the runtime's single `NSLock`. `addMissedLocked` and failed-claim restoration use
  `addingReportingOverflow` and saturate at `Int64.max`; no peer-controlled count can wrap the
  aggregate or allocate one marker per loss.
- A new runtime generation invalidates the prior claim before replacing context, clears obsolete
  sessions and the obsolete live aggregate, and adds at most one new initial marker. Repeated
  start callbacks for the same generation neither reset the scalar aggregate nor add another
  initial marker. Runtime end and explicit storage close clear only the ended generation.
- `beginRecoveryAttemptLocked` transfers ownership while holding the runtime lock. Completion
  accepts only the exact generation, coordinator object identity, runtime logical ID, and
  coordinator/runtime association. Failure uses saturating merge; success leaves observations
  received during the attempt owned by the next recovery decision.
- The runtime lock is not held while calling the reopen execution gate, constructing a SQLite
  coordinator, scheduling preparation work, executing writer work, waiting for test semaphores,
  closing the old coordinator, or publishing outward status. Recovery completion takes the
  runtime lock only for bounded scalar/dictionary state and publishes after unlocking.
- Active-session snapshots are sorted while locked, but the collection is hard-bounded to the
  existing 16-device maximum. The new marker adds no Event traversal, JSON encoding, database
  operation, task, timer, queue entry, or variable-sized metadata on a protocol executor.
- `reopenScheduled` permits only one outstanding reopen block. Failed construction clears that
  flag and waits for a later explicit trigger; there is no polling or recurring retry loop.

These properties preserve the existing requirement that storage failure cannot block, terminate,
or mutate a device protocol session, while ensuring the new runtime-level outage path increases
only one saturating scalar for missed observations rather than retaining one value per loss.

## `reopenExecutionGate` Audit

The new seam is a single stored `@Sendable () -> Void` closure on the Viewer-internal
`ViewerStoreRuntime` initializer. Its security and performance boundary is acceptable:

- Repository search finds one nondefault injection, in
  `testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime`. Production composition calls
  `ViewerStoreRuntime()` and therefore retains the no-capture, no-op default.
- The runtime, initializer parameter, and seam are module-internal to the macOS Viewer. They are
  absent from `ViewerSessionJournaling`, Core, SDK, root Swift Package products, CocoaPods, and
  user-visible settings or protocol input.
- The closure is invoked on the private serial reopen queue before coordinator construction and
  before acquiring the runtime lock. It cannot block the main actor, a device protocol executor,
  the preparation executor, or the writer executor. While it is paused, `reopenScheduled`
  prevents queue growth and networking remains independent.
- The production closure captures no value. The sole test closure captures one bounded gate
  object; its semaphore wait has a five-second timeout, and the runtime retains one closure rather
  than a callback collection. `ViewerStoreRuntime`'s closed custom mirror and redacted
  descriptions expose neither the closure nor captured state.

The seam therefore makes the replacement race deterministic without introducing a production
blocking hook, public denial-of-service surface, unbounded callback retention, or a new sensitive
reflection root.

## Recovery Integrity, Gap Metadata, and Privacy

- Failed bootstrap or schema rejection creates no recording and does not delete/recreate the
  database. A failed replacement construction leaves the generation marker with the runtime. A
  failed admitted retry creates no false successful status and returns the exact claimed count to
  bounded runtime ownership.
- Successful recovery first creates the original logical recording with its original start
  context, then materializes only currently live sessions. Zero-observation recovery creates no
  device. A later retry is idempotent and does not append a second initial-outage gap.
- The new runtime marker contains only a saturating count. On durable transfer it uses the
  existing fixed `storageUnavailable` reason and existing bounded local gap fields. It adds no
  Event type/content, query, SQL, path, peer identifier, endpoint, pairing value, certificate,
  session epoch, direction, or wire sequence.
- The gap is recording-local analysis data, not a safe status or diagnostic value. Existing
  export rules may include bounded gap metadata, while descriptions, reflection, logs,
  `UserDefaults`, status presentation, and recent rows remain content-free. Export disclosure
  continues to warn that the ordinary JSON output is unencrypted, outside Viewer quota and
  retention, pseudonymous rather than redacted, and may be synchronized or backed up.
- The runtime's custom description, debug description, and mirror remain closed. The marker,
  recovery generation, logical ID, coordinator identity, execution gate, and active-session map
  cannot be traversed through generic diagnostics.

## Prior Security, Performance, and Documentation Recheck

- `NW-ISPD10-001` remains resolved. The finite current-prefix barrier has one test caller and no
  production caller; the blocking writer fault separately proves recovery admission and in-flight
  claim ownership. The new runtime marker does not change that queue or its fixed structural
  allowance.
- `NW-ISPD9-001` remains resolved. Populated latest-only change snapshots retain bounded trusted
  refresh IDs while description, interpolation, presentation, and direct reflection remain
  identity- and content-free.
- SQLite still opens and accepts the writer/schema before either reader, uses checked
  parameter-bound operations and generation-bound progress cancellation, and fails closed on
  unknown/corrupt schema without automatic deletion or recreation.
- Preparation, ingress, structural ownership, transaction quanta, maintenance campaigns,
  query/export pages and leases, status coalescing, recovery claims, and shutdown remain bounded
  by the existing count, byte, task, generation, time, and work limits. No task-per-Event path,
  unbounded result/alias materialization, automatic retry loop, or long read transaction was
  introduced.
- Owner-only nonsymlink database/WAL/SHM/temp rules and descriptor-relative export replacement
  are unchanged. The applicable live audit observed `0700` Application Support ownership and
  `0600` SQLite artifacts, restored the exact prior store identity, and removed its temporary
  audit state without leaving a duplicate database outside quota and retention.
- Operator documentation still states directly that the SQLite database and JSON exports have
  no NearWire application-layer at-rest encryption; FileVault is outside NearWire's guarantee;
  `secure_delete` is defense in depth rather than guaranteed erasure; and aliases are not
  redaction. The general unavailable-start and replacement-runtime descriptions remain accurate
  for the new zero-observation behavior.
- The checked-in and fresh built Viewer privacy manifests are byte-identical. The local capacity
  query does not transmit data. The manifest continues to declare the existing UserDefaults
  accessed-API reason and linked, nontracking device identifier used for app functionality.
- Fresh package inspection reports no external Swift Package dependency, Swift language version
  5, iOS 16 and macOS 13 platform floors, and only the root products. Repository discovery found
  no nested manifest or podspec. The Viewer continues to link system SQLite; no third-party
  Core/SDK runtime dependency or project-generation tool was introduced.

## Test and Evidence Accuracy

The two corrected tests genuinely contain no device, Event, policy, or drop observation for the
new logical runtime before the first recovery attempt. The unavailable-bootstrap test repairs the
rejected schema, proves one injected recovery writer failure, and then checks the exact partial
recording/gap/no-device result. The replacement-runtime test pauses the one reopen turn outside
all runtime/store locks, arms the injected writer failure before release, and verifies late old
runtime cleanup after successful replacement cannot mutate the new recording.

`implementation-validation-round12.md` accurately discloses the earlier focused failure caused
by the former two-count assertion and explains the current exact total of three: one generation
start marker plus two deliberate nondurable policy observations. It records the direct result,
the 100-iteration-per-test stress result, focused recovery result, complete Store and unsigned
Viewer suites, complete Swift package suite, formatting suggestions, package/privacy hashes,
unchanged-input CocoaPods basis, skips, and signing exclusions without representing excluded or
environment-dependent work as a pass.

## Fresh Validation

This review reran the two Round 11 remediations plus the eight prior focused recovery and boundary
regressions in one exact command. Result:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerRound12SPD \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound12SPDModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireRound12SPDModuleCache test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testUnavailableRuntimeReopensAfterExplicitRetry \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testQueuedSettingsRecoveryIsRevokedByANewerNonrecoveringRevision \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRunningSettingsRecoveryIsRevokedBeforePublicationByNewerRevision \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRuntimeShutdownQuiescesMaintenanceBeforeOneTerminalFlush \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testFreshReopenRetainsMissedAggregateUntilMaterializationCompletes \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testSameCoordinatorRetainsClaimedMissesAcrossFailedRecoveryWork \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLatestOnlyChangeSignalCarriesSafeRecordingAndUpperRowSnapshot \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testDirectMaterializationFailureAndFailedRetryCannotReopenIngress

ViewerStoreTests: 10 tests, 0 failures
0.236 seconds test execution
/tmp/NearWireViewerRound12SPD/Logs/Test/Test-NearWireViewer-2026.07.13_13-12-47-+0800.xcresult
** TEST SUCCEEDED **
```

The two zero-observation regressions were then repeated ten times each in one fresh stress
invocation:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerRound12SPD \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound12SPDModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireRound12SPDModuleCache \
  test -test-iterations 10 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testUnavailableRuntimeReopensAfterExplicitRetry \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testLateRuntimeCleanupCannotCloseOrAttachTheReplacementRuntime

ViewerStoreTests: 20 tests, 0 failures
0.355 seconds test execution
/tmp/NearWireViewerRound12SPD/Logs/Test/Test-NearWireViewer-2026.07.13_13-15-18-+0800.xcresult
** TEST SUCCEEDED **
```

Fresh static, formatting, package, binary, and privacy checks on the reviewed tree produced:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches

find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print
exit 0, no output

ruby -c NearWire.podspec
Syntax OK

xcrun swift-format lint --recursive Viewer/NearWireViewer/Store Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0; seven nonblocking trailing-closure suggestions and one test-only for-loop suggestion

swift package ... dump-package
exit 0; no external dependencies; iOS 16; macOS 13; Swift language version 5

Package.swift
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1

NearWire.podspec
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33

checked-in and fresh built PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9

fresh Viewer code dylib
/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)
```

The saved complete Store, unsigned Viewer, Swift-package, 200-iteration zero-observation stress,
and unchanged-input CocoaPods evidence remain applicable as recorded in
`implementation-validation-round12.md`. The explicit live-resource skip, environment-dependent
Swift-package skips, and configured-signing exclusions are not represented here as passes.

## Unresolved Count

**No actionable findings remain unresolved: 0 High, 0 Medium, 0 Low. Approved.**
