## 1. Planning Gate

- [x] 1.1 Complete proposal, design, capability deltas, and this task plan.
- [x] 1.2 Strictly validate the active OpenSpec change before source modification.

## 2. Byte-Budget Retention

- [x] 2.1 Derive internal slot capacity from the retained-byte budget and fixed per-Event accounting overhead.
- [x] 2.2 Remove the independent 512-Event eviction condition while preserving byte-budget eviction and gap diagnostics.
- [x] 2.3 Align replacement, import, marker, authority, disposition, and evaluation defensive capacities with the byte-derived bound.

## 3. Timeline Publication

- [x] 3.1 Publish every matching row from the retained snapshot without applying a fixed suffix count.
- [x] 3.2 Add focused coverage above 512 Events, byte-budget eviction, filters, and tail-follow preservation.

## 4. Validation and Review

- [x] 4.1 Run focused tests, Viewer test classes, strict-concurrency compilation, Viewer build, and strict OpenSpec validation; save exact evidence.
- [x] 4.2 Run independent architecture/API, correctness/testing, and security/performance/documentation reviews.
- [x] 4.3 Fix all actionable findings, run a fresh clean review, complete the spec-to-evidence audit, and archive the change.
