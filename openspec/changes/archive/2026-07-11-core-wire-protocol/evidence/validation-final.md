# Core Wire Protocol Final Validation

## Canonical Run

- Run ID: `20260711T001821Z-99496`
- Status: `raw/all-capture-status.log` reports `complete` with exit status 0.
- Source state: captured after all four review rounds, session binding, canonical JSON enforcement, lossless canonical dates, batch hardening, sealed payload APIs, typed golden decode, and isolated fixture-harness support.

Every numbered raw log contains the same run ID, command, UTC timestamps, combined output, and exit status. The all-mode capture verified all nine logs before marking the run complete.

## Raw Evidence Index

| Sequence | Gate | Result |
| ---: | --- | --- |
| 01 | Environment | Xcode 26.6, Swift 6.3.3 toolchain, CocoaPods 1.16.2, OpenSpec 1.2.0; exit 0 |
| 02 | OpenSpec strict validation | Eight change/specification items passed, zero failed; exit 0 |
| 03 | Repository structure | Passed; exit 0 |
| 04 | Mechanical English scan | Passed; exit 0 |
| 05 | Validation-tool mutation tests | Evidence capture, simulator restoration, distribution contract, and validation tools passed; exit 0 |
| 06 | Version agreement | Version 0.1.0 passed; exit 0 |
| 07 | Module and distribution boundaries | Swift imports, package and pod paths/dependencies, and exact manifest contract passed; exit 0 |
| 08 | Swift Package compatibility | iOS/macOS builds, tests, golden fixtures, and sealed public payload API passed; exit 0 |
| 09 | CocoaPods private lint | `NearWire passed validation`; exit 0 |

Authoritative output is stored in `evidence/raw/01-environment.log` through `evidence/raw/09-cocoapods.log`.

## Platform and Test Results

The Swift Package gate compiled every distributed target for `arm64-apple-ios16.0` and every Core target for `arm64-apple-macosx13.0`. Compilation used Swift 5 language mode, complete strict-concurrency diagnostics, and warnings as errors.

- iOS Simulator package suite: 117 passed, 0 failed, 0 skipped.
- macOS Core harness: 114 passed, 0 failed.
- NearWireTransport within the macOS harness: 39 passed, 0 failed.
- The package gate successfully compiled a supported external wire API fixture and proved that an external `WireMessagePayload` conformance cannot compile.
- CocoaPods: Core, default SDK, optional UI, and optional Performance subspec import/build validation passed.

Transport coverage includes exact big-endian framing, byte fragmentation, coalesced frames, empty input, terminal decoder errors, hard and lane limits, truncation, many-frame streaming, canonical and duplicate-key JSON, typed bounded control messages, explicit version/capability/phase admission, V1 codec registration, local-limit monotonicity, Viewer identity binding, version and capability negotiation, acknowledgement anti-escalation, zero-start directional sequence, overflow, plain event content, active model limits, canonical lossless dates, origin and receiver TTL overflow, batch count-before-map, cumulative and exact frame budgets, exact-boundary acceptance, drop summaries, typed checked-in golden fixture encode/decode, and safe error dispositions.

## Expected Tool Notes

CocoaPods emits a public-release URL warning for `https://example.invalid/nearwire`. The reserved non-resolving placeholder is locked by the bootstrap contract and must be replaced by an authorized internal HTTPS location before release. Private lint still compiles and imports every source set and exits 0.

CocoaPods records App Intents metadata extraction lines because the targets do not link AppIntents. They are metadata notes, not Swift compiler warnings, and do not weaken warnings-as-errors.

The mechanical language gate detects CJK scripts; semantic English and documentation accuracy were independently reviewed rather than mechanically assumed.

## Residual Scope Boundaries

- Wire protocol values and session codecs are internal Core infrastructure, not the supported SDK facade.
- Framing and message validation provide no encryption, authentication, certificate trust, discovery, or network connection by themselves.
- V1 provides ordered at-most-once transfer within a live connection, without ACK, retry, persistence, exactly-once, RPC, or cross-session replay guarantees.
- Remaining TTL intentionally starts a receiver-local deadline at receipt and can be extended by network transit duration; unrelated device uptimes are never compared.
- Network.framework transport, TLS identity and trust, Bonjour/P2P discovery, pairing-code admission, connection leases, reconnection, SDK actor/timer ownership, Viewer storage/UI, and performance collection remain later changes.
