# Implementation Review Round 13 — Security, Performance, and Documentation

Date: 2026-07-13 (Asia/Shanghai)

## Scope

This fresh independent review examined `AGENTS.md`; the complete active
`viewer-local-store-search` artifacts; the current Viewer storage/runtime, session-manager, and
application lifecycle implementation; the current focused tests and operator documentation; the
Round 12 architecture/API report; `implementation-remediation-round12.md`;
`implementation-validation-round13.md`; and prior security/performance/documentation findings and
resource evidence. It audited the persistent reopen-on-next-runtime reason, one-shot scheduling,
lock/executor order, failure and recovery-claim integrity, duplicate same-ID idempotence,
application Retry and identity-reset ownership, test gates, gap/privacy metadata, evidence
accuracy, filesystem/export protections, and packaging boundaries.

Production, test, specification, task, packaging, and operator-documentation files were not
modified. This report is the only file added by this review. Configured signing, entitlement
assertions, and the stable-signer update-boundary probe remain explicitly deferred by user
direction to goal-level `release-hardening`; they are neither findings nor passing results in
this report.

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 0 Medium, 1 Low.**

## Round 12 Finding Disposition

- `NW-LSS-IMPL-R12-ARCH-001` is resolved for a sequential runtime that remains active through
  its automatic reopen. Detaching runtime A now preserves one Boolean reopen-on-next-runtime
  reason without immediately opening an idle coordinator. Starting runtime B adds one bounded
  initial marker and schedules at most one reopen through the existing `reopenScheduled` gate.
  Construction or admitted recovery failure does not poll; it retains/restores the exact marker
  for a later explicit retry. The two direct sequential-runtime regressions passed freshly.
- `NW-LSS-IMPL-R12-ARCH-002` is resolved. `runtimeStarted` returns under the runtime lock when the
  retained logical ID already matches. It therefore preserves the first wall/monotonic context,
  active sessions, recovery authority, live and claimed counts, and coordinator-local/runtime
  marker separation. The repeated callback cannot reach preparation admission or clear recovery
  authority. Its direct regression passed freshly.

The finding below is adjacent to the Medium remediation but does not dispute those tested
steady-state paths. It covers cancellation of the triggering runtime after its automatic reopen
has been queued.

## Finding

### `NW-ISPD13-001` — Low — A queued automatic reopen can outlive its runtime and retain an idle coordinator

`ViewerStoreRuntime` now deliberately leaves `needsRuntimeReopen = true` when an owned runtime
fully detaches, including when no successor exists (`ViewerStoreCoordinator.swift:1756-1778`). A
later runtime with no coordinator sees that reason and calls `retryStorage`, which sets the single
`reopenScheduled` flag and queues `attemptReopen` on the private reopen executor
(`ViewerStoreCoordinator.swift:1446-1477`, `1729-1740`). This is correctly one-shot and does not
poll.

However, the queued block is not bound to the logical runtime or recovery generation that
triggered it. `attemptReopen` runs the test gate and constructs all three SQLite connection owners
before taking the runtime lock. Under the lock it checks only `coordinator == nil`; it does not
require that the triggering runtime context still exists or still matches. It then installs the
replacement, sets `needsRuntimeReopen = false`, and begins a claim only if whatever
`runtimeContext` happens to exist at that later point is nonnil
(`ViewerStoreCoordinator.swift:1781-1819`).

The missing branch is reachable when runtime B starts after A's completed shutdown, queues its
automatic reopen, and then ends before the reopen gate or coordinator construction completes.
`detachRuntime(B)` clears B's context, sessions, marker, and recovery attempt, but because no
replacement has been installed yet `coordinatorRuntimeLogicalID` is still nil; it returns without
cancelling or invalidating the queued reopen. When that block resumes, it installs the
replacement with a nil runtime context. The process consequently retains an idle
`ViewerStoreCoordinator`, its writer/query/export SQLite connections, maintenance owner, status
handler, and associated executors until a later runtime closes them or the process exits.

This is not an unbounded leak, polling loop, remote denial-of-service path, or privacy exposure:
`reopenScheduled` still limits ownership to one block and at most one coordinator, and production
uses the no-op reopen gate. It is nevertheless actionable because application Retry, identity
reset, or a fast window open/close can end the newly created manager while SQLite reopen work is
still pending. It also contradicts the remediation evidence's explicit claim that the persistent
reason does not reopen an idle store. The current application regression waits for each successor
recording to become active before the next stop, and the two gate regressions never end the
runtime whose automatic reopen is paused, so all current passing results omit this resource edge.

Required resolution:

1. Bind an automatic reopen request to the exact runtime logical ID and a monotonic runtime/reopen
   generation, distinct from an explicit operator retry.
2. Recheck that authority after the test gate and again before publishing a constructed
   coordinator. If the triggering runtime ended or was replaced, cancel the automatic turn,
   preserve the bounded reopen-on-next-runtime reason as appropriate, and explicitly close any
   already-constructed replacement rather than installing or merely dropping its three
   connections. Do not add polling or an automatic successor.
3. Add a deterministic regression that pauses B's automatic reopen, fully ends B, releases the
   gate, and proves no idle coordinator becomes available or remains retained. A later runtime C
   should still receive exactly one automatic reopen attempt. Add proportional application
   Retry/reset or rapid window lifecycle coverage for the same cancellation edge.
4. Correct `implementation-remediation-round12.md` and save fresh focused plus complete
   validation after the generation-bound cancellation behavior exists.

## Rechecked Boundaries Without Additional Findings

### Persistent reason, locking, and claims

- `needsRuntimeReopen` is one Boolean protected by the existing runtime lock. It does not retain
  a runtime, Event, session, path, error, or callback. A normal runtime end stores the reason but
  schedules no work until another runtime starts.
- `reopenScheduled` admits one reopen block and suppresses repeated Retry calls while that block
  is pending. Failed construction clears the flag and schedules no successor. A later automatic
  attempt requires another logical runtime start; a later explicit attempt requires operator
  action. No timer, sleep, recursive dispatch, or retry loop was introduced.
- The reopen execution gate and coordinator construction execute on the private reopen queue
  outside the runtime lock. Preparation, writer, maintenance, protocol, and MainActor executors
  are not held while the gate waits. Runtime completion publishes status only after releasing its
  lock.
- Recovery still moves the saturating missed aggregate into one generation-bound scalar claim.
  Rejected admission or failed materialization merges it back with checked saturation. Success
  clears recovery authority only after matching coordinator/runtime/generation completion. New
  runtime, runtime end, and explicit close invalidate obsolete completion.

### Duplicate starts and application lifecycle

- Same-ID start is a constant-time early return while locked. It does not overwrite the original
  timestamps, forward another coordinator start, mutate sessions, add a second marker, change
  `needsRuntimeReopen`, or disturb an in-flight/failed claim.
- `ViewerRuntimeDependencies.live` intentionally owns one process-lifetime store runtime. Normal
  application Retry and TLS/full identity-reset flows await the prior cleanup receipt before
  creating a new `ViewerMultiDeviceSessionManager`; the current composition regression proves
  three sequential generations close their predecessors and create one successor each without a
  storage Retry call.
- After a completed shutdown with no successor, only the store runtime, paths/preferences/status
  owners, private queue, and one Boolean reason remain; the coordinator and its three connections
  are closed. `closeStorage` clears the context, sessions, reason, and recovery state. The Low
  finding is limited to a queued automatic reopen that crosses another shutdown.

### Test gates, privacy, documentation, and packaging

- `reopenExecutionGate` remains Viewer-module-internal and absent from Core, SDK,
  `ViewerSessionJournaling`, Swift Package products, CocoaPods, and user/protocol input. Production
  composition uses the no-capture no-op default. Each test owns one bounded gate object whose
  semaphore wait has a five-second timeout; runtime reflection and descriptions remain closed.
- The persistent reason and same-ID guard introduce no new durable metadata. Runtime outage
  accounting remains a saturating count transferred to the fixed recording-level
  `storageUnavailable` gap. It contains no Event, SQL, path, endpoint, pairing value, certificate,
  session epoch, device identity, direction, or wire sequence and remains absent from safe status,
  logs, reflection, `UserDefaults`, and recent rows.
- Operator documentation continues to disclose local unencrypted SQLite and JSON, logical rather
  than guaranteed secure erasure, FileVault limits, pseudonym-not-redaction, export sync/backup
  risk, owner-only artifacts, bounded gaps, and replacement-runtime isolation. The user-facing
  documents do not expose test seams or claim polling.
- SQLite bootstrap, query/export work budgets, filesystem no-follow and owner-only validation,
  descriptor-relative export commit, privacy declarations, package boundaries, Swift 5/iOS 16/
  macOS 13 compatibility, and system-SQLite-only Viewer linkage are unchanged. Prior reflection,
  current-prefix barrier, filesystem/export, and documentation findings remain resolved.

## Test and Evidence Accuracy

The four Round 12 remediation regressions passed freshly and accurately establish their stated
paths: repeated-start idempotence, sequential automatic success, automatic failure followed by
explicit recovery, and steady-state application Retry/TLS-reset reuse. The saved 80-test stress,
14-test focused result, complete 83-test Store result, complete 164-test unsigned Viewer result,
and 536-test Swift package result are current-tree evidence. Their explicit skips/exclusions and
the earlier test-assumption failure are disclosed rather than represented as passes.

The evidence is incomplete only for `NW-ISPD13-001`: no test ends the triggering runtime while
`reopenExecutionGate` is blocked. Therefore the existing passes neither contradict nor resolve
the state-machine path described above.

## Fresh Validation

To avoid creating another large DerivedData tree while `/private/tmp` had only approximately
1.8 GiB available, this review reused the current Round 13 build tree and reran the four direct
remediation regressions:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound13Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound13ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound13ModuleCache test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRepeatedRuntimeStartPreservesOriginalContextAndRecoveryOwnership \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testSequentialRuntimeAutomaticallyReopensAfterCompletedShutdown \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testFailedAutomaticSequentialReopenRetainsMarkerForExplicitRetry \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testApplicationRetryAndIdentityResetReuseOneStoreRuntimeAutomatically

ViewerStoreTests: 4 tests, 0 failures
0.100 seconds test execution
/tmp/NearWireViewerRound13Focused/Logs/Test/Test-NearWireViewer-2026.07.13_13-41-35-+0800.xcresult
** TEST SUCCEEDED **
```

Fresh static, formatting, package-resource, and binary checks produced:

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

Package.swift
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1

NearWire.podspec
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33

checked-in and current built PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9

current Viewer code dylib
/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)
```

The current isolated package dump, full Store/Viewer/Swift-package suites, 80-test lifecycle
stress, built privacy comparison, and unchanged-input CocoaPods evidence remain applicable as
recorded in `implementation-validation-round13.md`. Configured signing, entitlement assertions,
and the stable-signer probe remain deferred and uncounted.

## Unresolved Count

**Exactly one actionable finding remains unresolved: 0 High, 0 Medium, 1 Low. Approval is withheld.**
