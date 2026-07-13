# Security, Performance, Privacy, and Documentation Implementation Review — Round 3

## SPD-R3-001 — P1 High: terminal overflow permits stale-active session poisoning

The 16-entry terminal map drops a replacement generation's terminal transitions when the prior
projected generation already fills the map. Those replacement sessions can then remain falsely active
and block later capacity. Preserve or authoritatively reconcile terminal state for every projected or
Event-materialized session and add blocked A-end/B-start-and-end/C-start coverage.

## SPD-R3-002 — P1 High: durable change notifications can create unbounded gateway work

Every successful write can schedule a MainActor change task and submit a snapshot operation. Marking
a prior queued gateway operation cancelled does not remove its dictionary record, DispatchQueue
closure, completion, or dispatch-group entry. A blocked reader and high-rate commits can therefore
create notification-proportional memory and shutdown latency.

Add a latest-only change bridge with one in-flight request and one dirty successor, or another
constant-bound admission mechanism. Cover a blocked gateway plus thousands of changes and assert
constant retained work and bounded cleanup.

Cancellation cleanup, privacy, export, packaging, and documentation were otherwise clean. Signing
and embedded-entitlement verification remains explicitly deferred to Goal-level release hardening.

**Unresolved findings: 2**
