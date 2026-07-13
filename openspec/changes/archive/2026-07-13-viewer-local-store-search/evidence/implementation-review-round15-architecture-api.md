# Implementation Review Round 15 — Architecture and API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

The Round 14 remediation resolves all three findings assigned to this review. Explicit retry and
automatic next-runtime authority are now independent; an admitted reopen construction has an
exact request/runtime lease whose shutdown owner waits for resource disposal; and physical reopen
work is bounded to one serial worker chain with one coalesced latest successor rather than one
queued block per runtime generation. No architecture, API, repository-boundary, or evidence-accuracy
regression was found.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain
explicitly deferred, by user direction, to goal-level `release-hardening`. They are neither a
finding nor represented as passing in this review.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both
capability specifications, and task plan; all three Round 14 implementation-review reports;
`implementation-remediation-round14.md`; `implementation-validation-round15.md`; the current
runtime/coordinator, SQLite ownership, maintenance shutdown, session-manager, application
composition, focused and adjacent Store tests, package manifests, Xcode project, privacy and
operator documentation paths.

The review retraced initial unavailable startup, explicit retry with and without a runtime,
intentional coordinator detach, automatic sequential reopen, constructor failure, request
supersession, late old-runtime cleanup, matching and nonmatching runtime end, terminal close,
stale replacement disposal, recovery-claim publication, worker handoff, and 64-generation
coalescing. It also rechecked public/internal API exposure and the Core/SDK/Viewer packaging
boundary.

## Round 14 Finding Disposition

### `NW-LSS-IMPL-R14-ARCH-001` — Resolved

Explicit retry no longer creates automatic authority for a later runtime.

- `retryStorage()` creates only a typed `.explicit(runtimeLogicalID:)` request when no coordinator
  exists; it does not write the persistent automatic-reopen reason
  (`ViewerStoreCoordinator.swift:1732-1800`).
- `needsRuntimeReopen` is set only when the coordinator owned by a logical runtime is intentionally
  detached (`ViewerStoreCoordinator.swift:1822-1850`). Constructor failure, explicit failure, and
  cancellation do not synthesize that reason.
- Every request must match the current runtime shape: automatic and runtime-bound explicit requests
  require the exact logical ID, while an explicit no-runtime request requires the deliberate nil
  context (`ViewerStoreCoordinator.swift:1982-2028`). Successful replacement consumes the retained
  reason; terminal close clears it (`ViewerStoreCoordinator.swift:1484-1500`, `1938-1947`).
- `testFailedInitialExplicitRetryDoesNotAuthorizeLaterRuntime` and
  `testCancelledInitialExplicitRetryDoesNotAuthorizeLaterRuntime` prove that failure and
  post-authorization cancellation in runtime A leave runtime B unavailable until B performs its
  own explicit retry (`ViewerStoreTests.swift:1149-1297`).

The separation is structural rather than timing-dependent: a surviving intentional-detach reason
can authorize a later automatic request, while a standalone explicit request has no path that can
create that reason.

### `NW-LSS-IMPL-R14-CT-001` — Resolved

Shutdown completion now owns every already-admitted reopen construction that belongs to it.

- The worker reserves a `ViewerStoreReopenConstructionLease` while holding the runtime lock and
  before entering the deterministic execution gate or constructing SQLite ownership
  (`ViewerStoreCoordinator.swift:1299-1321`, `1889-1917`). The lease is request- and
  attempt-generation-bound.
- A matching `runtimeEnded` captures the lease even when a newer runtime context has already
  superseded the request, awaits it without holding the runtime lock, and only then completes its
  coordinator shutdown. It does not wait for unrelated newer-runtime construction
  (`ViewerStoreCoordinator.swift:1802-1850`, `1999-2009`).
- Terminal `closeStorage` invalidates request, recovery, context, sessions, and retained reopen
  reason under the lock, then waits for the single current construction lease before closing the
  installed coordinator (`ViewerStoreCoordinator.swift:1484-1500`).
- If construction loses authority, the fresh coordinator closes maintenance and all three SQLite
  owners before the construction lease is completed. The `defer` therefore cannot release a
  runtime-end or terminal-close waiter early (`ViewerStoreCoordinator.swift:1902-1908`,
  `1931-1936`, `2042-2056`; `ViewerStoreMaintenance.swift:1304-1318`;
  `ViewerSQLite.swift:562-566`). Constructor failure also unwinds its partial local ownership
  before the `try?` returns and the lease finishes.

The gate-controlled runtime-end, terminal-close, explicit-cancellation, and newer-runtime tests
prove the required ordering: shutdown remains incomplete while construction is paused; after
release, construction occurs, the stale replacement closes, and only then does shutdown complete
(`ViewerStoreTests.swift:1216-1297`, `1744-2009`, `2090-2168`). The late-superseded-runtime case
also proves that cleanup for B waits B's exact lease while valid runtime C remains independently
eligible.

### `NW-ISPD14-001` — Resolved

Logical request authority and physical worker occupancy are now separate.

- `reopenScheduled` and `reopenRequest` describe only the latest logical request;
  `reopenWorkerScheduled` owns the physical serial worker chain
  (`ViewerStoreCoordinator.swift:1357-1361`, `1982-1997`).
- Superseding a request replaces the latest request/generation but cannot enqueue another worker
  while the worker token is occupied. When the current turn ends, it performs at most one handoff
  to the then-current latest request (`ViewerStoreCoordinator.swift:1853-1887`). Because the queue
  is serial, there is one executing turn and at most one queued handoff successor; repeated runtime
  generations cannot accumulate retained closures.
- Current constructor or recovery failure clears the current request and produces no automatic
  successor. Terminal close invalidates the latest request, so the occupied worker exits without
  handing off. The path adds no timer, polling, sleep, recursive retry, or third executor.
- `testRepeatedRuntimeSupersessionCoalescesOneReopenSuccessor` applies 64 distinct superseding
  runtime IDs while one turn is blocked and proves exactly two gate turns, one final recording,
  no intermediate recording, and one unavailable gap. The terminal variant applies the same 64
  generations and proves one gate turn and no successor publication
  (`ViewerStoreTests.swift:2012-2168`).

The implementation therefore replaces the former O(runtime generations) retained queue work with
a constant physical bound and latest-only logical ownership.

## Architecture, API, and Boundary Audit

- The runtime lock is never held while waiting at the execution gate, constructing or closing a
  coordinator, awaiting a construction lease, shutting down preparation/maintenance, or publishing
  outward status. Lease waits therefore add ownership ordering without introducing a lock/executor
  cycle.
- Request generation, request identity, current runtime identity, coordinator absence, and recovery
  generation are checked at the relevant admission/publication boundaries. An obsolete constructor
  or recovery completion cannot clear, publish into, or close a newer runtime's ownership.
- Same-logical-ID start remains idempotent. Distinct-runtime replacement invalidates old reopen and
  recovery generations before installing the new context. Late old-runtime cleanup cannot detach
  the replacement coordinator or consume its recovery claim.
- The new lease, request, worker, and observer types remain Viewer-internal. They add no supported
  SDK API, public package product, Core database abstraction, wire field, persistence field,
  diagnostic content, or user-visible string.
- Viewer store implementation remains under `Viewer`; no Viewer database source appears in Core,
  SDK, the root package targets, or the CocoaPods subspecs. The root package still has no external
  dependency, the Viewer Xcode project links the system `libsqlite3`, and no nested `Package.swift`
  or podspec exists.
- The Round 15 validation counts and exclusions match the reviewed tree. Its 160 focused executions,
  91-test Store result with one explicit live-resource-audit skip, 172-test unsigned Viewer result
  with that same skip and two signing probes excluded, and unchanged-input package/CocoaPods claims
  are kept distinct. No configured-signing result is implied.

## Fresh Read-Only Validation

The review reused the current Round 15 compiled products. The test binary timestamp
(`2026-07-13 14:20:27`) is later than the reviewed runtime and test source timestamps
(`14:19:53` and `14:20:07`). The first sandboxed test invocation failed before test execution
because Xcode attempted to write user cache/module-cache state; the approved read-only rerun with
the same test selection succeeded.

### Eight remediation and application regressions

```text
ViewerStoreTests: 8 tests, 0 skipped, 0 failures
0.132 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-28-08-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Complete Store regression

```text
ViewerStoreTests: 91 tests, 1 explicit live-resource-audit skip, 0 failures
4.267 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-28-36-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Specification, formatting, structure, and hygiene

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
exit 0, no output

xcrun swift-format lint --recursive Viewer/NearWireViewer/Store \
  Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0; seven nonblocking OnlyOneTrailingClosureArgument suggestions and one test-only
ReplaceForEachWithForLoop suggestion

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
exit 1, no matches

find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print
exit 0, no output

ruby -c NearWire.podspec
Syntax OK
```

## Completion Gate

Architecture/API approval is granted with exactly **zero** unresolved actionable findings. The
active change may proceed to the remaining independent Round 15 review gates; configured signing,
entitlement assertions, and the stable-signer update-boundary probe remain outside this verdict and
deferred to `release-hardening`.
