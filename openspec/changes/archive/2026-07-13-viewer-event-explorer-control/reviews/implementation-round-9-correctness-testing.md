# Correctness and Testing Implementation Review — Round 9

## CT-R9-001 — P1 High: controller cancellation or Store replacement can discard an already-committed export success

**Confidence:** 10/10

The gateway correctly treats a successful export candidate as authoritative after the atomic
destination commit. `ViewerStoreExplorerGateway.executeExport` opts into
`successfulCandidateIsAuthoritative` (`Viewer/NearWireViewer/Store/ViewerStoreExplorerGateway.swift:792-810`),
and `finish` preserves that success across later generic cancellation or coordinator replacement
(`1014-1034`). The controller can still discard the same authoritative result through either of
two deterministic paths:

- `ViewerEventExplorerController.cancelExport` cancels `.exportExecution` and immediately publishes
  `.cancelled` (`Viewer/NearWireViewer/Application/ViewerEventExplorerController.swift:1143-1149`).
  The shared cancellation path removes the active operation before checking whether delivery was
  already claimed (`1894-1897`). A committed success that claims afterward is rejected by its gate;
  one that claimed just before cancellation reaches the MainActor but `finish` rejects it because
  the operation identity was removed (`1884-1892`). In both cases the destination has already been
  replaced while the UI says `Export Cancelled` and states that no prior destination was replaced.
- Coordinator replacement invalidates the export token before publishing the successor. Even
  though the gateway deliberately returns the committed `.success`, controller `finish` requires
  `storeToken.isDeliveryValid` (`1884-1892`) and drops it. No store-change path repairs
  `exportState`, so the sheet can remain in `.exporting` indefinitely after the file has committed.

This regresses the round-6 committed-export remediation and the still-current design statement
that committed success remains authoritative across generic cancellation or coordinator replacement
(`openspec/changes/viewer-event-explorer-control/design.md:331-341`). It also violates truthful
completion presentation: the operator can retry, overwrite, or disclose another file because the
Viewer denied or never acknowledged the first completed export.

Current coverage stops at the gateway boundary:
`testGatewayCancellationAfterCommittedExportPreservesSuccessAndClearsState` proves the gateway
returns success, while the round-8 old-generation controller regression covers a catalog result,
not the irreversible export result. The complete suite therefore passes without exercising this
cross-layer handoff.

**Required action:** define committed export success as the narrow exception to mutable
old-generation presentation, and reconcile the conflicting artifact sentence that currently says
all predecessor export results are discarded. Give controller export execution its own exact state
machine: cancellation before commit must still produce `.cancelled` and preserve the destination,
but once the gateway reports committed success, that content-free receipt must retire the exact
controller identity and publish `.completed` despite a racing user cancellation or coordinator
replacement. Runtime sealing may still clear all presentation and join the callback without
repopulating the sealed controller. Add controller-level commit-boundary regressions for both
generic cancellation and coordinator replacement. Each must block after destination replacement,
apply the race, release delivery, and prove `.completed`, one callback, the replaced JSON file, and
zero gateway/controller work. Keep the old-catalog rejection regression unchanged.

## Reviewed remediation and validation

The renderer and composer delivery pumps are hard bounded to one processing plus one replaceable
pending value, release displaced values after leaving the pump lock, and join their one drain during
cleanup. The deterministic blocked-MainActor, pre-claim replacement, claimed-cleanup, old-catalog,
delayed-destination, and SQLite ownership tests passed 45 executions across five iterations with no
failure. The isolated SQLite regression passed ten more iterations with no libsqlite API-violation
diagnostic. The delayed destination callback is weakly captured, lifecycle-cancelled, and unable to
mutate or retain a sealed controller. No additional actionable race was found in those remediations.

Fresh validation:

- Complete Viewer suite: 270 tests, 2 skipped, 0 failures; no libsqlite API-violation diagnostic.
- Swift Package suite: 537 tests, 0 failures.
- Strict OpenSpec validation: passed.
- `git diff --check`: passed.

Configured signing and embedded-entitlement validation remains deferred to Goal-level
`release-hardening` and is not a finding in this review.

**Unresolved findings: 1**
