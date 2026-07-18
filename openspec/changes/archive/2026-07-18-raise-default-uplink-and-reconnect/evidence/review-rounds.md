# Independent Review Rounds

## Round 1

### Architecture and API

Reviewer result: no actionable findings. The review confirmed source-compatible public initializer
shape, bounded `.automatic` plus explicit `.disabled`, conservative directional negotiation,
session-specific burst ownership, schema-v1 preference migration, and SDK/Viewer repository
boundaries.

### Correctness and testing

Findings:

1. Viewer tests exercised the 64-MiB ingress limit before reaching the new 2,048-entry capacity.
2. Configuration tests asserted the automatic preset but did not prove the public default lifecycle
   scheduled recovery after an active transient failure.

Resolution:

- Added `testLiveProjectionAdmitsFullMinimumAccountedIngressCapacity`, which admits 2,048
  minimum-accounted entries and rejects the successor while retaining exact accounting.
- Added `testDefaultConfigurationSchedulesAutomaticRecoveryAfterOneSecond`, which uses the public
  default configuration, observes a one-second recovery delay, and completes a fresh route.

### Security, performance, and documentation

Findings:

1. `SDK-Public-API.md` retained two statements describing automatic recovery as disabled.
2. `Viewer-Event-Explorer.md` retained a former 32-MiB Session-window value.

Resolution:

- Documented default `.automatic` behavior, exact 20-attempt/one-second/30-second values, and
  explicit `.disabled` opt-out consistently.
- Corrected the cross-capability Event Explorer document to the maintained 256-MiB retained window.

## Round 2

All three reviewers confirmed the product code, public API, specifications, tests, and documentation
findings were resolved. Architecture/API and correctness/testing reviewers found one remaining
evidence issue: `implementation-validation.md` still described the pre-fix 554-test run and omitted
the two new focused tests.

Resolution:

- Reran the full Swift Package suite: 555 tests, zero failures.
- Reran the new SDK recovery and Viewer 2,048-entry focused tests: both passed.
- Reran the complete maintained Viewer suite against the final source: exit `0`.
- Updated `implementation-validation.md` with those final results.

## Final fresh review

Architecture/API, correctness/testing, and security/performance/documentation reviewers independently
re-read the final source, specifications, documentation, tests, and corrected evidence. All three
reported no actionable findings. The final review specifically confirmed:

- public source compatibility, bounded automatic recovery, and explicit opt-out;
- conservative rate negotiation, session-specific burst behavior, and unchanged system/control
  bounds;
- directional queue ownership, 2,048-entry/64-MiB ingress, and 256-MiB retained Session bounds;
- exact and idempotent schema-v1 default migration without overwriting custom policy;
- final 555-test package and maintained Viewer evidence, including both post-review regressions;
- truthful documentation and explicit environment-only validation exclusions.
