# Core Event Model Final Validation

## Canonical run

- Run ID: `20260710T222748Z-85587`
- Status: `raw/all-capture-status.log` reports `complete` with exit status 0.
- Source state: captured after round-5 audit findings added the final draft and performance-header regressions; round 6 reviews this exact production and test state for archive readiness.

Every numbered raw log contains the same run ID, exact command, UTC timestamps, standard output and error, and exit status. The atomic capture verified all nine logs before marking the run complete.

## Raw evidence index

| Sequence | Gate | Result |
| ---: | --- | --- |
| 01 | Environment | Xcode 26.6, Swift 6.3.3 toolchain, CocoaPods 1.16.2, OpenSpec 1.2.0; exit 0 |
| 02 | OpenSpec strict validation | Four changes/specifications passed, zero failed; exit 0 |
| 03 | Repository structure | Passed; exit 0 |
| 04 | Mechanical language scan | Passed; exit 0 |
| 05 | Validation-tool mutation tests | Evidence capture, simulator restoration, distribution contract, and validation tools passed; exit 0 |
| 06 | Version agreement | Version 0.1.0 passed; exit 0 |
| 07 | Module and distribution boundaries | Swift imports, package and pod paths/dependencies, and exact manifest contract passed; exit 0 |
| 08 | Swift Package compatibility | iOS and macOS builds and tests passed; exit 0 |
| 09 | CocoaPods private lint | `NearWire passed validation`; exit 0 |

Authoritative output is stored in `evidence/raw/01-environment.log` through `evidence/raw/09-cocoapods.log`.

## Platform and test results

The Swift Package gate compiled all distributed targets for `arm64-apple-ios16.0` and every Core target for `arm64-apple-macosx13.0`. Compilation used Swift 5 language mode, complete strict-concurrency diagnostics, and warnings as errors.

- iOS Simulator package suite: 37 passed, 0 failed, 0 skipped.
- macOS Core harness: 34 passed, 0 failed.
- NearWireCore event-model and module suite within the harness: 31 passed, 0 failed.
- CocoaPods: Core, default SDK, optional UI, and optional Performance subspec import/build validation passed.

Coverage includes JSON lexical integer boundaries, decimals and exponents, compact tagged numeric fidelity, deterministic plain JSON, raw and canonical size limits, nesting and collection limits, near-limit many-scalar round trip, aggregate preflight, custom-limit propagation, draft Codable round trip, event namespaces, identities, endpoint roles, origin-clock TTL overflow, causality, envelope ownership and enrichment, missing and unknown envelope fields, required performance headers, performance ranges and units, absent versus zero values, unavailability, unknown enums, and schema-only side-effect boundaries.

## Expected tool notes

CocoaPods emits a public-release URL warning for `https://example.invalid/nearwire`. The reserved non-resolving placeholder is locked by the bootstrap contract and must be replaced by an authorized internal HTTPS location before release. Private lint still compiles and imports all source and exits 0.

CocoaPods records App Intents metadata extraction messages as notes because the targets do not link AppIntents. They are not compiler warnings and do not weaken warnings-as-errors.

The mechanical language gate detects CJK scripts; semantic English and documentation accuracy were independently reviewed rather than claimed as mechanically proven.

## Residual scope boundaries

- Logical Codable models are complete for this change; wire framing and receiver-local TTL establishment remain `core-wire-protocol` work.
- Public declarations support internal cross-module compilation and are not supported SDK facade API.
- The performance snapshot is schema-only; collection, timers, display links, battery monitoring, and transmission remain `sdk-performance` work.
- Queueing, coalescing, rate negotiation, transport, Bonjour, pairing, persistence, and Viewer rendering remain later changes.
