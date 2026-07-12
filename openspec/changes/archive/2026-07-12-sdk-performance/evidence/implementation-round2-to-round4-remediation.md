# Implementation Round 2 to Round 4 Remediation

Date: 2026-07-12

## Product corrections

- Starting now authorizes activation without suppressing cancellation. One locked final transition decides cancellation versus Running, so a cancellation before commit cleans the prepared collector and lease.
- Lifecycle tests use exact waiter and stopping-target observations instead of fixed scheduler-yield counts.
- Manifest semantics are decoded and asserted in XCTest, including per-record linkage/tracking values and omitted unused keys.
- The activation-to-actor scheduling tolerance is documented explicitly and proportionately rather than adding complex synchronization for a sub-turn timing distinction.

## Validation simplification

- Deleted the Performance-specific source-text/API-inventory/privacy-mutation validator.
- Removed Performance symbol scanning and exact SwiftPM/CocoaPods declaration-tree comparison.
- Retained small real SwiftPM and CocoaPods consumer builds plus built privacy-resource checks because XCTest cannot observe packaging.
- Replaced isolated per-file Swift frontend parsing in the generic import-boundary gate with its comment/string-aware token inspection. Existing positive and mutation fixtures pass, and the boundary command passed three consecutive remediation runs.

## Final review and validation

- Round 4 architecture/API: approved, 0 unresolved findings.
- Round 4 correctness/testing: approved, 0 unresolved findings.
- Round 4 security/performance/documentation: approved, 0 unresolved findings.
- Focused Performance XCTest: 51 passed, 0 failed.
- Canonical run `20260712T101542Z-40669`: complete, exit status 0.
- iOS Simulator: 517 passed, 4 skipped, 0 failed.
- Isolated Core: 196 passed, 0 failed.
- SwiftPM, CocoaPods, TLS integration, OpenSpec, structure, language, validation-tool, version, and boundary gates: passed.
