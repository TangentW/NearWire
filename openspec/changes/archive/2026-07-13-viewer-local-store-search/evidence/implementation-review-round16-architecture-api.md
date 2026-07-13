# Implementation Review Round 16 — Architecture and API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

`NW-LSS-IMPL-R15-CT-001` is resolved. Ending the final current runtime now takes ownership of the
one active reopen-construction lease even when that construction belongs to a stale predecessor.
Noncurrent late cleanup still uses exact-request identity, so old-runtime cleanup cannot drain a
valid newer runtime. The change preserves the existing request, generation, resource-disposal,
worker-coalescing, and recovery-publication boundaries.

All prior implementation findings remain resolved on the current tree. No architecture, API,
isolation, ownership, repository-boundary, specification-alignment, or evidence-accuracy issue was
found.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain
explicitly deferred, by user direction, to goal-level `release-hardening`. They are neither a
finding nor represented as passing in this review.

## Scope

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both
capability specifications, and task plan; all three Round 15 implementation-review reports;
`implementation-remediation-round15.md`; `implementation-validation-round16.md`; current
runtime/coordinator, construction-lease, worker, SQLite, maintenance, session-manager,
application-lifecycle, test, package, Xcode-project, privacy, and operator-documentation paths.

The review retraced unavailable startup, explicit and automatic reopen authority, intentional
detach, same-ID start, B-to-C supersession, final-current C shutdown before late B cleanup,
concurrent and repeated lease waiters, stale constructor failure and success, replacement close,
later D recovery, recovery claims, terminal close, physical worker handoff, and application cleanup
ownership. It also rechecked the disposition chain for earlier data, query, export, filesystem,
privacy, packaging, and finite-shutdown findings.

## Round 15 Finding Disposition

### `NW-LSS-IMPL-R15-CT-001` — Resolved

The two cleanup authorities are now intentionally different:

- `detachRuntime(logicalID:)` determines current-runtime ownership while holding the runtime lock.
  If the ending logical ID is current, it captures `reopenConstruction?.lease` regardless of the
  predecessor request ID. Clearing the last current context makes that one active construction
  stale, so current shutdown owns its resource disposal
  (`ViewerStoreCoordinator.swift:1822-1843`).
- If cleanup is noncurrent, the existing exact-ID helper remains in force. It returns a lease only
  when the active automatic or runtime-bound explicit request carries that cleanup's logical ID;
  an old B cleanup therefore cannot wait for valid C or D construction
  (`ViewerStoreCoordinator.swift:1830-1832`, `2001-2012`).
- Lease selection and request invalidation are atomic under `NSLock`, but the asynchronous wait is
  performed after unlock. The runtime then shuts down any detached coordinator and schedules only
  a still-matching captured successor (`ViewerStoreCoordinator.swift:1802-1819`, `1833-1852`).
- The construction lease is reserved after the first authority check and before the execution gate
  or filesystem/SQLite constructor (`ViewerStoreCoordinator.swift:1891-1912`). If the request loses
  authority, the new coordinator closes maintenance and all three SQLite connections before the
  defer finishes the lease (`ViewerStoreCoordinator.swift:1928-1938`, `2044-2058`;
  `ViewerStoreMaintenance.swift:1304-1318`; `ViewerSQLite.swift:562-566`).

This closes the exact Round 15 ordering:

1. A detaches cleanly and retains one automatic next-runtime reason.
2. B begins an authorized construction and pauses after reserving its lease.
3. C supersedes B and owns the current runtime context plus the coalesced latest request.
4. C ends before late cleanup for B arrives.

At step 4, C now captures B's active lease, invalidates C's latest request, and remains incomplete
until B constructs, fails its publication check, closes the replacement, and finishes the lease.
Late B cleanup is then a harmless noncurrent no-op. The retained intentional-detach reason remains
available, so later D receives one automatic attempt and one unavailable gap.

`testFinalCurrentRuntimeWaitsForSupersededReopenConstruction` exercises that full sequence. It
proves C enters `runtimeEndWaiting`, cannot complete while B is paused, observes B construction and
stale close before completion, creates no B or C recording, tolerates late B cleanup, and gives D
exactly one successful automatic recovery and gap (`ViewerStoreTests.swift:2012-2123`).

### Ownership matrix

| Cleanup call | Active construction | Wait decision |
|---|---|---|
| current B ends | B-owned | waits the active lease |
| current C ends | stale B-owned | waits the active lease |
| noncurrent B cleanup | B-owned while C remains current | waits B's exact lease |
| noncurrent B cleanup | C- or D-owned | does not wait |
| terminal close | any active construction | waits the active lease |

The matrix prevents both premature final shutdown and an old runtime globally draining legitimate
newer ownership.

## Prior-Finding Re-Audit

### Reopen authority, leases, and physical work

- Explicit Retry still creates only typed explicit authority. It cannot create the independent
  process-lifetime automatic reason. Only intentional detach of a coordinator associated with a
  logical runtime sets `needsRuntimeReopen`; successful replacement and terminal close consume it
  (`ViewerStoreCoordinator.swift:1732-1800`, `1844-1852`, `1940-1950`). This preserves the
  resolution of `NW-LSS-IMPL-R14-ARCH-001`.
- Construction still has one request- and generation-bound lease, two authority checks, and
  close-before-finish disposal. Matching end, final-current end, noncurrent exact cleanup, and
  terminal close now cover every required shutdown owner without holding the runtime lock while
  waiting. This preserves the resolution of `NW-LSS-IMPL-R14-CT-001` and closes
  `NW-LSS-IMPL-R15-CT-001`.
- Logical latest-request state remains separate from physical worker occupancy. Superseding
  generations replace one request; one serial worker performs at most one handoff to the current
  latest successor. Constructor/recovery failure adds no automatic retry, and terminal close
  clears successor authority (`ViewerStoreCoordinator.swift:1855-1889`, `1984-2042`). The former
  O(runtime generations) queue growth from `NW-ISPD14-001` remains removed.
- Ownerless publication from `NW-LSS-IMPL-R13-ARCH-001` / `NW-ISPD13-001` remains impossible:
  request, generation, coordinator absence, and current-runtime identity must still match at both
  construction admission and publication. A stale replacement is closed rather than installed.
- Sequential automatic reopen, same-ID idempotence, recovery-claim ownership, and unavailable-gap
  accounting from the Round 10 through Round 12 findings remain generation- and coordinator-bound.
  Late constructor, recovery, or runtime-cleanup completion cannot clear or publish into a newer
  runtime.

### Runtime, writer, query, export, and resource boundaries

- `ViewerMultiDeviceSessionManager.beginShutdown()` remains idempotent through one stored shutdown
  task. It waits for device shutdown before calling `journal.runtimeEnded` with its exact logical
  runtime ID (`ViewerMultiDeviceSessionManager.swift:195-224`). Application cleanup keeps that
  ownership alive through the bounded receipt even if the UI wait times out.
- Runtime, construction, maintenance, preparation, writer, query, export, and Main Actor work retain
  their prior lock/executor separation. No reviewed path waits, opens or closes SQLite, runs
  maintenance, flushes preparation, or publishes status while holding the runtime lock.
- Writer-first migration and schema acceptance still precede opening the interactive and export
  readers. Writer-authoritative recovery, reserve admission, finite ingress/maintenance work,
  generation-bound cancellation, short query/export transactions, frozen keyset bounds, and one
  finite terminal flush remain unchanged.
- A successful stale construction cannot retain startup maintenance or SQLite ownership: stale
  close quiesces maintenance, then closes export, query, and writer connections before lease
  completion. Constructor failure unwinds partial local ownership before the lease finishes.
- The current change adds no Event, query, SQL, path, endpoint, pairing, certificate, session epoch,
  raw frame, or peer-controlled value to status, reflection, logs, preferences, persistence, or
  diagnostics. Store/runtime descriptions and mirrors remain closed.

### API and repository boundaries

- `ViewerStoreRuntime`, `ViewerStoreReopenConstructionLease`, `ReopenRequest`,
  `ReopenConstruction`, and `ViewerStoreReopenResourceEvent` remain Viewer-internal. The remediation
  adds no supported SDK API, public package product, wire/schema field, persistence format, or
  user-visible behavior.
- Store, SQLite, maintenance, query, and export implementation remains under `Viewer`. No Viewer
  database type appears in Core, SDK, `Package.swift`, or `NearWire.podspec`.
- The root package still has no external dependency, targets iOS 16 and macOS 13 in Swift 5 language
  mode, and retains the existing products. No nested package manifest, nested podspec, project
  generator, shell harness, or third-party Core/SDK runtime dependency exists.
- The manually maintained Viewer Xcode project continues to link the system `libsqlite3` and keeps
  Viewer-only source out of the root Swift Package targets.

### Specification and documentation alignment

- Final-current shutdown now owns stale predecessor construction and resource release, matching the
  finite-owned-flush requirement. A valid newer runtime can still overlap old bounded cleanup, as
  allowed by the design and operator documentation.
- The change does not alter Event identity, durable admission, gap, quota, retention, query,
  pagination, export, privacy, or at-rest-encryption semantics. Current documentation continues to
  distinguish logical quota from allocated SQLite footprint, retention from Event TTL, secure
  delete from guaranteed erasure, and export pseudonyms from redaction.
- The UI boundary remains limited to storage settings, status, cleanup, and Retry. No explorer,
  timeline, renderer, export-selection, control-composition, or performance-chart scope was added.

## Review-Threshold Observation

The terminal-close guard-only worker tail remains non-actionable under the user's Goal threshold.
The only possible post-close work is one already-sampled successor closure reaching its first
locked guard, clearing worker occupancy, and returning. It cannot reach the execution gate,
filesystem, SQLite, maintenance, status publication, recording, or another successor; it cannot
accumulate with runtime generations. Round 15 evidence already classified this bounded private
bookkeeping tail accurately, and the Round 16 remediation does not change it or add material
impact.

## Evidence Accuracy

`implementation-validation-round16.md` matches the current tree and keeps unlike evidence
separate:

- nine focused scenarios times 20 iterations equals 180 successful test executions;
- the Store suite contains 92 tests, with one explicit live-resource-audit skip and no failure;
- the unsigned Viewer suite contains 173 tests, with that same one skip and no failure while the two
  configured-signing tests are excluded rather than counted;
- the unchanged Core/SDK package suite records 536 tests, seven disclosed condition-based skips,
  and no failure;
- the current remediation is Viewer-only, so package build reuse and unchanged-input CocoaPods
  evidence are disclosed rather than described as fresh builds; and
- the manifest-cache failure, configured-signing deferral, formatting suggestions, privacy
  comparison, and system-SQLite linkage are reported without broadening them into unrelated passes.

No configured-signing, entitlement, or stable-signer result is inferred by this approval.

## Fresh Read-Only Validation

The review reused the current Round 16 compiled products. The test binary timestamp
(`2026-07-13 14:36:00`) is later than the reviewed runtime and test source timestamps
(`2026-07-13 14:34:01`).

### Nine-scenario repeated stress

```text
ViewerStoreTests: 180 tests, 0 skipped, 0 failures
3.427 seconds test execution
/tmp/NearWireViewerRound16Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-45-00-+0800.xcresult
** TEST EXECUTE SUCCEEDED **
```

### Complete Store regression

```text
ViewerStoreTests: 92 tests, 1 explicit live-resource-audit skip, 0 failures
4.184 seconds test execution
/tmp/NearWireViewerRound16Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-43-40-+0800.xcresult
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

The authoritative saved complete unsigned Viewer and package results remain those recorded in
`implementation-validation-round16.md`. This review did not run the configured-signing tests.

## Completion Gate

Architecture/API approval is granted with exactly **zero** unresolved actionable findings. The
active change may proceed to the remaining independent Round 16 review gates; configured signing,
entitlement assertions, and the stable-signer update-boundary probe remain outside this verdict and
deferred to `release-hardening`.
