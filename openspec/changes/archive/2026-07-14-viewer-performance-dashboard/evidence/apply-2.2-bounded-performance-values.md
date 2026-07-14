# Apply 2.2 — Bounded Performance Values

## Implementation

- Added validated immutable current/historical source and Store-scope values.
- Added a scope-bound last-examined continuation, durable/transient locator, canonical/oversized
  Event carrier, Event page, normalized gap carrier/page, live slice, frozen receipt, and closed
  failure values.
- Encoded the normative deterministic accounting constants directly:
  - 65,536-byte row copy threshold;
  - 4,194,304 copied content bytes;
  - 512 Event carriers and 4,096 examined candidates;
  - 4,460,544-byte Store Event page;
  - 256-byte gap carriers, 32 per 8,704-byte gap page;
  - 128 live gaps and a 4,493,312-byte live slice;
  - generic pagination plus saturating applicable count/`hasMoreApplicableGaps`.
- Added content-free reflection for carriers, pages, gaps, and live slices.

## Validation

```text
xcodebuild test -project Viewer/NearWireViewer.xcodeproj -scheme NearWireViewer \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/NearWire-Task22-arm64 \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceCarriersAndPagesEnforceExactAccountingAndRedaction \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceGapPageAndLiveSliceReachExactCaps \
  -only-testing:NearWireViewerTests/ViewerStoreTests/testPerformanceScopeAndContinuationRejectInvalidBounds
```

Exit 0:

```text
Executed 3 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

The first compile exposed a factory name collision with the historical enum case. Renaming the
validated factory to `makeHistorical` resolved the compiler finding; the fresh command above passed.

```text
xcrun swift-format lint --strict \
  Viewer/NearWireViewer/Store/ViewerPerformanceStore.swift \
  Viewer/NearWireViewerTests/ViewerStoreTests.swift
```

Exit 0 with no output.

```text
plutil -lint Viewer/NearWireViewer.xcodeproj/project.pbxproj
```

Exit 0: `Viewer/NearWireViewer.xcodeproj/project.pbxproj: OK`.

```text
git diff --check
```

Exit 0 with no output.
