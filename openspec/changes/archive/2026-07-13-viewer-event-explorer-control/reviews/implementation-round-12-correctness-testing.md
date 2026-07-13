# Correctness and Testing Implementation Review — Round 12

Date: 2026-07-14

## Result

No actionable correctness, testing, or lifecycle finding remains after the Round 11 SQLite fixture
remediation and its broader pool-ownership hardening.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change by product-owner decision. That
deferred gate is not a finding in this review.

## CT-R11-001 remediation verification

### Deterministic pool ownership

The original 19 test methods identified by Round 11 now install scope-bound pool cleanup. This
includes the two deterministic reproducers,
`testAppendOnlyDispositionPolicyAndDropSamplesAreIdempotentAndDetectConflicts` and
`testCapacityPauseRunsOneRecoveryAndExplicitProbeResumesAfterCapacityIncrease`, plus the
viewer-time query fixture and every other direct `makePaths()` pool named in the prior audit.

The remediation was then broadened beyond those 19 methods. A function-scope scan of the final
`ViewerStoreTests.swift` finds 70 functions that own at least one named `ViewerSQLitePool`. One
function owns both `first` and `reopened`, so a variable-name audit counts 71 distinct pool variables
across those function scopes. Every one has a matching explicit close and the missing count is zero.
The ordinary `pool` fixtures use exception-safe `defer { pool.close() }`; purpose-specific pools that
must be closed before a later reopen or verification step close explicitly at that boundary.

The cleanup ordering remains safe. Tests with higher-level asynchronous owners still perform their
existing stop, cancel, seal, or queue-join operation before scope exit. `ViewerSQLitePool.close()` is
idempotent and synchronously closes the export reader, query reader, and writer, so a redundant
explicit close plus deferred close cannot reopen work or leave a live SQLite descriptor for XCTest
temporary-directory deletion.

### Focused reproduction and raw diagnostics

The supplied focused result bundle contains three tests repeated ten times:

```text
/tmp/NearWire-Round11-SQLite-Lifecycle-Remediated.xcresult
30 executions
0 failures
```

I independently exported that bundle to:

```text
/tmp/NearWire-Round12-Focused-Diagnostics
```

The raw gate below exited 1 with zero matches:

```text
rg -n -i 'BUG IN CLIENT OF libsqlite3|API violation|vnode unlinked|invalidated open fd' \
  /tmp/NearWire-Round12-Focused-Diagnostics
```

### Final complete Viewer result

The authoritative result produced after the broader final ownership hardening is:

```text
/tmp/NearWire-Round11-FinalPoolOwnership.xcresult
totalTestCount: 276
passedTests: 274
skippedTests: 2
failedTests: 0
expectedFailures: 0
result: Passed
```

I independently exported its diagnostics to:

```text
/tmp/NearWire-Round12-FinalPoolOwnership-Diagnostics
```

The same four-keyword raw gate exited 1 with zero matches. This confirms that the green XCTest
summary no longer hides `vnode unlinked while in use`, invalidated descriptors, or another SQLite
API-violation diagnostic in the final source state.

The saved Round 11 remediation evidence correctly records the original 19-method repair, its focused
30-execution bundle, and the first clean complete result. The later broader ownership audit and the
post-hardening complete result are recorded here so the final review corresponds to the final diff,
not only to the earlier subset.

## Traversal and synchronous successor regressions

The prior traversal guarantees remain independently mutation-sensitive and unchanged:

- Release-token invalidation prevents query submission; query-token invalidation prevents page and
  gap submission.
- Page and gap delivery guards run in separate phases with nonempty sentinels, so removal of either
  guard changes observable rows or completion state.
- Synchronously rejected query, page, and gap successors return delivery-invalid tokens, publish no
  stale error or content, create no replacement-generation work, and retire exactly to zero pending
  work.
- Rejected traversals remain incomplete until an explicit fresh traversal succeeds.

The real-gateway test still asserts `.storeReplaced`, invalid query/page/gap tokens, zero retained
gateway operations, and a successful fresh replacement request. The coordinator tests still assert
empty Event/gap presentation, the prior loading state, explicit recovery, and exact zero work.

## Export commit-boundary regressions

Fresh repeated validation covered all established export boundaries:

- user cancellation before commit preserves the prior destination;
- cancellation after commit publishes authoritative success;
- Store replacement after commit publishes authoritative success;
- a delayed destination callback cannot mutate or retain a sealed explorer;
- gateway cancellation after committed export preserves success and clears operation state;
- injected pre-commit failures preserve the destination, while post-rename failures retain the
  committed export.

The nine traversal/export tests ran five times each in the final review:

```text
/tmp/NearWire-Round12-Traversal-Export.xcresult
45 executions
0 failures
```

Its freshly exported raw diagnostics at
`/tmp/NearWire-Round12-Traversal-Export-Diagnostics` contain zero SQLite API-violation or XCTest
failure matches.

## Other correctness review

The gateway's invalid delivery token remains separate from the delivery-valid generation-zero token
used for a direct request while no Store is installed. Completion handlers attach the returned token
before MainActor delivery, validate it before presentation mutation, and retire work outside the
presentation guard. The commit-aware export path remains the only operation allowed to deliver an
authoritative terminal success after cancellation or Store replacement. No new generation-retarget,
stale-presentation, double-completion, export-destination, or retained-work gap was found elsewhere
in the change.

## Fresh validation

```text
Focused SQLite lifecycle bundle
30 executions, 0 failures
Fresh raw diagnostic scan: zero matches

Final complete Viewer bundle
276 total, 274 passed, 2 skipped, 0 failed
Fresh raw diagnostic scan: zero matches

Traversal and export regressions, 5 iterations each
45 executions, 0 failures
Fresh raw diagnostic scan: zero matches

swift test
Executed 537 tests, with 0 failures

xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
```

## Unresolved finding count

**0**
