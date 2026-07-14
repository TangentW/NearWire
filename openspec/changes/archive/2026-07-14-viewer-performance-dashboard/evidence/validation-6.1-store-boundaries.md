# Validation 6.1 Evidence: Store Traversal Boundaries

Date: 2026-07-14

## Coverage

- Residual filtering now has an explicit 4,095/4,096/4,097 nonmatching-row matrix. It proves a
  complete empty page below the cap, an empty progress continuation exactly at the cap, and a second
  complete empty turn above the cap.
- Emission has an explicit 511/512/513 matching-row matrix. It proves completion below the cap,
  continuation plus a terminal empty page at equality, and a 512-plus-1 split above the cap.
- A 513-row equal-monotonic fixture proves the continuation orders by `(viewerMonotonicNs, rowID)`
  and neither skips nor duplicates the 513th Event.
- Injected clocks prove a 49,999,999-nanosecond turn can complete, 50,000,000 nanoseconds yields
  after one examined match, and equality or excess before any candidate fails terminally. The SQLite
  scan and classification budgets remain exactly 5,000,000 and 2,000,000 VM steps.
- Existing focused coverage also proves exact frozen scope/uppers, accepted index-backed plans,
  65,536/65,537-byte classification, aggregate-copy retry before examination, complete closed gap
  mapping, irrelevant-only versus hidden-applicable 129th tails, conservative classification
  exhaustion, content-free normalized carriers, Event/gap/live accounting, cancellation and lease
  release, exact raw locator behavior, schema version 2, and no projection table or migration.

## Focused test result

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/nearwire-performance-6-1-tests CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 [16 explicit -only-testing selections]

Executed 16 tests, with 0 failures (0 unexpected) in 0.419 (0.423) seconds
** TEST SUCCEEDED **
```

The exact selections were the Store performance raw-locator, candidate scan, residual-boundary,
emission-boundary, equal-tie, copied-byte, injected-clock, frozen gateway, live-first freeze, gap
classification, cancellation, accounting, scope, shared-arbiter, and schema-version tests.

## Static gates

```text
xcrun swift-format lint --strict Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

Testing is unsigned and does not claim the deferred Goal-level signed entitlement or stable-signer
validation.
