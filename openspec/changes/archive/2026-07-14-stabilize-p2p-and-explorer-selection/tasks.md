## 1. Planning Gate

- [x] 1.1 Complete proposal, design, capability deltas, and this task plan.
- [x] 1.2 Strictly validate the active OpenSpec change before source modification.

## 2. Peer-to-Peer Session Continuity

- [x] 2.1 Add explicit fixed TCP keepalive idle, interval, and count values to both secure transport roles.
- [x] 2.2 Add focused parameter tests for the fixed keepalive policy.
- [x] 2.3 Keep an exact-match production Bonjour browser active, quiesce its callbacks and pairing-derived state, and transfer its silent lifetime into the secure session.
- [x] 2.4 Release retained discovery exactly once on connection setup failure, cancellation, or active-session termination, with focused lifecycle tests.

## 3. Event Explorer Traversal Ownership

- [x] 3.1 Correct backward Event-page boundaries, map Event/gap cursors to chronological edges by cursor direction, and keep them valid across same-traversal sliding lease refreshes.
- [x] 3.2 Gate Event/gap pagination and durable-detail admission by current traversal readiness without a pre-start ownership bypass.
- [x] 3.3 Clear predecessor page failures when the presentation generation advances.
- [x] 3.4 Defer SwiftUI Event selection mutation outside the active view-update transaction and reject stale, superseded, or nonresident deferred identities.
- [x] 3.5 Add focused tests for backward cursor boundaries, sibling-operation lease refreshes, refresh-time pagination, pending durable selection, successor detail loading, and deferred selection invalidation.

## 4. Verification and Delivery

- [x] 4.1 Run focused Core and Viewer tests, required full tests, strict-concurrency checks, and application builds; save exact results under `evidence`.
- [x] 4.2 Inspect runtime logs and exercise repeated Event delivery beyond the previously observed route-loss window when the device remains available. The captured peer-absence evidence and current device limitation are recorded in `evidence/runtime.md`; no post-fix physical success is claimed.
- [x] 4.3 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews; fix every actionable finding and repeat until no unresolved finding remains.
- [x] 4.4 Complete the spec-to-evidence audit, validate strictly, and archive the change.
