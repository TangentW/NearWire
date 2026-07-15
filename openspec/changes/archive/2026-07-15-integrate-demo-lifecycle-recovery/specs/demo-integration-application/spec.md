## MODIFIED Requirements

### Requirement: Demo owns one explicit SDK and Performance lifecycle

The maintained iOS Demo SHALL create exactly one `NearWire` instance configured with an enabled bounded recovery policy of six total attempts, a 500-millisecond initial delay, and a four-second maximum delay, plus one `NearWirePerformanceMonitor` injected with that exact instance. It SHALL inject the same facade into `NearWireConnectionView`, SHALL NOT use a singleton, and SHALL NOT automatically perform an initial connection or start sampling during construction, launch, view appearance, or scene transitions.

The Demo SHALL forward SwiftUI background phase to `suspendConnection()` and active phase to `resumeConnection()` through one structured scene-owned task; inactive phase SHALL perform no lifecycle action. With no retained active connection intent, active phase SHALL start no discovery or connection work. After an explicit successful connection, foreground recovery MAY use the retained in-memory intent and the configured bounded policy. Explicit Disconnect, Reset, teardown, permanent failure, retry exhaustion, and process termination SHALL retain their existing intent-clearing boundaries and SHALL NOT reconnect without a new explicit code.

One MainActor model SHALL own finite presentation state, at most one Event-loop Task, and at most one Performance-state Task. Reset SHALL generation-invalidate, cancel, and join both predecessors; stop Performance; await reusable `disconnect()`; clear state; and install one fresh pair as the only explicit Event-stream restart. Terminal teardown SHALL join Demo work and stop Performance before terminal shutdown. Neither path creates another SDK instance, and the Demo SHALL add no independent retry Task, App lifecycle observer, background execution request, or persisted recovery state.

#### Scenario: Demo launches

- **WHEN** the Demo application reaches its first active rendered surface with no retained connection intent
- **THEN** it shows the injected connection UI and stopped Performance state
- **AND** the active-scene resume is a no-op that starts no discovery, connection, sampling run, or duplicate facade

#### Scenario: Connected Demo enters background and returns active

- **WHEN** the Demo has an explicitly connected intent, enters background, and later becomes active while the process remains alive
- **THEN** it asks the SDK to suspend the old route and resume with a fresh bounded route
- **AND** eligible Events still in the SDK's bounded offline queue may drain through the fresh session without reusing old accepted bytes, epoch, sequence, or Viewer capability

#### Scenario: Operator disconnects before a later active transition

- **WHEN** the operator explicitly disconnects or resets the Demo and the scene later becomes active
- **THEN** no retained intent exists and no automatic connection starts
- **AND** another pairing code is required for the next explicit connection

#### Scenario: Scene becomes inactive without entering background

- **WHEN** a system interruption changes the Demo scene only to inactive
- **THEN** the Demo performs no suspend, resume, disconnect, or recovery action
- **AND** the existing route remains under SDK transport ownership

### Requirement: Demo validation uses public product boundaries

The compact Demo unit suite SHALL cover only Demo-owned input limits, control mapping, bounded summary presentation, and forwarding of scene lifecycle to the supported SDK facade. It SHALL NOT emulate discovery, TLS, wire negotiation, Viewer storage, queue internals, or transport. Validation SHALL include the focused production lifecycle regressions proving that an Event queued while suspended drains on a fresh resumed SDK route and that a Viewer exact-route replacement accepts a fresh-epoch Event, plus both consumer builds and a launch smoke test.

#### Scenario: Background recovery validation runs

- **WHEN** the Demo completion gate executes
- **THEN** lifecycle forwarding, fresh-route buffered Event drain, Viewer replacement Event acceptance, the compact Demo suite, and the supported build paths pass
- **AND** no test-only transport or implementation import is linked into either Demo application product

### Requirement: Demo operation is documented for internal developers

English documentation SHALL explain SwiftPM and CocoaPods builds, pairing with Viewer, ordinary and latest-value Event semantics, Viewer control payloads and replies, Performance start/stop, buffer diagnostics, host privacy declarations, local-only delivery meanings, cleanup, configured signing checks, and background recovery. It SHALL state that iOS may end the route after suspension, NearWire recovers only while the process remains alive and runnable, recovery is bounded, and no background mode or process-termination recovery is provided.

#### Scenario: Developer follows the background recovery runbook

- **WHEN** an internal developer connects the Demo, backgrounds it long enough for the route to end, and returns it active
- **THEN** the documentation identifies the expected suspended/reconnecting/connected states and fresh-session Event behavior
- **AND** it does not claim continuous background networking, remote delivery acknowledgement, process-termination recovery, or persisted pairing state
