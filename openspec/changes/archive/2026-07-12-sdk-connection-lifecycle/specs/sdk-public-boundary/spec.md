## MODIFIED Requirements

### Requirement: SwiftPM and CocoaPods expose one supported API

The repository SHALL compile the same representative iOS consumer source against the Swift Package product and CocoaPods default SDK subspec in Swift 5 language mode for iOS 16 or later. Both paths SHALL link the SDK's Apple Security.framework use without requiring a host-facing third-party dependency or supported Security type.

#### Scenario: Consumer compile gate

- **WHEN** distribution validation runs
- **THEN** construction, configuration including recovery policy, connect, disconnect, suspend, resume, public connection errors and status, state handling, send, decode, reply, streams, diagnostics, and shutdown compile through both integrations

### Requirement: Public API work does not start session features early

NearWire construction and every supported public operation without an explicit connection request or existing lifecycle intent SHALL remain side-effect-free with respect to connection ownership. Pairing and connection-limit validation SHALL precede lease claim. Only one token-current explicit connect or generation-current lifecycle recovery SHALL claim the lease, access installation identity, discover, open mandatory TLS, perform admission, attach the active pump, publish connection state, and transfer Events. Disconnect, suspension, shutdown, and active-owner deinitialization MAY only detach and cancel exact existing ownership and initiate terminal cleanup. Resume MAY start recovery only from an existing non-suspended intent. Ordinary Event and observation APIs SHALL NOT implicitly connect.

This change SHALL expose no active-pump handle, effective rate, lease, protocol, Network.framework, Security.framework, endpoint, certificate, or Keychain type. It SHALL register no automatic UIKit, SwiftUI scene, NotificationCenter, reachability, or background-execution observer. Supported signatures SHALL continue to use only standard-library, Foundation, or supported NearWire facade types. Products, targets, pod subspecs, third-party dependencies, entitlements, and privacy declarations SHALL remain unchanged.

#### Scenario: Side-effect audit

- **WHEN** NearWire is constructed and public operations without a valid explicit request or retained intent are exercised
- **THEN** no lease, Keychain, browser, permission request, connection, handshake, pump, lifecycle observer, or background work begins

#### Scenario: Explicit public connect

- **WHEN** a token-current call invokes connect with valid input
- **THEN** only that operation may compose the reviewed internal discovery, secure admission, and active pump
- **AND** no implementation type enters the supported API

#### Scenario: Lifecycle recovery

- **WHEN** a generation-current retained intent becomes eligible for resume or bounded transient recovery
- **THEN** only one fresh lifecycle attempt may compose the same reviewed pipeline

