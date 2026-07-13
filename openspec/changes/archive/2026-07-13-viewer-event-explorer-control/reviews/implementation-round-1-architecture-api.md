# Architecture/API Implementation Review

## Scope and method

Read-only review of `viewer-event-explorer-control`, focused on architecture boundaries, ownership,
lifecycle, concurrency, and internal API invariants. The reviewer compared implementation and tests
against the active proposal, design, capability specs, tasks, repository guide, and review checklist.
No files were changed. Signing and embedded-entitlement verification were intentionally deferred and
are not findings.

## Findings

### ARCH-001 — P1 High: cancellation is not exact or successor-safe end to end

- `ViewerStoreExplorerGateway.swift:708` validates the gateway token while holding its lock, but
  releases the lock before invoking the untyped `arbiter.cancelCurrentOperation()` at line 732.
- `ViewerExplorerQueryArbiter.swift:199` broadcasts that cancellation to query, diagnostic, and export
  services without an operation identifier.
- `ViewerStoreQuery.swift:739` and `ViewerStoreDiagnostics.swift:216` forward it as
  `cancelCurrentOperation()`.
- `ViewerSQLite.swift:578` snapshots and interrupts whichever SQLite generation is active when
  cancellation finally arrives; it cannot verify that this generation belongs to the gateway token
  originally cancelled.

This permits the required forbidden race:

1. Cancellation validates operation A as active.
2. A completes after the gateway lock is released.
3. Successor B starts on the same SQLite connection.
4. A's delayed `cancelCurrentOperation()` interrupts B.

The result can falsely cancel a page, detail, gap, causality, catalog, or export successor and may also
end its traversal or lease. This violates the exact enqueue-to-completion token requirement and the
explicit “A must not interrupt B” scenario in `viewer-local-store-search`.

The existing test at `ViewerStoreTests.swift:1357` does not exercise this window: it completes A before
starting the successor and provides no hook between gateway token validation and the eventual SQLite
interrupt.

Recommended remediation:

- Carry `operationID` from gateway submission through the arbiter and relevant query/diagnostic/export
  service.
- Bind that external operation ID to the active SQLite generation under
  `ViewerSQLiteConnection.stateLock`.
- Replace `cancelCurrentOperation()` with an exact `cancel(operationID:)` operation that atomically
  compares the requested ID with the currently active ID before setting cancellation state or calling
  `sqlite3_interrupt`.
- Keep export cancellation similarly bound to its own exact operation token.
- Add a deterministic regression test that pauses cancellation after gateway validation, allows A to
  finish and B to become SQLite-active, then releases A's cancellation and proves B completes without
  interruption.

Confidence: 10/10.

## Validation observations

- Changed production implementation remains inside Viewer; no Core or SDK runtime-boundary expansion
  was observed.
- The project declares macOS 13, Swift 5 language mode, and complete strict-concurrency checking.
- Runtime component composition and gateway generation sealing generally preserve the intended
  single-bundle and stale-generation ownership boundaries.
- Production committed-event observation uses the context-validating initializer, preserving
  source/target session checks.
- The reviewer did not rerun the full validation suite; this review is based on source,
  specifications, tests, and saved change evidence.

**Unresolved findings: 1**
