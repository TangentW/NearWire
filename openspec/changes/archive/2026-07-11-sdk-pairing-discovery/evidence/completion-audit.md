# SDK Pairing Discovery Completion Audit

## `sdk-pairing-code`

- Core SPI implements a six-byte canonical code with the fixed 31-character alphabet.
- Raw input examines at most 65 UTF-8 bytes, retains at most six canonical bytes, accepts every documented ASCII separator, and rejects ambiguous, Unicode, control, DEL, and bidi input with non-echoing errors.
- Exact `NearWire-<CODE>` derivation, redacted descriptions/reflection, and memory-only behavior have deterministic coverage.
- Core derives `vid` only through `CryptoKit.SHA256`, matches both golden vectors, retains only 16 lowercase hexadecimal bytes, and documents reset, collision, linkability, and non-authentication semantics.

Status: proven.

## `sdk-bonjour-discovery`

- The production browser has one non-overridable TXT-enabled `_nearwire._tcp` / `local.` descriptor, peer-to-peer inclusion, and a privately owned serial callback queue.
- The coordinator is the sole source of the expected instance name.
- Raw results are rejected above 256 before conversion; interface observations beyond 32 do not affect identity; TXT processing reads only bounded `vid` data.
- Exact attributed, exact unattributed, unrelated/discarded, same-publisher duplicate, distinct-publisher ambiguity, and interface-neutral endpoint behavior have deterministic tests.
- Waiting epochs, duplicate ready, start failure, policy denial, unsolicited cancellation, task cancellation, already-cancelled tasks, repeated run, late callbacks, and cancellation/result races complete exactly once.
- The callback edge and async ingress latch the first terminal, coalesce only the latest complete snapshot, reject late work, and expose fixed candidate and canonical-identity byte bounds.
- Terminal paths close browser callbacks, release handlers, cancel exactly when required, and retain no endpoint or continuation.

Status: proven.

## Modified `sdk-public-boundary`

- Supported NearWire initialization remains side-effect-free.
- The supported application API inventory is unchanged in SwiftPM and CocoaPods.
- Core discovery values require `NearWireInternal` SPI; all Network.framework discovery implementation remains SDK-internal.
- No public connection method or background behavior was added.

Status: proven.

## Documentation and Host Integration

- English SDK documentation defines `NSLocalNetworkUsageDescription`, `NSBonjourServices` with `_nearwire._tcp`, the absence of a multicast entitlement, and the reviewed no-privacy-manifest decision.
- Pairing-code visibility, exact matching, `vid` derivation/linkability/limitations, P2P inclusion, lifecycle, diagnostics, and non-guarantees are explicit.
- The platform architecture contains the normative shared `vid` derivation.
- The roadmap now separates pairing discovery, active session, and connection lifecycle without changing final product scope.

Status: proven.

## Validation and Review

- Focused strict-concurrency tests: 36 passed.
- iOS Simulator full suite: 226 passed.
- macOS Core harness: 165 passed.
- SwiftPM, CocoaPods, API inventory, package parity, module boundary, distribution, structure, English, formatting, version, validation-tool, and OpenSpec gates passed.
- Four post-implementation review rounds resolved every finding; the final architecture, correctness, and security reviews each report zero findings.

Status: proven.

## Audit Conclusion

Every requirement and scenario has implementation, deterministic test, packaging, documentation, validation, and independent review evidence. No task or finding remains unresolved. The change is ready for strict validation, archive, and commit before `sdk-active-session` begins apply.
