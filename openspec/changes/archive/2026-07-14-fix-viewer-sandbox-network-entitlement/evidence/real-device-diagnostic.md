# Real-Device Entitlement Diagnostic

Date: 2026-07-15 (Asia/Shanghai)

## Device and Baseline

The connected test device was an iPhone 17 Pro running the maintained NearWire Demo. The original
Viewer build had App Sandbox and network-server entitlements. Bonjour publication succeeded and
the iPhone traffic reached the Mac listener over Wi-Fi, but macOS rejected the accepted flow before
TLS:

```text
nw_path_evaluator_create_flow_inner failed NECP_CLIENT_ACTION_ADD_FLOW
Operation not permitted
Failed to create connection from listener
```

This excluded pairing-code lookup, Bonjour discovery, routing to the Mac, and TLS application logic
as the first failure.

## Controlled Comparisons

Two temporary builds used the same Viewer source, `com.nearwire.viewer` bundle identifier, and Apple
Development signer:

1. App Sandbox disabled: the iPhone connected, TCP completed, and TLS 1.3 negotiated ALPN
   `nearwire/1`.
2. App Sandbox enabled with network-server and network-client entitlements: the iPhone connected
   again without changing application code.

The second trace recorded these decisive transitions:

```text
Listener received new flow
nw_path_evaluator_create_flow_inner Added flow
Handling inbound connection
is accepting an inbound connection
Transport protocol connected (tcp)
TLS connected ... version(0x0304) ... alpn(nearwire/1)
```

The repository owner confirmed that the Demo was connected normally. This proves the narrow
entitlement change while preserving App Sandbox. The temporary applications and live log streams
were closed after the comparison.
