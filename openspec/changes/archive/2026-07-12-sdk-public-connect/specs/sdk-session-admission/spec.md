## MODIFIED Requirements

### Requirement: Session admission is one explicit internal operation

The SDK SHALL provide one internal App admission actor constructed from validated pairing, validated hello, immutable limits, fixed dependencies, one `SDKSessionTransitionGate` created before run, and an optional content-free async phase observer returning a closed authorization result. Construction SHALL start no work. Public orchestration SHALL pass its attempt gate; an internal caller MAY create one private default gate. One run SHALL perform at most one discovery and secure admission attempt; second run and cancel-before-run SHALL remain deterministic. Existing exact `_nearwire._tcp` local-domain peer-to-peer-enabled discovery, ordered TCP, TLS 1.3, `nearwire/1`, hello, pong, wire, transport, reservation, deadline, and resource validation SHALL remain unchanged.

After exact discovery selection and before core or channel construction, admission SHALL require its current state, absence of Task cancellation, and gate authorization; invoke the observer at most once; then require observer authorization and immediately recheck all three sources. Cancellation latched in the shared gate SHALL prevent core/channel construction even when admission-actor cancellation delivery is delayed. Existing internal callers MAY omit the observer and use an always-authorized gate.

One successful admission SHALL return an admitted owner backed by one `SDKSessionLifetime` containing the existing permanent cancellation relay, exactly one one-shot termination value, and the exact gate supplied before run. The admitted session, any pump attachment, and any active handle SHALL share the same lifetime and SHALL NOT construct another termination or gate. A first terminal wait MAY begin while admitted and remain authoritative through attachment and activation. Task cancellation recorded before admission return and terminal marked before result delivery SHALL therefore retain their true order in one gate.

At the permanent core's exact first terminal transition, before resuming the termination waiter, scheduling channel cleanup, or delivering callbacks, the core SHALL synchronously mark the terminal code in the lifetime gate. The gate SHALL store a pre-registration terminal for a later first wait and SHALL expose the same terminal mark to public active-transfer and connected-commit claims. Async waiter scheduling SHALL NOT define terminal ordering.

#### Scenario: Discovery selects the exact Viewer

- **WHEN** selection wins and observer plus shared gate remain authorized
- **THEN** one connecting phase completes before core and channel construction

#### Scenario: Outer cancellation wins during phase delivery

- **WHEN** shared authorization is revoked while the observer suspends
- **THEN** post-observer validation starts no core, channel, transport, or attachment

#### Scenario: Terminal wait starts before attachment

- **WHEN** public orchestration begins the lifetime's one terminal wait after admission
- **THEN** that same wait observes terminal through later attachment and activation without replacement

#### Scenario: Core terminates before waiter Task resumes

- **WHEN** the core marks terminal and waiter scheduling is delayed
- **THEN** the lifetime gate already rejects later transfer or connected-commit claims with that exact code

#### Scenario: Task cancellation crosses admission result delivery

- **WHEN** Task cancellation and core terminal marking occur on opposite sides of delayed admission-result delivery
- **THEN** their order is the order recorded by the one gate created before admission run
