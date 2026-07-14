# Validation 6.7 Evidence: Deterministic Projection Benchmark

Date: 2026-07-14

## Benchmark design

`ViewerPerformanceAggregationTests.testHundredThousandAlternatingInputsStayAtExactProjectionCapsAndCleanUp`
streams 100,000 deterministic inputs through the production projection session without retaining a
second Event-sized test collection:

- 25,000 valid measured performance snapshots;
- 25,000 snapshots with missing numeric values and alternating categorical values;
- 25,000 interval-less uncertain gaps;
- 25,000 malformed performance events.

The 75,000 Event candidates are delivered in 147 pages of at most 512 candidates. The 25,000 gap
receipts are delivered in 782 pages of at most 32 receipts. Decoding is limited to 64 Events per
turn. The test uses 512 buckets and asserts the production VM budget and turn-clock constants.

The test makes exact assertions for all deterministic behavior:

- 75,000 decoded candidates and 1,172 decode turns;
- 25,000 measured values for each numeric metric;
- 49,488 bounded categorical changes;
- 128 retained gaps, 128 retained invalid details, and 49,744 omitted details;
- 512 buckets, 10,240 chart marks against a 12,288 global cap, and 384 accessibility values;
- 1,103,104 bytes per projected result;
- a 4-entry cache containing 4,412,416 bytes after five inserts, with the first entry evicted;
- zero cache entries and zero ledger bytes after explicit cleanup.

Elapsed time and process physical-footprint growth are printed only as host diagnostics. They are
not pass/fail thresholds because those values vary by machine and concurrent system load. No shell
benchmark harness was added.

## Focused benchmark command

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-performance-6-7-benchmark \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerPerformanceAggregationTests/testHundredThousandAlternatingInputsStayAtExactProjectionCapsAndCleanUp

NearWire 100,000 projection diagnostics: elapsed-ns=22653216625,
process-footprint-growth=268910784, event-candidates=75000, event-pages=147,
gap-pages=782, decode-turns=1172, buckets=512, cache-entries-before-cleanup=4,
marks=10240, accessibility-values=384, result-bytes=1103104,
cleanup-ledger-bytes=0
ViewerPerformanceAggregationTests: Executed 1 test, with 0 failures.
Selected tests: Executed 1 test, with 0 failures (0 unexpected) in 22.703 seconds.
** TEST SUCCEEDED **
```

The first invocation stopped during test compilation because the new assertion referred to the
availability count as `invalidSnapshot`; the production field is named `invalid`. The test source
was corrected to use the production name, and the unchanged command above then passed. No product
implementation or assertion was weakened.

## Complete aggregation regression

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/nearwire-performance-6-7-aggregation \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerPerformanceAggregationTests

NearWire 100,000 projection diagnostics: elapsed-ns=22748523458,
process-footprint-growth=268779712, event-candidates=75000, event-pages=147,
gap-pages=782, decode-turns=1172, buckets=512, cache-entries-before-cleanup=4,
marks=10240, accessibility-values=384, result-bytes=1103104,
cleanup-ledger-bytes=0
ViewerPerformanceAggregationTests: Executed 8 tests, with 0 failures.
Selected tests: Executed 8 tests, with 0 failures (0 unexpected) in 22.948 seconds.
** TEST SUCCEEDED **
```

The test host emitted its existing macOS 13/XCTest 14 linker warning and transient App Intents
service diagnostics. Neither affected compilation, execution, or the deterministic assertions.

## Static gates

```text
xcrun swift-format lint --strict \
  Viewer/NearWireViewer/Store/ViewerPerformanceStore.swift \
  Viewer/NearWireViewerTests/ViewerStoreTests.swift
exit 0

git diff --check
exit 0

env DO_NOT_TRACK=1 openspec validate viewer-performance-dashboard --strict --no-interactive
Change 'viewer-performance-dashboard' is valid
```

All testing is unsigned. It does not claim the deferred Goal-level signed-entitlement or
stable-signer validation.
