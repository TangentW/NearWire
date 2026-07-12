## MODIFIED Requirements

### Requirement: SwiftPM and CocoaPods expose one supported API

The repository SHALL compile the same representative iOS consumer source against the Swift Package product and CocoaPods default SDK subspec in Swift 5 language mode for iOS 16 or later. Both paths SHALL link the SDK's Apple Security.framework use without requiring a host-facing third-party dependency or supported Security type.

#### Scenario: Consumer compile gate

- **WHEN** distribution validation runs
- **THEN** construction, configuration, connect, public connection errors, state handling, send, decode, reply, streams, diagnostics, and shutdown compile through both integrations

### Requirement: Public API work does not start session features early

NearWire construction and every supported public operation other than connect, shutdown, and active-owner deinitialization SHALL remain side-effect-free with respect to connection ownership. Pairing and connection-limit validation SHALL precede lease claim. Only one token-current explicit connect SHALL claim the lease, access installation identity, discover, open mandatory TLS, perform admission, attach the active pump, publish connection state, and transfer Events. Shutdown and active-owner deinitialization MAY only detach and cancel exact existing ownership and initiate terminal cleanup; they SHALL NOT start or replace a connection. Ordinary Event and observation APIs SHALL NOT implicitly connect.

This change SHALL expose no public disconnect, reconnect, lifecycle observer, terminal-error history, active-pump handle, effective rate, lease, protocol, Network.framework, Security.framework, endpoint, certificate, or Keychain type. Supported signatures SHALL continue to use only standard-library, Foundation, or supported NearWire facade types. Products, targets, pod subspecs, third-party dependencies, entitlements, and privacy declarations SHALL remain unchanged.

#### Scenario: Side-effect audit

- **WHEN** NearWire is constructed and public operations other than connect or exact existing-owner cleanup are exercised
- **THEN** no lease, Keychain, browser, permission request, connection, handshake, pump, lifecycle, or background work begins

#### Scenario: Explicit public connect

- **WHEN** a token-current call invokes connect with valid input
- **THEN** only that operation may compose the reviewed internal discovery, secure admission, and active pump
- **AND** no implementation type enters the supported API
