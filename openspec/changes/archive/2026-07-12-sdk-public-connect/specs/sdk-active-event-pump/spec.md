## MODIFIED Requirements

### Requirement: Active Event pumping is one explicit internal operation

The active-pump starter SHALL continue to consume exactly one admitted attachment and one NearWire owner, start only through explicit run, and preserve its existing single-run, cancellation, activation, channel, decoder, codec, route, gate, and terminal authority. The admitted attachment, starter, and returned handle SHALL carry the same `SDKSessionLifetime` and exactly one termination value created at admission; the active handle SHALL NOT create a replacement. Existing internal callers that did not start an earlier wait MAY continue waiting through the active handle.

Active binding SHALL capture App maximum directional rates by value before suspension. The permanent core SHALL remove every strong NearWire owner reference. `SDKActiveLiveOperations` SHALL capture NearWire weakly for instance clock, wake registration/removal, scheduling, drain, and incoming publication and SHALL return a closed owner-unavailable outcome when the weak owner is absent. The core SHALL map owner absence to existing `ownerUnavailable`, close the operation gate, and perform terminal cleanup. If NearWire still exists, exact tokenized wake removal remains required; if it has deinitialized, destruction of its actor storage has already released the registration.

No strong path from permanent core, live-operation closures, signal ingress, transport callback, channel, terminal coordinator, or wait Task SHALL reach NearWire. Channel, decoder, route, session codec, cancellation relay, sequence, policy, queue, backpressure, and bounded timer semantics SHALL otherwise remain unchanged.

#### Scenario: Existing internal pump use

- **WHEN** no earlier lifetime terminal wait exists and an internal caller activates a pump
- **THEN** the returned handle exposes the same unused termination value and may wait once as before

#### Scenario: Public owner disappears

- **WHEN** the final NearWire reference is released after activation
- **THEN** weak live operations report owner unavailable, the hidden handle deinitializes and requests cancellation, and the permanent core terminates
- **AND** no strong core-to-owner cycle prevents cleanup

#### Scenario: Wake cleanup observes absent owner

- **WHEN** terminal cleanup runs after NearWire deinitialization
- **THEN** no actor operation is attempted and destroyed owner storage retains no wake registration
