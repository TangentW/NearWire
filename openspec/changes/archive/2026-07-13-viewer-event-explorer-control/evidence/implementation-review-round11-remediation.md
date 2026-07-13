# Implementation Review Round 11 Remediation

Date: 2026-07-14

## Result

The one round-11 correctness finding is remediated. The original 19 directly affected test methods
now own scope-bound pool cleanup, and the ownership audit was then widened to every retained named
`ViewerSQLitePool` construction in `ViewerStoreTests`. Seventy defer-eligible constructor sites have
an immediate, exception-safe matching defer close; the remaining two sequencing fixtures close
explicitly before reopen or fault-injection work. The original 30-execution reproduction and the
final complete 276-test Viewer suite pass, and exported raw diagnostics contain zero SQLite
API-violation matches. A fresh independent three-discipline review remains required before this
change can close.

Configured distribution signing and validation of entitlements embedded in a signed product remain
explicitly deferred to the Goal-level `release-hardening` change by product-owner decision. This
remediation does not claim that deferred gate passed.

## CT-R11-001 — deterministic ownership for every retained named temporary pool

- Nineteen initially affected tests that directly construct
  `ViewerSQLitePool(migrating: makePaths())` now install `defer { pool.close() }` immediately after
  successful construction.
- The audit was widened after that focused remediation to all named `pool`, `setupPool`, and
  `verification` constructions, including paths retained in local variables and helper scopes. All
  70 defer-eligible constructor sites install their matching defer immediately after successful
  construction.
- One sequencing test also retains `first` and `reopened` pools. Each closes explicitly before the
  next reopen or fault-injection step, so an intervening throwing operation cannot defer either
  connection lifetime to test teardown.
- Existing higher-level owners retain their explicit stop/join calls before scope exit. Explicit
  pool closes remain valid because `ViewerSQLitePool.close()` is idempotent.
- A static constructor-site audit reports 72 retained named constructors: 70 immediate defer
  closes, two sequencing-point explicit closes, and zero missing owner. Constructors used only
  inside an expected-throw expression retain no pool.
- Raw diagnostic scans are a release gate independent of XCTest result counts.

## Focused reproduction

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testAppendOnlyDispositionPolicyAndDropSamplesAreIdempotentAndDetectConflicts \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testCapacityPauseRunsOneRecoveryAndExplicitProbeResumesAfterCapacityIncrease \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testQueryUsesViewerTimeTypedJSONScalarOrAndFrozenTerminalPresence \
  -test-iterations 10 \
  -resultBundlePath /tmp/NearWire-Round11-SQLite-Lifecycle-Remediated.xcresult
Executed 30 tests, with 0 failures
** TEST SUCCEEDED **
```

Diagnostics were exported with:

```text
xcrun xcresulttool export diagnostics \
  --path /tmp/NearWire-Round11-SQLite-Lifecycle-Remediated.xcresult \
  --output-path /tmp/NearWire-Round11-SQLite-Lifecycle-Diagnostics-Remediated
```

The raw gate:

```text
rg -n -i 'BUG IN CLIENT OF libsqlite3|API violation|vnode unlinked|invalidated open fd' \
  /tmp/NearWire-Round11-SQLite-Lifecycle-Diagnostics-Remediated
exit 1
zero matches
```

## Complete Viewer validation and raw diagnostic gate

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -skip-testing:NearWireViewerTests/ViewerFoundationTests/testRunningApplicationHasOnlyFoundationNetworkEntitlement \
  -resultBundlePath /tmp/NearWire-Round11-FinalPoolOwnership.xcresult
totalTestCount: 276
passedTests: 274
skippedTests: 2
failedTests: 0
expectedFailures: 0
** TEST SUCCEEDED **
```

Diagnostics were exported with:

```text
xcrun xcresulttool export diagnostics \
  --path /tmp/NearWire-Round11-FinalPoolOwnership.xcresult \
  --output-path /tmp/NearWire-Round11-FinalPoolOwnership-Diagnostics
```

The complete raw gate:

```text
rg -n -i 'BUG IN CLIENT OF libsqlite3|API violation|vnode unlinked|invalidated open fd' \
  /tmp/NearWire-Round11-FinalPoolOwnership-Diagnostics
exit 1
zero matches
```

The constructor-site ownership audit also passed:

```text
retained named ViewerSQLitePool constructor sites: 72
immediate matching defer closes: 70
sequencing-point explicit closes: 2
missing retained named owners: 0
```

The complete run also passed both large migration gates. Its diagnostic machine context was:

```text
success heap-growth=21217328
success database-high-water=26894336
success wal-high-water=0
success temp-high-water=0
cancellation acknowledgement-ns=233083
cancellation heap-growth=245760
cancellation database-high-water=26894336
cancellation wal-high-water=0
cancellation temp-high-water=0
```

The structural assertions, not these host values, remain the normative gates.

## Package, build, and static validation

```text
swift test
Executed 537 tests, with 0 failures

xcodebuild build -workspace NearWire.xcworkspace -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **

xcrun swift-format lint --strict --recursive Core SDK Viewer Demo Tests
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-event-explorer-control --strict --no-interactive
Change 'viewer-event-explorer-control' is valid
```
