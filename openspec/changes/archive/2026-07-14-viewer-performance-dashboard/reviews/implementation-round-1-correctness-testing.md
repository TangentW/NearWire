# Implementation Round 1: Correctness and Testing

Date: 2026-07-14
Reviewer: independent correctness/testing agent
Verdict: changes requested; do not archive

## Findings

### P1: Failed traversal release can publish predecessor data

Location: `Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift:666-699`

`endTraversal` discards its result. `finishAfterTraversalRelease` checks only local cancellation and
otherwise returns the previously completed projected outcome. If Event and gap traversal completes
but `endTraversal` reports `storeReplaced`, the retired Store generation can still enter delivery,
cache, and model state.

Required remediation: pass the release result into finalization. Drop the owned publication on
failure and emit the matching Store failure or cancellation. Add release-failure tests for
`storeReplaced`, unavailable, and cancellation, including zero ledger bytes and no delivery.

### P1: Store-generation replacement is handled as an ordinary refresh

Locations:

- `Viewer/NearWireViewer/Application/ViewerAnalysisModeCoordinator.swift:285-288`
- `Viewer/NearWireViewer/Application/ViewerApplicationModel.swift:71-78`
- `Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift:1011-1016`

`noteStoreChanged()` only requests refresh. It does not advance source generation, invalidate and
join delivery/deadline work, cancel a scan, or clear model/cache. While paused, predecessor cards,
buckets, raw identities, and cache can remain indefinitely.

Required remediation: add an explicit Store-generation replacement path distinct from data-change
refresh. It must force invalidation, cancel/join, immediately clear presentation/cache/identities,
and admit one successor only after cleanup. Test ready, paused, blocked-scan, and claimed-delivery
states across an actual replacement.

### P1: Replacing a freshness deadline retains every prior scheduled task

Location: `Viewer/NearWireViewer/Application/ViewerPerformancePipeline.swift:860-948`

The scheduler returns no cancellation handle. `arm` replaces only the logical active value while
every previous `Task.sleep` continues. `invalidate` clears logical state but neither cancels nor
joins scheduled work. The existing test asserts one logical wake while also accepting two scheduler
jobs after one replacement. At 10 Hz with a 180-second horizon, about 1,800 sleepers could coexist,
and cleanup can report completion while old deadline work remains scheduled.

Required remediation: make scheduling return an owned cancellable handle. Cancel and replace the
prior handle on every arm, and provide invalidate-and-wait behavior for controller cleanup. Assert
actual scheduled work is at most one and becomes zero after replacement, invalidation, and sealing.

## Test and evidence gaps

- Projection finalization after `endTraversal` failure.
- Ready, paused, blocked-scan, and claimed-delivery dashboard behavior across actual Store
  replacement.
- Actual deadline scheduler work count after repeated replacement and after `sealAndWait`.
- Stress replacement of many deadline receipts with a bounded scheduled-task assertion.

Fresh focused unsigned pipeline, dashboard-controller, and analysis-coordinator tests passed, as did
strict OpenSpec validation and diff hygiene. Existing range/bucket, decoding, gap, LRU, and raw
resolution evidence is proportionate. No file was edited by the reviewer.
