# Implementation Review Round 15 — Security, Performance, and Documentation

Date: 2026-07-13 (Asia/Shanghai)

## Scope

This fresh independent review examined `AGENTS.md`; the complete active
`viewer-local-store-search` proposal, design, capability specifications, and task plan; all three
Round 14 implementation-review reports; `implementation-remediation-round14.md`;
`implementation-validation-round15.md`; and the current Viewer store/runtime, session-manager,
application-lifecycle, tests, operator documentation, privacy resource, package, podspec, and
evidence tree.

The review independently retraced all three Round 14 findings through explicit Retry failure and
cancellation, runtime replacement, generation-specific runtime end, terminal close, coordinator
construction, stale replacement disposal, physical worker coalescing, and recovery publication.
It also re-audited queue/task bounds across many logical generations, generation-specific
quiescence, lock and executor order, maintenance/resource release, privacy and reflection
surfaces, SQLite/filesystem/export safety, packaging boundaries, documentation disclosures, and
the accuracy of the saved evidence.

Production, test, specification, task, packaging, privacy-resource, and operator-documentation
files were not modified. This report is the only file added by this review. Configured signing,
entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred,
by user direction, to goal-level `release-hardening`; they are neither findings nor passing
results in this report.

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

## Round 14 Finding Disposition

### `NW-LSS-IMPL-R14-ARCH-001` — Resolved

- A no-coordinator explicit Retry creates only
  `ReopenRequest.explicit(runtimeLogicalID:)`. It no longer creates the independent
  process-lifetime automatic-reopen reason. `needsRuntimeReopen` is now set only when a
  coordinator actually associated with the ending logical runtime is detached
  (`ViewerStoreCoordinator.swift:1792-1799`, `1822-1850`).
- Failure or cancellation clears the exact request generation without granting a later runtime
  authority. The persistent automatic reason remains available only after an intentional clean
  detach, is consumed by successful replacement publication, and is cleared by terminal close.
- `testFailedInitialExplicitRetryDoesNotAuthorizeLaterRuntime` and
  `testCancelledInitialExplicitRetryDoesNotAuthorizeLaterRuntime` exercise unsupported-schema
  failure and cancellation, repair the schema, and prove that a later runtime does not reopen
  until its own explicit Retry. The later successful Retry owns exactly one unavailable gap.

No explicit-user action now leaks into a different runtime's automatic authority. The reported
architecture and lifecycle-boundary defect is closed.

### `NW-LSS-IMPL-R14-CT-001` — Resolved

- After the first authority check and while still holding the runtime lock, an authorized turn
  installs a request- and generation-bound construction lease before releasing the lock and
  entering the execution gate or coordinator constructor
  (`ViewerStoreCoordinator.swift:1889-1910`). There is no authority-to-resource gap in which
  construction can start without shutdown being able to observe it.
- Matching runtime end captures only a construction lease whose typed request belongs to that
  exact logical runtime and awaits it asynchronously. Terminal `closeStorage` captures any
  current construction lease, invalidates request and recovery authority, unlocks, waits, and
  only then closes the installed coordinator (`ViewerStoreCoordinator.swift:1484-1500`,
  `1802-1850`). Unrelated newer-runtime construction is not globally attributed to an older
  runtime end.
- The lease completes only after constructor failure, valid publication, or explicit close of a
  replacement that became stale after construction. The stale branch calls
  `replacement.closeStorage()` before it emits `staleCoordinatorClosed` and before the lease's
  deferred completion (`ViewerStoreCoordinator.swift:1902-1907`, `1910-1936`).
- Content-free internal resource events and the focused regressions prove the waiting and close
  order for exact runtime end, terminal close, newer-runtime supersession, and real application
  rapid stop. Application stop remains in progress until the authorized construction is
  quiescent.

No shutdown path reviewed can return while a construction it is required to own is still opening
or retaining the writer, interactive reader, export reader, or maintenance resources. The
reported correctness/resource-lifetime defect is closed.

### `NW-ISPD14-001` — Resolved

- Logical request authority and physical worker occupancy are now separate. One
  `reopenWorkerScheduled` guard owns the serial worker chain, while repeated distinct runtime
  generations replace one latest `reopenRequest` and monotonic generation instead of enqueueing
  one closure per generation (`ViewerStoreCoordinator.swift:1853-1887`).
- The current turn validates the latest typed request, performs at most one construction attempt,
  and hands off at most one successor when a newer authorized request remains. Constructor or
  recovery failure clears the current request and creates no polling or automatic retry chain.
  Terminal close invalidates the latest request and automatic reason.
- `testRepeatedRuntimeSupersessionCoalescesOneReopenSuccessor` applies 64 distinct superseding
  generations while the first construction is paused. It proves two execution-gate turns, only
  the latest runtime materialized, no intermediate recording, and one latest-runtime unavailable
  gap. `testTerminalCloseDiscardsCoalescedReopenSuccessor` applies the same fixed churn and proves
  no coordinator, recording, or authorized successor survives terminal close.
- The hard physical bound is constant: one running worker and, only during handoff, at most one
  queued successor closure. It is independent of runtime-generation count. This is the material
  resource bound required by the active change; it replaces the Round 14 linear queue-retention
  behavior.

No timer, sleep, recursive retry, unbounded task/value list, or additional executor was added.
The reported physical backlog defect is closed.

## Non-actionable Physical-Quiescence Observation

There is one narrow handoff interleaving worth recording for evidence precision. A worker can
finish `attemptReopen`, sample `reopenScheduled == true` under the lock, and unlock immediately
before calling `enqueueReopenWorker` (`ViewerStoreCoordinator.swift:1882-1886`). If terminal
`closeStorage` invalidates the request in that exact interval, terminal close can return before
the already-decided successor closure is physically submitted. That closure later enters the
guard, finds no request, clears only the internal worker-occupancy flag, and returns
(`ViewerStoreCoordinator.swift:1870-1875`).

This is not an actionable finding under the review threshold:

- it is capped at one guard-only closure, rather than accumulating with generation count;
- it cannot pass request/generation authority or reach the execution gate;
- it cannot construct or publish a coordinator, open SQLite connections, start maintenance,
  claim a gap, create a recording, publish availability, mutate a session, or schedule another
  successor;
- it carries no Event, identifier, path, query, pairing, endpoint, or other content; and
- its only bookkeeping effect is draining the worker guard that intentionally remains owned by
  the worker chain during handoff.

Accordingly, terminal close provides logical quiescence and resource quiescence for the active
change, while not promising that the private serial queue contains literally zero future
guard-only blocks. The Round 14 remediation phrase “at most one queued or running closure” is
slightly stronger than the implementation during the brief handoff; the verified and sufficient
bound is one running plus at most one queued empty or authorized successor. The saved functional
test proves that no authorized successor or storage side effect survives close; it should not be
read as instrumentation of literal queue emptiness.

## Rechecked Boundaries

### Authority, resources, maintenance, and locking

- Reopen publication still requires exact request equality, exact attempt generation,
  coordinator absence, and matching runtime identity both before construction and before
  publication. Runtime end, distinct-runtime start, and terminal close invalidate obsolete
  authority while holding the runtime lock.
- A replacement that loses authority after construction is explicitly closed before lease
  completion. Its maintenance controller and all three SQLite pool connections therefore do not
  become ownerless. Constructor failure clears only the current request; it does not schedule a
  successor or consume an independent next-runtime reason.
- Recovery remains bound to coordinator identity, runtime logical ID, and recovery generation.
  A late invalidated completion cannot publish into a successor. Failed recovery merges the
  scalar missed-observation claim back with observations accumulated during the attempt using
  saturating arithmetic.
- Same-logical-ID `runtimeStarted` remains an early return. It cannot invalidate or duplicate
  work, replace the original timestamps, clear sessions, add an outage marker, or disturb a
  current claim.
- Construction gates, SQLite opening, coordinator close, maintenance close, DispatchGroup waits,
  outward status publication, and async runtime completion all occur without the runtime lock
  held. Lease creation/removal and request/generation transitions are short lock-protected state
  changes. No runtime/preparation/writer/maintenance/Main Actor lock inversion was found.
- Runtime end waits only for the matching generation-specific construction lease; terminal close
  waits any currently authorized construction. Neither path polls, spins, sleeps, recursively
  dispatches, or globally drains unrelated newer-runtime work.

### Privacy, reflection, and diagnostics

- The remediation adds only typed local authority, UUID equality, scalar generations, a
  DispatchGroup lease, a Boolean worker guard, and four internal resource-event enum cases. The
  resource events are content-free and default to a no-op outside tests.
- No Event body, query, SQL, filesystem path, endpoint, pairing code, certificate, session epoch,
  raw frame, peer-controlled string, or runtime identifier was added to status, reflection,
  description, debug description, logs, `UserDefaults`, recent rows, or persistence.
- Viewer store/runtime mirrors and descriptions remain deliberately closed. No new `print`, OSLog,
  signpost, metric label, crash annotation, or dynamic reflection surface was introduced by the
  remediation.
- The checked-in and built privacy manifests remain byte-identical. No new collected-data,
  tracking, accessed-API, network-discovery, or file-observation declaration is implied by these
  internal lifecycle controls.

### SQLite, filesystem, export, and retention

- Writer-first schema acceptance still precedes interactive and export readers. Unknown,
  future, or corrupt schema fails closed without deletion or silent recreation. The Viewer links
  the system SQLite library.
- Database, WAL, SHM, journal/migration, and export-temporary paths retain owner-only,
  regular-file, no-follow validation. The export commit seal keeps original temporary and parent
  descriptors, uses descriptor-relative replacement, and preserves the prior destination on
  pre-commit cancellation or failure.
- Query and export retain short transactions, finite leases, keyset/frozen bounds,
  generation-bound cancellation, VM/time budgets, and streaming output. No complete-result,
  alias-map, queue, or Event-body materialization was added.
- Writer-serialized reserve decisions, one finite ingress shutdown flush, saturating gap
  aggregation, finite maintenance batches, logical quota/TTL treatment, and late-callback
  rejection are unchanged from the previously approved boundaries.

### Packaging and documentation

- `Package.swift` and `NearWire.podspec` are unchanged. There is no third-party Core/SDK runtime
  dependency, nested package manifest, nested podspec, project-generation tool, shell harness,
  or new package product. Viewer continues to use the system SQLite library.
- Operator documentation still states that local SQLite and exported JSON have no NearWire
  application-layer at-rest encryption; FileVault is outside NearWire's guarantee;
  `secure_delete` is defense in depth rather than guaranteed erasure; export aliases are
  pseudonyms rather than redaction; and logical quota differs from database/WAL/SHM allocation.
- Runtime/gap documentation remains accurate for unavailable start, explicit Retry,
  replacement-runtime isolation, bounded missed aggregation, and rejection of stale completion.
  The worker implementation is private and changes no documented Event, query, export, SDK, or
  Viewer-facing API.
- `implementation-validation-round15.md` accurately distinguishes fresh results, reused
  unchanged-input package/CocoaPods evidence, the one explicit live-resource audit skip, and the
  two configured-signing exclusions. None is broadened into a passing claim.

## Prior Finding and Evidence Audit

All actionable security/performance/documentation findings through Round 14 are resolved. The
review specifically rechecked the previously approved boundaries for reflection and
latest-only-change-snapshot privacy, bounded preparation/ingress/maintenance/query/export work,
writer-serialized reserve decisions, finite shutdown flush, generation-bound recovery claims,
filesystem identity, descriptor-relative export commit, privacy-resource packaging, and honest
retention/erasure disclosures. The Round 14 remediation does not regress those dispositions.

The new direct regressions are proportionate to the reported defects:

- two tests separate explicit Retry from later-runtime automatic authority;
- three coordinator tests force runtime-end, terminal-close, and newer-runtime construction
  quiescence with resource-event ordering;
- two 64-generation tests prove constant physical worker/request bounds and terminal logical
  cancellation; and
- one application-level rapid-stop test proves the real lifecycle awaits owned construction.

The final repeated evidence ran all eight scenarios 20 times each. Complete Store and unsigned
Viewer suites, package tests, specification validation, formatting, hygiene, privacy, binary,
and packaging checks cover the remaining affected boundaries. The nonactionable empty-handoff
observation above is not represented as a literal-queue-emptiness pass.

## Fresh Validation

This review reran the eight direct remediation tests once against the reviewed source:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound14Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound14ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound14ModuleCache test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testFailedInitialExplicitRetryDoesNotAuthorizeLaterRuntime \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testCancelledInitialExplicitRetryDoesNotAuthorizeLaterRuntime \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testTerminalCloseCancelsPausedAutomaticReopen \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testNewerRuntimeSupersedesPausedAutomaticReopen \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testRepeatedRuntimeSupersessionCoalescesOneReopenSuccessor \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testTerminalCloseDiscardsCoalescedReopenSuccessor \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testApplicationRapidStopCancelsPausedAutomaticReopen

ViewerStoreTests: 8 tests, 0 failures
0.138 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-27-54-+0800.xcresult
** TEST SUCCEEDED **
```

Fresh specification, whitespace, hygiene, formatting, package-resource, binary, and privacy
checks produced:

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

swift package dump-package --disable-sandbox
exit 0; no external dependencies; iOS 16; macOS 13; Swift language version 5;
products NearWire, NearWireUI, NearWirePerformance, and internal NearWireCore

Package.swift
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1

NearWire.podspec
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33

checked-in and current built PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9

current Viewer code dylib
/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)
```

An initial plain `swift package dump-package` invocation was blocked by this review environment's
`sandbox-exec` restriction before evaluating the product. The `--disable-sandbox` rerun above
succeeded; the environment-only failure is not represented as a product failure or hidden as a
pass.

The saved authoritative Round 15 evidence remains applicable: 160 repeated direct tests with no
failure; 91 Store tests with one explicit live-resource-audit skip and no failure; 172 unsigned
Viewer tests with one skip and no failure while the two signing tests were excluded; and 536
package tests with no skip or failure. The unchanged-input CocoaPods result is reused and no
fresh CocoaPods pass is claimed.

## Deferred Validation

The configured signing, entitlement assertions, and stable-signer update-boundary probe remain
deferred exclusively to goal-level `release-hardening`. They are not an unresolved finding and
are not counted as passing validation for this change.

## Unresolved Count

**Zero actionable findings remain unresolved: 0 High, 0 Medium, 0 Low. Security/performance/documentation approval is granted.**
