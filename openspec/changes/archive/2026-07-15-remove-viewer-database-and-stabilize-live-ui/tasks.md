## 1. Planning Gate

- [x] 1.1 Complete proposal, design, capability deltas, and this task plan.
- [x] 1.2 Strictly validate the active OpenSpec change before source modification.

## 2. Memory-Only Viewer Session

- [x] 2.1 Remove production Store construction and Store lifecycle/status/configuration work from Viewer startup and shutdown.
- [x] 2.2 Make the bounded live projection the final current-Session authority without Store-unavailable or transient-to-durable reconciliation states.
- [x] 2.3 Preserve serialized Clear and bounded complete-Session JSON import/export directly against immutable memory snapshots.
- [x] 2.4 Update current-Session UI copy and documentation so memory retention and explicit JSON transfer are truthful.

## 3. SwiftUI Stability and Composer Editing

- [x] 3.1 Suppress Timeline publications for internal retained-refresh phase changes and preserve stable Event row/container identity.
- [x] 3.2 Suppress intermediate Performance refresh publications while retaining a complete presentation and publish one completed successor.
- [x] 3.3 Disable implicit data-refresh animation at the affected Event and Performance container boundaries without disabling user interactions.
- [x] 3.4 Resize bounded AppKit editor document views during layout and verify the composer Event type field is hit-testable, focusable, and editable.

## 4. Tests and Evidence

- [x] 4.1 Add proportionate memory-runtime, Clear/transfer, publication-count, layout/editing, and regression tests.
- [x] 4.2 Run focused tests, full Viewer tests, strict-concurrency checks, and the Viewer build; save exact results under `evidence`.
- [x] 4.3 Launch or render focused Event, Performance, and composer states and record the visual inspection.

## 5. Review and Completion

- [x] 5.1 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews focused on real regressions in this change.
- [x] 5.2 Fix actionable findings and run one fresh clean review round without expanding scope into unrelated cleanup.
- [x] 5.3 Complete the spec-to-evidence audit, strictly validate the finished change, and archive it.
