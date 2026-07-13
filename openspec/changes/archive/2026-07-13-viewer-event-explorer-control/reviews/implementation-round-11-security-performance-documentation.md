# Security, Performance, and Documentation Implementation Review — Round 11

Date: 2026-07-14

## Result

No actionable security, performance, privacy, lifecycle, or documentation finding remains in the
reviewed Round 10 remediation.

## Rejected traversal successors and bounded ownership

The gateway now distinguishes a direct request made while no Store is available from a successor
whose predecessor has lost ownership. The former keeps a delivery-valid generation-zero token so
its closed `unavailable` result can be presented. The latter receives a generation-zero token backed
by an already-invalid validity cell, and its synchronous `storeReplaced` callback therefore retires
controller work without applying presentation state (`ViewerStoreExplorerGateway.swift:47-59,
501-534`). Query, page, and gap successor entry points all use this same helper.

The invalid token contains only an operation UUID, generation number, and content-free validity
cell. Its description, debug description, and reflection remain redacted. It is neither inserted
into the gateway operation table nor retained after the exact callback chain releases it. Normal
generation work remains capped at 16 retained operations; replacement invalidates delivery, seals
queued work, interrupts the exact active operation, joins the completion group, and closes the query
arbiter before deferred rejections run (`ViewerStoreExplorerGateway.swift:538-570, 934-971,
1000-1057`). The coordinator gives every release, query, page, and gap callback one delivery box and
one tracked identity, checks the attached token before applying a result, and starts a following
stage only from the still-valid predecessor (`ViewerEventExplorerCoordinator.swift:358-418,
495-596`). Synchronous rejection can therefore queue only the constant number of MainActor handlers
in the current traversal stage; no request-proportional task chain, token collection, or
content-bearing retained result was introduced.

The two coordinator regressions now provide independent failure sensitivity. One invalid page
returns a nonempty Event sentinel while the gap succeeds, and one invalid gap returns a nonempty gap
sentinel while the Event page succeeds. Each result is discarded, the traversal remains incomplete,
tracked work reaches zero, and only a later explicit traversal reaches `ready`
(`ViewerFoundationTests.swift:5534-5684`). The separate synchronous-successor regression covers
release-to-query and query-to-page/gap loss windows (`ViewerFoundationTests.swift:5687-5776`), while
the real gateway regression proves rejected query, page, and gap tokens are independently
delivery-invalid and create no replacement operation (`ViewerStoreTests.swift:2048-2125`).

## SQLite fixture lifecycle

`testRecordingCatalogUsesFrozenDescendingKeysetsAndRelevantChangeRestart` now installs
scope-bound `pool.close()` immediately after successful pool construction
(`ViewerStoreTests.swift:2431-2435`). `ViewerSQLitePool.close()` synchronously closes the export
reader, query reader, and writer (`ViewerSQLite.swift:874-882`), so the test's later XCTest teardown
cannot unlink the database, WAL, or shared-memory vnode while SQLite still owns it. The repeated
focused run and its result-bundle scan contained no SQLite API-violation diagnostic.

## Export privacy and commit semantics

The export boundary remains narrow and truthful:

- The preflight disclosure identifies sensitive Event/App content, unencrypted JSON,
  pseudonym-not-redaction aliases, external quota/retention ownership, and possible provider sync or
  backup (`ViewerStoreExport.swift:23-40`). The sheet displays every item, excludes transient rows,
  and says that NearWire does not remember the destination
  (`ViewerEventExplorerView.swift:820-849`).
- The exporter creates an owner-only nonsymlink temporary sibling, writes and synchronizes bounded
  chunks, closes and validates the file, and couples lease/cancellation validation to the commit
  seal before `renameat`. Rename is the sole irreversible point; observer and best-effort directory
  synchronization failures after rename cannot be reported as pre-commit failure
  (`ViewerStoreExport.swift:330-395, 912-965`).
- Only `executeExport` enables an authoritative successful candidate across cancellation or Store
  replacement, and that candidate exists only after the exporter returns from the atomic replacement
  (`ViewerStoreExplorerGateway.swift:877-895, 1099-1122`). The controller clears the prepared ticket,
  retains the exact export operation while displaying `cancelling`, and accepts invalidated Store
  delivery only for that existing content-free terminal result. The callback publishes a terminal
  state and performs no query, mutation, ticket reuse, dynamic gateway lookup, or successor request
  (`ViewerEventExplorerController.swift:1117-1167, 1902-1925`). Runtime sealing still cancels, clears,
  and joins the operation without repopulating a sealed controller.

The implementation, UI, local-store guide, Event Explorer guide, design, and capability specs all
describe the same pre-commit preservation rule, committed-success authority, synchronous successor
rejection, and joined-cleanup behavior. Targeted source scans found no received/stored Event logging,
analytics, preferences, restoration, drag, share, or clipboard path. The only Viewer pasteboard use
outside operator-owned text editing remains the explicit pairing-code copy action.

## Package and project boundaries

The repository still contains only the root `Package.swift` and root `NearWire.podspec`. The package
dump confirms no external dependency, iOS 16, macOS 13, Swift language mode 5, and no Viewer product
or target. The Viewer project remains macOS 13/Swift 5 with complete strict concurrency, one local
root-package `NearWireCore` product, no remote package, and no shell-script build phase. The Core
wire carrier additions remain internal SPI, preserve redacted reflection, and do not change encoded
wire output.

## Independent validation

- Nine focused traversal, SQLite lifecycle, and export commit-boundary tests repeated five times:
  45 executions passed, 0 failures.
- The result bundle and its stored data contained no `BUG IN CLIENT`, database-integrity, vnode
  unlink, or libsqlite diagnostic. Result bundle:
  `/tmp/nearwire-r11-spd-derived/Logs/Test/Test-NearWireViewer-2026.07.14_03-35-08-+0800.xcresult`.
- The saved Round 10 complete gate reports 276 Viewer tests with 274 passed, two configured skips,
  zero failures, no SQLite API violation, 537 passing package tests, and a successful unsigned
  production build.
- Strict OpenSpec validation, strict recursive Swift format lint, and `git diff --check` passed.
- Root package dump and source Info/privacy/entitlement plist parsing passed. Package cache warnings
  were limited to inaccessible user cache locations and a read-only cache database; the manifest
  compiled successfully with the isolated module cache.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change and are not findings in this review.

**Unresolved findings: 0**
