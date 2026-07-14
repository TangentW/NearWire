# Validation 6.4 Evidence: Range, Freshness, and Gap Semantics

Date: 2026-07-14

## Coverage

- Range tests cover current, ended, interrupted, and empty anchors; one/five/fifteen-minute and
  Current Session ranges; inclusive one-tick geometry; checked lower underflow; `Int64.max` span;
  512-bucket width/count; interior exact edges; final-upper placement; and out-of-range rejection.
- Card tests cover no snapshot, a latest Event outside the one-minute chart but inside the fixed
  180-second card lookback, missing without fallback, fresh invalid content, fresh explicit
  unavailable without fallback, and stale winning over invalid/unavailable/Not collected.
- The freshness table proves exact horizons and stale equality for 100, 999, 1,000, 1,001, 10,000,
  59,999, and 60,000 milliseconds. Invalid/unreadable headers use three seconds, checked excessive
  intervals cap at 180 seconds, and adjacency uses the larger neighboring interval.
- Current delivery tests cross the absolute deadline between claim and MainActor apply, reject stale
  receipts, arm exactly one future wake, do not arm at equality, and retain one paused expiry bit.
  Historical publication is unchanged for simulated current uptimes below, equal to, and above its
  frozen upper, including an uptime reset, and historical freshness owns zero wakeups.
- Wall-envelope tests cover a uniquely placed gap, in-bucket wall intervals, exact envelope edges,
  ambiguous/nonoverlapping intervals, wall regression, invalid intervals, unknown kinds, and
  interval-less gaps. Placement mutates only discontinuity flags and never synthesizes a sample.
- Gap-count tests cover exact 127/128/129 boundaries independently for Store, live, and combined
  receipts. The 129th occurrence sets combined overflow and suppresses every inter-bucket
  connection; 127 and 128 remain placed when complete evidence exists.
- Store classification proves two 129-row receipts can retain the same irrelevant prefix while only
  the receipt with a hidden App-to-Viewer tail sets `hasMoreApplicableGaps`. Generic `hasMoreRows`
  alone does not disconnect a series.
- Presentation tests prove missing metric buckets create no point, metric-specific holes disconnect
  only that metric on both sides, and Unplaced gaps isolate every measured bucket. Live-only
  projection labels limited coverage and disconnects unknown leading history.

## Viewer result

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-performance-6-4-tests \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerPerformanceRangeAndCacheTests \
  -only-testing:NearWireViewerTests/ViewerPerformanceSemanticsTests \
  -only-testing:NearWireViewerTests/ViewerPerformancePipelineTests \
  -only-testing:NearWireViewerTests/ViewerPerformancePresentationTests \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceGapClassificationSeparatesGenericAndApplicableOverflow

ViewerPerformancePipelineTests: Executed 10 tests, with 0 failures.
ViewerPerformancePresentationTests: Executed 9 tests, with 0 failures.
ViewerPerformanceRangeAndCacheTests: Executed 7 tests, with 0 failures.
ViewerPerformanceSemanticsTests: Executed 12 tests, with 0 failures.
ViewerStoreTests: Executed 1 test, with 0 failures.
Selected tests: Executed 39 tests, with 0 failures (0 unexpected) in 0.306 seconds.
** TEST SUCCEEDED **
```

The first attempt to execute the newly added wall-envelope case did not reach test execution because
the restricted process could not write Xcode/SwiftPM caches and CoreSimulatorService was
unavailable. The identical unsigned test command was rerun with permitted local compiler-cache
access and passed. No assertion or gate was changed.

## Static gates

```text
xcrun swift-format lint --strict Viewer/NearWireViewerTests/ViewerFoundationTests.swift
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

Testing is unsigned and does not claim the deferred Goal-level signed entitlement or stable-signer
validation.
