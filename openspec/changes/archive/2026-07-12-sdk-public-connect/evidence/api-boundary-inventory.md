# Public API and Boundary Inventory

The supported surface added by this change is `public func connect(code: String) async throws` on the existing instance-based `NearWire` actor, plus fixed `NearWireError.Code` cases needed before success. Existing public state observation reports discovering, connecting, connected, disconnected, and shutdown.

The public SwiftPM consumer fixture compiles connection, state, and error usage in Swift 5 mode for iOS 16. CocoaPods compiles the same source set and consumer contract. API-digester and source-boundary gates prove the public surface does not expose:

- Core, FlowControl, or Transport implementation modules;
- Network.framework connection, listener, parameters, endpoint, or interface types;
- Security identity, certificate, query, or OSStatus types;
- process lease, transition gate, admission, pump, channel, wire codec, or internal limit-plan types.

This change intentionally exposes no disconnect, retry, reconnect, background policy, pairing getter, Viewer identity, effective flow rate, delivery receipt, terminal-error history, or certificate API. Those remain separate lifecycle or Viewer changes.
