# Core Wire Pre-Handshake Codec Completion Audit

## Fixed V1 Bootstrap Boundary

- `WirePreHandshakeCodec` is immutable, Sendable, repository SPI, and has no caller-selected version, phase, lane, capability set, or raw-message extension point.
- Closed encode overloads admit only hello, safe error, and disconnect through the registered V1 bootstrap envelope.
- A hello may advertise a wider interval without changing the bootstrap envelope.
- The sealed Sendable result contains only fully validated hello, safe-error, or disconnect models.

Status: proven by source inspection, deterministic byte tests, typed round trips, compile-time Sendable checks, and SPI consumer failures.

## Decode Order and Failure Safety

- Event-lane preflight rejects before JSON or version parsing.
- Control frames parse and validate version before requiring or interpreting V1 type, required lane, or body fields.
- Version zero yields terminal invalid configuration; a nonzero non-V1 version yields terminal incompatible version.
- Mixed-invalid future frames prove precedence over missing fields, invalid type, required-lane conflict, and invalid allowed payload bodies.
- V1 admission has exact phase or capability outcomes for every known disallowed type and unknown Control types.
- Allowed messages return no typed value until their complete bounded payload model succeeds.

Status: proven by exact terminal-code tests and direct raw, bootstrap, and negotiated-session regression coverage.

## Bounds, Determinism, and Retention

- Direct frame payloads are checked against their lane limit before JSON materialization.
- Canonical deterministic JSON is required; malformed, noncanonical, direct duplicate, and escaped-equivalent duplicate inputs fail terminally.
- Tight control-text and collection limits reject over-limit hello, error, and disconnect bodies.
- The codec stores only validated immutable limits and retains no message, frame, application content, closure, continuation, task, timer, or endpoint identity.

Status: proven by exact-byte, malformed-input, limit, Mirror shape, and full regression tests.

## Negotiation and Session Handoff

- V1 hello exchange feeds `WireNegotiator` and a registered V1 `WireSessionCodec`.
- Bootstrap-decoded 1...2 and 1...3 intervals select version 2, after which session activation fails because no V2 session codec is registered.
- `WireSessionCodec` now uses the same early expected-version guard, preserving terminal version-confusion prevention after negotiation.

Status: proven by end-to-end in-memory negotiation tests without network, timers, tasks, or sleeps.

## Distribution and Scope

- Normal SwiftPM and CocoaPods consumers cannot name the pre-handshake codec or typed result.
- Supported SDK API inventories match and expose no raw wire, payload, admitted-message, or pre-handshake type.
- Package products, targets, dependencies, pod subspecs, supported SDK signatures, entitlements, and privacy declarations are unchanged.
- The implementation remains platform-neutral Core and adds no SDK session, network operation, TLS action, process lease claim, discovery, Viewer approval, route, flow policy, event transfer, persistence, Keychain access, or UI.

Status: proven by strict iOS/macOS builds, consumer negative fixtures, API digests, package and pod boundaries, CocoaPods lint, and source audit.

## Validation and Review

- Focused protocol suites: 22 passed, 0 failed.
- Full local Swift suite: 256 passed, 0 failed; five existing restricted-environment Network/Trust skips were separately covered by the unrestricted package gate.
- iOS Simulator package suite: 256 passed, 0 failed, 0 skipped.
- macOS Core harness: 175 passed, 0 failed, 0 skipped.
- CocoaPods lint passed for all subspec paths.
- OpenSpec, structure, boundaries, English, version, validation-tool, formatting, and whitespace gates passed.
- Three pre-apply review rounds and four post-implementation review rounds completed. The third round confirmed the corrected archive-merge delta and found only stale evidence wording. After remediation, the fourth round reported zero findings across architecture, correctness, and security dimensions.

Status: proven.

## Audit Conclusion

Every requirement and scenario has current implementation, deterministic test, packaging, documentation, validation, and independent review evidence. No implementation, specification, validation, product-scope, or review issue remains unresolved. The change is ready for strict validation, archive, and commit before SDK session-admission apply begins.
