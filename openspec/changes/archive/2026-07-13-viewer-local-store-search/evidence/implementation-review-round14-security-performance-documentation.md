# Implementation Review Round 14 — Security, Performance, and Documentation

Date: 2026-07-13 (Asia/Shanghai)

## Scope

This fresh independent review examined `AGENTS.md`; the complete active
`viewer-local-store-search` proposal, design, capability specifications, and task plan; the
current Viewer store/runtime, session-manager, application-lifecycle, test, documentation,
privacy-resource, packaging, and evidence tree; all three Round 13 implementation-review
reports; `implementation-remediation-round13.md`; `implementation-validation-round14.md`; and
the applicable prior security/performance/documentation and resource/filesystem evidence.

The review retraced stale automatic-reopen cancellation through runtime end, terminal close,
replacement-runtime supersession, coordinator construction, publication, and recovery
completion. It then re-audited physical queue ownership, no-polling behavior, lock/executor
ordering, failed-construction and claimed-gap integrity, SQLite/filesystem/export protections,
privacy and diagnostic surfaces, operator disclosures, packaging boundaries, and validation
accuracy.

Production, test, specification, task, packaging, privacy-resource, and operator-documentation
files were not modified. This report is the only file added by this review. Configured signing,
entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred,
by user direction, to goal-level `release-hardening`; they are neither findings nor passing
results in this report.

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 0 Medium, 1 Low.**

## Round 13 Finding Disposition

### `NW-LSS-IMPL-R13-ARCH-001` / `NW-ISPD13-001` — Resolved on the reported stale-publication and resource-retention path

- Reopen authority is now a typed request. An automatic request carries the exact runtime
  logical ID; an explicit request carries either the current logical ID or the deliberate
  no-runtime state. Admission also captures a monotonic reopen-attempt generation.
- `attemptReopen` checks the stored request, attempt generation, coordinator absence, and current
  runtime identity after the execution gate and before constructing SQLite ownership. It checks
  the same authority again before publication. Runtime end, distinct-runtime start, and terminal
  `closeStorage` invalidate obsolete authority while holding the runtime lock.
- If authority changes after construction, the replacement is not installed. The runtime
  unlocks and explicitly calls `replacement.closeStorage()`, which closes maintenance and the
  three-connection pool. The stale turn cannot publish available status, consume the persistent
  reopen-on-next-runtime reason, or materialize an ownerless recording.
- Ending runtime B while its automatic attempt is paused leaves no B recording or idle available
  coordinator, and later runtime C receives one valid automatic recovery. Terminal close and
  application rapid-stop paths likewise prevent stale publication. The four direct regressions
  passed freshly in this review.

The finding below is adjacent to the remediation but is not a recurrence of stale coordinator
publication. Logical authority is generation-safe; physical reopen-queue ownership is not yet
bounded across repeated supersession.

## Finding

### `NW-ISPD14-001` — Low — Repeated runtime supersession can enqueue an unbounded number of stale reopen blocks

`ViewerStoreRuntime` uses `reopenScheduled` both as logical request authority and as if it were a
physical-work occupancy flag. A distinct runtime start calls `invalidateReopenAttemptLocked`
(`ViewerStoreCoordinator.swift:1463-1471`). That method increments the generation and calls
`clearReopenRequestLocked`, which immediately sets `reopenScheduled = false`
(`ViewerStoreCoordinator.swift:1919-1927`). This correctly makes the old request stale, but it
does not remove the old closure already running or retained by the serial `reopenQueue`.

Because the flag is already false, the new runtime can immediately pass
`beginReopenRequestLocked` and enqueue another closure (`ViewerStoreCoordinator.swift:1486-1490`,
`1798-1811`, `1889-1897`). If one predecessor is paused in `reopenExecutionGate` or delayed while
constructing a coordinator, each further distinct runtime generation can repeat that sequence.
The queue therefore retains one captured request/generation closure per superseding runtime,
rather than one active turn plus a bounded latest-only successor. When the predecessor releases,
each stale closure still invokes the gate and performs its generation check before returning
(`ViewerStoreCoordinator.swift:1814-1819`).

The current `testNewerRuntimeSupersedesPausedAutomaticReopen` demonstrates the first instance:
runtime B is blocked and runtime C schedules a second physical queue turn
(`ViewerStoreTests.swift:1760-1772`). It proves that C eventually recovers, but it neither asserts
the gate call count nor exercises many superseding generations. Repeating that test twenty times
starts twenty independent bounded fixtures; it does not test accumulation within one runtime.

The impact is limited, so severity is Low. A device peer, Event rate, database content, or remote
packet cannot create runtime generations; normal production uses the no-op execution gate, and
stale blocks do not construct SQLite after their authority check fails. The retained closures
are small and eventually drain. Nevertheless, a slow filesystem/coordinator construction
combined with rapid failed application Retry/reset or internal replacement-runtime churn can
grow retained queue work linearly with the number of generations. This violates the active
change's finite-shutdown requirement that storage cleanup own no unbounded queue and weakens the
evidence claim that reopen work remains one-shot and bounded.

Required resolution:

1. Separate logical request/generation authority from physical reopen-worker occupancy. Retain
   at most one queued/running worker plus one coalesced latest-request/dirty successor while a
   predecessor is executing.
2. A superseding runtime should replace the bounded latest request rather than enqueue another
   closure. When the current worker exits, it may schedule at most one successor for the latest
   still-authorized request. Terminal close must discard that successor. Do not add a timer,
   polling loop, recursive retry chain, or an automatic successor after construction/recovery
   failure.
3. Preserve the existing two authority checks and explicit close of a replacement that becomes
   stale after construction. Logical cancellation must still leave the process-lifetime
   reopen-on-next-runtime reason available to the latest valid runtime.
4. Add a deterministic regression that blocks one reopen turn, supersedes it with a large fixed
   number of distinct logical runtimes, and proves physical gate/worker turns stay within the
   declared bound, only the latest runtime can materialize, intermediate runtimes create no
   recording, and exactly one unavailable gap is owned by the final runtime. Add the terminal
   close variant proving no dirty successor survives. A post-construction/prepublication gate or
   equivalent resource counter should also prove the already-implemented stale replacement close
   branch releases all three connections.
5. Save fresh repeated, focused, complete Store/Viewer, package, formatting, privacy, and
   packaging validation, and correct any prior statement that treats `reopenScheduled` alone as
   a bound on physical queued work.

## Rechecked Boundaries Without Additional Findings

### Stale work, resource release, locking, and claims

- Ending the exact runtime invalidates its request before clearing context and recovery state.
  Terminal `closeStorage` invalidates reopen and recovery generations before releasing the lock
  and closing the installed coordinator. A newer runtime invalidates predecessor authority before
  publishing its own context.
- The execution gate and coordinator constructor run on the private reopen executor without the
  runtime lock. The stale-after-construction branch also releases the lock before closing the
  replacement. Runtime end awaits coordinator shutdown without holding the lock, and outward
  status publication occurs after unlocking. No new runtime/preparation/writer/maintenance/Main
  Actor lock inversion was found.
- A currently authorized construction failure clears only that request, publishes safe status,
  and schedules no successor. The persistent Boolean reason remains available for a later
  explicit or valid next-runtime trigger. There is no timer, sleep, dispatch recursion, or
  automatic retry polling.
- Recovery still moves the saturating missed aggregate into one generation-bound scalar claim.
  Successful or failed completion requires the exact claim generation, coordinator object,
  runtime logical ID, and coordinator/runtime association. Failure merges the claim back with
  observations accumulated during the attempt using saturating arithmetic; invalidated late
  completion cannot publish into a successor.
- Same-logical-ID `runtimeStarted` remains an early return. It cannot invalidate or enqueue
  reopen work, replace original timestamps, clear sessions, add another outage marker, or disturb
  an in-flight recovery claim.

### SQLite, filesystem, export, and privacy

- Writer-first schema acceptance still precedes the interactive and export readers. Unknown or
  corrupt schema fails closed without deletion or recreation. Query/export work retains short
  transactions, generation-bound cancellation, VM/time budgets, finite leases, keyset/frozen
  bounds, and no complete-result or alias-map materialization.
- Database, WAL, SHM, journal/migration, and export-temporary handling retains owner-only,
  regular-file, no-follow validation. Export retains the original temporary and parent
  descriptors through its commit seal, uses descriptor-relative replacement, and preserves the
  prior destination on pre-commit cancellation or failure.
- The remediation adds only runtime IDs, typed local authority, and scalar generations. It adds
  no Event, query, SQL, path, endpoint, pairing code, certificate, session epoch, raw frame, or
  peer-controlled value to status, reflection, logs, `UserDefaults`, recent rows, or persistence.
  Runtime/store descriptions and mirrors remain closed.
- The checked-in and freshly built privacy manifests remain byte-identical. The Viewer continues
  to link the system SQLite library. No third-party Core/SDK dependency, nested manifest, nested
  podspec, project-generation tool, or new package product was introduced.

### Documentation and evidence accuracy

- Operator documentation still accurately states that local SQLite and exported JSON have no
  NearWire application-layer at-rest encryption; FileVault is outside NearWire's guarantee;
  `secure_delete` is defense in depth, not guaranteed erasure; logical quota differs from
  database/WAL/SHM allocation; and export aliases are pseudonyms rather than redaction.
- The runtime/gap documentation remains accurate for unavailable start, same-runtime retry,
  replacement-runtime isolation, bounded gap aggregation, and late callback rejection. The
  current remediation changes no export field or user-visible disclosure.
- `implementation-validation-round14.md` discloses the initial application-test MainActor error,
  the unrelated sandbox/cache invocation failure, the corrected direct rerun, the 12-test focused
  result, 80-test cancellation stress, 87-test Store result with one explicit live-resource
  audit skip, 168-test unsigned Viewer result with that skip and the two signing tests excluded,
  and the 536-test package result. None of those exclusions is represented as a pass.
- The four new regressions establish stale request invalidation before construction and correct
  final logical state. They do not establish an end-to-end physical queue bound or directly force
  stale authority after construction; the former omission is part of `NW-ISPD14-001`.

All security/performance/documentation findings through Round 12 remain resolved. In particular,
the reflection chain and latest-only change snapshot remain content-free in diagnostics;
preparation/ingress/maintenance/query/export work bounds are unchanged; reserve decisions remain
writer-serialized; shutdown still performs one finite ingress flush; filesystem/export identity
hardening remains intact; privacy and packaging evidence remains applicable; and documentation
continues to distinguish retention from Event TTL and logical deletion from secure erasure.

## Fresh Validation

This review reused the current Round 14 DerivedData tree and reran the four direct cancellation
regressions against the reviewed source:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/NearWireViewerRound14Focused \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/private/tmp/NearWireRound14ModuleCache \
  SWIFT_MODULECACHE_PATH=/private/tmp/NearWireRound14ModuleCache test \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testTerminalCloseCancelsPausedAutomaticReopen \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testNewerRuntimeSupersedesPausedAutomaticReopen \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testApplicationRapidStopCancelsPausedAutomaticReopen

ViewerStoreTests: 4 tests, 0 failures
0.052 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-06-17-+0800.xcresult
** TEST SUCCEEDED **
```

Fresh specification, hygiene, formatting, package-resource, binary, and privacy checks produced:

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

The saved complete current-tree Store, unsigned Viewer, package, repeated cancellation, package
dump, system-SQLite, built-privacy, and unchanged-input CocoaPods evidence remains applicable as
recorded in `implementation-validation-round14.md`. The explicit live-resource skip, configured
signing exclusions, and unchanged-input CocoaPods basis are preserved rather than broadened into
fresh passing claims.

## Unresolved Count

**Exactly one actionable finding remains unresolved: 0 High, 0 Medium, 1 Low. Approval is withheld.**
