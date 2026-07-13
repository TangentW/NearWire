# Correctness and Testing Implementation Review — Round 13

Date: 2026-07-14

## Decision

No actionable correctness, testing, race, lifecycle, or evidence-integrity finding remains after
the Round 12 evidence remediation. This review reinspected the current source and corrected evidence
without relying on the Round 12 correctness conclusion.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change by product-owner decision. That
deferred gate is not a finding in this review.

## Final SQLite ownership and evidence audit

The direct constructor-site audit of the current `ViewerStoreTests.swift` reports 72 retained named
`ViewerSQLitePool` construction sites:

- 70 defer-eligible `pool`, `setupPool`, or `verification` sites each place an immediate matching
  `defer { ...close() }` after successful construction, including multiline constructions;
- the two remaining sequencing sites, `first` and `reopened`, close explicitly before the next
  reopen or fault-injection operation; and
- zero retained named construction lacks deterministic ownership.

The earlier 71 figure is a different, deduplicated function-and-variable-name measure, not a direct
constructor-site count. The 72 sites collapse to 71 such identities because
`testMaintenanceMutationFailuresReportAuthoritativeStateAndRollback` contains two separate
construction sites both named `pool`. The final evidence correctly uses the direct 72-site metric:
70 immediate defer closes plus two sequencing-point explicit closes.

The corrected `implementation-review-round11-remediation.md`,
`implementation-review-round12-remediation.md`, and `validation-6.9-aggregate.md` now agree on that
decomposition and on the authoritative result paths. They preserve the historical 19-fixture
reproduction while distinguishing it from the broadened final ownership audit. No stale
`NearWire-Round11-Full-Remediated` path or malformed DerivedData-plus-`/tmp` result reference remains
in those three evidence files.

I independently read `/tmp/NearWire-Round11-FinalPoolOwnership.xcresult`, which was produced after
the final test-source modification. Its summary is:

```text
totalTestCount: 276
passedTests: 274
skippedTests: 2
failedTests: 0
expectedFailures: 0
result: Passed
```

I freshly exported that bundle to
`/tmp/NearWire-Round13-FinalPoolOwnership-Diagnostics`. The raw diagnostic gate exited 1 with zero
matches for `BUG IN CLIENT OF libsqlite3`, `API violation`, `vnode unlinked`, or
`invalidated open fd`. The evidence-referenced export at
`/tmp/NearWire-Round11-FinalPoolOwnership-Diagnostics` also passed the same zero-match gate.

## Traversal, delivery, and retained-work review

The final traversal implementation preserves predecessor Store identity through release, query,
page, and gap operations. A rejected following operation returns a delivery-invalid token rather
than a generation-zero token that could be mistaken for a valid direct request. Completion delivery
attaches the returned token before MainActor handling, validates it before presentation mutation,
and retires tracker work independently of presentation acceptance.

The tests remain mutation-sensitive at each stage. Release- and query-token invalidation prevent
successor submission; page and gap invalidation use separate nonempty sentinels, so either missing
guard changes observable state. Synchronously rejected query, page, and gap successors publish no
stale content or failure, retain no replacement-generation operation, and return the tracker to
exactly zero work. Recovery requires and verifies an explicit fresh traversal.

Gateway replacement invalidates delivery, interrupts exact active work, joins the completion group,
closes the arbiter, and only then releases deferred rejection callbacks. The current lock ordering
does not expose a generation-retarget, double-completion, stale-presentation, or retained-operation
gap in the reviewed paths.

## Export commit-boundary review

Export still has one irreversible commit point: the validated sibling temporary file replaces the
destination with `renameat`. Cancellation and lease checks cover every pre-commit phase. A completed
atomic replacement remains authoritative even when user cancellation or Store replacement wins
after the rename; pre-commit cancellation preserves the prior destination. Delayed destination
selection cannot mutate or retain a sealed explorer.

The gateway marks only successful export candidates as authoritative after invalidation, while the
controller accepts invalidated Store delivery only for that commit-aware terminal path. Ordinary
operations remain delivery-validity gated. No destination-corruption, false cancellation,
post-seal mutation, or retained export work issue was found.

## Fresh independent validation

Nine traversal and export boundary tests were run five times each against the current source:

```text
/tmp/NearWire-Round13-Traversal-Export.xcresult
45 executions
0 failures
```

Fresh diagnostics exported to `/tmp/NearWire-Round13-Traversal-Export-Diagnostics` contain zero
matches for the SQLite misuse patterns, XCTest assertion failures, or fatal errors.

Additional gates passed:

```text
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
