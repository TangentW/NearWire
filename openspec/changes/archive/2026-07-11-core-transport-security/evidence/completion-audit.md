# Core Transport Security Completion Audit

## Audit Basis

- Canonical validation run: `20260711T012245Z-60850`
- Canonical capture status: complete, exit 0
- Automated platform results: iOS 152/152; macOS Core 149/149; secure transport focused suites 35/35
- OpenSpec capabilities: secure network parameters, Viewer TLS identity, and secure byte channel
- Final independent review gate: architecture/API, correctness/concurrency/testing, and security/performance/documentation all reported `ZERO FINDINGS`

## Requirement-to-Evidence Matrix

| Requirement | Implementation and test evidence | Result |
| --- | --- | --- |
| Mandatory encrypted transport | Role-specific Network.framework parameters always combine ordered TCP and TLS; supported factories expose no plaintext switch | Proven |
| Fixed TLS policy | TLS 1.3 minimum and maximum, only `nearwire/1` ALPN, runtime metadata validation, P2P routing | Proven |
| App and Viewer integration entry points | App channel factory and identity-required hidden Viewer listener with one-shot incoming wrappers | Proven |
| No raw construction bypass | File-private raw connection initializer, external negative fixtures, same-module CocoaPods negative fixture, SDK source scan | Proven |
| Coherent hard bounds | Validated receive, pending-count, pending-byte, single-send, and timeout limits; complete wire frames include five overhead bytes | Proven |
| Caller-owned Viewer identity | `SecIdentity` adaptation only; no key generation, Keychain mutation, export, logging, or persistence | Proven |
| Connection-local App trust | Presented leaf required, Basic X.509, leaf-only anchor, Security evaluation, fail-closed completion | Proven |
| Accurate security claim | Documentation separates passive-observer protection from absent pre-established Viewer authentication | Proven |
| Serial bounded receive | One active receive token, ordered callback ingress, duplicate/replayed callback rejection, bounded chunks | Proven |
| Bounded FIFO send | Atomic count/byte admission, one in flight, overflow safety, exact order, immediate payload release | Proven |
| Terminal fault behavior | One terminal outcome, idempotent cancel, late-callback rejection, no retry/reconnect or underlying private error | Proven |
| Listener lifecycle | Single start, serial callbacks even with concurrent target, one cancellation, atomic close versus channel claim | Proven |
| Platform and distribution compatibility | Swift 5 mode, iOS 16, macOS 13, Xcode 16-era APIs, strict concurrency, SwiftPM and CocoaPods | Proven |

## Review History

Round 1 identified completed-send payload retention, missing five-byte frame overhead, an unusable Viewer role entry point, CocoaPods same-module raw wrapping, duplicate receive callback races, unordered callback tasks, insufficient TLS wiring coverage, a live-trust skip false negative, missing receive/late-send faults, and stale evidence. Optional queue slots, exact frame limits, a hidden secure Viewer listener, file-private construction and compiler gates, receive tokens, ordered ingress, real TLS tests, independent trust capability probing, new fault regressions, and recaptured evidence resolved them.

Round 2 identified a listener-close versus incoming-claim time-of-check race, potentially concurrent listener events, a newer-SDK ALPN symbol outside the Xcode 16 baseline, and overly permissive negative-handshake expectations. A gate-protected claim/construction operation, private serial listener queue, Xcode 16-era metadata getter, and outcome-specific TLS/ALPN tests resolved them.

Round 3 found that the first admission-race regression exercised a sibling helper rather than the production primitive and did not synchronize at the close lock boundary. The duplicate helper was removed; production and test now share `withOpenClaim`, and the barrier test holds the real claim while a close is released to contend at the exact pre-lock boundary.

Round 4 independently reported zero findings in all three review dimensions.

## Expected Notes and Residual Scope

The CocoaPods `example.invalid` warning and App Intents metadata notes are expected bootstrap artifacts described in `validation-final.md`.

Discovery, pairing, leases, reconnect orchestration, the SDK public facade, Viewer identity persistence, event storage, and UI remain outside this transport-security change. Connection-local trust is deliberately not claimed as strong active-attacker authentication.

## Decision

Every normative requirement and scenario has implementation, automated validation, English documentation, canonical evidence, and independent zero-finding review coverage. The change is ready for strict validation, archive into baseline specifications, archive validation, and commit before `sdk-public-api` enters apply.
