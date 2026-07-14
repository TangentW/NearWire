## 1. Change Gate

- [x] 1.1 Complete and strictly validate the proposal, design, capability deltas, and task plan
  before modifying production or test source.

## 2. Regression and Implementation

- [x] 2.1 Add a Core regression proving a peer Hello offer above the local 256 KiB session limit
  decodes, negotiates down, and cannot widen the local session codec.
- [x] 2.2 Add a Viewer admission regression using the production SDK's exact maximum deterministic
  Event-record offer and prove it reaches handoff.
- [x] 2.3 Change Hello offer validation to use the existing hard protocol bound while retaining all
  local post-negotiation limits.

## 3. Validation and Evidence

- [x] 3.1 Run focused Core and Viewer tests, the complete root package suite, and the complete Viewer
  test suite with strict concurrency and warnings as errors where supported.
- [x] 3.2 Build the SwiftPM Demo and Viewer unsigned for supported Simulator destinations and record
  exact results under this change's evidence directory.
- [x] 3.3 Record a requirement-to-evidence audit showing that dynamic Event sizing remains unchanged
  and the 256 KiB content maximum was not expanded.

## 4. Review and Completion

- [x] 4.1 Obtain one independent focused review covering architecture/API, correctness/testing, and
  security/performance/documentation; fix every actionable finding and rerun affected validation.
- [ ] 4.2 Strictly validate and archive the change, verify canonical specs and archived evidence, then
  commit and push only the scoped fix while excluding local Xcode/signing changes.
