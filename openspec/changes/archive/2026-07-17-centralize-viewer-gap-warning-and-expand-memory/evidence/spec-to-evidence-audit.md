# Spec-to-evidence audit

Date: 2026-07-18

| Requirement | Implementation and evidence |
|---|---|
| 256-Event / 64-MiB ingress | Exact constants in `ViewerLiveProjectionLimits`; focused count and byte-bound tests pass. |
| 256-MiB retained accounting | Exact constant and derived 8,192-slot carrier; byte-bound eviction and >512-Event tests pass. |
| Session-wide loss is not copied to Events | Projection maps only exact conflict state to `hasGap`; ingress, window, and diagnostic-loss assertions pass. |
| One warning above Timeline content | Diagnostic lane is ordered before `content`; localized warning and accessibility hint compile in the maintained build. |
| No generic Gap badge/accessibility on Event rows | Row status model excludes `hasGap`; focused row-presentation test passes. |
| Warning survives evaluation bounds/cancellation | Gap lane is captured before filter/evaluator work; pre-delivery and supersession regressions pass. |
| Complete-Session transfer limit is coherent | Transfer file limit equals retained capacity and import still validates accounted bytes and carrier bounds. |
| Performance remains bounded | Existing 16,384 predicate, one-million JSON-node, and 100-ms evaluator bounds remain unchanged; full Viewer suite passes. |

Validation evidence is recorded in `implementation-validation.md`. Three independent review rounds
are recorded with no unresolved findings.
