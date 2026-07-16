# Review Round 1

## Architecture and API

No actionable findings. The reviewer confirmed off-main projection preparation, immutable publication, semantic identities, compatibility, and capability alignment.

## Correctness and testing

No source-code or regression-test design findings. The reviewer requested final test, build, concurrency, and visual evidence; those records are now present in this evidence directory.

## Security, performance, documentation, and UI

One actionable performance finding: prepared chart points were initially described as part of the existing completed-result cache ledger but were not charged there.

Resolution: the design now defines a separate deterministic publication-layer budget. Production code enforces a maximum of 1,200 points and 157,696 bytes through `ViewerPerformanceAccounting.chartProjectionBytes(pointCount:)`, with exact-boundary coverage.

The reviewer also noted that removing the fixed Timeline event-count cap is a separate user request. It is intentionally handled in the next narrow OpenSpec change because the active change declares retention out of scope.
