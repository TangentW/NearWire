# demo-integration-application Specification

## Purpose
TBD - created by archiving change demo-distribution-e2e. Update Purpose after archive.
## Requirements
### Requirement: Demo owns one explicit SDK and Performance lifecycle

The maintained iOS Demo SHALL create exactly one `NearWire` instance and one
`NearWirePerformanceMonitor` injected with that exact instance. It SHALL inject the same facade into
`NearWireConnectionView`, SHALL NOT use a singleton, and SHALL NOT automatically connect or start
sampling during construction, launch, view appearance, or scene transitions. One MainActor model
SHALL own finite presentation state, at most one Event-loop Task, and at most one Performance-state
Task. Reset SHALL generation-invalidate, cancel, and join both predecessors; stop Performance; await
reusable `disconnect()`; clear state; and install one fresh pair as the only explicit Event-stream
restart. Terminal teardown SHALL join Demo work and stop Performance before synchronous terminal
`shutdown()` without claiming hidden SDK cleanup was awaited. Neither path creates another SDK
instance, and no automatic stream retry is permitted.

#### Scenario: Demo launches

- **WHEN** the Demo application reaches its first rendered surface
- **THEN** it shows the injected connection UI and stopped Performance state
- **AND** no discovery attempt, connection, sampling run, or duplicate facade exists before explicit user action

#### Scenario: Demo resets active work

- **WHEN** the operator resets the Demo while Event observation and Performance are active
- **THEN** the exact monitor and observation Tasks complete cleanup before presentation state clears
- **AND** exactly one fresh Event observer and one fresh Performance-state observer start afterward
- **AND** stale Events or monitor state cannot repopulate the reset model

#### Scenario: Event observation fails and is explicitly restarted

- **WHEN** the Event stream fails or overflows and the operator selects Reset
- **THEN** the failed predecessor is canceled and joined before a fresh stream is acquired
- **AND** repeated or racing Reset actions leave only the newest observer generation active

### Requirement: Demo sends bounded ordinary and latest-value Events

The Demo SHALL send UTF-8-bounded Codable `demo.message` payloads through `.normal` and integer
`demo.counter` payloads through `.keepLatest(key: "demo-counter")`. Input SHALL be validated before
submission and SHALL retain no more than 512 UTF-8 bytes. The UI SHALL present only local
`NearWireSendResult` and `NearWireBufferDiagnostics` meanings and SHALL NOT describe a local enqueue
as transmitted, received, acknowledged, processed, or persisted.

#### Scenario: Message is sent while disconnected

- **WHEN** the operator submits a valid message while the facade is idle or disconnected
- **THEN** the Demo reports the exact local enqueue outcome and refreshes bounded queue diagnostics
- **AND** it makes no remote-delivery claim

#### Scenario: Counter changes repeatedly while offline

- **WHEN** several counter values are submitted with the fixed latest-value key before transport accepts them
- **THEN** the ordinary NearWire queue retains only the current eligible counter Event for that key
- **AND** the Demo reports coalescing from the public send result without retaining predecessor payloads

### Requirement: Viewer controls are decoded, bounded, and causally answered

The Demo SHALL observe the public Event stream and SHALL execute an application control only for a
Viewer-to-App Event of exact type `demo.control.set-banner`. Its Codable payload SHALL contain one
banner no longer than 512 UTF-8 bytes. A valid command SHALL replace the displayed banner and SHALL
use `NearWire.reply` to enqueue `demo.control.result` against the exact source Event. Unknown types,
wrong directions, malformed payloads, and oversized banners SHALL NOT mutate the banner or receive a
reply. The sequential production loop SHALL keep the exact source Event local until evaluation and
reply complete and SHALL stop before Reset completes. The model SHALL retain at most 50 bounded safe
Event summaries and one fixed content-safe stream error; it SHALL NOT retain or log pairing codes,
endpoints, underlying error descriptions, or transport implementation values.

#### Scenario: Viewer sets a valid banner

- **WHEN** a valid `demo.control.set-banner` Viewer Event arrives on the active facade stream
- **THEN** the Demo displays the validated banner and replies with `demo.control.result`
- **AND** the reply uses the source Event's causal identity through the public SDK API

#### Scenario: Viewer sends invalid or unknown control

- **WHEN** an incoming Event has an unknown type, wrong direction, malformed content, or an oversized banner
- **THEN** the Demo records at most one bounded summary without changing the banner
- **AND** it performs no action and sends no reply

#### Scenario: Incoming presentation exceeds its history bound

- **WHEN** more than 50 Events are summarized
- **THEN** only the newest 50 safe summaries remain in deterministic order
- **AND** no hidden unbounded Event-content history is retained

### Requirement: Performance collection is an explicit optional Demo action

The Demo SHALL expose explicit Start and Stop actions for its injected
`NearWirePerformanceMonitor`, SHALL observe its latest-value state, and SHALL label sampling as
ordinary keep-latest Event submission. Start failure SHALL display only the fixed public
`NearWirePerformanceError.message`. Reset and teardown SHALL stop the exact monitor before shutting
down the facade. The Demo SHALL NOT add another timer, collector, queue, transport, persistence path,
or automatic retry around Performance.

#### Scenario: Operator starts and stops Performance

- **WHEN** the operator starts sampling and later stops it
- **THEN** the one monitor transitions through its public states and releases its exact run
- **AND** the Demo creates no second collector or hidden performance queue

#### Scenario: Performance start fails

- **WHEN** the public monitor rejects start
- **THEN** the Demo remains operable and displays only the content-safe public error
- **AND** it does not retry or replace the monitor automatically

### Requirement: Demo owns required host declarations without extra privilege

Both Demo application targets SHALL support iOS 16 in Swift 5 language mode and SHALL use the same
host Info.plist declarations. `NSLocalNetworkUsageDescription` SHALL explain connection to a nearby
NearWire Viewer, and `NSBonjourServices` SHALL contain `_nearwire._tcp`. The Demo SHALL NOT add
multicast, Keychain sharing, background mode, network extension, or another entitlement for NearWire.
It SHALL use distinct internal bundle identifiers for the SwiftPM and CocoaPods products without
changing visible behavior.

#### Scenario: Host declarations are inspected

- **WHEN** each built Demo App's Info.plist and entitlements are inspected
- **THEN** the local-network message and exact Bonjour service are present
- **AND** no unapproved entitlement or package-manager-specific behavior is present

### Requirement: Demo validation uses public product boundaries

The compact Demo unit suite SHALL cover only Demo-owned input limits, control mapping, and bounded
summary presentation. The production Demo driver SHALL call only supported SDK products, and Demo
tests SHALL NOT emulate discovery, TLS, wire negotiation, Viewer storage, queue internals, or
transport. Validation SHALL emphasize building both distribution paths, the existing production
bidirectional SDK/Viewer exchange regression, an iOS Simulator build, and a launch smoke test of the
maintained application surface.

#### Scenario: End-to-end validation runs

- **WHEN** the Demo completion gate executes
- **THEN** both consumer builds, the focused production exchange regression, compact Demo tests, and launch smoke all pass
- **AND** no test-only transport or implementation import is linked into either Demo application product

### Requirement: Demo operation is documented for internal developers

English documentation SHALL explain SwiftPM and CocoaPods builds, pairing with Viewer, ordinary and
latest-value Event semantics, Viewer control payloads and replies, Performance start/stop, buffer
diagnostics, host privacy declarations, local-only delivery meanings, cleanup, and the configured
signing checks deferred to `release-hardening`.

#### Scenario: Developer follows the runbook

- **WHEN** an internal developer opens the root workspace or prepares the CocoaPods consumer path
- **THEN** the documented commands and UI flow identify the correct scheme, target, Event types, and expected Viewer surface
- **AND** the runbook does not claim unsigned evidence proves signed entitlements or stable-signer behavior
