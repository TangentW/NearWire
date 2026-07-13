# Architecture and API Implementation Review - Round 13

Date: 2026-07-14

## Result

No actionable architecture, API, lifecycle, generation, export-ownership, module-boundary, or
compatibility finding remains in the current final diff. This review re-read the current source and
corrected evidence after SPD-R12-001; it does not inherit the Round 12 conclusion.

## Module and API boundaries

The only shared transport change adds precomputed canonical Event content and deterministic byte
accounting to `WireEventRecord` and `WireReceivedEvent`. Both carriers remain behind the existing
`NearWireInternal` SPI (`WireEventPayloads.swift:7-11, 400-405`), keep content-free reflection, and
preserve the existing wire JSON because encoding still uses the original `EventEnvelope` value.
No public SDK surface, SDK dependency, or Viewer type was added to the root package API.

All Event Explorer, SQLite, gateway, controller, and runtime types remain internal to the Viewer
application module. The root package dump confirms zero dependencies, iOS 16, macOS 13, Swift 5
language mode, and no Viewer product or target. The Viewer target resolves to macOS 13, Swift 5.0,
complete strict concurrency, the local root-package `NearWireCore` product, and no remote package or
shell build phase. This preserves the repository's Core/SDK/Viewer ownership rules.

## Traversal generations and lifecycle ownership

The gateway keeps direct no-Store generation-zero tokens distinct from delivery-invalid rejected
successors (`ViewerStoreExplorerGateway.swift:47-59`). Every `following:` submission checks both the
predecessor's delivery validity and its exact coordinator generation; rejection returns a new
delivery-invalid token and cannot retarget the active replacement generation (`519-534`). Accepted
operations retain their originating generation cell, and replacement invalidates that cell before
sealing work.

The controller and coordinator attach the returned Store token before MainActor presentation work
can consume a synchronously completed result. Every later mutation checks both Store delivery and
the current presentation token. Synchronously rejected query, page, and gap successors therefore
retire tracked work without publishing a stale result or creating replacement-generation work
(`ViewerEventExplorerCoordinator.swift:358-419, 495-595`).

Generation teardown is ordered correctly. `sealAndWait()` invalidates delivery, rejects queued
operations, interrupts the exact active operation, waits for every entered operation, and only then
closes the query arbiter (`ViewerStoreExplorerGateway.swift:934-971`). The arbiter owns one traversal,
ends it on replacement/error/close, and serializes filtered-export scope creation independently of
presentation (`ViewerExplorerQueryArbiter.swift:21-101, 248-260`). Store runtime end and terminal
close seal the originating gateway before closing coordinator storage
(`ViewerStoreCoordinator.swift:1532-1550, 1830-1848`). Viewer shutdown separately seals controller
deliveries, joins controller work, seals control/live admission, and joins admission cleanup before
the runtime components are released (`ViewerApplicationModel.swift:307-353`).

## Export ownership and commit boundary

Prepared export tickets retain the originating coordinator generation and an immutable complete or
filtered scope. Execution rejects a ticket from another generation. Export cancellation and lease
validation are checked through file generation, synchronization, close, and temporary-file
validation; `beginCommit` then seals cancellation and validates the lease before the single
`renameat` commit point (`ViewerStoreExport.swift:330-395, 865-965`). Before rename, failure removes
the temporary sibling and preserves the prior destination. After rename, post-commit hooks and
directory synchronization are best effort and cannot turn committed output into a reported
pre-commit failure.

The gateway marks only a successful export candidate as authoritative after cancellation or Store
replacement (`ViewerStoreExplorerGateway.swift:877-895, 1099-1122`). The controller permits that
content-free terminal export receipt to cross Store-token invalidation, but still requires the same
controller operation and a live, unsealed controller before changing presentation
(`ViewerEventExplorerController.swift:1117-1167`). Sealed runtime cleanup suppresses all late UI
mutation while still joining the underlying export operation.

## Final SQLite test ownership and evidence

The authoritative constructor-site audit is internally consistent and matches the final source:

```text
retained named ViewerSQLitePool constructor sites: 72
immediate matching defer closes: 70
sequencing-point explicit closes: 2
missing retained named owners: 0
```

The 70 defer-eligible `pool`, `setupPool`, and `verification` constructions install their matching
defer immediately after successful construction. The remaining `first` and `reopened` fixtures are
deliberate sequencing cases: each has no intervening throwing operation and closes explicitly before
the next reopen or schema fault injection (`ViewerStoreTests.swift:170-203`). Constructors used only
inside an expected-throw expression retain no pool and are outside the retained-owner count.

This ownership matches XCTest teardown, which removes registered temporary directories only after a
test returns (`ViewerStoreTests.swift:108-112`). `ViewerSQLitePool.close()` synchronously closes the
export reader, query reader, and writer (`ViewerSQLite.swift:878-882`); each connection close clears
its pointer under synchronization and calls `sqlite3_close_v2` only for a non-nil pointer
(`ViewerSQLite.swift:502-512`). Deferred plus explicit safety closes are therefore repeat-safe and
cannot extend a descriptor into directory removal.

The corrected artifacts now distinguish the original 19-fixture reproduction from the final
72-site audit and reference the authoritative paths:

- `/tmp/NearWire-Round11-FinalPoolOwnership.xcresult`
- `/tmp/NearWire-Round11-FinalPoolOwnership-Diagnostics`

I independently read the current result: 276 total tests, 274 passed, two configured skips, zero
failures, and zero expected failures. A fresh raw scan of the saved diagnostic export found zero
matches for `BUG IN CLIENT OF libsqlite3`, `API violation`, `vnode unlinked`, or
`invalidated open fd`. The counts, paths, scan, and deferred signing statement agree across
`implementation-review-round11-remediation.md`, `implementation-review-round12-remediation.md`, and
`validation-6.9-aggregate.md`.

## Fresh validation

- Nine generation, synchronously rejected successor, export commit-boundary, and concurrent runtime
  close tests ran three times each: 27 executions, zero failures. Result bundle:
  `/tmp/NearWire-Round13-Architecture-Lifecycle.xcresult`.
- The fresh result's diagnostics were exported to
  `/tmp/NearWire-Round13-Architecture-Lifecycle-Diagnostics`; the SQLite misuse and XCTest failure
  scan exited 1 with zero matches.
- The affected root package suite passed 537 tests with seven configured skips and zero failures.
- `git diff --check`, strict OpenSpec validation, recursive strict Swift format lint, and project,
  Info, privacy, and entitlement plist parsing passed.
- `swift package --disable-sandbox dump-package` passed with isolated module caches and confirmed the
  package/module/platform boundaries above. Viewer build settings independently confirmed macOS 13,
  Swift 5.0, complete strict concurrency, sandboxing, hardened runtime, and the configured
  entitlement file.

Configured distribution signing and validation of entitlements embedded in a signed product remain
deferred to the Goal-level `release-hardening` change by product-owner decision. That deferred gate
is outside this change's closure claim and is not a finding.

**Unresolved findings: 0**
