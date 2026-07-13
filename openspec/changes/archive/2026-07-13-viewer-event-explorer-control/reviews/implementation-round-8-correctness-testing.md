# Correctness and Testing Implementation Review — Round 8

## Scope and disposition

This was a fresh, independent review of the complete working tree and the active
`viewer-event-explorer-control` change. The review covered the normative specs and design,
gateway replacement linearizability, renderer/composer cancellation-to-delivery handoff,
cleanup joins, test determinism, and the accuracy of the recorded validation evidence.

The round-7 gateway remediation correctly retires operation and group ownership before invoking
arbitrary completions, serializes replacement transitions, and publishes a successor only after
the previous generation is sealed. The generic delivery gate and tracker also correctly distinguish
cancellation before and after delivery claim, and cleanup joins claimed MainActor deliveries for
both renderer generation and composer preparation. No unresolved correctness issue was found in
those remediations.

## CT-R8-001 — P2 Medium: a store test removes SQLite shared-memory while the pool is still open

**Confidence:** High

`ViewerStoreTests.tearDownWithError()` removes every registered temporary directory
(`Viewer/NearWireViewerTests/ViewerStoreTests.swift:109-111`).
`testWholeTransactionPlanIncludesInitialDispositionAndDuplicateIsZeroQuota()` creates a
`ViewerSQLitePool` at line 6680 and installs a capacity-recovery closure retaining its maintenance
owner at lines 6725-6738, but reaches the end of the test at line 6764 without explicitly closing
the pool. The pool owns three SQLite connections and exposes the required deterministic
`close()` operation at `Viewer/NearWireViewer/Store/ViewerSQLite.swift:796-881`; relying on
`deinit` does not guarantee that those descriptors are closed before XCTest calls teardown.

This is not hypothetical or limited to noisy aggregate output. Ten isolated iterations of only
this test all passed their assertions, but every iteration emitted the libsqlite client API
violation:

```text
BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation:
vnode unlinked while in use: .../Store/NearWire.sqlite-shm
invalidated open fd: 10
Executed 10 tests, with 0 failures
```

The fresh complete Viewer run reproduced the same diagnostic for the same test before reporting
266 tests, 2 skipped, and 0 assertion failures. Therefore the round-7 evidence statement that the
suite had zero test failures is numerically accurate, but it does not establish clean SQLite
resource teardown and omits a deterministic system-reported API violation. The violation can
invalidate later file-descriptor or cleanup checks and creates an avoidable source of
order-dependent failures even though no production data corruption was demonstrated here.

**Required action:** make the test own deterministic resource shutdown, preferably by adding
`defer { pool.close() }` immediately after pool construction (and joining any asynchronously
retained maintenance/status work first if the corrected test reveals such ownership). Then rerun
the isolated test for at least ten iterations and the complete Viewer suite, requiring both zero
test failures and absence of the libsqlite API-violation diagnostic. Record those exact results in
the active change evidence.

## Validation performed

- Round-7 gateway and renderer/composer remediation tests, ten iterations each: 90 tests, 0
  failures.
- Complete Viewer suite with the configured signing/entitlement test skipped: 266 tests, 2 skipped,
  0 assertion failures; CT-R8-001 reproduced once.
- Isolated CT-R8-001 reproduction: 10 tests, 0 assertion failures; the libsqlite API violation
  reproduced in all 10 iterations.
- Swift Package suite: 537 tests, 0 failures.
- `openspec validate viewer-event-explorer-control --strict --no-interactive`: passed.
- `git diff --check`: passed.

Configured signing and embedded-entitlement validation is intentionally deferred to the final
Goal-level `release-hardening` verification and is not a finding in this review.

**Unresolved findings: 1**
