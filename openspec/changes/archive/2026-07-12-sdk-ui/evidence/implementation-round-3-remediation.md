# Implementation Round 3 Remediation

Date: 2026-07-12

The architecture/API review identified one medium compatibility issue in the API validation gate. The production UI API and lifecycle architecture required no change.

## Finding and Resolution

The gate required Xcode 26.6-specific synthesized declaration attributes and marker conformances. Those details are not source-authored API and may vary across the declared Xcode 16-or-later range.

The gate now:

- validates the exact two struct declarations, initializer labels and parameter types, body declarations/getters, implicit Body aliases, and source-declared `View` conformance;
- rejects any source-authored public declaration, member, extension, conformance, or attribute outside that contract;
- compares normalized SwiftPM and CocoaPods semantic declaration trees under the same toolchain;
- ignores compiler-synthesized attributes and non-View marker conformances; and
- includes a self-check proving distinct synthesized-marker inventories normalize to the same semantic `View` contract, plus a mutation proving a source-authored attribute is rejected.

This preserves strict source/API coverage without coupling the supported contract to one compiler's synthesized ABI metadata.

## Correctness and Testing Findings

The correctness review found that cross-panel cancellation could revoke the coordinator's origin completion while leaving the initiating model's local token set. The model now reconciles that exact token against the coordinator's locked origin ownership whenever a shared phase arrives. The initiating panel clears its bounded input on shared cancellation and can start the next Connect after both exact operations return. A deterministic two-panel test covers both Connect-first and Disconnect-first completion orders.

The correctness and security reviews also found that unlocked deliveries from concurrent phase mutations could be yielded in reverse order. Every entry now carries a monotonic phase revision. Delivery re-reads the current phase and subscriber snapshot, yields outside the state lock, then repeats if a newer revision raced that yield. A blocking test hook forces Cancelling to publish after Disconnecting and proves the surviving model converges back to the coordinator's current Disconnecting phase while Disconnect remains held. That race passed 100 consecutive runs.

The public replacement scenario now mounts `NearWireConnectionView` in a real platform hosting controller, replaces its injected `NearWire` at the same structural root, and proves the status subscription transfers from A to B. The existing distinct fake-controller test continues to prove stale A status/completion is inert and subsequent actions target only B.

## Security, Resource, and Evidence Findings

The reentrant cancellation observer is now cleared from the test that installs it, and weak probes prove both the fake controller and coordinator release. The public API inventory no longer reports the earlier simulator-service limitation and records the final successful iOS result.

## Round 4 Coalescing Finding

All three Round 4 reviews identified the same medium issue: the latest-value phase stream may legally coalesce a rapid cross-panel Disconnecting-to-Idle transition, while the model previously cleared revoked-origin input/error only after observing Cancelling or Disconnecting. Exact token liveness recovered, but the cancelled code could remain prefilled.

Revoked exact-origin ownership is now the sole clearing condition, independent of which current phase survives latest-value coalescing. A generation-current model with an exact token clears that token, pairing input, and action error whenever the coordinator proves the origin callback was revoked. Normal success/failure remains unchanged because its synchronous origin completion clears the token before the asynchronous phase consumer runs. A behavioral model test starts a real fake-controller Connect, applies coalesced Idle with revoked ownership, proves the model input clears, completes the predecessor, and proves the same model can start exactly one successor Connect.

## Final Validation After Remediation

- Focused UI: 43 passed; final 25 consecutive suites totaling 1,075 test executions; forced reverse-delivery race passed 100 consecutive runs.
- Full macOS: 470 executed, seven existing skips, zero failures.
- Full iOS: 470 total, 466 passed, four existing skips, zero failures.
- Full package, Core harness, TLS integrations, API/boundary consumers, and CocoaPods lint gates passed.
