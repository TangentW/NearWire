# Architecture and API Implementation Review — Round 5

## ARCH-R5-001 — P2 Medium: stale conflict markers survive lifecycle reconciliation

`reconcileDirectObservationSessions` removes conflict markers only for keys returned by the live
window. A durable `journalConflict` removes its transient Event first and retains the key only in the
bounded conflict-marker collection. If the first lifecycle callback later retires that direct-only
session, no resident Event key remains to identify and remove the marker. The stale marker continues
inflating `residentConflictCount` after its session is gone.

Remove every marker whose connection ID belongs to a retired direct-only session, independent of
current Event-window residency. Add an `offer -> journalConflict -> lifecycle transition` regression
that proves the obsolete session, Event, and marker are cleared.

The bounded store-status refresh coordinator and lifecycle-mode switch are otherwise structurally
sound. Focused unsigned regressions pass. Signing and embedded-entitlement verification remains
deferred to Goal-level `release-hardening` and is not a finding.

**Unresolved findings: 1**
