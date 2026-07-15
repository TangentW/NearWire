## 1. Planning Gate

- [x] 1.1 Complete proposal, design, capability deltas, and this task plan.
- [x] 1.2 Strictly validate the active OpenSpec change before source modification.

## 2. Single-Session Storage

- [x] 2.1 Create a process-scoped Viewer working Store and terminal exact cleanup without exposing historical Sources.
- [x] 2.2 Add one serialized current-Session Clear transaction and matching live-projection invalidation.
- [x] 2.3 Add bounded complete-Session JSON import with inactive-device admission, rollback, cancellation, and export/import round-trip coverage.
- [x] 2.4 Rematerialize Event and Performance controllers after Clear or import and reject stale predecessor work.

## 3. Viewer Information Architecture

- [x] 3.1 Remove the Sources sidebar and storage-history controls; add the bounded top Devices strip and pending approvals.
- [x] 3.2 Add current-Session Import, Export, and confirmed Event Clear actions with truthful disclosure and disabled states.
- [x] 3.3 Add top Timeline, Inspector, and Composer visibility controls with accessible labels, tooltips, and stable split-view hosts.
- [x] 3.4 Preserve multi-device Event scope, Device details targeting, Performance single-device guidance, and composer targeting.

## 4. SwiftUI Stability and Experience

- [x] 4.1 Split broad publication into semantic header, Devices, Timeline, Inspector, and composer/layout signatures.
- [x] 4.2 Coalesce equivalent high-frequency snapshots, retain stable row/container identities, and disable implicit animation for data-only Event updates.
- [x] 4.3 Add deterministic publication-count, high-frequency arrival, panel-layout, minimum-size, light/dark, keyboard, and accessibility coverage.

## 5. Documentation and Verification

- [x] 5.1 Update Viewer integration and architecture documentation for one Session, Clear, panel controls, import/export, and process-scoped retention.
- [x] 5.2 Run focused tests, full Viewer tests, strict-concurrency checks, app and Demo builds, and save exact results under `evidence`.
- [x] 5.3 Launch and inspect the Viewer at minimum, standard, and wide sizes in light and dark appearances; save screenshots and observations.
- [x] 5.4 Run independent architecture/API, correctness/testing, security/performance/documentation, and UI aesthetics/interaction reviews; fix every actionable finding and repeat fresh review rounds until all reviewers are clean.
- [x] 5.5 Complete the spec-to-evidence audit and validate the finished change strictly.
