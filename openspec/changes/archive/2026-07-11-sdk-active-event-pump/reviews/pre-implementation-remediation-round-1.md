# Pre-Implementation Remediation — Round 1

All Round 1 findings were incorporated into the planning artifacts before source apply.

## Cross-Actor Terminal Linearization

- Added one shared lock-protected active-operation gate used at the actual NearWire mailbox/queue/telemetry and event-hub publication boundaries.
- Core terminal cleanup closes the gate synchronously before asynchronous cleanup.
- Defined only two outcomes: complete committed-before-terminal side effect, or terminal-first no mutation.
- Added deterministic barriers and test tasks for both drain and publication orderings.

## Dynamic Policy Atomicity

- Replaced split directional reconfiguration with a bounded FIFO of complete policy transactions.
- Each transaction retains validated values, observation time, and an acceptance intent without encoded `Data`.
- New Event selection pauses while a transaction is pending; old-policy drain/publication work commits tokens at captured selection time first.
- Acceptance bytes enter the mailbox before both buckets reconfigure, and multiple offers apply in exact order.

## Backpressure Progress and Power

- Added a constant-size secure-mailbox capacity snapshot, progress generation, and known-size predicate.
- Blocked results retain candidate ID and exact encoded size but no encoded payload.
- Completion-before-result is closed by an immediate capacity re-snapshot.
- Small Control completions cannot trigger expensive re-encoding until capacity can fit the known size plus reservation.
- Queue mutation uses a cheap next-fair-candidate identity probe before invalidating the block.

## TTL Liveness

- Added queue scheduling observation for the next origin-local expiration deadline and next fair candidate ID.
- Each direction owns one decision wake for the earlier of token availability and TTL; zero rate schedules TTL only.
- Downlink tracks the earliest deadline across the entire FIFO, expires due work in a bounded quantum, and rechecks TTL immediately before publication.

## Policy Consumer Ownership

- Added irreversible unclaimed, attachment-pull, and active-runner ownership.
- A non-pre-cancelled pull claims pull ownership even after immediate completion or later cancellation.
- Runner-versus-pull and post-runner pulls return exact `policyConsumerClaimed`; pre-cancelled pulls retain `pullCancelled` precedence.
- Pending pulls are never stolen or cancelled by runner claim.

## Pump and Observer Lifetime

- Changed the pump to a one-shot starter whose run waits only for initial activation and returns a lifetime handle.
- The handle explicitly cancels on deinit and exposes a separate one-shot termination observer that retains neither handle nor relay.
- Defined exact observer cancellation and second-wait codes without changing core terminal state.
- Pre-registration run cancellation now terminally cancels the attached core without installing work.

## Bounds and Deterministic Coverage

- Added a 2 MiB default/64 MiB hard queue-accounted outbound byte turn bound and compatibility validation against the configured single Event.
- Combined incoming FIFO and in-flight publication under the same count/byte accounting; separately bounded decoder, ingress, and subscriber retention must be audited.
- Added barrier-capable live/test dependencies for drain, publication, gate, mailbox, wake, and completion ordering.
- Expanded tasks for every actor-reentrancy, lost-wake, TTL, ownership, retention, power, and terminal race without sleeps.

Strict OpenSpec validation, English scan, and `git diff --check` pass after remediation.
