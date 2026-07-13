# Implementation Review Round 14 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Not approved. Exact unresolved actionable finding count: 1 — 0 High, 1 Medium, 0 Low.**

`NW-LSS-IMPL-R13-ARCH-001` is resolved. Automatic reopen work now carries its authorizing runtime ID and a monotonic attempt generation, is checked before construction and publication, is invalidated by matching runtime end, newer runtime start, and terminal close, and closes a constructed replacement that loses authority before publication. The new coordinator-level and real application regressions prove the reported pre-construction cancellation paths.

One recovery-authority leak remains across logical runtimes. An explicit Retry Storage request sets the process-level automatic reopen reason before its runtime-bound request is admitted. If that explicit request fails or is cancelled with its runtime, the request generation is invalidated but the automatic reason survives. A later runtime therefore performs an automatic database open even though initial bootstrap/path/schema failure is specified to remain explicit-retry-only.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. This review records neither a finding nor a pass for that deferred work.

## Scope and Fresh Evidence

This independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and tasks; current runtime/coordinator, SQLite ownership, maintenance shutdown, session-manager, application-composition, regression-test, and operator-documentation paths; all prior architecture/API verdict and disposition chains; the Round 13 report; `implementation-remediation-round13.md`; and `implementation-validation-round14.md`. It audited automatic and explicit reopen authority, both request-generation checks, replacement disposal, recovery-claim identity, runtime replacement, runtime end, terminal close, initial unavailable startup, public/internal API exposure, packaging, and repository boundaries.

Fresh current-tree validation performed by this review:

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output

find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print
# exit 0; no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
# exit 1; no matches
```

The four direct Round 13 cancellation regressions passed independently using the existing current-tree DerivedData:

```text
ViewerStoreTests: 4 tests, 0 failures
0.084 seconds test execution
/tmp/NearWireViewerRound14Focused/Logs/Test/Test-NearWireViewer-2026.07.13_14-05-38-+0800.xcresult
** TEST SUCCEEDED **
```

The complete package suite was also rerun from the existing current-tree build:

```text
NearWirePackageTests.xctest: 536 tests, 7 skipped, 0 failures
All tests: 536 tests, 7 skipped, 0 failures
```

The seven skips are the declared trust/network-service skips in the restricted review sandbox: two SDK production-TLS tests and five Core secure-transport tests. Round 14 validation records the same 536 tests with zero skips from its environment. That difference is consistent with the tests' explicit environment gates and is not treated as either a product finding or a pass for the seven tests in this fresh run. The saved Round 14 Viewer evidence reports 12 focused tests, 80 repeated cancellation iterations, 87 Store tests with one explicit live-resource-audit skip, and 168 unsigned Viewer tests with that one skip and the two deferred signing tests excluded, all with zero failures.

`swift-format lint` exited zero with the same seven `OnlyOneTrailingClosureArgument` suggestions and one test-only `ReplaceForEachWithForLoop` suggestion recorded in the validation evidence. Boundary search found no store/reopen implementation in Core or SDK and no public Viewer declaration for the runtime, request, generation, or test seams.

## Prior Finding Disposition

- Rounds 1–3 were closed by the clean Round 4 architecture/API review. Rounds 5–9 were closed by the clean Round 10 review. Current schema, connection, query/export, protocol-observer, maintenance-quiescence, and package boundaries still match those dispositions.
- The Round 11 zero-observation outage marker remains generation-owned and materializes one recording-level unavailable gap without inventing a device.
- Both Round 12 findings remain resolved on their direct paths: intentional coordinator detach enables the next runtime's bounded automatic reopen, failed materialization restores the exact claim, real application Retry/TLS reset reuse one store runtime, and repeated same-ID start preserves the first context and recovery authority.
- `NW-LSS-IMPL-R13-ARCH-001` is resolved in its reported form. `ReopenRequest.automatic` binds the exact runtime ID, every request receives a generation, and `isCurrentReopenRequestLocked` requires request, generation, coordinator absence, and current runtime identity before both construction and publication (`ViewerStoreCoordinator.swift:1301-1304`, `1814-1843`, `1889-1917`). Matching runtime end, newer runtime start, and terminal close invalidate queued work (`ViewerStoreCoordinator.swift:1442-1455`, `1458-1475`, `1757-1795`). A constructed replacement that loses authority is closed before return (`ViewerStoreCoordinator.swift:1835-1843`; `ViewerStoreMaintenance.swift:1304-1318`; `ViewerSQLite.swift:562-566`).
- `testEndedRuntimeCancelsPausedAutomaticReopenAndPreservesNextAttempt`, `testTerminalCloseCancelsPausedAutomaticReopen`, `testNewerRuntimeSupersedesPausedAutomaticReopen`, and `testApplicationRapidStopCancelsPausedAutomaticReopen` cover ended runtime, terminal close, newer-context supersession/late cleanup, and real application Retry followed by termination (`ViewerStoreTests.swift:1594-1813`, `5395-5448`).

## Finding

### `NW-LSS-IMPL-R14-ARCH-001` — Medium — Failed or cancelled explicit retry grants automatic reopen authority to a later runtime

**Confidence: 10/10.**

Initial constructor/bootstrap failure correctly begins with `needsRuntimeReopen == false`, so the first unavailable runtime does not automatically reopen (`ViewerStoreCoordinator.swift:1319-1323`, `1341-1348`, `1458-1494`). However, when no coordinator exists, every explicit `retryStorage` call unconditionally sets `needsRuntimeReopen = true` before creating the runtime-bound `.explicit` request (`ViewerStoreCoordinator.swift:1687-1754`).

If construction fails, `attemptReopen` clears only the current typed request and leaves `needsRuntimeReopen` true (`ViewerStoreCoordinator.swift:1820-1833`). If the runtime ends while that explicit request is queued or constructing, `detachRuntime` invalidates the request generation and clears the context, but its early return for `coordinatorRuntimeLogicalID == nil` also leaves `needsRuntimeReopen` true (`ViewerStoreCoordinator.swift:1772-1787`). The next distinct `runtimeStarted` then sees a nil coordinator plus that surviving Boolean and schedules `.automatic` for the new logical ID (`ViewerStoreCoordinator.swift:1458-1490`).

The typed explicit request was correctly cancelled, but its side effect escaped the request generation and became new automatic authority. This is reachable after unknown-schema, corrupt-path, missing-feature, or other initial coordinator-construction failure: one explicit attempt can fail or be cancelled as window A closes, then merely opening window B probes the database again without another operator action. If external repair occurred between the windows, B can publish successful recovery without the explicit successful retry required by the design. If repair did not occur, each later runtime may perform another bounded but unauthorized automatic probe.

This violates the approved distinction that startup path/schema/bootstrap failure remains explicit-retry-only and unavailable until an explicit successful retry (`design.md:34-45`; `specs/viewer-local-store-search/spec.md:17-21`). It also makes the Round 13 claim that explicit authority is captured by the current runtime incomplete: the request is captured, but its automatic eligibility side effect is not. The issue is Medium because it crosses a recovery-authority and failure-boundary decision, although each attempt remains finite and fail-closed and does not corrupt data or block networking.

Required resolution:

1. Separate the intentional-detach next-runtime automatic reason from explicit retry state. A failed or cancelled `.explicit(runtimeLogicalID:)` request must not authorize `.automatic` for another logical runtime.
2. Preserve same-runtime explicit retry after failure and the existing stale-automatic cancellation behavior without polling. Define exactly when the intentional-detach automatic opportunity is consumed or retained, and keep that decision generation-bound rather than deriving it from one shared Boolean.
3. Add deterministic regressions for both explicit escape paths: initial unsupported schema with an explicit request cancelled by runtime A ending before construction, and initial unsupported schema with an explicit construction attempt that fails. Repair the schema, start runtime B, and prove B remains unavailable with no recording or automatic construction until B receives its own explicit retry. Retain the existing tests proving that a clean intentional detach still grants exactly one later automatic attempt.

## Lifecycle, Resource, and API Boundary Audit

- A current request must match before coordinator construction and again before publication. Authority loss after construction closes maintenance synchronously and closes export, query, and writer connections; no stale coordinator is published.
- Automatic B cancellation leaves the intentional-detach reason for C; terminal `closeStorage` clears request, recovery, context, sessions, and the reopen reason; newer runtime C replaces B's request and marker while late B cleanup is ignored. Those reported state-matrix cells are correct.
- The remaining invalid cell is `initial unavailable runtime A -> explicit request admitted -> request fails or A ends -> runtime B starts`: the typed request is gone but its shared Boolean still creates an automatic B request.
- Reopen types, generations, gates, status signals, SQLite owners, query/export services, and all test seams remain Viewer-only and module-internal. Core and SDK expose no persistence API or database abstraction. No nested manifest/podspec or third-party Core/SDK dependency exists, and system SQLite remains linked only by the manually maintained Viewer project.
- Persistence remains an observer of validated protocol outcomes and owns no transport sequence, token, mailbox, queue, timeout, admission, or terminal decision.

## Approval Gate

Architecture/API approval requires resolving `NW-LSS-IMPL-R14-ARCH-001`, adding the cancelled/failed explicit-retry cross-runtime regressions, saving fresh affected and complete validation, and obtaining a fresh independent architecture/API review with **zero unresolved actionable findings**. Configured signing, entitlement assertions, and stable-signer validation remain deferred exclusively to `release-hardening` and are outside this finding count.
