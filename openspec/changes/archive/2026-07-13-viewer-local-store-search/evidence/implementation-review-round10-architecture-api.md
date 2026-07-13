# Implementation Review Round 10 — Architecture/API

Date: 2026-07-13 (Asia/Shanghai)

## Verdict

**Approved. Exact unresolved actionable finding count: 0 — 0 High, 0 Medium, 0 Low.**

The complete current change is consistent with the active proposal, design, capability specifications, and repository boundaries. All three Round 9 architecture findings are resolved in implementation and focused regressions: maintenance is lifecycle-invalidated and quiesced before the terminal flush, SQLite schema migration and acceptance occur on the writer before either reader opens, and runtime recovery retains a generation-bound missed-observation claim until durable recovery work completes. No new architecture or API issue was found.

Configured signing, entitlement assertions, and the stable-signer update-boundary probe remain explicitly deferred, by user direction, to the goal-level `release-hardening` change. This review records neither a finding nor a pass for that deferred work.

## Scope and Evidence Basis

This fresh independent review read `AGENTS.md`; the complete active proposal, design, both capability specifications, and task plan; the complete current production, test, packaging, and operator-documentation change; all three Round 9 implementation-review reports; `implementation-remediation-round9.md`; and `implementation-validation-round10.md`. It retraced the writer, ingress, maintenance, query, export, runtime-recovery, session-journal, and shutdown ownership graphs and rechecked public/internal API exposure, reflection boundaries, Core/SDK/Viewer placement, packaging constraints, compatibility settings, and excluded product scope.

The review also ran the complete current `ViewerStoreTests` suite independently:

```text
xcodebuild -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWireViewerRound10ArchitectureReviewDerived \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH=/tmp/NearWireRound10ArchitectureModuleCache \
  SWIFT_MODULECACHE_PATH=/tmp/NearWireRound10ArchitectureModuleCache \
  test -only-testing:NearWireViewerTests/ViewerStoreTests

Executed 79 tests, with 1 test skipped and 0 failures
** TEST SUCCEEDED **
/tmp/NearWireViewerRound10ArchitectureReviewDerived/Logs/Test/Test-NearWireViewer-2026.07.13_12-38-14-+0800.xcresult
```

The one skip is the explicit opt-in live Application Support audit and is not represented as a pass.

## Round 9 Architecture Finding Disposition

- **NW-LSS-IMPL-R9-ARCH-001 — resolved.** `ViewerStoreMaintenanceOwner.runtimeEnded()` invalidates the lifecycle, recovery publication, pending work, and dirty successors. `waitForQuiescence()` then establishes a serial maintenance-queue barrier before the coordinator begins preparation shutdown and its single terminal ingress flush (`ViewerStoreMaintenance.swift:1286-1317`, `ViewerStoreCoordinator.swift:706-777`). A queued campaign validates lifecycle ownership before execution, while a campaign already in progress must finish before shutdown crosses the barrier (`ViewerStoreMaintenance.swift:1349-1427`). `testRuntimeShutdownQuiescesMaintenanceBeforeOneTerminalFlush` deterministically proves the terminal flush cannot overlap maintenance ownership and that an invalid dirty successor performs no work (`ViewerStoreTests.swift:4233`).
- **NW-LSS-IMPL-R9-ARCH-002 — resolved.** Pool construction opens the writer, migrates and probes the schema, emits schema acceptance, and only then opens and probes the query and export readers (`ViewerSQLite.swift:507-596`). Each connection remains local until full construction succeeds, so an error unwinds without publishing a partial pool. `testReadersOpenOnlyAfterSchemaAcceptanceAndNeverOnMigrationRejection` verifies the successful order and proves unknown and incomplete schemas stop before either reader opens (`ViewerStoreTests.swift:140`).
- **NW-LSS-IMPL-R9-ARCH-003 — resolved.** `recoverRuntimeAndSessions` reports completion only after recording materialization, all required live-device materialization, and bounded gap ownership (`ViewerStoreCoordinator.swift:329-375`). `ViewerStoreRuntime` moves missed observations into an exact generation-bound claim, clears it only on matching successful completion, and saturating-merges it back with concurrent misses on failure (`ViewerStoreCoordinator.swift:1646-1713`, `1753-1868`). Coordinator/runtime identity checks reject obsolete callbacks. The fresh-reopen and same-coordinator regressions prove post-admission materialization failure retains the exact aggregate until a successful retry (`ViewerStoreTests.swift:1124`, `1190`).

## Architecture and API Recheck

- The sole SQLite writer remains the authority for migration, mutation planning, disk admission, transactions, maintenance, and failure-generation publication. Query and export readers are serialized independently, bounded by progress budgets and frozen row-ID snapshots, and do not migrate or mutate the store.
- Runtime, coordinator, ingress, and maintenance recovery are generation-bound. Queue admission is distinct from recovery completion; late callbacks cannot attach to or reopen a replacement runtime; and terminal shutdown has one finite ingress prefix followed by pool close.
- Settings-triggered recovery is bound to the exact serialized settings revision. A later edit supersedes both queued and already-running publication authority, including when the later revision has no recovery permit (`ViewerStoreMaintenance.swift:1204-1257`, `1386-1406`; `ViewerStoreTests.swift:4356`, `4406`).
- The session manager remains authoritative for protocol sequence, queues, mailbox handoff, timeout, disposition, and terminal decisions. Store journaling callbacks are immutable, bounded, nonthrowing handoffs; persistence failure cannot become protocol authority.
- Internal refresh callbacks retain only the row identities required for trusted in-process invalidation. `ViewerStoreChangeSnapshot` closes description, debug description, interpolation, and mirror traversal while preserving exact callback values (`ViewerEventStore.swift:221-233`; `ViewerStoreTests.swift:1533`).
- The Viewer store, schema, SQLite bridge, query, maintenance, export, preferences, and runtime coordinator are module-internal. No supported SDK persistence or search API was introduced. Core changes remain platform-neutral deterministic-byte and diagnostic-reflection behavior; SDK production code is unchanged.
- SQLite remains Viewer-only and links the system `libsqlite3`. The root Swift package has no external dependency, no nested `Package.swift` or podspec exists, and no third-party runtime dependency entered Core or SDK. The Viewer continues to consume the root package locally through its manually maintained Xcode project.
- Distributed source remains Swift 5 language mode; the root package retains iOS 16 and macOS 13 platform declarations, and the Viewer target remains macOS 13 compatible with explicit concurrency ownership.
- Current UI scope is limited to storage configuration, safe status, cleanup, and explicit retry. Timeline/history browsing, search UI, event detail rendering, export selection UI, control composition, charts, import, cloud/server, and SDK persistence remain outside this change and are absent.

## Fresh Static Validation

```text
env DO_NOT_TRACK=1 openspec validate viewer-local-store-search --strict --no-interactive
Change 'viewer-local-store-search' is valid

git diff --check
# exit 0; no output

rg -n 'NWDEBUG|TODO\(NearWire\)|FIXME\(NearWire\)' Core SDK Viewer Demo Documentation
# exit 1; no matches

find . -mindepth 2 \( -name Package.swift -o -name '*.podspec' \) -print
# exit 0; no nested manifest or podspec
```

## Approval Gate

Architecture/API implementation review is approved with **zero unresolved actionable findings**. The change may proceed to the remaining independent Round 10 review gates and final spec-to-evidence audit. The configured-signing, entitlement, and stable-signer work remains deferred exclusively to `release-hardening` and is outside this approval.
