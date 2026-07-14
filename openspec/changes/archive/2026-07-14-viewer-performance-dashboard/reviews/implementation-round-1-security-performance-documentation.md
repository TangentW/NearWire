# Implementation Round 1: Security, Performance, and Documentation

Date: 2026-07-14
Reviewer: independent security/performance/documentation agent
Verdict: changes requested; do not archive

## Findings

### P1: Unsealed deinitialization does not clear or join performance state

Location: `Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift:956-968`

The fallback `deinit` invalidates helpers but discards the task returned by
`activeRun?.cancelAndWait()`, uses unjoined `deliveryPump.seal()`, and never seals or clears the
model. If lifecycle ownership releases the controller without explicit `sealAndWait`, an externally
retained model can continue holding cards, buckets, diagnostics, accessibility values, and raw
locators while projection cleanup remains outstanding.

Required remediation: make lifecycle ownership guarantee joined cleanup before controller release,
and make the deinit-safe path synchronously invalidate and clear/seal the model. Retain a cleanup
receipt outside the controller until active run and delivery work join. Add a blocked-operation test
that drops an unsealed controller while retaining its model and verifies immediate clearing,
eventual zero work, and zero ledger bytes.

### P2: Current projections duplicate the complete live carrier array outside accounting

Locations: `Viewer/NearWireViewer/Application/ViewerPerformancePipeline.swift:227-313`

The session retains `receipt.liveSlice.events` and also creates a separate `sorted()` array.
`activeAccountedBytes` charges only reducer state while the exact peak formula accounts for one live
slice. At 512 carriers, the second owner adds at least 262,144 deterministic carrier bytes, and raw
content remains retained through gap traversal.

Required remediation: enforce canonical ordering when constructing `ViewerPerformanceLiveSlice`
and reuse its buffer, or consume events into the session while retaining only scalar receipt/gap
metadata. Otherwise charge the second owner and update every peak contract. Add a maximum live-slice
session test covering 512 carriers and the maximum copied-content case.

### P2: Every gap page rescans the complete frozen gap scope

Locations:

- `Viewer/NearWireViewer/Store/ViewerPerformanceStore.swift:685-755,951-1004`
- `Viewer/NearWireViewer/Application/ViewerPerformanceDashboardController.swift:590-627`

`gapPage` invokes `classifyGaps` for every 32-row page. Classification resets continuation to nil
and scans the complete frozen scope. An N-gap history therefore performs approximately
`ceil(N / 32)` complete classifications, producing quadratic SQLite work and monopolizing the
shared traversal. The synthetic benchmark injects pages directly and cannot detect this Store path.

Required remediation: compute one immutable classification receipt per frozen traversal and carry
it through refreshed traversal values. Reuse its saturating count and conservative overflow bit for
all pages. Add a real SQLite large-gap traversal test with instrumentation proving classification
runs once and total work grows linearly.

## Documentation and evidence mismatches

- `Documentation/Viewer-Performance.md` repeats the peak that omits the duplicate live-carrier
  owner.
- Lifecycle evidence covers explicit replacement/seal paths, not unsealed deinitialization.
- The deterministic benchmark feeds synthetic gap pages rather than exercising repeated Store
  classification.
- The benchmark is historical and cannot substantiate maximum current live-slice coexistence.

No new logging, clipboard, drag/share, analytics, preference, restoration, derived persistence,
export, entitlement, or third-party runtime sink was found. Host process-footprint timing remains
appropriately diagnostic. No file was edited by the reviewer.
