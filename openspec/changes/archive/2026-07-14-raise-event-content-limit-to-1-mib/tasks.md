## 1. Change Gate

- [x] 1.1 Complete and strictly validate proposal, design, capability deltas, and tasks before
  modifying production or test source.

## 2. Core Boundaries

- [x] 2.1 Add red Core tests for exactly 1 MiB content acceptance and one-byte-over rejection.
- [x] 2.2 Raise Event validation and derived tagged-model defaults while preserving all structural
  bounds and dynamic byte accounting.
- [x] 2.3 Raise bounded-queue defaults to the reviewed derived single-Event and total byte budgets.

## 3. Wire and Viewer Integration

- [x] 3.1 Add red wire tests proving a maximum-content Event crosses the exact record and frame
  boundaries while an oversized Event fails before session mutation.
- [x] 3.2 Update shared Event-frame, protocol, and Hello defaults to carry the exact deterministic
  record without changing the 16 MiB hard ceiling or conservative negotiation.
- [x] 3.3 Update Viewer admission and active session construction to use the same production wire
  limits and prove automatic handoff plus active codec construction.

## 4. SDK and Documentation

- [x] 4.1 Add red SDK coverage proving default offline send accepts 1 MiB canonical content and
  rejects 1 MiB plus one byte without queue mutation.
- [x] 4.2 Raise SDK default queue accounting, active-pump quantum, and total byte capacities to the
  reviewed derived values; retain explicit smaller configurations and existing overflow behavior.
- [x] 4.3 Update public API comments, README guidance, and relevant deterministic fixtures/default
  assertions to distinguish content, queue-accounting, record, and frame bytes.

## 5. Validation and Evidence

- [x] 5.1 Run focused Core, wire, SDK, and Viewer boundary tests with strict concurrency and warnings
  as errors where supported.
- [x] 5.2 Run the complete root package and Viewer suites, recording the existing unsigned entitlement
  limitation separately rather than weakening it.
- [x] 5.3 Build the SwiftPM Demo and Viewer unsigned and record exact results under `evidence`.
- [x] 5.4 Record a requirement-to-evidence audit including actual default byte values and proof that
  sub-limit Events remain dynamically sized.

## 6. Review and Completion

- [x] 6.1 Obtain one independent focused review covering architecture/API, correctness/testing,
  security/performance, and documentation; fix all actionable findings and repeat with the same
  reviewer until no unresolved finding remains.
- [ ] 6.2 Strictly validate and archive the change, verify canonical specs and archived evidence, then
  commit and push only scoped files while excluding local Xcode/signing changes.
