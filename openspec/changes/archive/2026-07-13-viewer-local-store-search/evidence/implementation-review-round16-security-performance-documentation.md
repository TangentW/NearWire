# Implementation Review Round 16 — Security, Performance, and Documentation

Date: 2026-07-13 (Asia/Shanghai)

## Scope

This fresh independent review examined `AGENTS.md`; the complete active
`viewer-local-store-search` proposal, design, capability specifications, and task plan; all three
Round 15 implementation-review reports; `implementation-remediation-round15.md`;
`implementation-validation-round16.md`; and the final current Viewer store/runtime,
session-manager, application-lifecycle, test, operator-documentation, privacy-resource,
packaging, and evidence paths.

The review retraced the Round 15 stale-predecessor construction finding through runtime
supersession, final-current runtime end, late predecessor cleanup, lease completion, stale
coordinator close, later-runtime recovery, and repeated cleanup. It then re-audited all prior
findings and the unchanged boundaries for lock/wait discipline, physical worker bounds,
maintenance/resource lifetime, SQLite and filesystem hardening, query/export work limits,
privacy/reflection/diagnostics, packaging, documentation, and evidence accuracy.

Production, test, specification, task, package, privacy-resource, and operator-documentation
files were not modified. This report is the only file added by this review. Configured signing,
entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred,
by user direction, to goal-level `release-hardening`; they are neither findings nor passing
results in this report.

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

## Round 15 Finding Disposition

### `NW-LSS-IMPL-R15-CT-001` — Resolved

The missing shutdown-ownership cell is now covered structurally rather than by timing.

- `detachRuntime(logicalID:)` determines whether the ending ID is the current runtime while the
  runtime lock still protects the current context and the single active construction. When it is
  current, it captures `reopenConstruction?.lease` regardless of which predecessor request owns
  that construction. It then invalidates reopen/recovery authority and removes the final current
  context (`ViewerStoreCoordinator.swift:1822-1843`).
- A noncurrent late cleanup still uses `reopenConstructionLeaseLocked(for:)`, which returns a
  lease only for an automatic or runtime-bound explicit request carrying that exact logical ID
  (`ViewerStoreCoordinator.swift:2001-2011`). Old runtime B therefore cannot drain valid current
  runtime C or later runtime D work.
- The captured lease is awaited only after the runtime lock has been released
  (`ViewerStoreCoordinator.swift:1802-1819`). The gate, filesystem and SQLite construction,
  coordinator disposal, DispatchGroup notification, installed-coordinator shutdown, and any
  later automatic scheduling also remain outside that lock.
- The construction lease is created after the first authority check but before the execution
  gate and constructor. Its one deferred completion occurs only after constructor failure, valid
  publication, or explicit close of a successfully constructed replacement that lost authority
  (`ViewerStoreCoordinator.swift:1891-1938`, `2044-2058`). Multiple waiters may safely observe the
  same one-shot DispatchGroup completion.
- `testFinalCurrentRuntimeWaitsForSupersededReopenConstruction` deterministically pauses a
  B-owned construction, supersedes it with current runtime C, and ends C before B cleanup. It
  proves C remains incomplete, B constructs and explicitly closes, neither B nor C records,
  late B cleanup is harmless, and later runtime D receives the retained single automatic
  recovery attempt and one unavailable gap (`ViewerStoreTests.swift:2012-2123`).

The final current runtime can no longer report shutdown complete while a stale predecessor still
opens or retains the writer, query reader, export reader, startup reconciliation, or maintenance
ownership. At the same time, noncurrent cleanup does not become a global drain. The reported
finite-shutdown and resource-lifetime defect is closed.

## Prior Finding Disposition

### Round 14 explicit-retry authority finding remains resolved

- A no-coordinator explicit Retry creates only a typed explicit request. It does not create the
  independent next-runtime automatic-reopen reason.
- `needsRuntimeReopen` is set only when a coordinator associated with an ending logical runtime is
  intentionally detached. Constructor failure and request cancellation do not grant a later
  runtime automatic authority.
- Failed and cancelled explicit-retry regressions continue to prove that a later runtime remains
  unavailable until its own explicit Retry, after which it owns one bounded unavailable gap.

### Round 14 construction-quiescence finding remains resolved

- Authority validation and construction-lease reservation are atomic under the runtime lock.
  Runtime end and terminal close can therefore observe every resource-opening turn they are
  required to own.
- Matching noncurrent runtime end waits its exact typed lease. Final-current runtime end now waits
  any active stale predecessor lease. Terminal close waits any active construction lease. Every
  wait remains outside `NSLock`.
- A replacement that becomes stale after construction closes maintenance and all three SQLite
  connections before completing the lease. Partial constructor failure is unwound before the
  throwing initializer returns.

### Round 14 physical-worker accumulation finding remains resolved

- Logical latest-request state is separate from the `reopenWorkerScheduled` physical worker
  token. Repeated runtime generations replace one request/generation rather than retaining one
  queue closure per generation (`ViewerStoreCoordinator.swift:1855-1888`, `1984-2042`).
- One running turn can hand off at most one successor. Constructor/recovery failure creates no
  timer, polling loop, recursion, or automatic retry chain. Sixty-four-generation regressions
  continue to prove only the latest runtime can materialize and physical execution remains
  constant-bounded.
- The Round 15 remediation changes only which already-existing construction lease the final
  current runtime awaits. It adds no queue, executor, task, request value, retry source, or
  generation-retention structure.

All security/performance/documentation findings through Round 14 remain resolved on their
reported paths. The current one-line ownership selection and one regression do not reopen the
previously approved ingress, maintenance, query, export, filesystem, privacy, or documentation
boundaries.

## Shutdown, Lock, and Resource Audit

### Final-current and predecessor ownership

- If B owns the only active construction and C is current, ending C captures B's lease before C
  clears the context and invalidates request authority. B can still finish local construction,
  but its second authority check must fail; it closes the replacement before the lease completes.
- A later cleanup for B may capture and wait the same lease while C is already waiting. Dispatch
  group completion supports both waiters without duplicate close or duplicate `finish()`.
- If a genuinely newer runtime D starts while a predecessor waiter is suspended, D may replace
  the latest logical request. That newer ownership remains independent: C waits only the already
  captured construction, and the bounded worker may later service D after B unwinds.
- If construction fails instead of producing a replacement, the lease still finishes through the
  same defer. A stale failure does not clear a newer latest request; a current failure clears only
  its own request and publishes one safe status update.
- Same-logical-ID start remains an early return. It cannot invalidate the active request, replace
  original timing, clear sessions, add a gap, or duplicate physical work.

### Lock and executor order

- Request identity, attempt generation, runtime identity, coordinator absence, construction
  identity, and recovery generation are checked under one short runtime lock. No raw SQLite
  operation or serial-executor wait occurs under it.
- Construction gates and coordinator initialization run on the private reopen queue after lease
  reservation. Stale coordinator close runs after unlocking. Runtime-end lease waits use
  continuation notification; terminal close's synchronous lease wait also occurs after unlock.
- Coordinator shutdown first invalidates maintenance ownership, cancels the periodic wake, clears
  dirty and pending successors, and synchronizes the maintenance queue. Its finite preparation
  prefix and ingress flush then close all three connections (`ViewerStoreCoordinator.swift:709-785`;
  `ViewerStoreMaintenance.swift:1286-1318`; `ViewerSQLite.swift:562-566`).
- No runtime/reopen/preparation/writer/maintenance/query/export/Main Actor lock inversion,
  lock-held await, polling wait, semaphore cycle, or newly introduced executor dependency was
  found.

### Bounded work and lifecycle

- Reopen state owns one construction lease and one coalesced latest request. The worker chain is
  bounded to one executing closure and at most one handoff successor; its size is independent of
  the number of runtime generations.
- Recovery remains bound to exact generation, coordinator object, current runtime ID, and
  coordinator-runtime ID. A late invalidated completion cannot publish into another runtime.
  Failed recovery saturating-merges its scalar missed-observation claim with observations received
  during the attempt.
- Ingress retains its shared 4,096-record/32-MiB default and 8,192-record/64-MiB hard bounds,
  separate 36-record structural lane, normal 256-observation/4-MiB quantum, and one bounded
  oversize Event path. The remediation adds no Event or per-generation retention.
- Maintenance remains one replaceable periodic wake and at most eight immediate campaign turns.
  Shutdown clears dirty successors and establishes maintenance-queue quiescence before one finite
  ingress flush. No recurring cleanup or retry work holds the application open.

## Nonactionable Bounded Worker-Tail Observation

The Round 15 terminal-close handoff observation remains nonactionable under the goal threshold.
A worker can sample a still-present successor request, unlock, and then have terminal close clear
authority before the worker physically submits that successor. The submitted closure reaches only
the first locked guard, clears the internal worker token, and returns
(`ViewerStoreCoordinator.swift:1872-1888`).

This tail is capped at one closure, cannot pass request/generation authority, cannot reach the
execution gate, and performs no filesystem, SQLite, maintenance, recording, gap, status,
session, Event, or successor-scheduling work. The final-current lease remediation neither expands
nor depends on it. It is therefore retained as an evidence-precision note, not an unresolved
finding or approval blocker.

## SQLite, Filesystem, Query, and Export Audit

- Schema migration and acceptance still occur writer-first before either reader opens. Unknown,
  incomplete, future, or corrupt schema fails closed without deletion or automatic recreation.
  JSON1, FTS5, WAL, full synchronization, foreign keys, defensive mode, untrusted schema,
  memory-only temporary storage, and `secure_delete` are probed or configured as documented.
- Writer, interactive reader, and export reader remain three serialized owners. Progress handlers
  enforce generation-bound cancellation and VM/time budgets; late cancellation cannot interrupt a
  later generation. Query and export use short transactions and do not retain a SQLite snapshot
  while awaiting UI or file I/O.
- Query inputs retain closed bounds and grammar. Search/JSON values are bound parameters; FTS
  terms are literalized; Event-type prefix uses binary `substr`; JSON containment uses `instr`;
  keyset pages contain 1 through 200 rows; cursor fingerprint, frozen upper IDs, and finite leases
  prevent traversal substitution. There is no offset or complete-result materialization.
- Store directories remain owner-only `0700`; database, WAL, SHM, rollback/migration, and export
  temporary files remain regular nonsymlink owner-only `0600` files. Sidecars are validated before
  and after WAL activation and close.
- Export retains the opened parent directory and original temporary descriptor, validates
  descriptor/leaf/parent identity, synchronizes and closes before the commit seal, and uses
  descriptor-relative `renameat`. Pre-commit failure or cancellation removes temporary state and
  preserves the prior destination. Successful rename remains the single irreversible commit
  point.
- Export remains streaming: one Event, bounded metadata/data pages, a 64-KiB output buffer, one
  finite export lease, frozen append-only bounds, stored aliases, and no complete result or alias
  dictionary. Forbidden transport/security/internal fields remain omitted.
- Quota, retention, reclaim, volume-floor, writer-serialized reservation, pinned/active/leased
  protection, and tombstone visibility behavior are unchanged. The remediation creates no new SQL,
  path, schema field, quota category, file operation, or export field.

## Privacy, Reflection, Packaging, and Documentation Audit

### Privacy and diagnostics

- The remediation changes only local lease selection and adds a test. It introduces no Event,
  query, SQL, path, peer identifier, pairing code, certificate, session epoch, raw frame,
  endpoint, or arbitrary error value to status, logs, `UserDefaults`, recent rows, persistence, or
  accessibility output.
- Viewer store/runtime roots, query and export carriers, latest-only change snapshots, paths,
  connections, statements, and cancellation values retain redacted descriptions and closed
  mirrors. No new `print`, OSLog, signpost, analytics, crash annotation, clipboard, or dynamic
  reflection surface was added.
- Internal reopen resource events remain four content-free enum cases and default to a no-op
  outside tests. The new test observes only lifecycle ordering, UUID equality through database
  assertions, and scalar counts.
- The checked-in and built Viewer privacy manifests remain byte-identical. The local store remains
  intentionally on-device and adds no tracking or transmission purpose.

### Packaging and documentation

- `Package.swift` and `NearWire.podspec` are unchanged. There is no external package dependency,
  third-party Core/SDK runtime dependency, nested manifest, nested podspec, project generator,
  shell harness, or new product. The Viewer continues to link the system SQLite library.
- Operator documentation still accurately distinguishes logical history retention from transport
  Event TTL and logical deletion from secure erasure. It states that SQLite and JSON exports have
  no NearWire application-layer at-rest encryption and that FileVault is outside NearWire's
  detection or guarantee.
- Export documentation still states that aliases are pseudonyms rather than redaction, Event/App
  content can identify people or secrets, output is outside Viewer quota/retention, and the chosen
  destination may synchronize or back up the file.
- Runtime/gap documentation remains accurate: late older-runtime callbacks cannot attach to or
  close a replacement runtime, and a newer runtime can begin networking while bounded older
  cleanup finishes. The final-current lease correction strengthens that promise without changing
  a user-visible API or requiring new operator instructions.

## Evidence Accuracy

- `implementation-validation-round16.md` records nine remediation/application scenarios run 20
  times each: 180 tests, zero failures. The matrix now contains the exact final-C-before-late-B
  ordering that Round 15 lacked.
- The saved Store result is 92 tests with one explicit machine-local live-resource-audit skip and
  zero failures. The unsigned Viewer result is 173 tests with the same one skip and zero failures;
  the two configured-signing tests are excluded rather than counted as passes or skips.
- The package result executes 536 tests with seven disclosed condition-based environment/platform
  skips and zero failures. Those skips are not represented as passing. Later remediation is
  Viewer-only, so reusing the current previously built Core/SDK products is accurately stated.
- Root package and podspec hashes are unchanged from the successful Round 9 CocoaPods evidence.
  The validation correctly claims only unchanged-input applicability, not a fresh CocoaPods pass.
- The built privacy resource matches the checked-in resource, the final Viewer code dylib links
  `/usr/lib/libsqlite3.dylib`, and the manifest dump confirms no external dependencies, iOS 16,
  macOS 13, Swift language version 5, and the four intended products.
- The only explicit live-resource test skip and the two configured-signing exclusions remain
  visible. No narrow focused result is used to substitute for the complete Store, Viewer, or
  package gates.

## Fresh Validation

This review independently reused the final Round 16 built products and ran the nine focused
runtime/remediation/application tests:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound16Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound16ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound16ModuleCache \
  test-without-building [nine focused -only-testing selections]

ViewerStoreTests: 9 tests, 0 skipped, 0 failures
0.216 seconds test execution
/tmp/NearWireViewerRound16Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-41-00-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

The complete Store suite was also rerun independently:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound16Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound16ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound16ModuleCache \
  test-without-building -only-testing:NearWireViewerTests/ViewerStoreTests

ViewerStoreTests: 92 tests, 1 explicit live-resource-audit skip, 0 failures
4.366 seconds test execution
/tmp/NearWireViewerRound16Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-41-48-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

Fresh specification, whitespace, hygiene, formatting, package, privacy, and binary checks
produced:

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

swift package --disable-sandbox --scratch-path /private/tmp/NearWireRound16ReviewDumpPackage dump-package
exit 0; no external dependencies; iOS 16; macOS 13; Swift language version 5;
products NearWire, NearWireUI, NearWirePerformance, and internal NearWireCore

Package.swift
93dbfe2b33b9017b85fd27a6b73f524d7ca4cd5dcd3aeaa350f084c1eb23e0d1

NearWire.podspec
4845721a210c9afd6fa88c0dcdfb23556f3db66f9c51b44b0dd22c74467e9b33

checked-in and built Viewer PrivacyInfo.xcprivacy
dd1a6a9d17cafb1792382fe0ac61d82d4c61d179d82d091e9421c96127283ec9

final Viewer code dylib
/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 382.0.0)
```

The isolated manifest evaluation emitted read-only user-cache warnings but completed successfully
from the explicit temporary scratch/module-cache paths. These environment warnings are not hidden
and do not change the manifest result.

## Deferred Validation

The configured signing, entitlement assertions, and stable-signer update-boundary probe remain
deferred exclusively to goal-level `release-hardening`. They are not unresolved findings and are
not counted as passing validation for this change.

## Unresolved Count

**Zero actionable findings remain unresolved: 0 High, 0 Medium, 0 Low. Security/performance/documentation approval is granted.**
