# Core Flow Control Final Validation

## Canonical run

- Run ID: `20260710T232302Z-39035`
- Status: `raw/all-capture-status.log` reports `complete` with exit status 0.
- Source state: captured after queue indexing, safe delay, scheduler composition, canonical documentation, hard-bound stress, burst reconfiguration, and the round-3 expiration-only zero-token path.

Every numbered raw log contains the same run ID, command, UTC timestamps, combined output, and exit status. The all-mode capture verified all nine logs before marking the run complete.

## Raw evidence index

| Sequence | Gate | Result |
| ---: | --- | --- |
| 01 | Environment | Xcode 26.6, Swift 6.3.3 toolchain, CocoaPods 1.16.2, OpenSpec 1.2.0; exit 0 |
| 02 | OpenSpec strict validation | Six change/specification items passed, zero failed; exit 0 |
| 03 | Repository structure | Passed; exit 0 |
| 04 | Mechanical English scan | Passed; exit 0 |
| 05 | Validation-tool mutation tests | Evidence capture, simulator restoration, distribution contract, and validation tools passed; exit 0 |
| 06 | Version agreement | Version 0.1.0 passed; exit 0 |
| 07 | Module and distribution boundaries | Swift imports, package and pod paths/dependencies, and exact manifest contract passed; exit 0 |
| 08 | Swift Package compatibility | iOS and macOS builds and tests passed; exit 0 |
| 09 | CocoaPods private lint | `NearWire passed validation`; exit 0 |

Authoritative output is stored in `evidence/raw/01-environment.log` through `evidence/raw/09-cocoapods.log`.

## Platform and test results

The Swift Package gate compiled all distributed targets for `arm64-apple-ios16.0` and every Core target for `arm64-apple-macosx13.0`. Compilation used Swift 5 language mode, complete strict-concurrency diagnostics, and warnings as errors.

- iOS Simulator package suite: 79 passed, 0 failed, 0 skipped.
- macOS Core harness: 76 passed, 0 failed.
- NearWireFlowControl suite within the harness: 43 passed, 0 failed.
- NearWireCore event-model suite within the harness: 31 passed, 0 failed.
- CocoaPods: Core, default SDK, optional UI, and optional Performance subspec import/build validation passed.

Flow-control coverage includes queue configuration hard bounds, Unicode key controls, critical priority, distinct and keep-latest admission, stale admission, duplicate IDs, TTL reset and exact expiration IDs, overflow order, byte accounting, clock reversal, clear reasons, weighted cross-call fairness, promotion and demotion, heap compaction, 10,000-entry fill and single-event drain, directional negotiation, minimum and maximum rates, pause and resume, fractional refill, safe next-token delay, burst reconfiguration, scheduler configuration binding, exact token use, count and byte limits, paused and empty attempts, expiration-only attempts, 2,000 one-event scheduled flushes, and 1,000 paused flushes at the 10,000-entry hard bound.

## Expected tool notes

CocoaPods emits a public-release URL warning for `https://example.invalid/nearwire`. The reserved non-resolving placeholder is locked by the bootstrap contract and must be replaced by an authorized internal HTTPS location before release. Private lint still compiles and imports all source and exits 0.

CocoaPods records App Intents metadata extraction messages as notes because the targets do not link AppIntents. They are not compiler warnings and do not weaken warnings-as-errors.

The mechanical language gate detects CJK scripts; semantic English and documentation accuracy remain independently reviewed rather than mechanically proven.

## Residual scope boundaries

- Flow control is internal Core infrastructure, not supported SDK facade API.
- It buffers only in memory and creates no delivery, acknowledgement, retry, persistence, or remote-processing guarantee.
- Accounted bytes come from the owning layer; the future wire encoder must enforce its own frame limit.
- Session epoch, sequence allocation, wire framing, receiver-local TTL establishment, Bonjour, P2P transport, pairing, and control-lane policy remain later changes.
- SDK actor ownership, timers, offline retention policy, Viewer storage, UI, and performance collection remain later changes.
