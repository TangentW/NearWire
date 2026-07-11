# Core Transport Security Final Validation

## Canonical Run

- Run ID: `20260711T012245Z-60850`
- Status: `raw/all-capture-status.log` reports `complete` with exit status 0.
- Review state: architecture/API, correctness/concurrency/testing, and security/performance/documentation each reported `ZERO FINDINGS` in the final review round.

Every numbered raw log contains the same run ID, command, UTC timestamps, combined output, and exit status. The all-mode capture verified all nine logs before marking the run complete.

## Raw Evidence Index

| Sequence | Gate | Result |
| ---: | --- | --- |
| 01 | Environment | Xcode 26.6, Swift 6.3.3 toolchain, CocoaPods 1.16.2, OpenSpec 1.2.0; exit 0 |
| 02 | OpenSpec strict validation | Twelve change/specification items passed, zero failed; exit 0 |
| 03 | Repository structure | Passed; exit 0 |
| 04 | Mechanical English scan | Passed; exit 0 |
| 05 | Validation-tool mutation tests | Evidence capture, simulator restoration, distribution contract, and validation tools passed; exit 0 |
| 06 | Version agreement | Version 0.1.0 passed; exit 0 |
| 07 | Module and distribution boundaries | Swift imports, SDK secure-construction scan, package/pod paths, dependencies, and manifest contract passed; exit 0 |
| 08 | Swift Package compatibility | iOS/macOS builds, tests, TLS integrations, and three mandatory-secure compiler boundaries passed; exit 0 |
| 09 | CocoaPods private lint | `NearWire passed validation`; exit 0 |

Authoritative output is stored in `evidence/raw/01-environment.log` through `evidence/raw/09-cocoapods.log`.

## Platform and Test Results

The Swift Package gate compiled every distributed target for `arm64-apple-ios16.0` and every Core target for `arm64-apple-macosx13.0`. Compilation used Swift 5 language mode, complete strict-concurrency diagnostics, and warnings as errors.

- iOS Simulator package suite: 152 passed, 0 failed, 0 skipped.
- macOS Core harness: 149 passed, 0 failed.
- Secure transport focused suites inside the macOS harness: 35 passed, 0 failed.
- Supported external App and Viewer secure API fixtures compiled.
- External raw-parameter and raw-connection attempts failed compilation as expected.
- A CocoaPods-style same-module raw-connection attempt failed compilation as expected.
- SDK source boundaries reject direct connection construction or injected-driver bypasses.
- CocoaPods Core, default SDK, optional UI, and optional Performance subspec validation passed.

Security coverage includes fixed TLS 1.3 bounds, `nearwire/1` ALPN, peer-to-peer routing, caller-owned Viewer identity adaptation, real self-signed trust evaluation, an end-to-end production App/Viewer handshake, TLS 1.2 downgrade rejection, mismatched-ALPN channel rejection, connection-local fingerprinting, fail-closed injected Security paths, callback-once behavior, and source-level private-key lifecycle exclusion.

Channel coverage includes ordered callback ingress, distinct receive-operation tokens, duplicate and replay rejection, one outstanding receive, EOF and anomalous delivery, receive/send/driver failures, FIFO ordering, exact default and hard-bound frame admission, count/byte backpressure, arithmetic overflow, immediate completed-payload release, concurrent sends, synchronous callbacks, late callbacks, cancellation, listener one-shot lifecycle, serial listener delivery on a concurrent target, and atomic listener-close versus incoming-claim contention.

## Expected Tool Notes

CocoaPods emits a public-release URL warning for `https://example.invalid/nearwire`. The reserved non-resolving placeholder is locked by the bootstrap contract and must be replaced by an authorized internal HTTPS location before release. Private lint still compiles and imports every source set and exits 0.

CocoaPods records App Intents metadata extraction lines because the targets do not link AppIntents. They are metadata notes, not Swift compiler warnings, and do not weaken warnings-as-errors.

The mechanical language gate detects CJK scripts; semantic English and documentation accuracy were independently reviewed rather than mechanically assumed.

## Security Guarantees and Residual Scope

Mandatory TLS protects confidentiality and integrity from passive observers. Connection-local anchoring validates certificate structure and time but does not establish a pre-known Viewer identity, so an active local attacker can still impersonate a Viewer with another valid self-signed leaf. V1 intentionally does not persist or compare fingerprints. Pairing codes are not certificate secrets.

This change does not own Viewer identity generation or Keychain lifecycle, Bonjour service attachment or browsing, pairing admission, process connection leases, reconnection, session negotiation orchestration, SDK timers, event persistence, or UI. Those remain later roadmap changes.
