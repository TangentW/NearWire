## Context

The Viewer uses one peer-to-peer-enabled `NWListener` that publishes `_nearwire._tcp`, accepts an
incoming `NWConnection`, and performs mandatory TLS 1.3. The committed sandbox profile contains
only `com.apple.security.network.server`. On macOS 26.5, real iPhone traffic reaches the listener,
but the accepted flow fails at `NECP_CLIENT_ACTION_ADD_FLOW` with `Operation not permitted` before
the connection callback or TLS handshake.

Two temporary builds using the same code, bundle identifier, and signing identity isolated the
permission boundary:

- disabling App Sandbox allowed the incoming flow and TLS handshake;
- restoring App Sandbox and adding `com.apple.security.network.client` also allowed the incoming
  flow and TLS handshake.

## Decision

Keep App Sandbox enabled and add `com.apple.security.network.client` beside the existing
`com.apple.security.network.server` entitlement. Treat both as required packaging metadata for the
current Network.framework listener and accepted-connection path.

Update the existing running-process entitlement test rather than adding a source-text assertion.
The test will require sandbox, server, and client entitlements from the signed test host and will
continue to prove that multicast, Keychain-sharing, and application-group entitlements are absent.

## Alternatives Considered

### Disable App Sandbox

Rejected. It makes the connection work but removes a useful Viewer security boundary and grants a
much broader effective capability than the observed failure requires.

### Keep only the network-server entitlement

Rejected. That is the current configuration and the real-device accepted flow is denied by NECP
before TLS.

### Change Bonjour, TLS, or pairing logic

Rejected. Discovery, TCP arrival, pairing-code selection, and TLS configuration were all present
in the diagnostic traces. The failure was an entitlement decision before application admission.

## Security and Compatibility

The network-client entitlement permits outbound connections from the sandbox, but this change
adds no outbound Viewer code path or endpoint selection. Existing TLS-only transport, admission
bounds, and Bonjour metadata remain unchanged. The entitlement is available across the supported
macOS 13 deployment range and does not affect Swift language or package compatibility.

## Verification

- Strictly validate the OpenSpec artifacts before implementation.
- Run the focused signed-process entitlement test and the complete Viewer test suite.
- Build a signed Viewer and inspect its embedded entitlements and packaged local-network metadata.
- Record the real-device A/B evidence showing NECP flow creation and TLS 1.3 completion with the
  exact sandbox profile.
- Run independent architecture/API, correctness/testing, and
  security/performance/documentation reviews to a zero-finding final round.
