## 1. Planning Gate

- [x] 1.1 Complete proposal, design, capability deltas, and this task plan.
- [x] 1.2 Strictly validate the active OpenSpec change before source modification.

## 2. Reconnect Ownership

- [x] 2.1 Add bounded exact-route replacement ownership and cleanup to the Viewer session manager.
- [x] 2.2 Preserve per-connection queue, capability, epoch, terminal, recent-row, and shutdown isolation.
- [x] 2.3 Add deterministic tests for successful takeover, churn bounds, failure, and cleanup.
- [x] 2.4 Keep the predecessor current when candidate session attachment fails.

## 3. Live Analysis Presentation

- [x] 3.1 Make the analysis workspace directly observe mode-coordinator publication.
- [x] 3.2 Retain bounded timeline presentation across ordinary refresh and atomically replace or clear each successor lane.
- [x] 3.3 Reconcile one visible durable row with its exact transient observation during materialization lag, while rejecting ambiguity.
- [x] 3.4 Coalesce repeated Event and gap boundary callbacks while the corresponding pagination lane is in flight.
- [x] 3.5 Replace the filter editor `Form` with explicit scrollable grouped macOS layout.
- [x] 3.6 Add focused tests for mode publication, stable refresh, reconciliation, single-flight pagination, and filter draft behavior.
- [x] 3.7 Reconcile inspector ownership when retained refresh invalidates loading detail or removes selection.

## 4. Verification and Delivery

- [x] 4.1 Run focused Viewer tests, full Viewer tests, strict-concurrency build, and app build; save exact results under `evidence`.
- [x] 4.2 Launch and inspect the Viewer UI, capture focused screenshots, and exercise the attached iPhone reconnect path when available.
- [x] 4.3 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews; fix every actionable finding and repeat until no unresolved finding remains.
- [x] 4.4 Complete the spec-to-evidence audit, validate strictly, and archive the change.
