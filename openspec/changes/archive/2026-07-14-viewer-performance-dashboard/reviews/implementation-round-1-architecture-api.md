# Implementation Round 1: Architecture and API

Date: 2026-07-14
Reviewer: independent architecture/API agent
Verdict: changes requested; do not archive

## Findings

### P1: Store replacement is treated as an ordinary refresh

Locations:

- `Viewer/NearWireViewer/Application/ViewerAnalysisModeCoordinator.swift:285`
- `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:73`
- `Viewer/NearWireViewer/Store/ViewerStoreCoordinator.swift:1993`

The dashboard contract requires Store replacement to cancel and join work and clear presentation,
cache, locator, and delivery state before the existing receipt completes. `attemptReopen` installs a
replacement Store and publishes the generic status signal. That reaches `noteStoreChanged()`, which
only calls `requestRefresh()`. It does not advance source generation, invalidate delivery/deadline
receipts, cancel active projection work, or clear the old model/cache. Old Store-derived cards,
charts, and raw-event locators can remain visible and actionable while the successor refresh is
running or blocked.

Required remediation: introduce a distinct Store-generation replacement signal. Replacement must
synchronously invalidate generation and delivery ownership, cancel/join active work, clear
model/cache/raw/deadline state, and only then admit one fresh successor. Ordinary Store-content
changes retain dirty-refresh behavior. Add integration coverage around actual gateway replacement.

### P2: Current Store-failure fallback retains the prior chart

Locations:

- `Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift:1352`
- `Viewer/NearWireViewer/Application/ViewerPerformanceDashboardModel.swift:169`

The design requires the prior chart to clear before a fresh live-only generation. The
`restartWithFreshLiveOnlyFreeze` path immediately starts a new run without releasing presentation
ownership or clearing publication. `startRun` calls `beginLoading`, which deliberately retains an
existing publication. A slow or blocked live-only freeze therefore continues to show the prior
complete chart and may retain its deadline and raw actions under Store-unavailable conditions.

Required remediation: before the fallback submits, invalidate prior delivery/deadline ownership,
release presentation ownership, and clear publication, crosshair, raw locator, and relevant cache.
Add a barrier test that publishes a chart, fails durable scan, blocks live-only preparation, and
asserts predecessor content is absent.

### P3: Metric representatives do not carry source generation

Locations:

- `Viewer/NearWireViewer/Application/ViewerPerformanceAggregation.swift:226`
- `Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift:1141`

Every measured accumulator is required to carry a contributing journal key and source generation.
`ViewerPerformanceMetricRepresentative` carries only the journal key and timing data. Raw handoff
combines the key with `model.scope.sourceGeneration`, making provenance depend on two independently
held objects. Outer generation guards reduce immediate risk, but the accumulator cannot prove that
its representative belongs to the generation supplied to raw resolution.

Required remediation: bind `sourceGeneration` into the representative when reduction occurs,
preserve it through cache publication, validate it against publication scope, and construct raw
requests from that bound generation/key pair.

## Coverage summary

- Core/SDK/Viewer placement and shared SPI/public API compatibility: pass.
- Query-arbiter ownership, current/historical clock domains, ledger/cache bounds, Swift 5 and
  Sendable discipline, and package/Xcode boundaries: pass apart from the findings above.
- Raw Store/live authority and generation cleanup: blocked by P1 and P2.
- Raw handoff provenance: blocked by P3.

Strict OpenSpec validation, diff hygiene, an unsigned Viewer build, and repository manifest-boundary
inspection passed independently. No file was edited by the reviewer. Signed entitlement and
stable-signer work was excluded as intentionally deferred.
